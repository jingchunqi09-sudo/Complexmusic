// Fixed 4 bowed + 4 plucked physical banks. No paired timbre mux or octave replicas.
// R9 frame schedule: snapshot -> shared expression/control -> 8 strings ->
// shared four-lane expression engine -> tagged envelope multiplier -> modal body -> independent FX.
// Each string retains its own physical and envelope state. The 768clk deadline
// is below both 1024clk (default Fs) and 1041clk (48k) output-frame intervals.
// R13b: MIX_HEADROOM_SHIFT 改为 0（不再预先衰减），音量由软限幅器决定。
// 原 ÷8 是按"8 声部同时满幅不削顶"设的，代价是单声部只剩 4095（-18 dB）。
// 软限幅：|x|<=24576 完全直通；超过后斜率 1/32 渐近饱和，8 声部满幅也能装进 16 位。
module instrument_bank_core #(
parameter integer DELAY_LINE_LENGTH=1024,
parameter integer SAMPLE_RATE_MILLIHZ=48828125,
parameter integer MIX_HEADROOM_SHIFT=0,
parameter integer ENABLE_COMMON_BODY=1,
parameter integer VIOLIN_BODY_MIX=0,
parameter integer VIOLIN_CONTROL_PROFILE=1,
// R16：小提琴声部相对尤克里里的配平。用户反馈"小提琴音量偏大"。
// 四个 violin voice（v=0..3）在进入包络乘法前右移 SHIFT 位：
// 1 = -6 dB，2 = -12 dB。uke（v=4..7）不受影响。
// 放在包络乘法之前而不是混音出口，是为了让软限幅的工作点也跟着下移，
// 避免小提琴把整个混音推到限幅区、把尤克里里也一起压扁。
parameter integer VIOLIN_TRIM_SHIFT=1
)(
input i_clk, input i_reset, input i_sample_tick, input i_event,
input [31:0] i_event_sequence, input [63:0] i_event_clock,
input [55:0] i_note_bus, input [7:0] i_gate_bus,
input [7:0] i_trigger_bus, input [7:0] i_stop_bus,
input [63:0] i_velocity_bus, input [127:0] i_speed_bus,
input [191:0] i_position_bus, input [7:0] i_direction_bus,
input [31:0] i_vibrato_depth, input [31:0] i_vibrato_rate,
input [31:0] i_glide_ms, input [3:0] i_auto_expression,
input i_emergency, input i_fx_bypass, input [7:0] i_wet,
input [7:0] i_damping, input [1:0] i_tail,
// 总音色（timbre_shaper）：0..4095，2048 = 0 dB；i_tone_enable=0 时平滑回直通
input [11:0] i_tone_bright, input [11:0] i_tone_warm, input i_tone_enable,
output [15:0] o_tone_clip,
output reg signed [15:0] o_audio_sample,
output reg o_audio_sample_valid, output reg o_audio_first_sample,
output o_ready, output [127:0] o_voice_sample_bus, output [7:0] o_active_mask,
output [31:0] o_body_guards, output [31:0] o_body_clips,
output reg [31:0] o_output_sequence, output reg [63:0] o_output_event_clock,
output reg [31:0] o_output_first_sequence, output reg [15:0] o_output_event_count,
output reg [31:0] o_deadline_count, output reg [15:0] o_max_compute_clocks,
output [31:0] o_reverb_guard,
output reg [31:0] o_clip_count
);
reg [7:0] r_trigger_pending, r_stop_pending;
reg [55:0] r_trigger_note;
reg [63:0] r_trigger_velocity;
reg [127:0] r_trigger_speed;
reg [191:0] r_trigger_position;
reg [7:0] r_trigger_direction;
reg r_event_pending, r_tag;
reg [31:0] r_sequence;
reg [63:0] r_event_clock;
reg [31:0] r_pending_first_sequence, r_first_sequence;
reg [63:0] r_pending_oldest_clock;
reg [15:0] r_pending_event_count, r_event_count;
reg [9:0] r_phase;
reg [15:0] r_compute_clocks;
reg [55:0] r_note, r_selected_note;
reg [7:0] r_gate, r_trigger, r_stop, r_direction;
reg [63:0] r_velocity;
reg [127:0] r_speed;
reg [191:0] r_position;
reg [31:0] r_depth, r_rate, r_glide;
reg [3:0] r_auto;
wire [7:0] w_voice_ready;
wire signed [15:0] w_voice [0:7];
wire [15:0] w_envelope [0:7];
// Isolate each completed string sample from the envelope multiplier path.
reg signed [15:0] r_voice_stage [0:7] /* synthesis syn_preserve = 1 */;
reg signed [31:0] r_gain [0:7];
reg signed [31:0] r_gain_product;
reg [2:0] r_gain_lane;
reg r_gain_valid;
reg r_body_valid_d1;
reg r_body_valid_d2;
reg signed [16:0] r_pairs [0:3];
reg signed [17:0] r_drive [0:1];
wire signed [17:0] w_body [0:1];
reg signed [18:0] r_mix;
reg signed [15:0] r_dry;
wire w_fx_ready, w_fx_valid;
wire signed [15:0] w_fx_sample;
wire w_model_tick, w_prepare_tick, w_body_tick, w_fx_tick;
wire w_body_valid;
wire w_body_ready;
wire [127:0] w_expression_period;
wire [191:0] w_pluck_parameters;
wire w_expression_ready;
wire w_expression_valid;
reg r_available;
wire [35:0] w_body_sample_bus;
wire w_frame_timeout;
wire [2:0] w_gain_issue_lane;
assign w_frame_timeout=r_phase==767 && !w_fx_valid;
assign w_gain_issue_lane=r_phase[2:0]-3'd2;
assign w_prepare_tick=r_phase==55;
assign w_model_tick=r_phase==88;
assign w_body_tick=r_phase==101;
assign w_fx_tick=r_body_valid_d2 && r_phase!=0;
assign w_body[0]=w_body_sample_bus[17:0];
assign w_body[1]=w_body_sample_bus[35:18];
// Registered initialization readiness cuts reset -> voice -> router timing.
// This remains initialization readiness, not a new per-frame backpressure API.
assign o_ready=r_available;
always @(posedge i_clk)
begin
    if(i_reset || i_emergency || w_frame_timeout) r_available<=0;
    else r_available<=(&w_voice_ready) && w_fx_ready;
