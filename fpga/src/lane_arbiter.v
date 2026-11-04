`timescale 1ns/1ps
//=============================================================================
// lane_arbiter.v — 物理演奏事件 与 曲谱事件 合并到同一条 voice 总线
//
// 背景：instrument_bank_core 接受一条"8 lane 电平 + 脉冲"混合总线
// （依据 src/instrument_bank_core.v:14-19 的 i_note_bus/i_gate_bus/
//   i_trigger_bus/i_stop_bus/i_velocity_bus/i_speed_bus/i_direction_bus）。
// 物理前端与曲谱播放器都要驱动它，因此必须仲裁。
//
// 仲裁规则（人手优先，避免自动播放"抢走"正在拉的弦）：
//   note     : 该 lane 有物理 gate 或 trigger 时用物理音高，否则用曲谱持有值
//   gate     : 或（物理弓 gate ∪ 曲谱 BOW）
//   trigger  : 或（物理拨弦 ∪ 曲谱 PLUCK）
//   stop     : 或（物理停止 ∪ 曲谱 STOP）
//   velocity : 物理有效时用物理值，否则用曲谱值
//   speed    : 物理在拉时用物理弓速；曲谱持有该 lane（BOW 电平有效）时用 vel+32
//              （vel 0/64/127 → 32/96/159 → 弓压 224/240/255）。
//              没有这个映射，曲谱长音会因为 i_bow_speed=0 完全不发声。
//   trigger  : BOW 事件除了拉高电平，还会打一拍 trigger —— 小提琴波导的冷启动
//              要求 trigger 与 gate 同时出现（见 2'd1 分支的注释）。
//   event    : 或，任一侧有事件就置 1
//=============================================================================
module lane_arbiter (
    input  wire        clk,
    input  wire        reset,
    // 物理演奏总线
    input  wire [55:0] p_note,
    input  wire [7:0]  p_gate,
    input  wire [7:0]  p_trigger,
    input  wire [7:0]  p_stop,
    input  wire [63:0] p_velocity,
    input  wire [127:0] p_speed,
    input  wire [7:0]  p_direction,
    input  wire        p_ev,
    // 曲谱事件
    input  wire        s_ev_valid,
    input  wire [1:0]  s_kind,
    input  wire [2:0]  s_lane,
    input  wire [6:0]  s_note,
    input  wire [6:0]  s_vel,
    // 合并输出
    output wire [55:0] o_note,
    output wire [7:0]  o_gate,
    output wire [7:0]  o_trigger,
    output wire [7:0]  o_stop,
    output wire [63:0] o_velocity,
    output wire [127:0] o_speed,
    output wire [7:0]  o_direction,
    output wire        o_ev
);
    reg [6:0] r_hold [0:7];
    reg [7:0] r_hold_en;
    reg [7:0] r_bow_lvl;      // R26：BOW 的**电平** gate（到 STOP 才清）
    reg [7:0] r_vel  [0:7];
    reg [7:0] r_trig;
    reg [7:0] r_bow;
    reg [7:0] r_stp;
    integer i;

    // 曲谱事件锁存
    always @(posedge clk) begin
        if (reset) begin
            r_hold_en <= 8'd0;
            r_bow_lvl <= 8'd0;
            r_trig    <= 8'd0;
            r_bow     <= 8'd0;
            r_stp     <= 8'd0;
            for (i = 0; i < 8; i = i + 1) begin
                r_hold[i] <= 7'd0;
                r_vel[i]  <= 8'd0;
            end
        end else begin
            r_trig <= 8'd0;
            r_bow  <= 8'd0;
            r_stp  <= 8'd0;
            if (s_ev_valid) begin
                case (s_kind)
                    2'd0: begin                      // PLUCK
                        r_hold[s_lane]    <= s_note;
                        r_hold_en[s_lane] <= 1'b1;
                        r_vel[s_lane]     <= {s_vel, 1'b0};
                        r_trig[s_lane]    <= 1'b1;
                    end
                    2'd1: begin                      // BOW
                        r_hold[s_lane]    <= s_note;
                        r_hold_en[s_lane] <= 1'b1;
                        r_vel[s_lane]     <= {s_vel, 1'b0};
                        r_bow[s_lane]     <= 1'b1;
                        r_bow_lvl[s_lane] <= 1'b1;   // R26：电平，撑到 STOP
                        // R31：BOW 事件必须**同时**给一个 trigger 脉冲。
                        // 原因在 violin_waveguide_voice.v：
                        //   w_contact_allowed = i_gate && (!r_require_cold_start || i_trigger)
                        //   w_bow_target_velocity = !w_contact_allowed ? 0 : ...
                        // 冷启动（或 STOP 之后）r_require_cold_start=1，只有 gate 没有
                        // trigger 时接触永远不成立、目标弓速恒 0 —— 波导收不到一点能量，
                        // 于是"事件进得去、声音出不来"。物理通路的弓起音沿本来就会同时
                        // 给一个 violin_attack 脉冲，这里对齐同一套语义。
                        // 脉冲只持续 1 拍（20 ns），不影响后续的电平维持。
                        r_trig[s_lane]    <= 1'b1;
                    end
                    2'd2: begin                      // STOP
                        r_hold_en[s_lane] <= 1'b0;
                        r_bow[s_lane]     <= 1'b0;
                        r_bow_lvl[s_lane] <= 1'b0;
                        r_stp[s_lane]     <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    genvar g;
    // R25：曲谱 lane 没有物理弓速。小提琴波导的 i_bow_speed 同时控制
    // w_bow_target_velocity（0 就不发声）和弓压前馈，所以必须给一个非零值，
    // 否则 BOW/PLUCK 事件全都静音——这是 R18 版本"能存不能播"的真实原因之一。
    //
    // 固定值会让长音听起来"平"（弓压恒在 p_eff = 224 + (spd-32)>>2），
    // 所以按事件的力度字节映射：speed = vel + 32，范围 32..159。
    //   vel=0   -> 32  -> p_eff=224（最轻，仍在粘着台阶上沿）
    //   vel=64  -> 96  -> p_eff=240
    //   vel=127 -> 159 -> p_eff=255（饱和）
    // 千问与 Kimi 在 R25 评审里独立给出同一条建议（我原先写死 96）。
    // 代价：每 lane 一个 8 位加法，共约 16 LUT。

    generate for (g = 0; g < 8; g = g + 1) begin: LANE
        wire phys_active = p_gate[g] | p_trigger[g];
        wire [7:0] score_spd = (r_vel[g] >> 1) + 8'd32;   // r_vel 存的是 vel<<1
        assign o_note[g*7 +: 7] = (r_hold_en[g] && !phys_active) ? r_hold[g]
                                                                 : p_note[g*7 +: 7];
        assign o_velocity[g*8 +: 8] = phys_active ? p_velocity[g*8 +: 8]
                                                  : (r_hold_en[g] ? r_vel[g] : p_velocity[g*8 +: 8]);
        // 人手在拉这根弦时用物理弓速；曲谱 BOW 持有该 lane 时用力度映射值。
        assign o_speed[g*16 +: 16] = (phys_active || !r_bow_lvl[g]) ?
                                     p_speed[g*16 +: 16] : {8'd0, score_spd};
    end endgenerate

    // R26：BOW 用**电平**（r_bow_lvl），不是单拍脉冲。
    // R25 这里是 p_gate | r_bow，而 r_bow 每拍先清 0、只在事件那一拍置 1，
    // 于是曲谱 BOW 只给出 20 ns 的 gate —— 小提琴波导的 gate 是电平维持，
    // 长音根本发不出来（PLUCK 用脉冲是对的，uke 是触发式）。
    assign o_gate      = p_gate | r_bow_lvl;
    assign o_trigger   = p_trigger | r_trig;
    assign o_stop      = p_stop | r_stp;
    assign o_direction = p_direction;
    assign o_ev        = p_ev | s_ev_valid;
endmodule
