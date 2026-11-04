`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// piezo_string_vote.v —— 压电四通道选弦投票（R24，2026-11-01）
//
// 为什么要有这个模块
// ------------------
// R22b/R23 用一条瞬时判据：
//     mask[i] = (ay[i] >= max(MIN, ay_max>>1)) && (ay[i] >= 左右邻居)
// 它的致命弱点是**只看一个时刻**。四通道串扰实测（main_piezo_hspi 按压录音）：
//     一弦 主/次 = 1.33、二弦 4.8、三弦 20.0、四弦 1.56
// 邻弦经常落在 50%~75% 区间，只要它恰好比自己另一侧的邻居强，"局部最大"
// 这一条就放它进来。三根同时过线 = 用户说的"拉一根响好几个弦"。
//
// R24 改成两级决策，核心思想是"宁可弃权，也不要乱选"：
//
//   ① 指标只用 argmax + 绝对门限
//      一开始想加一条"ay_max > 1.5 x 次大值"的置信门，但算下来不可行：
//      实测最坏的主/次比就是一弦的 1.33（即次大 = 75%）。要求 1.5 倍，
//      真正的单弦演奏也永远不满足，投票会永远弃权、换弦永远不跟随。
//      所以这里只保留两条：包络过绝对下限 SELECT_MIN，且取 argmax。
//      比值这条判据取消，省掉 5 个 16 位比较器。
//
//   ② 时间投票（4 个 3 位漏桶）
//      每窗 argmax 得 +1（饱和 7），其余 -1（下溢 0）。
//      某弦票数 >= VOTE_WIN(6) 才锁定。
//      这一条正好补上 R23 的短板：R23 用的是"连续 8 次同向"，
//      一次不同就清零重来；漏桶对单窗丢失只掉 1 票，下一窗就补回来。
//      反过来，如果 argmax 在两根弦之间来回抖（真·分不清），
//      两边的票数都停在 0~1，永远达不到 6 —— pick 保持上一次的值，
//      也就是"不确定时不动"，而不是每隔 10 ms 换个弦。
//
//   ③ 起音沿零延迟但容易被改写
//      bow_start 且包络够门限时，argmax 立即成为 pick（不延迟），
//      但票数只置 2，不是置满 —— 起音瞬间的机械冲击如果让邻弦最强，
//      两窗之后就会被纠正。R23 是"置选 + 连续 8 次才改"，短于 10.5 ms 的
//      音符会整段锁错。
//
//   ④ 回退顺序
//      pick -> 当前 argmax（若够 SELECT_MIN）-> FALLBACK_MASK(四弦)。
//      四弦只在上电后第一次、且压电完全没有信号时出现，用来保证"琴能响"。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module piezo_string_vote #(
    parameter [15:0] SELECT_MIN    = 16'd32,
    parameter integer DIV_BITS     = 16,
    parameter integer VOTE_WIN     = 6,
    parameter [3:0]   FALLBACK_MASK = 4'b1111,
    // 起音沿锁定时的初始票数。2 = 两窗内可被改写；7 = 置满（不推荐）
    parameter integer START_VOTE    = 2
    //------------------------------------------------------------------
    // R52b：这里原本加了"快换弦(2 窗切)"和"pick 超时释放(100 ms 清零)"，
    // 实板出现两个严重回归，**已整段删除**：
    //
    //  ① pick 清零 -> pick_eff 回退 FALLBACK_MASK(1111) -> **四弦齐鸣**。
    //     下面 pick_eff 的语义是 `pick -> 当前 argmax -> FALLBACK_MASK`，
    //     它依赖 pick 常驻。静默期/起音最初几毫秒 enabled_w=0 时，
    //     pick=0 就等于"四弦全开"，听感是"一拉就把四根弦都带响、声音特别大"。
    //     这条不可修（除非把回退值也改成单弦），代价比收益大。
    //  ② 快换弦让起音冲击直接改写 pick，叠加上面的四弦，表现为"弹完还乱响好几次"。
    //
    // 结论：**判据与状态机保持 R51 原样**。要"能控制"用手动强制（REG_SEL_FORCE），
    // 要"换弦快"必须先解决 pick 清零时的回退语义，单独立项。
    //------------------------------------------------------------------
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [63:0] ay,          // 四路慢包络，[15:0]=弦0，逐 16 位递增
    input  wire        bow_start,   // 弓门控上升沿
    output wire [3:0]  pick,        // 投票锁定的空弦，one-hot 或 0
    output wire [3:0]  pick_eff,    // pick -> 当前 argmax -> FALLBACK_MASK
    output wire        enabled      // 诊断：本窗包络是否过绝对门限
);
    wire [15:0] ay0 = ay[15:0],  ay1 = ay[31:16];
    wire [15:0] ay2 = ay[47:32], ay3 = ay[63:48];

    // ---------------- 最大值 / argmax ----------------
    wire [15:0] ay_lo = (ay0 >= ay1) ? ay0 : ay1;
    wire        ay_lo_i = (ay0 >= ay1) ? 1'b0 : 1'b1;
    wire [15:0] ay_hi = (ay2 >= ay3) ? ay2 : ay3;
    wire        ay_hi_i = (ay2 >= ay3) ? 1'b0 : 1'b1;
    wire [15:0] ay_max = (ay_lo >= ay_hi) ? ay_lo : ay_hi;
    wire [1:0]  ay_arg = (ay_lo >= ay_hi) ? {1'b0, ay_lo_i} : {1'b1, ay_hi_i};

    // 绝对门限：静默时四路都在噪声底（实测 0.7~1.2 码），
    // 不过门限就不投票，否则 argmax 是纯噪声。
    // R53：R52 曾把它改成 `thr` 可配（多一级 16 位 mux 在使能路径上），已删除。
    wire enabled_w = (ay_max >= SELECT_MIN);

    // ---------------- 4 个 3 位漏桶 ----------------
    reg [2:0] vote0, vote1, vote2, vote3;
    wire [2:0] inc0 = (vote0 == 3'd7) ? 3'd7 : vote0 + 1'b1;
    wire [2:0] inc1 = (vote1 == 3'd7) ? 3'd7 : vote1 + 1'b1;
    wire [2:0] inc2 = (vote2 == 3'd7) ? 3'd7 : vote2 + 1'b1;
    wire [2:0] inc3 = (vote3 == 3'd7) ? 3'd7 : vote3 + 1'b1;
    wire [2:0] dec0 = (vote0 == 3'd0) ? 3'd0 : vote0 - 1'b1;
    wire [2:0] dec1 = (vote1 == 3'd0) ? 3'd0 : vote1 - 1'b1;
    wire [2:0] dec2 = (vote2 == 3'd0) ? 3'd0 : vote2 - 1'b1;
    wire [2:0] dec3 = (vote3 == 3'd0) ? 3'd0 : vote3 - 1'b1;

    wire [2:0] v_lo = (vote0 >= vote1) ? vote0 : vote1;
    wire [2:0] v_hi = (vote2 >= vote3) ? vote2 : vote3;
    wire [2:0] v_max = (v_lo >= v_hi) ? v_lo : v_hi;
    wire [3:0] vote_win = {(vote3 >= v_max), (vote2 >= v_max),
                           (vote1 >= v_max), (vote0 >= v_max)} &
                          {4{v_max >= VOTE_WIN}};

    reg [3:0] pick_r;
    reg [DIV_BITS-1:0] div_cnt;
    always @(posedge clk) begin
        if (reset) begin
            vote0 <= 3'd0; vote1 <= 3'd0; vote2 <= 3'd0; vote3 <= 3'd0;
            pick_r <= 4'd0; div_cnt <= {DIV_BITS{1'b0}};
        end else begin
            div_cnt <= div_cnt + 1'b1;
            // 先按票数结果刷新（用上一拍算出的 vote_win）
            if (vote_win != 4'd0) pick_r <= vote_win;

            if (bow_start && enabled_w) begin
                // 明确起音：argmax 立即生效（零延迟），但票数只置 START_VOTE，
                // 起音瞬间的冲击如果让邻弦最强，两窗内就会被投票纠正。
                vote0 <= (ay_arg == 2'd0) ? START_VOTE : 3'd0;
                vote1 <= (ay_arg == 2'd1) ? START_VOTE : 3'd0;
                vote2 <= (ay_arg == 2'd2) ? START_VOTE : 3'd0;
                vote3 <= (ay_arg == 2'd3) ? START_VOTE : 3'd0;
                pick_r <= 4'b0001 << ay_arg;
                div_cnt <= {DIV_BITS{1'b0}};
            end else if (&div_cnt) begin
                div_cnt <= {DIV_BITS{1'b0}};
                if (enabled_w) begin
                    vote0 <= (ay_arg == 2'd0) ? inc0 : dec0;
                    vote1 <= (ay_arg == 2'd1) ? inc1 : dec1;
                    vote2 <= (ay_arg == 2'd2) ? inc2 : dec2;
                    vote3 <= (ay_arg == 2'd3) ? inc3 : dec3;
                end else begin
                    // 静默：全体衰减，票数自然回落，不会因"长期没声音"锁死
                    vote0 <= dec0; vote1 <= dec1;
                    vote2 <= dec2; vote3 <= dec3;
                end
            end
        end
    end

    wire [3:0] arg_onehot = 4'b0001 << ay_arg;
    assign pick     = pick_r;
    assign pick_eff = (pick_r != 4'd0) ? pick_r :
                      (enabled_w ? arg_onehot : FALLBACK_MASK);
    assign enabled  = enabled_w;

    // synthesis translate_off
    initial begin
        if (DIV_BITS < 4 || DIV_BITS > 24 || VOTE_WIN < 1 || VOTE_WIN > 7 ||
            START_VOTE < 0 || START_VOTE > 7)
            begin $display("FAIL piezo_string_vote parameters out of range"); $finish; end
    end
    // synthesis translate_on
endmodule

`default_nettype wire