end
violin_expression_bank #(.DELAY_LINE_LENGTH(DELAY_LINE_LENGTH),.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) u_expression_bank (
    .i_clk(i_clk),.i_reset(i_reset || i_emergency || w_frame_timeout),.i_start(r_phase==2),
    .i_note(r_note[27:0]),.i_pluck_note(r_note[55:28]),.i_gate(r_gate[3:0]),.i_auto(r_auto),
    .i_depth(r_depth),.i_rate(r_rate),.i_glide(r_glide),
    .o_period(w_expression_period),.o_pluck_parameters(w_pluck_parameters),.o_ready(w_expression_ready),.o_valid(w_expression_valid)
);

genvar v;
generate
    for(v=0;v<8;v=v+1)
    begin: PHYSICAL_STRING
        if(v<4)
        begin: BOWED
            violin_waveguide_voice #(
            .DELAY_LINE_LENGTH(DELAY_LINE_LENGTH),
            .SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),
            .BOW_CONTROL_PROFILE(VIOLIN_CONTROL_PROFILE),
            .SEPARATE_CONTROL_PREPARE(1),.ENABLE_MOVING_BOW_POSITION(1),.ENABLE_FINE_PITCH(1),.SHARE_INTERPOLATION_MULTIPLIER(1)
            ) u_string (
            .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_sample_tick(w_model_tick),
            .i_prepare_tick(w_prepare_tick),.i_period_q16(w_expression_period[v*32 +:32]),
            .i_stop(r_stop[v]),.i_trigger(r_trigger[v] && !r_stop[v]),
            .i_gate(r_gate[v] && !r_stop[v]),
            .i_midi_note(r_note[v*7 +:7]),.i_velocity(r_velocity[v*8 +:8]),
            .i_bow_speed(r_speed[v*16 +:16]),.i_bow_direction(r_direction[v]),
            .i_bow_position(r_position[v*24 +:24]),
            .o_audio_sample(w_voice[v]),.o_ready(w_voice_ready[v])
            );
        end
        else
        begin: PLUCKED
            ukulele_waveguide_voice #(
            .DELAY_LINE_LENGTH(DELAY_LINE_LENGTH),
            .SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),.ENABLE_EXTERNAL_PITCH(1)
            ) u_string (
            .i_external_period_q16(w_pluck_parameters[(v-4)*48 +:32]),
            .i_external_excitation_step(w_pluck_parameters[(v-4)*48+32 +:16]),
            .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_sample_tick(w_model_tick),
            .i_stop(r_stop[v]),.i_trigger(r_trigger[v] && !r_stop[v]),
            .i_gate(1'b0),.i_midi_note(r_note[v*7 +:7]),
            .i_velocity(r_velocity[v*8 +:8]),
            .o_audio_sample(w_voice[v]),.o_ready(w_voice_ready[v]),.o_guard_count()
            );
        end
        voice_envelope #(.CONTINUOUS_RETRIGGER(1)) u_envelope (
        .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_sample_tick(w_model_tick),
        .i_gate(r_gate[v]),.i_trigger(r_trigger[v] && !r_stop[v]),
        .i_plucked(v>=4),.i_stop(r_stop[v]),
        .i_attack_step(8'd80),.i_decay_step(8'd24),
        .i_sustain_level(8'd190),.i_release_step(8'd24),
        .o_envelope(w_envelope[v])
        );
        assign o_voice_sample_bus[v*16 +:16]=w_voice[v];
        assign o_active_mask[v]=w_envelope[v]!=0;
    end
