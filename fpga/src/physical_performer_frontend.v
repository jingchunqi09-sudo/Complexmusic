`timescale 1ns/1ps
`include "left_hand_vote_config.vh"
`include "latency_profile.vh"
// Sensor transactions -> independent controllers -> registered eight-voice bank.
// No packet parser or shared instrument-switching state in the performer path.
module physical_performer_frontend #(
    parameter integer CLOCK_HZ=50000000,
    parameter [3:0] OPEN_BOW_MASK=4'b1111,
    parameter integer BOW_AXIS_Y=1,
    // 弓速门限（0..255，来自 bow_motion_tracker 的 9 样本 SUM）
    parameter integer BOW_SUPPRESS_SPEED=40,
    // ---- R22b：多弦同时运弓 ----
    // 0 = R16 起的"弓一次只碰一根弦"（单弦，音色最干净但拉不了双音）
    // 1 = 多弦：按品的弦全部发声 + 压电投票选出的 1 根空弦（默认）
    parameter integer BOW_MULTI_STRING=1,
    // R24：此参数已废弃。R23 的 mask 相对门槛（ay_max>>PIEZO_MULTI_SHIFT）
    // 被"1.5x 比值置信门 + 4 路漏桶投票"取代，见下方选弦段。
    // 保留声明只是为了让上层例化不必改（Gowin 对参数个数敏感）。
    parameter integer PIEZO_MULTI_SHIFT=1
)(
    input wire clk_50m,reset,
    output wire paw_ncs,paw_sclk,paw_mosi,input wire paw_miso,
    output wire left_adc_sclk,left_adc_din,left_adc1_cs_n,input wire left_adc1_out,
    output wire left_adc2_cs_n,input wire left_adc2_out,
    output wire left_tx1,left_tx2,left_tx3,left_tx4,left_sk_clk,left_sk_data,
    output wire piezo_sclk,piezo_mosi,input wire piezo_miso,
    output wire piezo_cs_n,piezo_convst_n,piezo_reset_n,input wire piezo_busy_n,
    output reg [55:0] note_bus,output reg [7:0] gate_bus,trigger_bus,stop_bus,
    output reg [63:0] velocity_bus,output reg [127:0] speed_bus,
    output wire [191:0] position_bus,output reg [7:0] direction_bus,
    output reg [3:0] view_instrument,
    output reg event_valid,output reg [31:0] event_sequence,
    output reg [63:0] event_clock,
    output wire [3:0] sensor_ready,output wire [3:0] sensor_fault,
    output wire [15:0] left_status,
    // R7：压电识别/包络与弓链路诊断（供 HDMI 显示）
    output wire [63:0] piezo_ay,output wire [3:0] piezo_warm,
    output wire piezo_ev_valid,output wire [3:0] piezo_ev_strings,
    output wire [15:0] piezo_ev_total,
    output wire [7:0] bow_gate_debug,output wire [7:0] bow_speed_debug,
    output wire signed [15:0] paw_dx_debug,output wire signed [15:0] paw_dy_debug,
    output reg signed [15:0] bow_pos_x,output reg signed [15:0] bow_pos_y,
    output wire piezo_smpl_valid,output wire [1:0] piezo_smpl_ch,
    output wire [19:0] left_fret_bus,output wire [3:0] piezo_fire,
    // R17：拍琴身（琴体传导）被判为非音符事件时转成的颤音深度（0..63）
    output wire [7:0] piezo_vibrato,
    // R25：8 lane 定弦（来自 ESP32，透传给 performer_pitch_map）
    input wire [55:0] i_tune
);
    wire signed [15:0] dx,dy;
    wire paw_ready,paw_error,paw_valid;
    wire [7:0] motion;
    // R10：CPI 1000 -> 3200。1000 CPI 下慢弓（28 mm/s）只有 1.3 个量化级，
    // 与静止噪声底只差 0.26 count（mouse_typec 报告 §3.2），任何阈值都分不开；
    // 3200 CPI 下慢弓 4.1 count、峰值 24 count，8 位速度不溢出。
    paw3395_driver #(.CPI(3200)) u_paw(
        .clk_50m(clk_50m),.reset_n(!reset),.paw_miso(paw_miso),.paw_motion(1'b1),
        .paw_nreset(),.paw_ncs(paw_ncs),.paw_sclk(paw_sclk),.paw_mosi(paw_mosi),
        .delta_x(dx),.delta_y(dy),.motion_valid(),.ready(paw_ready),.init_error(paw_error),
        .debug_product_id(),.debug_inverse_id(),.debug_motion(motion),.debug_squal(),
        .debug_cpi_x(),.debug_cpi_y(),.debug_error(),.sample_valid(paw_valid)
    );
    wire [191:0] snapshot;
    wire snapshot_valid;
    wire [1:0] snapshot_string, slot_string;
    wire slot_valid;
    wire [15:0] slot_sample_count;
    // Pure hardware detection: a 1.25 ms slot supplies 70 complete raw
    // scans; reference 5 ms/300 scan/20 round profile remains in config/.
    // Protocol timing is unchanged; no UART or external DDR transaction.
    left_hand_sensor_adapter #(.CLK_HZ(CLOCK_HZ),.EXC_SLOT_TICKS(`LEFT_SLOT_TICKS),
        .SETTLE_TICKS(`LEFT_SETTLE_TICKS),.CARRIER_HALF(`LEFT_CARRIER_HALF)) u_left_adc(
        .clk_50m(clk_50m),.reset(reset),.adc_sclk(left_adc_sclk),.adc_din(left_adc_din),
        .adc1_cs_n(left_adc1_cs_n),.adc1_out(left_adc1_out),
        .adc2_cs_n(left_adc2_cs_n),.adc2_out(left_adc2_out),
        .fpga_tx1(left_tx1),.fpga_tx2(left_tx2),.fpga_tx3(left_tx3),.fpga_tx4(left_tx4),
        .snapshot(snapshot),.snapshot_valid(snapshot_valid),.snapshot_string(snapshot_string),
        .slot_valid(slot_valid),.slot_string(slot_string),.slot_sample_count(slot_sample_count),.excitation()
    );
    wire [15:0] left_evidence;
    wire evidence_valid, evidence_fault;
    wire [3:0] evidence_fault_mask;
    wire [1:0] evidence_string;
    left_hand_slot_evidence #(.GROUP_SCANS(`LEFT_GROUP_SCANS),
        .PRESS_PERCENT(`LEFT_PRESS),.RELEASE_PERCENT(`LEFT_RELEASE),
        .DIRECTION_LOW(`LEFT_DIRECTION_LOW),
        .USE_DIFF(`LEFT_USE_DIFF),.T_DIFF(`LEFT_T_DIFF),
        .THRESHOLD_CODES(`LEFT_THRESHOLDS)) u_left_evidence(
        .clk_50m(clk_50m),.reset(reset),.snapshot(snapshot),.snapshot_valid(snapshot_valid),
        .snapshot_string(snapshot_string),.slot_valid(slot_valid),.slot_string(slot_string),
        .slot_sample_count(slot_sample_count),.evidence(left_evidence),.evidence_valid(evidence_valid),
        .evidence_string(evidence_string),.used_samples(),.used_groups(),.fault(evidence_fault),.fault_mask(evidence_fault_mask));
    // Each string owns its ready/fault/common state. Multi-electrode hits are
    // normal finger contact: the decoder publishes the highest fret, so a
    // chord no longer becomes a global mute, and one disconnected string
    // cannot block the other three. Common-mode and fault still block.
    wire [19:0] fret;
    wire [3:0] left_ready,left_multi,left_common,left_fault;
    left_hand_string_decoder #(.COMMON_CELLS(`LEFT_COMMON),
        .CHANNEL_FRETS(`LEFT_CHANNEL_FRETS)) u_fret(
        .clk_50m(clk_50m),.reset(reset),.evidence(left_evidence),
        .evidence_valid(evidence_valid),.evidence_string(evidence_string),
        .evidence_fault(evidence_fault_mask[evidence_string]),
        .fret_bus(fret),.valid_mask(left_ready),.multi_mask(left_multi),
        .common_mask(left_common),.fault_mask(left_fault)
    );
    wire [3:0] left_blocked=left_fault|left_common|~left_ready;
    // SK9822 灯带：呼吸灯 + 分弦配色（MODE=1，见模块内说明）
    // 触发源：低 4 位 = 小提琴 gate（电平），高 4 位 = 尤克里里拨弦触发。
    //   R51 修正：R50 用的是 gate_bus[7:4]，而顶层 `next_gates={4'd0,…}` 让那 4 位
    //   恒为 0 —— 所以弹尤克里里灯完全不动，只有小提琴有反应。
    //   改用 trigger_bus[7:4]（= p_trigger & ~bow_contact）：
    //     · 它是寄存器输出，已经和发声用同一个屏蔽口径（运弓时不误亮）
    //     · 它是**单拍脉冲**，灯内部 0.40 s 拖尾会把这一拍记住
    //   R51 评审采纳：三家一致建议进灯模块前再打一拍隔离，别让 trigger_bus 的
    //   布线直接拉进灯模块（CLS 85% 下新增组合负载最容易推布局）。
    //   打一拍只是延后 20 ns，对 0.4 s 拖尾毫无影响。
    reg [3:0] led_pluck_r;
    always @(posedge clk_50m)begin
        if(reset) led_pluck_r<=4'd0;
        else      led_pluck_r<=trigger_bus[7:4];
    end
    left_led_status u_led_status(.clk(clk_50m),.reset(reset),
        .i_ready(left_ready),.i_multi(left_multi),.i_common(left_common),
        .i_fault(left_fault),
        .i_active(gate_bus[3:0]|led_pluck_r),
        .sclk(left_sk_clk),.data(left_sk_data));
    assign left_status={left_ready,left_multi,left_common,left_fault};
    wire p_valid,p_initialized,p_fault;
    wire [1:0] p_channel;
    wire [11:0] p_value;
    ad7091r4_sensor_adapter #(.CLOCK_HZ(CLOCK_HZ),
        .SAMPLE_GAP_CLKS(`R61_PIEZO_SAMPLE_GAP),
        .SPI_HALF_PERIOD_CLKS(`R61_PIEZO_SPI_HALF)) u_piezo(
        .clk_50m(clk_50m),.reset(reset),.adc_sclk(piezo_sclk),.adc_mosi(piezo_mosi),
        .adc_miso(piezo_miso),.adc_cs_n(piezo_cs_n),.adc_convst_n(piezo_convst_n),
        .adc_reset_n(piezo_reset_n),.adc_busy_n(piezo_busy_n),.sample_valid(p_valid),
        .sample_channel(p_channel),.sample_value(p_value),.frame_valid(),.frame_values(),
        .initialized(p_initialized),.fault(p_fault)
    );
    wire bow_gate,bow_dir,bow_lift,bow_bounce;
    wire [7:0] bow_speed;
    wire signed [23:0] bow_pos_counts;
    bow_motion_tracker #(.CLOCK_HZ(CLOCK_HZ),.AXIS_Y(BOW_AXIS_Y)) u_bow(
        .clk(clk_50m),.reset(reset),.sample_valid(paw_valid),.ready(paw_ready&&!paw_error),
        .motion(motion),.dx(dx),.dy(dy),.gate(bow_gate),.direction(bow_dir),
        .lifted(bow_lift),.speed(bow_speed),.bounce(bow_bounce),.position(bow_pos_counts)
    );
    wire [55:0] mapped_notes;
    wire [3:0] fingered_strings;
    performer_pitch_map #(.CLOCK_HZ(CLOCK_HZ)) u_pitch(
        .clk(clk_50m),.reset(reset),.fret_bus(fret),.valid_mask(left_ready),
        .open_notes(i_tune),
        .note_bus(mapped_notes),.bowed_strings(fingered_strings)
    );
    wire [3:0] p_trigger;
    wire [31:0] p_velocity;
    // R17：右手判据换成移植自 rh6 的版本（55~900 Hz 带通 + 双包络 + 8 ms 空间判据
    // + 60 ms 消抖），时间常数按真实 24.9 kSPS 重标。接口与原 piezo_onset_bank 一致，
    // 多一路 vibrato_depth：拍琴身被判为琴体事件时不再发声，而是转成颤音。
    piezo_string_det u_onset(.clk(clk_50m),.reset(reset),.sample_valid(p_valid),
        .healthy(p_initialized),.channel(p_channel),.value(p_value),
        .trigger(p_trigger),.velocity(p_velocity),
        .ev_valid(piezo_ev_valid),.ev_strings(piezo_ev_strings),.ev_peak(),
        .ev_total(piezo_ev_total),.dbg_ay(piezo_ay),.dbg_warm(piezo_warm),
        .vibrato_depth(piezo_vibrato),.rej_total());
    // R7 弓链路诊断：ready/error/gate/lift 与速度、位移供显示定位"拉弓无反应"
    assign bow_gate_debug={4'd0,paw_error,paw_ready,bow_lift,bow_gate};
    assign bow_speed_debug=bow_speed;
    assign paw_dx_debug=dx;
    assign paw_dy_debug=dy;
    assign piezo_smpl_valid=p_valid;
    assign piezo_smpl_ch=p_channel;
    assign left_fret_bus=fret;
    assign piezo_fire=p_trigger;
    // R10: 左右手解耦。left_blocked 只表示"该弦音高不可信"，只能阻止
    // note_bus 更新，不得封锁弓门控或压电发声。R7~R9 把它串进
    // trigger_bus/gate_bus 后，左手一旦 ready=0（载波失配、阈值不当、共模误判）
    // 右手就完全无声——这是 2026-10-31 现场"弹奏没声音"的直接原因。
    // ---------------- R16：压电选弦；R24：改成投票 ----------------
    // 需求："小提琴按压哪个弦和品就拉哪根弦，这个结合压电陶瓷片来识别"。
    // 旧逻辑 selected_strings = 按品弦，不按品时 = OPEN_BOW_MASK（四弦）：
    //   ① 拉空弦时四根波导同时被注能，一个音被四根弦叠加，音色发糊；
    //   ② 多弦按品（手型搭到邻弦）时四根一起响，分不出弓实际在哪根。
    // 压电四路包络 piezo_ay 反映的是"哪根弦真的在振动"。弦序已在
    // piezo_onset_bank 输出端反转，piezo_ay[15:0] = 弦 0，逐 16 位递增。
    // 投票逻辑单独成模块（src/piezo_string_vote.v），便于单元验证与复用。
    // 判据、时间常数、为什么用它而不是 R23 的瞬时 mask，全部写在那里的头注释。
    // 一句话：R23 的 mask 会同时放进来多根弦（串扰 75% 也能过 50% 门槛），
    // R24 的投票只出一根，且 argmax 抖动时保持不动。
    localparam [15:0] PIEZO_SELECT_MIN=16'd32;
    reg bow_gate_d;
    always @(posedge clk_50m)
        bow_gate_d<=reset?1'b0:bow_gate;
    wire bow_start=bow_gate&&!bow_gate_d;
    wire [3:0] piezo_pick,piezo_pick_eff;
    wire piezo_vote_on;
    // R52b：不要在这里加 FAST_SWITCH_WIN / QUIET_WIN —— R52 加过，实板四弦齐鸣，
    // 已从模块里删除（原因见 piezo_string_vote.v 头注释）。
    piezo_string_vote #(.SELECT_MIN(PIEZO_SELECT_MIN),.DIV_BITS(16),
        .VOTE_WIN(6),.FALLBACK_MASK(OPEN_BOW_MASK),.START_VOTE(2)) u_vote(
        .clk(clk_50m),.reset(reset),.ay(piezo_ay),.bow_start(bow_start),
        .pick(piezo_pick),.pick_eff(piezo_pick_eff),.enabled(piezo_vote_on)
    );
    wire [3:0] selected_fingered=fingered_strings;
    // 单选（BOW_MULTI_STRING=0）沿用 R16 语义：
    //   按品时优先取"压电选中的那根 ∩ 按品集合"，交集为空说明弓碰到的弦没按品，
    //   此时仍按左手按的弦发（否则会出现"按了没声音"）；完全不按品时用压电选弦，
    //   压电也没结论才回退四弦。
    // 多弦（BOW_MULTI_STRING=1，默认）：
    //   按品弦全部发声（左手最可靠），**再加最多 1 根**压电投票赢的空弦。
    //   注意这里用的是 piezo_pick（真正锁定过的值），**不是 piezo_pick_eff**：
    //   pick_eff 在压电完全没信号时会回退到 OPEN_BOW_MASK(1111)，
    //   若拿它去和 ~fingered 相与，等于把没按品的三根全加进来 —— 又变回四弦齐鸣。
    //   R23 的 piezo_pick_eff 是多弦 mask、不会回退到 1111，所以那里没这个问题；
    //   R24 换成 one-hot 赢家之后必须分开用。
    wire [3:0] piezo_extra = piezo_pick & ~selected_fingered;
    // R53：R52 曾在这里插过 force mux（force_hot / force_on / selected_auto），
    //   实板"S1 乱响不停"。原因是这条线是 selected_strings -> next_gates -> gate_bus
    //   的**发声门控本身**，多加一级 mux + 一个移位器就推动布局，而本工程
    //   hold 只有 43~45 ps。**这段永远不要再插回来**（要覆盖选弦请改 vote 内部）。
    wire [3:0] selected_strings=
        (BOW_MULTI_STRING!=0) ?
            ((selected_fingered!=0) ? (selected_fingered | piezo_extra) :
                piezo_pick_eff) :
            ((selected_fingered!=0)?(((piezo_pick&selected_fingered)!=0)?
                (piezo_pick&selected_fingered):selected_fingered):
            ((piezo_pick!=0)?piezo_pick:OPEN_BOW_MASK));
    // 只有"确实在运弓"才与拨弦互斥：静止时鼠标 ±1 count 抖动（实测偏置）
    // 不再抑制压电。门限取报告 §4.2 的开弓门限 40。
    // 只抑制正在运弓的那根弦（selected_strings），不是四弦全抑制——
    // 否则一根弦在拉，其余弦都拨不响。
    wire bow_active=bow_gate && (bow_speed>=BOW_SUPPRESS_SPEED);
    wire [3:0] bow_contact=selected_strings & {4{bow_active}};
    wire [7:0] next_gates={4'd0,selected_strings & {4{bow_gate}}};
    // 弓门控的上升/下降沿：上升 -> violin 起音 + 停全部 uke 尾音，下降 -> violin 停音。
    wire [3:0] violin_attack =next_gates[3:0] & ~gate_bus[3:0];
    wire [3:0] violin_release=gate_bus[3:0] & ~next_gates[3:0];
    assign position_bus=192'd0; // audio model's default contact position
    assign sensor_ready={(&left_ready),p_initialized,paw_ready,!bow_lift};
    assign sensor_fault={|left_fault,p_fault,paw_error,1'b0};
    reg [63:0] clock_count;
    integer note_string;
    wire [3:0] note_change;
    genvar string_index;
    generate for(string_index=0;string_index<4;string_index=string_index+1)begin: g_note_change
        assign note_change[string_index]=!left_blocked[string_index] &&
            (note_bus[string_index*7 +:7]!=mapped_notes[string_index*7 +:7] ||
             note_bus[(string_index+4)*7 +:7]!=mapped_notes[(string_index+4)*7 +:7]);
    end endgenerate
    wire changed=(|note_change)||(gate_bus!=next_gates)||
        (|(p_trigger & ~bow_contact))||
        (speed_bus[7:0]!=bow_speed)||(direction_bus[0]!=bow_dir);
    reg signed [23:0] bow_acc_x,bow_acc_y;   // CPI=3200：1 count = 7.94 µm
    always @(posedge clk_50m)begin
        event_valid<=0;trigger_bus<=0;stop_bus<=0;
        if(reset)begin
            note_bus<={7'd69,7'd64,7'd60,7'd67,7'd76,7'd69,7'd62,7'd55};
            gate_bus<=0;velocity_bus<=0;speed_bus<=0;direction_bus<=0;view_instrument<=0;
            event_sequence<=0;event_clock<=0;clock_count<=0;bow_pos_x<=0;bow_pos_y<=0;
            bow_acc_x<=0;bow_acc_y<=0;
        end else begin
            clock_count<=clock_count+1'b1;
            // R10 琴弓方位：改用"死区后的双轴增量"积分。
            // 旧版条件是 paw_valid && motion[7] && !motion[3]；Type-C 采集实测
            // 0x02 的 bit3 恒为 1（mouse_typec 报告 §2.1），所以 !motion[3] 恒假，
            // 弓位在屏幕上根本不动——这是"拉弓没反应"的表象之一。
            // 同时实测存在 ±1 count 确定性偏置，不去掉会持续漂移（1.34 m/min）。
            // 缩放：±60 mm 行程 = ±7559 count（CPI=3200），所以 >>>7 后用 24 位
            // 累加器保留小数，避免慢弓被整数截断吃掉。
            if(paw_valid && paw_ready && !paw_error)begin
                if((dx>16'sd1)||(dx< -16'sd1)) bow_acc_x<=bow_acc_x+dx;
                if((dy>16'sd1)||(dy< -16'sd1)) bow_acc_y<=bow_acc_y+dy;
                if((bow_acc_x>>>7)>24'sd60) bow_pos_x<=16'sd60;
                else if((bow_acc_x>>>7)< -24'sd60) bow_pos_x<=-16'sd60;
                else bow_pos_x<=(bow_acc_x>>>7);
                if((bow_acc_y>>>7)>24'sd40) bow_pos_y<=16'sd40;
                else if((bow_acc_y>>>7)< -24'sd40) bow_pos_y<=-16'sd40;
                else bow_pos_y<=(bow_acc_y>>>7);
            end
            for(note_string=0;note_string<4;note_string=note_string+1)
                if(!left_blocked[note_string])begin
                    note_bus[note_string*7 +:7]<=mapped_notes[note_string*7 +:7];
                    note_bus[(note_string+4)*7 +:7]<=mapped_notes[(note_string+4)*7 +:7];
                end
            gate_bus<=next_gates;
            // R24：小提琴基础弓压 192 -> 224。
            // tb_violin_grid 实测（A4，速度=128）：p_eff=192 时 h2 比 h1 高 4.0 dB、
            // rms 1132；p_eff=224 时 h1 反超 6.4 dB、rms 2112 —— 这是"粘着主导"
            // 台阶的上沿，跨过去音量和音色同时抬一级。而 R23 的
            // p_eff = 192 + max(0,speed-64)>>1 在 speed<=64 时就是 192，
            // 中速段（speed 80~140）落在 200~230，正好卡在台阶下方，
            // 这就是用户听到的"弓压不够"。基础值抬到 224 后整条曲线过台阶。
            // 尤克里里仍用压电力度 p_velocity，不受影响。
            velocity_bus<={p_velocity,{4{8'd224}}};
            speed_bus<={64'd0,{4{8'd0,bow_speed}}};
            direction_bus<={4'd0,{4{bow_dir}}};
            // Only the affected string is blocked. Healthy strings retain
            // their independent piezo triggers and bow gates.
            // Bow/pluck arbitration: while a string is bowed its piezo pluck
            // is suppressed, and a bow attack issues the uke voice a STOP so
            // an old pluck tail cannot ring under the bow (R6).
            // R10 解耦：拨弦只被"真实运弓"抑制，不再被 left_blocked 抑制。
            // left_blocked 的职责仅限于 note_bus（见上方 if(!left_blocked[...])）。
            // R16：任一根弦起弓都要停掉全部 uke 尾音（R6 的仲裁语义）。
            // 选弦后一次只有一根弦开 gate，若还按 lane 发 STOP，另外三根 uke
            // 的拨弦尾音会在弓下继续响——听感是"拉弓时底下还有拨弦余音"。
            trigger_bus<={(p_trigger & ~bow_contact), violin_attack};
            stop_bus<={{4{|violin_attack}}, violin_release};
            if(p_trigger!=0)view_instrument<=4'hf;
            else if(bow_gate)view_instrument<=0;
            if(changed)begin
                event_valid<=1;event_sequence<=event_sequence+1'b1;event_clock<=clock_count;
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
// SK9822 灯带：呼吸灯 + 分弦配色（R50）
//
// ── 硬件事实 ──
// 依据 `00_首页_最新版本/LED指引打分系统_20261031/04_DOCS/04_限流与亮度预算.md` §1~§3
// 与 `07_灯序映射表.md`：
//  · 灯珠为 SK9822 / HD107S 类，每通道恒流典型 20 mA（5 bit 亮度码 31 = 满）
//  · 5 bit 亮度码是**全局电流缩放**，8 bit RGB 才是 PWM：
//        单通道电流 I = 20 mA × (BRI/31) × (value/255)
//  · LED 序号 = 品×4 + 弦（品优先）。**一个"品"= PCB 上一列 4 颗，一列里 4 颗 = 4 根弦。**
//    板上贴前 31 个位置（index 0..30）= 品 0~6 的四根弦（28 颗）+ 品 7 的弦 0/1/2（3 颗）。
//    所以 `弦号 = LED 序号 % 4`，`品号 = LED 序号 / 4`，本模块直接用 pixel[3:2]/pixel[1:0]，
//    不需要任何映射表。
//  · **L23 已经物理拆掉**（用户 2026-11-03 确认）。原理图链路是
//    `L01.SDO→DATA1→L02.SDI→…`，即 **L 位号 = 串联第几颗（1 起算）** →
//    L23 = 第 23 颗 = **0 起算 index 22** = **品 5、弦 2**（第 6 列第 3 行）。
//  · **拆掉一颗 = 后面整串前移一格**（这是最容易漏的一点）：
//    SK9822 是移位链，每颗吃掉 32 bit。L23 不在链上了，L24 就会吃掉本该属于
//    L23 的那个字，于是从 L24 起每颗显示的都是"前一个逻辑索引"的颜色。
//    所以必须做补偿：物理接收者 r >= 22 时，逻辑索引取 r+1（参数 SKIP_DEAD）。
//    不补偿的表现：静默看不出来（全同色），一演奏就从第 6 列开始整行偏一格。
//  · 灯带串行移位**不能真的跳过某一颗**（发送时少发一个字会让后面全体错位）。
//    正确做法是"照常发满，只在算颜色时把索引前移"。
//  · 这条 5 V 供电路径在 0.6 A 就已经吃力（`LED序列测试_20261028/README` 第 9 节）
//
// ── 本模块的电流上限（改 BRI 或配色表后必须照此重算）──
//    BRI = 3 → 单通道满量程 20×3/31 = 1.94 mA
//    配色表单颗最大和 = 220（弦 3：110+110），最坏 31 颗同时到峰值：
//        I_max = 31 × 220 × (1.94/255) = 51.8 mA
//    呼吸是线性三角波，平均约为峰值一半 → 典型 ≈ 26 mA
//    相对 0.6 A 的供电压降点留 11 倍余量；比 R41（90.3 mA）低 43%。
//
// ── 显示规则（这是"有规则的变化"的定义，改之前先想清楚）──
//    **触发源 = 小提琴 gate + 尤克里里拨弦触发，两路都要能点亮**（R51 修）：
//      · 小提琴：`gate_bus[3:0]`，运弓期间是**电平**，稳定为 1
//      · 尤克里里：`trigger_bus[7:4]` = `p_trigger & ~bow_contact`，是**单拍脉冲**
//        （R50 及以前接的是 `gate_bus[7:4]`，而 `next_gates={4'd0,…}` 让它恒为 0
//          —— 这就是"只有小提琴有反应、弹尤克里里灯不动"的唯一原因。
//         用 trigger_bus 而不是直接引 p_trigger，是因为它已经过了 `~bow_contact` 屏蔽：
//         运弓时压电被弓毛激发的那点信号不会把别的弦点亮，与发声口径完全一致。）
//      灯内部有 0.40 s 拖尾，所以单拍脉冲也能稳定显示，不需要额外展宽。
//    静默：31 颗**完全相同**，单一底色青 (0,48,64)，统一呼吸，周期 1.34 s
//    弹弦：该弦**整行**（8 个品）变该弦固定颜色，并且**不呼吸、常亮在满值**
//          —— 变成一条稳定的"色柱"；其余行压暗到 **0.5**（仍是青），照常呼吸。
//          "别人在慢慢呼吸、我弹的这行是稳的"——一眼就能认出是哪根弦，
//          而且不靠抬亮（总电流反而下降）。
//          松弦后 0.40 s 内颜色保持，然后一起褪回底色。
//    弦色固定：弦0 琥珀 / 弦1 青绿 / 弦2 蓝 / 弦3 紫
//    **不做故障染色**：i_fault/i_common 只要某弦 select_ok=0 就常置位，
//          一列常年偏红比底色亮一倍多，整条看起来就是"乱"（R45/R46 的教训）。
//          诊断请看屏幕 MONITOR 页。
//    **行方向**：默认 index 0（第 1 列第 1 颗）在最上面。若实板发现上下颠倒
//          （弹某弦亮的是对面那一行），只改 ROW_FLIP 一行即可，别动别处。
//
// ── 时序（一个字都不许动）──
//    divider 249 → sclk 100 kHz，每帧 2272 bit
//    （32 前导 0 + 64×32 + 32 尾 1 + 160 空闲 0）= 22.7 ms 一帧。
//    本版只改「每颗灯的颜色从哪来」，不改帧结构、不改 sclk 相位、不改引脚。
//    仍然发满 64 个字（第 32 颗之后填黑），绝不缩短帧 —— 缩短会让坏点之后
//    收到错位数据而随机乱闪。
// ---------------------------------------------------------------------------
module left_led_status(
    input wire clk,reset,
    input wire [3:0] i_ready,i_multi,i_common,i_fault,
    input wire [3:0] i_active,          // 每根弦正在发声（弓/拨两组已合并）
    output reg sclk,output reg data
);
    // MODE = 0：还原成原来的左手指板诊断配色（红=故障/共模，绿=就绪，蓝=未就绪）
    // MODE = 1：呼吸灯 + 分弦配色（本版）
    // 出问题要回退时只改这一行，其余不动。
    localparam integer MODE = 1;

    // 全局电流档（5 bit）：整条灯亮度的总闸门，也是电流上限的第一因子。
    // R50：4 -> 3。最坏 31 颗全亮从 90.3 mA 降到 51.8 mA。
    localparam [4:0] BRI = 5'd3;

    // ---- R51：L23 拆除后的索引补偿（这是本版最关键的一处）------------------
    // SK9822 是纯移位链：每颗灯**吃掉 32 bit**，再把这 32 bit 从 SDO 推给下一颗。
    // L23 被物理拆除并把 DI/DO 短接之后，数据从 L22.SDO 直接进 L24.SDI，
    // **L24 会吃掉本该属于 L23 的那个 32 bit 字** —— 于是从 L24 起，
    // 每一颗收到的都是"前一个逻辑索引"的颜色，整串**前移一格**。
    //
    //   物理接收者 r (0 起算)  →  它应该显示的逻辑索引
    //        r < 22                 r
    //        r >= 22                r + 1        （跳过被拆掉的 L23 = index 22）
    //
    // 不补偿的后果：静默时看不出来（全同色），一演奏就从第 6 列开始整行偏一格，
    // 表现为"某些灯对应错了品"。用户说的"认清楚哪几个灯对应哪几个品"就是这个。
    //
    // SKIP_DEAD = 1：L23 已拆除且短接（现状）
    // SKIP_DEAD = 0：L23 还装着（或拆了没短接），此时不要补偿，行为同 R50。
    //                实板若发现"从第 6 列开始整体偏一格"，第一件事就是查这个参数。
    localparam integer SKIP_DEAD = 1;

    // 只用逻辑索引 0..30（品 0~7，其中品 7 只有弦 0/1/2）。逻辑 31..63 没有灯珠，填黑。
    localparam [6:0] LAST_IDX = 7'd30;
    // 行方向：0 = 逻辑 index 0 那一颗在**最上面**（默认）；1 = 上下翻转。
    //   实板若发现"弹某弦亮的是对面那一行"，只把这里改成 1，别动其他任何地方。
    //   注意它只翻"显示行"，不翻弦色表 —— 弦 0 永远是琥珀。
    localparam integer ROW_FLIP = 0;
    // 被拆掉的那颗的逻辑索引
    localparam [6:0] DEAD_LOGIC = 7'd22;

    // ---------------- 呼吸 ----------------
    // 26 位自由计数，bit25 每 2^25 clk 翻转 = 671 ms
    // → 三角波半周期 671 ms、整周期 1.34 s；取 [24:17] 共 256 级，每级约 2.6 ms
    // R50：只要有弦在发声就切到 bit24（周期 0.67 s，快一倍）。
    //      这是"弹弦时明显变化"的第二维，且不增加任何电流。
    reg [25:0] breath_cnt;
    always @(posedge clk)begin
        if(reset) breath_cnt<=26'd0;
        else      breath_cnt<=breath_cnt+26'd1;
    end
    // R50 最终版：呼吸源保持单路（原来那一声明是给"整条加快"用的，
    // 两家评审指出那会让整条看起来像背景闪烁、削弱"哪根弦在响"的因果，
    // 所以删掉。改成"发声列常亮、其余列照常呼吸"——见下面的 breath_px。
    wire [7:0] breath_w = breath_cnt[25]?~breath_cnt[24:17]:breath_cnt[24:17];
    reg  [7:0] breath_r;
    always @(posedge clk) breath_r<=breath_w;

    // ---------------- 每弦拖尾 ----------------
    // 直接跟 gate 会「一离弦立刻变色」，看起来像闪。发声后保持 0.40 s 再褪回底色。
    // tick 每 1024 clk（20.5 µs）一次 → HOLD_TOP × 20.5 µs = 0.40 s
    localparam [15:0] HOLD_TOP=16'd19500;
    reg [9:0] tick_cnt;
    wire tick=(tick_cnt==10'd1023);
    always @(posedge clk)begin
        if(reset) tick_cnt<=10'd0;
        else      tick_cnt<=tick?10'd0:tick_cnt+10'd1;
    end

    reg [15:0] hold0,hold1,hold2,hold3;
    reg [3:0]  act_r;
    always @(posedge clk)begin
        if(reset)begin
            hold0<=16'd0;hold1<=16'd0;hold2<=16'd0;hold3<=16'd0;act_r<=4'd0;
        end else begin
            if(i_active[0])hold0<=HOLD_TOP;else if(tick&&hold0!=16'd0)hold0<=hold0-16'd1;
            if(i_active[1])hold1<=HOLD_TOP;else if(tick&&hold1!=16'd0)hold1<=hold1-16'd1;
            if(i_active[2])hold2<=HOLD_TOP;else if(tick&&hold2!=16'd0)hold2<=hold2-16'd1;
            if(i_active[3])hold3<=HOLD_TOP;else if(tick&&hold3!=16'd0)hold3<=hold3-16'd1;
            act_r[0]<=i_active[0]|(|hold0);
            act_r[1]<=i_active[1]|(|hold1);
            act_r[2]<=i_active[2]|(|hold2);
            act_r[3]<=i_active[3]|(|hold3);
        end
    end
    wire [3:0] act=act_r;
    // 注意：颜色/压暗必须用**带拖尾的** any_act_h，不能用瞬时 |i_active。
    // 否则松弦那一刻其余列会从 0.3125 直接跳回全亮（一次明显闪光），
    // 而本弦列还在 0.4 s 拖尾里保持弦色 —— 两者不同步，看起来就是"乱"。
    // 只有"呼吸快慢"用瞬时值：一开口就该立刻变快，这是想要的。
    wire any_act_h = |act;

    // ---------------- 位流计数器 ----------------
    reg [7:0]  divider;
    reg [11:0] bit_index;
    wire [11:0] next_index =(bit_index==12'd2271)?12'd0:bit_index+12'd1;
    wire [11:0] next_offset=next_index-12'd32;
    wire [5:0]  next_pixel =next_offset[10:5];
    wire [4:0]  next_bpos  =next_offset[4:0];
    // 注意：像素区判据必须用 next_index，不能用已经减过 32 的 next_offset。
    // next_index 32..2079 才是 64 颗灯的位；换成 next_offset 就是 0..2047，
    // 写成 (next_offset>=32) 会把**第 0 颗灯**排除在像素区外（实测 p0 恒为 0）。
    wire        in_pixels  =(next_index>=12'd32)&&(next_index<12'd2080);

    // 物理接收者序号 -> 逻辑索引（L23 拆除后必须跳过一格，见上面的推导）
    wire [6:0] next_logic = (SKIP_DEAD!=0 && next_pixel>=DEAD_LOGIC)
                          ? ({1'b0,next_pixel}+7'd1) : {1'b0,next_pixel};
    // 行方向（只翻显示行，不翻弦色表）
    wire [1:0] next_str   = (ROW_FLIP!=0) ? ~next_logic[1:0] : next_logic[1:0];

    // 一级流水：像素起始拍（bpos=0）锁存「逻辑索引 / 这根弦 / 是否故障」
    reg [1:0] px_str;
    reg [6:0] px_logic;
    reg       px_bad,px_valid;
    always @(posedge clk)begin
        if(reset)begin px_str<=2'd0;px_logic<=7'd0;px_bad<=1'b0;px_valid<=1'b0;end
        else if(divider==8'd249&&sclk)begin
            if(in_pixels&&next_bpos==5'd0)begin
                px_str  <=next_str;
                px_logic<=next_logic;
                px_bad  <=i_fault[next_str]|i_common[next_str];
                px_valid<=1'b1;
            end else if(!in_pixels) px_valid<=1'b0;
        end
    end

    // R51：逻辑索引超出 31 个位置的一律填黑（那里没有灯珠）。
    //      L23 已经用 SKIP_DEAD 补偿掉，不再单独压黑。
    wire px_dead = (px_logic>LAST_IDX);

    // 二级流水：查表选颜色。纯 mux，不含乘法。
    // 压暗系数当前取 **0.5**（`>>1`）。历史教训写在这里防止再犯：
    //   曾经写成 `48+(48>>2)+(48>>4)` = 63 —— 那是 **1.3125 倍（更亮）**，不是 0.3125。
    //   纯缩放不能带基值：0.3125 -> (48>>2)+(48>>4) = 15；0.5 -> 48>>1 = 24。
    reg [7:0] rsel,gsel,bsel;
    always @(*)begin
        if(MODE==0)begin
            rsel=px_bad?8'd32:8'd0;
            gsel=(!px_bad&&i_ready[px_str])?8'd16:8'd0;
            bsel=(!px_bad&&!i_ready[px_str])?8'd16:8'd0;
        end else if(!px_valid||px_dead)begin
            rsel=8'd0;gsel=8'd0;bsel=8'd0;               // 空白区 / 31 个索引位置之外
        end else if(act[px_str])begin
            case(px_str)                                  // 该弦在发声：整行（8 个品）变弦色
                2'd0:begin rsel=8'd150;gsel=8'd60; bsel=8'd0;  end  // 弦0 琥珀
                2'd1:begin rsel=8'd0;  gsel=8'd150;bsel=8'd60; end  // 弦1 青绿
                2'd2:begin rsel=8'd0;  gsel=8'd60; bsel=8'd150;end  // 弦2 蓝
                default:begin rsel=8'd110;gsel=8'd0;bsel=8'd110;end // 弦3 紫
            endcase
        end else if(any_act_h)begin
            // 别处在发声（含 0.4 s 拖尾）、这一行不是：底色青压暗到 **0.5**（右移一位）
            rsel=8'd0;               gsel=8'd48>>1;  bsel=8'd64>>1;
        end else begin
            rsel=8'd0;gsel=8'd48;bsel=8'd64;              // 静默：31 颗完全一致的青
        end
    end
    reg [7:0] rsel_r,gsel_r,bsel_r;
    always @(posedge clk)begin
        rsel_r<=rsel;gsel_r<=gsel;bsel_r<=bsel;
    end

    // 三级流水：乘呼吸做电流缩放。输入已是寄存器，8×8 乘法单独占一拍，
    // 结果只在 bpos≥8（第一个 RGB 位）才被用到，还有 4000 clk 余量。
    //
    // 位宽陷阱（必读）：不能写成 `red <= (rsel_r*breath_r)>>8;`
    // 赋值左边是 8 位，Verilog 会把乘法结果**截断成 8 位**再移位 → 恒为 0，
    // 综合器报 EX3041「Right shift count >= width of value」并把整条链路优化掉。
    // 必须先把乘积落到 16 位线网上，再取高 8 位。
    // R50：发声那一行**不呼吸，常亮在满值** —— 变成一根稳定的"色柱"。
    //   理由（千问 + Kimi 独立指出）：整条一起加快呼吸会削弱"灯随这根弦"的因果，
    //   看起来像背景闪烁；而"别的行在慢慢呼吸、我弹的这行是稳的"一眼就能认出来。
    //   px_str 与 rsel_r 在同一个像素内都保持 32 拍不变，所以这里混用是安全的。
    wire px_lit = px_valid && !px_dead && act[px_str] && any_act_h;
    wire [7:0] breath_px = px_lit ? 8'd255 : breath_r;
    wire [15:0] mul_r=rsel_r*breath_px;
    wire [15:0] mul_g=gsel_r*breath_px;
    wire [15:0] mul_b=bsel_r*breath_px;
    reg [7:0] red,green,blue;
    always @(posedge clk)begin
        red  <=mul_r[15:8];
        green<=mul_g[15:8];
        blue <=mul_b[15:8];
    end

    wire [31:0] pixel_word={3'b111,BRI,blue,green,red};
    wire next_bit=(next_index<32)?1'b0:(next_index<2080)?
        pixel_word[5'd31-next_bpos]:(next_index<2112);
    always @(posedge clk)begin
        if(reset)begin divider<=0;bit_index<=0;sclk<=0;data<=0;end
        else if(divider==249)begin
            divider<=0;sclk<=!sclk;
            if(sclk)begin bit_index<=next_index;data<=next_bit;end
        end else divider<=divider+1'b1;
    end
endmodule
