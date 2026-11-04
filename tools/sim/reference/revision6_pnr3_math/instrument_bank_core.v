// Fixed 4 bowed + 4 plucked physical banks. No paired timbre mux or octave replicas.
// Frame schedule: snapshot -> expression/control -> 8 simultaneous strings ->
// envelope drivers -> two wide public bodies -> final quantization -> independent FX.
module instrument_bank_core #(
parameter integer DELAY_LINE_LENGTH=1024,
parameter integer SAMPLE_RATE_MILLIHZ=48828125,
parameter integer MIX_HEADROOM_SHIFT=2,
parameter integer ENABLE_COMMON_BODY=1
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
reg [6:0] r_phase;
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
reg signed [16:0] r_pairs [0:3];
reg signed [17:0] r_drive [0:1];
wire signed [17:0] w_body [0:1];
reg signed [18:0] r_mix;
reg signed [15:0] r_dry;
wire w_fx_ready, w_fx_valid;
wire signed [15:0] w_fx_sample;
wire w_model_tick, w_prepare_tick, w_body_tick, w_fx_tick;
assign w_prepare_tick=r_phase==3;
assign w_model_tick=r_phase==20;
assign w_body_tick=r_phase==32;
assign w_fx_tick=r_phase==36;
assign o_ready=(&w_voice_ready) && w_fx_ready;
genvar v;
generate
    for(v=0;v<8;v=v+1)
    begin: PHYSICAL_STRING
        if(v<4)
        begin: BOWED
            wire [31:0] w_period;
            violin_expression #(.DELAY_LINE_LENGTH(DELAY_LINE_LENGTH),.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) u_expression (
            .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_tick(r_phase==2),
            .i_gate(r_gate[v]),.i_note(r_note[v*7 +:7]),
            .i_depth_cents(r_depth[v*8 +:8]),.i_rate_decihz(r_rate[v*8 +:8]),
            .i_glide_ms(r_glide[v*8 +:8]),.i_auto(r_auto[v]),
            .o_period_q16(w_period)
            );
            violin_waveguide_voice #(
            .DELAY_LINE_LENGTH(DELAY_LINE_LENGTH),
            .SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),
            .ENABLE_BODY_FILTER(0),.ENABLE_BODY_RESONATOR(0),
            .SEPARATE_CONTROL_PREPARE(1),.ENABLE_FINE_PITCH(1)
            ) u_string (
            .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_sample_tick(w_model_tick),
            .i_prepare_tick(w_prepare_tick),.i_period_q16(w_period),
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
            .SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),.OUTPUT_BARE_STRING(1)
            ) u_string (
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
    for(v=0;v<2;v=v+1)
    begin: PUBLIC_BODY
        instrument_body_resonator #(.SAMPLE_WIDTH(18),.PRESERVE_BYPASS_STATE(1)) u_body (
        .i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_sample_tick(w_body_tick),
        .i_trigger(1'b0),.i_bypass(ENABLE_COMMON_BODY==0),.i_instrument(v==1),
        .i_sample(r_drive[v]),.o_sample(w_body[v]),
        .o_guard_count(o_body_guards[v*16 +:16]),.o_clip_count(o_body_clips[v*16 +:16])
        );
    end
endgenerate
small_room_reverb #(.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) u_room (
.i_clk(i_clk),.i_reset(i_reset || i_emergency),.i_clear(i_emergency),
.i_sample_tick(w_fx_tick),.i_sample(r_dry),.i_bypass(i_fx_bypass),
.i_wet(i_wet),.i_damping(i_damping),.i_tail(i_tail),
.o_sample(w_fx_sample),.o_sample_valid(w_fx_valid),
.o_ready(w_fx_ready),.o_guard_count(o_reverb_guard)
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
        for(n=0;n<8;n=n+1)
        begin
            r_voice_stage[n] <= w_voice[n];
            r_gain[n] <= $signed(r_voice_stage[n]) * $signed({1'b0,w_envelope[n][14:0]});
        end
        if(i_emergency)
        begin
            r_phase<=0; r_gate<=0; r_trigger_pending<=0;
            r_stop_pending<=0; r_trigger<=0; r_stop<=0; r_mix<=0; r_dry<=0; o_audio_sample<=0;
            o_audio_sample_valid<=0; o_audio_first_sample<=0;
            o_output_sequence<=i_event_sequence; o_output_event_clock<=i_event_clock;
            o_output_first_sequence<=i_event_sequence; o_output_event_count<=1;
            r_event_pending<=1; r_pending_event_count<=1;
            r_pending_first_sequence<=i_event_sequence; r_pending_oldest_clock<=i_event_clock;
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
            if(r_phase<127) r_phase<=r_phase+1'b1;
            if(i_sample_tick)
            o_deadline_count<=o_deadline_count+1'b1;
            if(r_phase==24)
            for(n=0;n<4;n=n+1)
            r_pairs[n]<=($signed(r_gain[n*2])>>>15)+($signed(r_gain[n*2+1])>>>15);
            if(r_phase==25)
            begin
                r_drive[0]<=$signed(r_pairs[0])+$signed(r_pairs[1]);
                r_drive[1]<=$signed(r_pairs[2])+$signed(r_pairs[3]);
            end
            if(r_phase==33) r_mix<=$signed(w_body[0])+$signed(w_body[1]);
            if(r_phase==34)
            begin
                scaled=$signed(r_mix)>>>MIX_HEADROOM_SHIFT;
                if(scaled>32767)
                begin
                    r_dry<=16'sh7fff; o_clip_count<=o_clip_count+1'b1;
                end
                else if(scaled< -32768)
                begin
                    r_dry<=16'sh8000; o_clip_count<=o_clip_count+1'b1;
                end
                else r_dry<=scaled[15:0];
            end
            if(w_fx_valid)
            begin
                o_audio_sample<=w_fx_sample; o_audio_sample_valid<=1;
                o_audio_first_sample<=r_tag;
                o_output_sequence<=r_sequence; o_output_event_clock<=r_event_clock;
                o_output_first_sequence<=r_first_sequence; o_output_event_count<=r_event_count;
                if(r_compute_clocks>o_max_compute_clocks)
                o_max_compute_clocks<=r_compute_clocks;
                r_phase<=0;
            end
            if(r_phase==126)
            begin
                o_deadline_count<=o_deadline_count+1'b1;
                o_audio_sample<=0; o_audio_sample_valid<=1; r_phase<=0;
            end
        end
    end
end
endmodule