endgenerate
instrument_body_resonator_tdm #(
    .SAMPLE_WIDTH(18),.PRESERVE_BYPASS_STATE(1),
    .BODY0_VIOLIN_RADIATION_MIX(VIOLIN_BODY_MIX),.BODY1_VIOLIN_RADIATION_MIX(0)
) u_public_bodies (
    .i_clk(i_clk),.i_reset(i_reset || i_emergency || w_frame_timeout),.i_start(w_body_tick),
    .i_trigger(2'b00),.i_bypass({2{ENABLE_COMMON_BODY==0}}),.i_instrument(2'b10),
    .i_sample_bus({r_drive[1],r_drive[0]}),.o_sample_bus(w_body_sample_bus),
    .o_guard_count(o_body_guards),.o_clip_count(o_body_clips),
    .o_valid(w_body_valid),.o_ready(w_body_ready)
);
small_room_reverb #(.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) u_room (
.i_clk(i_clk),.i_reset(i_reset || i_emergency || w_frame_timeout),.i_clear(i_emergency || w_frame_timeout),
.i_sample_tick(w_fx_tick),.i_sample(r_dry),.i_bypass(i_fx_bypass),
.i_wet(i_wet),.i_damping(i_damping),.i_tail(i_tail),
.o_sample(w_fx_sample),.o_sample_valid(w_fx_valid),
.o_ready(w_fx_ready),.o_guard_count(o_reverb_guard)
);
//-----------------------------------------------------------------------------
// 总音色：混响之后、PT8211 之前。
//
// 时钟预算：本模块一帧 768 拍（r_phase 0..767），而 sample_tick 每 1024 拍一次，
// 所以帧尾还有 256 拍余量。timbre_shaper 固定 15 拍延迟，且**不复位 r_phase**，
// 因此帧长不变、`w_frame_timeout` 的判据（r_phase==767 && !w_fx_valid）不受影响。
// 若把 r_phase<=0 挪到 w_tone_valid，w_fx_valid 在 753..767 之间到达时会先在
// 767 触发 frame_timeout（此时 !w_fx_valid 成立），既丢样本又多出一个静音帧。
wire signed [15:0] w_tone_sample;
wire               w_tone_valid;
timbre_shaper #(.PARAM_WIDTH(12)) u_tone (
.i_clk(i_clk),
.i_reset(i_reset || i_emergency),
.i_sample_valid(w_fx_valid),
.i_sample(w_fx_sample),
.i_bright(i_tone_bright), .i_warm(i_tone_warm), .i_enable(i_tone_enable),
.o_sample(w_tone_sample), .o_sample_valid(w_tone_valid),
.o_clip_count(o_tone_clip),
.o_gain_low(), .o_gain_high()
);
integer n;
reg signed [18:0] scaled;
always @(posedge i_clk)
begin
    if(i_reset)
    begin
        r_trigger_pending<=0; r_stop_pending<=0; r_event_pending<=0;
        r_trigger_note<=0; r_trigger_velocity<=0; r_trigger_speed<=0;
        r_trigger_position<=0; r_trigger_direction<=0;
        r_phase<=0; r_tag<=0; r_sequence<=0; r_event_clock<=0;
        r_note<=0; r_selected_note<=0; r_gate<=0; r_trigger<=0; r_stop<=0;
        r_velocity<=0; r_speed<=0; r_position<=0; r_direction<=0;
        r_depth<=0; r_rate<=0; r_glide<=0; r_auto<=0;
        r_mix<=0; r_dry<=0; r_compute_clocks<=0;
        r_gain_product<=0; r_gain_lane<=0; r_gain_valid<=0;
        r_body_valid_d1<=0; r_body_valid_d2<=0;
        o_audio_sample<=0; o_audio_sample_valid<=0; o_audio_first_sample<=0;
        o_output_sequence<=0; o_output_event_clock<=0;
        o_output_first_sequence<=0; o_output_event_count<=0;
        r_pending_first_sequence<=0; r_pending_oldest_clock<=0; r_first_sequence<=0;
        r_pending_event_count<=0; r_event_count<=0;
        o_deadline_count<=0; o_max_compute_clocks<=0; o_clip_count<=0;
        for(n=0;n<8;n=n+1)
        begin
            r_voice_stage[n]<=0;
            r_gain[n]<=0;
        end
        for(n=0;n<4;n=n+1) r_pairs[n]<=0;
        r_drive[0]<=0; r_drive[1]<=0;
    end
    else
    begin
        o_audio_sample_valid<=0; o_audio_first_sample<=0;
        // Later triggers recover a prior STOP; simultaneous STOP always wins.
        r_trigger_pending<=(r_trigger_pending|i_trigger_bus)&~i_stop_bus;
        r_stop_pending<=(r_stop_pending&~i_trigger_bus)|i_stop_bus;
        for(n=0;n<8;n=n+1)
        begin
            if(i_trigger_bus[n] && !i_stop_bus[n])
            begin
                r_trigger_note[n*7 +:7]<=i_note_bus[n*7 +:7];
                r_trigger_velocity[n*8 +:8]<=i_velocity_bus[n*8 +:8];
                r_trigger_speed[n*16 +:16]<=i_speed_bus[n*16 +:16];
                r_trigger_position[n*24 +:24]<=i_position_bus[n*24 +:24];
                r_trigger_direction[n]<=i_direction_bus[n];
            end
        end
        r_event_pending<=r_event_pending|i_event;
        if(i_event)
        begin
            if(!r_event_pending)
            begin
                r_pending_first_sequence<=i_event_sequence;
                r_pending_oldest_clock<=i_event_clock;
            end
            if(r_pending_event_count!=16'hffff) r_pending_event_count<=r_pending_event_count+1'b1;
        end
        // Snapshot the completed physical strings, then issue one lane per clk.
        // Register the lane tag with the product so no voice can consume another
        // voice's envelope. Truncation remains AFTER the signed 16x16 product.
        r_gain_valid <= r_phase>=90 && r_phase<=97;
        if(r_phase==89)
        begin
            for(n=0;n<8;n=n+1)
                r_voice_stage[n] <= (n<4) ? (w_voice[n] >>> VIOLIN_TRIM_SHIFT) : w_voice[n];
        end
        if(r_phase>=90 && r_phase<=97)
        begin
            r_gain_product <= $signed(r_voice_stage[w_gain_issue_lane]) *
                              $signed({1'b0,w_envelope[w_gain_issue_lane][14:0]});
            r_gain_lane <= w_gain_issue_lane;
        end
        for(n=0;n<8;n=n+1)
        begin
            if(r_gain_valid && r_gain_lane==n) r_gain[n] <= r_gain_product;
        end
        r_body_valid_d1 <= w_body_valid && r_phase!=0;
        r_body_valid_d2 <= r_body_valid_d1;
        if(i_emergency)
        begin
            r_phase<=0; r_gate<=0; r_trigger_pending<=0;
            r_stop_pending<=0; r_trigger<=0; r_stop<=0; r_mix<=0; r_dry<=0; o_audio_sample<=0;
            o_audio_sample_valid<=0; o_audio_first_sample<=0;
            o_output_sequence<=i_event_sequence; o_output_event_clock<=i_event_clock;
            o_output_first_sequence<=i_event_sequence; o_output_event_count<=1;
            r_event_pending<=1; r_pending_event_count<=1;
            r_pending_first_sequence<=i_event_sequence; r_pending_oldest_clock<=i_event_clock;
            r_gain_valid<=0; r_body_valid_d1<=0; r_body_valid_d2<=0;
        end
        else if(i_sample_tick && o_ready && r_phase==0)
        begin
            r_note<=i_note_bus; r_selected_note<=i_note_bus; r_gate<=i_gate_bus;
            r_stop<=(r_stop_pending&~i_trigger_bus)|i_stop_bus;
            r_trigger<=(r_trigger_pending|i_trigger_bus)&~((r_stop_pending&~i_trigger_bus)|i_stop_bus);
            r_velocity<=i_velocity_bus; r_speed<=i_speed_bus;
            r_position<=i_position_bus; r_direction<=i_direction_bus;
            for(n=0;n<8;n=n+1)
            begin
                if(r_trigger_pending[n] && !i_trigger_bus[n])
                begin
                    r_note[n*7 +:7]<=r_trigger_note[n*7 +:7];
                    r_velocity[n*8 +:8]<=r_trigger_velocity[n*8 +:8];
                    r_speed[n*16 +:16]<=r_trigger_speed[n*16 +:16];
                    r_position[n*24 +:24]<=r_trigger_position[n*24 +:24];
                    r_direction[n]<=r_trigger_direction[n];
                end
            end
            r_depth<=i_vibrato_depth; r_rate<=i_vibrato_rate;
            r_glide<=i_glide_ms; r_auto<=i_auto_expression;
            r_tag<=r_event_pending|i_event;
            r_sequence<=i_event_sequence;
            r_event_clock<=r_event_pending ? r_pending_oldest_clock : i_event_clock;
            r_first_sequence<=r_event_pending ? r_pending_first_sequence : i_event_sequence;
            r_event_count <= r_pending_event_count == 16'hffff ? 16'hffff :
                r_pending_event_count + (i_event ? 1'b1 : 1'b0);
            r_pending_event_count<=0;
            r_trigger_pending<=0; r_stop_pending<=0; r_event_pending<=0;
            r_phase<=1; r_compute_clocks<=0;
        end
        else if(r_phase!=0)
        begin
            r_compute_clocks<=r_compute_clocks+1'b1;
            if(r_phase<767) r_phase<=r_phase+1'b1;
            if(i_sample_tick)
            o_deadline_count<=o_deadline_count+1'b1;
            if(r_phase==99)
            for(n=0;n<4;n=n+1)
            r_pairs[n]<=($signed(r_gain[n*2])>>>15)+($signed(r_gain[n*2+1])>>>15);
            if(r_phase==100)
            begin
                r_drive[0]<=$signed(r_pairs[0])+$signed(r_pairs[1]);
                r_drive[1]<=$signed(r_pairs[2])+$signed(r_pairs[3]);
            end
            if(w_body_valid) r_mix<=$signed(w_body[0])+$signed(w_body[1]);
            if(r_body_valid_d1)
            begin
                // R13b 软限幅：|x|<=24576 完全直通（单/双声部无损），超过后斜率 1/32，
                // 输出渐近 32000，不再硬削顶。全程只有比较、加法与移位，无乘法器。
                // 实测映射：1 声部 32767->24832（-2.4 dB，原来 -18 dB）；2 声部->25856；
                // 4 声部->27904；8 声部 262136->31999（刚好装进 16 位）。
                scaled=$signed(r_mix)>>>MIX_HEADROOM_SHIFT;
                if(scaled>32'sd24576)
                    r_dry<=16'sd24576+((scaled-32'sd24576)>>>5);
                else if(scaled< -32'sd24576)
                    r_dry<=-16'sd24576+((scaled+32'sd24576)>>>5);
                else
                    r_dry<=scaled[15:0];
                if(scaled>32'sd32000 || scaled< -32'sd32000)
                    o_clip_count<=o_clip_count+1'b1;
            end
            if(w_fx_valid)
            begin
                o_output_sequence<=r_sequence; o_output_event_clock<=r_event_clock;
                o_output_first_sequence<=r_first_sequence; o_output_event_count<=r_event_count;
                if(r_compute_clocks>o_max_compute_clocks)
                o_max_compute_clocks<=r_compute_clocks;
                r_phase<=0;
            end
            if(w_frame_timeout)
            begin
                // This frame was lost: emit one tagged silence sample, never
                // claim a first audible sample. Abort both downstream engines
                // so a late result cannot be mistaken for the next frame.
                o_deadline_count<=o_deadline_count+1'b1;
                o_audio_sample<=0; o_audio_sample_valid<=1; o_audio_first_sample<=0;
                o_output_sequence<=r_sequence; o_output_event_clock<=r_event_clock;
                o_output_first_sequence<=r_first_sequence; o_output_event_count<=r_event_count;
                if(r_compute_clocks>o_max_compute_clocks)
                    o_max_compute_clocks<=r_compute_clocks;
                r_phase<=0; r_tag<=0;
                r_gain_valid<=0; r_body_valid_d1<=0; r_body_valid_d2<=0;
            end
        end
        // 音色模块固定 15 拍延迟，样本与 first_sample 标记必须同一拍发出
        // （pt8211_tx 的 mailbox 在装载样本的同一拍采 event 标记）。
        //
        // 这一段**必须留在 else if(r_phase!=0) 之外**：w_fx_valid 那拍已经把
        // r_phase 清 0，15 拍后 w_tone_valid 正好落在空闲窗（r_phase 0..14），
        // 写进 r_phase!=0 分支里会被整段跳过 —— 实测第 3 帧就丢样本，
        // tb_physical_bank_integration 报 "prior PCM completed before next frame start"。
        if(w_tone_valid && !i_emergency)
        begin
            o_audio_sample<=w_tone_sample; o_audio_sample_valid<=1;
            o_audio_first_sample<=r_tag;
        end
    end
end
endmodule
