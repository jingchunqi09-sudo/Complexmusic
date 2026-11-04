// 双模式包络：小提琴 ADSR；尤克里里拨弦即刻起音，随后由弦环自然衰减。
// 统一使用 Q0.15 正增益（0..32767），停止运弓时按 release 回到零。
module voice_envelope #(parameter integer CONTINUOUS_RETRIGGER = 0) (
    input             i_clk,
    input             i_reset,
    input             i_sample_tick,
    input             i_gate,           // 持续运弓；拨弦瞬时 gate 不截断弦尾音
    input             i_trigger,        // 本采样的重新起音事件
    input             i_plucked,        // 1=尤克里里，0=提琴
    input             i_stop,           // 显式停音，优先于同时到达的 trigger
    input [7:0]       i_attack_step,    // 每采样增加的 Q0.15 增益
    input [7:0]       i_decay_step,
    input [7:0]       i_sustain_level,  // Q0.8，扩展成 Q0.15
    input [7:0]       i_release_step,
    output reg [15:0] o_envelope
);
    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_ATTACK = 3'd1;
    localparam [2:0] STATE_DECAY = 3'd2;
    localparam [2:0] STATE_SUSTAIN = 3'd3;
    localparam [2:0] STATE_RELEASE = 3'd4;

    reg [2:0] r_state;       // 当前包络阶段
    reg r_gate_delayed;      // 系统时钟边沿检测历史，采样间变化不会丢
    reg r_plucked;           // 锁存起音时的激励类型
    wire w_gate_rise;
    wire w_gate_fall;
    wire [15:0] w_sustain_target;
    wire [16:0] w_attack_sum;
    wire [7:0] w_release_step_nonzero;
    wire [7:0] w_decay_step;

    assign w_gate_rise = i_gate & ~r_gate_delayed;
    assign w_gate_fall = ~i_gate & r_gate_delayed;
    // R6: plucked strings no longer hold a 93.75% constant sustain. The
    // envelope now decays to zero so the pluck has one natural tail instead
    // of a permanent pedestal under a 4 s waveguide ring (noise source #2 in
    // the 2026-10-28 diagnosis). decay_step>>4 of 24 is 1: 32767 samples to
    // zero = ~671 ms at 48.828 kHz.
    assign w_sustain_target = r_plucked ? 16'd0 : {1'b0, i_sustain_level, 7'd0};
    assign w_decay_step = r_plucked ? ((i_decay_step >> 4) < 8'd1 ? 8'd1 : i_decay_step >> 4)
                                    : i_decay_step;
    assign w_attack_sum = {1'b0, o_envelope} + {9'd0, i_attack_step};
    assign w_release_step_nonzero = i_release_step == 8'd0 ? 8'd1 : i_release_step;

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_state <= STATE_IDLE;
            r_gate_delayed <= 1'b0;
            r_plucked <= 1'b0;
            o_envelope <= 16'd0;
        end
        else
        begin
            r_gate_delayed <= i_gate;
            if (i_sample_tick && i_stop)
            begin
                // gate 不能区分瞬时拨弦和主动停音，因此 STOP 使用独立字段。
                // 在这一帧直接开始衰减，事件标签对应的是已变化的增益样本。
                if (o_envelope <= {8'd0, w_release_step_nonzero})
                begin
                    o_envelope <= 16'd0;
                    r_state <= STATE_IDLE;
                end
                else
                begin
                    o_envelope <= o_envelope - {8'd0, w_release_step_nonzero};
                    r_state <= STATE_RELEASE;
                end
            end
            else if (i_sample_tick && i_trigger)
            begin
                r_plucked <= i_plucked;
                if (i_plucked)
                begin
                    if (CONTINUOUS_RETRIGGER != 0 && o_envelope != 0)
                    begin
                        r_state <= STATE_ATTACK;
                    end
                    else
                    begin
                        o_envelope <= 16'h7fff;
                        r_state <= STATE_DECAY;
                    end
                end
                else
                begin
                    // 有界小初始增益避免新的物理摩擦起音被多声部右移量化为零。
                    // 初值最大 4080（约满量程 12%），其后仍每样本按 attack_step 增长。
                    if (CONTINUOUS_RETRIGGER == 0 || o_envelope == 0)
                        o_envelope <= {4'd0, i_attack_step, 4'd0};
                    r_state <= STATE_ATTACK;
                end
            end
            else if (w_gate_fall && !r_plucked)
                r_state <= STATE_RELEASE;
            else if (w_gate_rise && !r_plucked && !i_sample_tick)
                r_state <= STATE_ATTACK;
            else if (i_sample_tick)
            begin
                case (r_state)
                    STATE_ATTACK:
                    begin
                        if (w_attack_sum >= 17'd32767)
                        begin
                            o_envelope <= 16'h7fff;
                            r_state <= STATE_DECAY;
                        end
                        else
                            o_envelope <= w_attack_sum[15:0];
                    end
                    STATE_DECAY:
                    begin
                        if (o_envelope <= w_sustain_target + {8'd0, w_decay_step})
                        begin
                            o_envelope <= w_sustain_target;
                            r_state <= STATE_SUSTAIN;
                        end
                        else
                            o_envelope <= o_envelope - {8'd0, w_decay_step};
                    end
                    STATE_SUSTAIN: o_envelope <= w_sustain_target;
                    STATE_RELEASE:
                    begin
                        if (o_envelope <= {8'd0, w_release_step_nonzero})
                        begin
                            o_envelope <= 16'd0;
                            r_state <= STATE_IDLE;
                        end
                        else
                            o_envelope <= o_envelope - {8'd0, w_release_step_nonzero};
                    end
                    default: o_envelope <= 16'd0;
                endcase
            end
        end
    end
endmodule
