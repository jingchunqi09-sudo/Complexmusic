`timescale 1ns/1ps
// All raw scans are consumed. GROUP_SCANS=4 takes a directional envelope
// over four scan phases, then votes across groups in this string slot.
// max(samples)>=threshold is exactly OR(sample>=threshold); low uses min.
// This is a declared algorithm change from voting on isolated raw samples.
module left_hand_slot_evidence #(
    parameter integer GROUP_SCANS=4, PRESS_PERCENT=71, RELEASE_PERCENT=60,
    parameter integer DIRECTION_LOW=0, MAX_SCANS=512,
    // ---- R12 差分判据（USE_DIFF=1 生效，置 0 回到绝对阈值老路）----
    // 绝对阈值判不了弱格：实测按压平台 399~586 码，而静止采集里有 812 码的
    // **共模**尖峰——阈值取低于 812 就误报，高于 586 就漏弱格，无解。
    // 改用 (peak - s2)：共模让 16 通道一起抬，(peak-s2) 基本不动
    // （实测静止 p99=62；注入共模漂移 ±500 码后最大值仍是 67，与干净时相同）；
    // 单格按压只抬一格，s2 不动，(peak-s2) ≈ 该格幅度（弱格 399 也能过 120）。
    // 只求"最大/次大"，不求跨通道最小值——后者被 Gowin SP00018 拒绝过。
    // 独立综合验证：LUT 1013 / ALU 89 / REG 37 / DSP 0 / BSRAM 0。
    parameter integer USE_DIFF=1,
    parameter integer T_DIFF=120,
    parameter [767:0] THRESHOLD_CODES={4{{15{12'd3227}},12'd3910}}
)(
    input wire clk_50m,reset,
    input wire [191:0] snapshot, input wire snapshot_valid,
    input wire [1:0] snapshot_string,
    input wire slot_valid, input wire [1:0] slot_string,
    input wire [15:0] slot_sample_count,
    output reg [15:0] evidence, output reg evidence_valid,
    output reg [1:0] evidence_string,
    output reg [15:0] used_samples, used_groups,
    output reg fault, output wire [3:0] fault_mask
);
    // 16-bit counters cover the bounded scan count without wrapping. These
    // counters are shared between slots; there is no 300x16 raw data buffer.
    // R18：16 路次大值归约流水化。
    // 打开 USE_DIFF 后，snapshot → 4 层 24 位比较器 → svroot 变成关键路径
    // （r18 PnR：Fmax 35.3 MHz / setup -8.301 / 393 条违例）。
    // snapshot 间隔 ≥16 拍（PROCESS 要逐拍右移 16 个通道），所以完全放得下
    // 4 拍流水：S2A 算 8 个 pair、S2B 算 4 个 q、S2C 算 2 个 r、S2D 出 root。
    // 每拍只做一层比较，路径从 20+ 级降到 ~6 级。
    localparam IDLE=0, S2A=1, S2B=2, S2C=3, S2D=4, PROCESS=5, FINISH=6;
    reg [2:0] state;
    reg [23:0] pr[0:7];
    reg [23:0] qr[0:3];
    reg [23:0] rr0, rr1;
    reg [191:0] frame;
    reg [3:0] channel;
    reg [1:0] active_string;
    reg active;
    reg [15:0] scans,groups,group_position;
    reg [15:0] rail_scans;
    reg [3:0] slot_faults;
    assign fault_mask=slot_faults;
    reg [15:0] group_hits;
    reg [15:0] hits [0:15];
    reg [63:0] previous_evidence;
    reg end_pending;
    reg [1:0] end_string;
    reg [15:0] end_samples;
    reg slot_bad;

    // ---------------- R12：16 通道双最大归约（peak, s2） ----------------
    // 只用于差分判据；snapshot 每个扫描有效一次，此处为纯组合。
    function [23:0] lh_pair2;
        input [11:0] a;
        input [11:0] b;
        begin lh_pair2 = (a > b) ? {a, b} : {b, a}; end
    endfunction
    function [23:0] lh_merge2;
        input [23:0] A;
        input [23:0] B;
        reg [11:0] a1, a2, b1, b2, m1, lo, h2, m2;
        begin
            a1 = A[23:12]; a2 = A[11:0];
            b1 = B[23:12]; b2 = B[11:0];
            m1 = (a1 > b1) ? a1 : b1;
            lo = (a1 > b1) ? b1 : a1;
            h2 = (a2 > b2) ? a2 : b2;
            m2 = (lo > h2) ? lo : h2;
            lh_merge2 = {m1, m2};
        end
    endfunction
    // ch5 未接铜极（固定电平），按 0 参与归约，永远不会成为最大或次大
    wire [11:0] sv0  = snapshot[11:0];
    wire [11:0] sv1  = snapshot[23:12];
    wire [11:0] sv2  = snapshot[35:24];
    wire [11:0] sv3  = snapshot[47:36];
    wire [11:0] sv4  = snapshot[59:48];
    wire [11:0] sv5  = 12'd0;
    wire [11:0] sv6  = snapshot[83:72];
    wire [11:0] sv7  = snapshot[95:84];
    wire [11:0] sv8  = snapshot[107:96];
    wire [11:0] sv9  = snapshot[119:108];
    wire [11:0] sv10 = snapshot[131:120];
    wire [11:0] sv11 = snapshot[143:132];
    wire [11:0] sv12 = snapshot[155:144];
    wire [11:0] sv13 = snapshot[167:156];
    wire [11:0] sv14 = snapshot[179:168];
    wire [11:0] sv15 = snapshot[191:180];
    wire [23:0] svp01 = lh_pair2(sv0,  sv1);
    wire [23:0] svp23 = lh_pair2(sv2,  sv3);
    wire [23:0] svp45 = lh_pair2(sv4,  sv5);
    wire [23:0] svp67 = lh_pair2(sv6,  sv7);
    wire [23:0] svp89 = lh_pair2(sv8,  sv9);
    wire [23:0] svpab = lh_pair2(sv10, sv11);
    wire [23:0] svpcd = lh_pair2(sv12, sv13);
    wire [23:0] svpef = lh_pair2(sv14, sv15);
    wire [23:0] svq0 = lh_merge2(svp01, svp23);
    wire [23:0] svq1 = lh_merge2(svp45, svp67);
    wire [23:0] svq2 = lh_merge2(svp89, svpab);
    wire [23:0] svq3 = lh_merge2(svpcd, svpef);
    wire [23:0] svr0 = lh_merge2(svq0, svq1);
    wire [23:0] svr1 = lh_merge2(svq2, svq3);
    wire [23:0] svroot = lh_merge2(svr0, svr1);
    wire [11:0] snap_s2 = svroot[11:0];

    // 次大值在 IDLE 锁存：PROCESS 里 frame 逐拍右移，届时已拿不到全通道
    reg [11:0] s2_hold;
    wire [11:0] t_diff_w = T_DIFF;
    wire [12:0] diff_need_ext = {1'b0, s2_hold} + {1'b0, t_diff_w};
    wire [11:0] diff_need = diff_need_ext[12] ? 12'hFFF : diff_need_ext[11:0];

    wire [5:0] address={active_string,channel};
    wire [11:0] threshold=THRESHOLD_CODES[address*12 +:12];
    // THRESHOLD_CODES 填 0 = 停用该格（PC 工具语义），两种模式都保留
    wire cell_enabled = (threshold != 0);
    wire hit_abs = cell_enabled &&
        (DIRECTION_LOW ? frame[11:0] <= threshold : frame[11:0] >= threshold);
    wire hit_diff = cell_enabled && (channel != 4'd5) &&
        (frame[11:0] != 12'd0) && (frame[11:0] >= diff_need);
    wire hit = USE_DIFF ? hit_diff : hit_abs;
    wire combined_hit=group_hits[channel] | hit;
    wire full_group=(group_position==GROUP_SCANS-1);
    wire [16:0] final_groups={1'b0,groups}+((group_position!=0)?17'd1:17'd0);
    wire [16:0] final_hits={1'b0,hits[channel]}+
        ((group_position!=0 && group_hits[channel])?17'd1:17'd0);
    // Constant shift/add products avoid a runtime divider or a DSP macro.
    function [23:0] percent_product;
        input [16:0] value;
        input integer percent;
        integer bit_number;
        begin
            percent_product=0;
            for(bit_number=0;bit_number<7;bit_number=bit_number+1)
                if((percent>>bit_number)&1)
                    percent_product=percent_product+({7'd0,value}<<bit_number);
        end
    endfunction
    wire [23:0] numerator=percent_product(final_hits,100);
    wire [23:0] press_limit=percent_product(final_groups,PRESS_PERCENT);
    wire [23:0] release_limit=percent_product(final_groups,RELEASE_PERCENT);
    wire old_active=previous_evidence[address];
    wire final_hit=(threshold!=0 && final_hits!=0) &&
        (old_active ? numerator>=release_limit : numerator>=press_limit);
    wire slot_healthy=active && !slot_bad && active_string==end_string &&
        scans!=0 && scans==end_samples && scans<=MAX_SCANS && rail_scans!=scans;
    // R13：选品与"槽完整性"解耦。
    // `scans` 是本模块数的 snapshot_valid 次数，`end_samples` 是 adapter 在 slot_valid
    // 时刻锁存的 slot_sample_count，两者计数起点天然可能差 1 拍。强制逐拍相等会让
    // 整弦永久 fault：slot_faults -> decoder 的 valid_mask=0 -> note_bus 不更新、
    // R9 屏幕的琴颈高亮条件 (!i_left_fault) 不成立 -> 表现就是"按品不亮"，
    // 而且 press/release 百分比在共模/fault 之后才生效，调它永远无效。
    // 现在：完整性只用于 fault 上报（屏幕诊断），选品只看"这一槽到底有没有测到"。
    // 仍然拒绝：从未收到快照、槽坏、字符串错配、超限、整槽 rail。
    wire select_ok=active && !slot_bad && active_string==end_string &&
        scans!=0 && scans<=MAX_SCANS && rail_scans!=scans;
    integer ch;
    always @(posedge clk_50m)begin
        evidence_valid<=0;
        if(reset)begin
            state<=IDLE;frame<=0;channel<=0;active_string<=0;active<=0;
            scans<=0;groups<=0;group_position<=0;group_hits<=0;
            rail_scans<=0;slot_faults<=0;
            previous_evidence<=0;end_pending<=0;end_string<=0;end_samples<=0;
            evidence<=0;evidence_string<=0;used_samples<=0;used_groups<=0;
            fault<=0;slot_bad<=0;s2_hold<=0;
            for(ch=0;ch<16;ch=ch+1)hits[ch]<=0;
        end else begin
            if(slot_valid)begin
                end_pending<=1;end_string<=slot_string;end_samples<=slot_sample_count;
                if(end_pending)begin fault<=1;slot_bad<=1;end
            end
            case(state)
                IDLE:begin
                    if(end_pending)begin channel<=0;state<=FINISH;end
                    else if(snapshot_valid)begin
                        frame<=snapshot;channel<=0;
                        // R19：归约流水只在差分模式下需要。USE_DIFF=0（R8 的绝对阈值
                        // 判据）时直接进 PROCESS，保持 R8 的槽对齐时序——否则会平白
                        // 多 4 拍，slot_valid 在 S2A..S2D 期间到来只能推迟一拍处理。
                        state<=USE_DIFF ? S2A : PROCESS;
                        // This AFE is biased near VCM. A whole slot of frames
                        // with all 16 ADCs at either rail is invalid evidence,
                        // not a confirmed idle fingerboard. Individual rails
                        // remain legal samples and are covered by the tests.
                        if(snapshot==192'd0 || snapshot=={192{1'b1}})
                            rail_scans<=rail_scans+1'b1;
                        if(!active)begin active<=1;active_string<=snapshot_string;end
                        else if(active_string!=snapshot_string)begin fault<=1;slot_bad<=1;end
                    end
                end
                // ---- 16 路次大值归约，一拍一层 ----
                S2A:begin
                    pr[0]<=lh_pair2(sv0, sv1);  pr[1]<=lh_pair2(sv2, sv3);
                    pr[2]<=lh_pair2(sv4, sv5);  pr[3]<=lh_pair2(sv6, sv7);
                    pr[4]<=lh_pair2(sv8, sv9);  pr[5]<=lh_pair2(sv10,sv11);
                    pr[6]<=lh_pair2(sv12,sv13); pr[7]<=lh_pair2(sv14,sv15);
                    state<=S2B;
                end
                S2B:begin
                    qr[0]<=lh_merge2(pr[0],pr[1]); qr[1]<=lh_merge2(pr[2],pr[3]);
                    qr[2]<=lh_merge2(pr[4],pr[5]); qr[3]<=lh_merge2(pr[6],pr[7]);
                    state<=S2C;
                end
                S2C:begin
                    rr0<=lh_merge2(qr[0],qr[1]); rr1<=lh_merge2(qr[2],qr[3]);
                    state<=S2D;
                end
                S2D:begin
                    // lh_merge2 返回 24 位 {max, second}，s2_hold 是 12 位，
                    // 直接赋值即取低 12 位 = second（Verilog 不允许对函数结果做 part-select）
                    s2_hold<=lh_merge2(rr0,rr1);
                    state<=PROCESS;
                end
                PROCESS:begin
                    if(full_group)begin
                        hits[channel]<=hits[channel]+combined_hit;
                        group_hits[channel]<=0;
                    end else group_hits[channel]<=combined_hit;
                    if(channel==15)begin
                        if(scans<MAX_SCANS)scans<=scans+1'b1;
                        else begin fault<=1;slot_bad<=1;end
                        if(full_group)begin group_position<=0;groups<=groups+1'b1;end
                        else group_position<=group_position+1'b1;
                        state<=IDLE;
                    end else begin channel<=channel+1'b1;frame<=frame>>12;end
                end
                FINISH:begin
                    evidence[channel]<=select_ok && final_hit;
                    previous_evidence[address]<=select_ok && final_hit;
                    hits[channel]<=0;group_hits[channel]<=0;
                    if(channel==15)begin
                        evidence_valid<=1;evidence_string<=end_string;
                        used_samples<=scans;used_groups<=final_groups[15:0];
                        // Retain each string's fault until that same string
                        // has fresh usable data; another string cannot clear it.
                        // R13b：这里原来用 slot_healthy，是"选品不亮"的最后一个漏点。
                        // decoder 的 valid_mask 只看 fault_mask，而 fault_mask 来自
                        // slot_faults；只要 slot_healthy 因为 scans!=end_samples 为 0，
                        // 整弦就被判 fault，屏幕琴颈与音高更新一起被封锁。
                        // 与 evidence 保持一致，改用 select_ok（真正决定"能不能选品"）。
                        slot_faults[end_string]<=!select_ok;
                        fault<=!select_ok || (|(slot_faults & ~(4'b0001<<end_string)));
                        end_pending<=0;
                        scans<=0;groups<=0;group_position<=0;active<=0;slot_bad<=0;
                        rail_scans<=0;
                        state<=IDLE;
                    end else channel<=channel+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(GROUP_SCANS<1 || GROUP_SCANS>32 || MAX_SCANS<1 || MAX_SCANS>65534 ||
           PRESS_PERCENT<1 || PRESS_PERCENT>100 || RELEASE_PERCENT<0 || RELEASE_PERCENT>PRESS_PERCENT ||
           T_DIFF<1 || T_DIFF>4095)
            $fatal(1,"invalid slot evidence parameters");
    end
    always @(posedge clk_50m)
        // R18：归约流水占 4 拍（S2A..S2D），这几拍内允许下一个 snapshot 到来；
        // 只有进入 PROCESS/FINISH 之后再来才是真的太快。
        if(!reset && snapshot_valid && state>S2D)
            $fatal(1,"raw scan faster than shared evidence pipeline");
    // synthesis translate_on
endmodule
