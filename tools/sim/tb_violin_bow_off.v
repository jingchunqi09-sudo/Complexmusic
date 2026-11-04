`timescale 1ns/1ps
// R16 verification: bow-off damping.
// Two identical violin voices driven by the same excitation; only
// BOW_OFF_DAMP_SHIFT differs. Gate is dropped after a settled bow stroke and
// the residual |sample| energy per 512-sample block is printed for both.
// Expectation: free (SHIFT=0) keeps ringing for hundreds of ms, damped
// (SHIFT=3) falls below 1/8 of the release level within ~50 ms.
module tb_violin_bow_off;
reg clk=0,reset=1,sample_tick=0,prepare_tick=0,trigger=0,gate=0,stop=0;
reg [31:0] period_q16=32'd7274496;      // 111 samples ≈ 440 Hz @ 48.83 kHz
reg [6:0] note=7'd69;
reg [7:0] velocity=8'd192;
reg signed [15:0] bow_speed=16'sd128;
reg bow_direction=1'b0;
reg [23:0] bow_position=24'd8388608;
wire signed [15:0] out_free,out_damp;
wire ready_free,ready_damp;
integer tick_cnt=0;
integer sample_count=0;
integer blocks=0;
integer acc_free=0,acc_damp=0,acc_i=0;

violin_waveguide_voice #(
    .DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48828125),
    .BOW_CONTROL_PROFILE(2),.SEPARATE_CONTROL_PREPARE(1),
    .ENABLE_MOVING_BOW_POSITION(1),.ENABLE_FINE_PITCH(1),
    .SHARE_INTERPOLATION_MULTIPLIER(1),.BOW_OFF_DAMP_SHIFT(0)
) u_free (
    .i_prepare_tick(prepare_tick),.i_period_q16(period_q16),.i_clk(clk),.i_reset(reset),
    .i_sample_tick(sample_tick),.i_trigger(trigger),.i_stop(stop),.i_gate(gate),
    .i_midi_note(note),.i_velocity(velocity),.i_bow_speed(bow_speed),
    .i_bow_direction(bow_direction),.i_bow_position(bow_position),
    .o_audio_sample(out_free),.o_ready(ready_free)
);
violin_waveguide_voice #(
    .DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48828125),
    .BOW_CONTROL_PROFILE(2),.SEPARATE_CONTROL_PREPARE(1),
    .ENABLE_MOVING_BOW_POSITION(1),.ENABLE_FINE_PITCH(1),
    .SHARE_INTERPOLATION_MULTIPLIER(1),.BOW_OFF_DAMP_SHIFT(3)
) u_damp (
    .i_prepare_tick(prepare_tick),.i_period_q16(period_q16),.i_clk(clk),.i_reset(reset),
    .i_sample_tick(sample_tick),.i_trigger(trigger),.i_stop(stop),.i_gate(gate),
    .i_midi_note(note),.i_velocity(velocity),.i_bow_speed(bow_speed),
    .i_bow_direction(bow_direction),.i_bow_position(bow_position),
    .o_audio_sample(out_damp),.o_ready(ready_damp)
);
always #10 clk=~clk;
// prepare 必须比 sample_tick 提前 26 拍（与 tb_revision8_violin_control 的
// frame task 一致：prepare=1 / +1 拍清零 / +24 拍 / tick）。
always @(posedge clk) begin
    tick_cnt<=tick_cnt+1;
    if(tick_cnt==1023)tick_cnt<=0;
    sample_tick  <= (tick_cnt==1023);
    prepare_tick <= (tick_cnt== 997);
end
// Per-block mean |sample| (512 audio samples per block ≈ 10.5 ms).
always @(posedge clk) if(sample_tick) begin
    sample_count<=sample_count+1;
    acc_free=acc_free+(out_free[15]? -out_free : out_free);
    acc_damp=acc_damp+(out_damp[15]? -out_damp : out_damp);
    acc_i=acc_i+1;
    if(acc_i==512)begin
        $display("BLOCK %0d free=%0d damp=%0d",blocks,acc_free/512,acc_damp/512);
        blocks<=blocks+1;acc_i=0;acc_free=0;acc_damp=0;
    end
end
initial begin
    repeat(20)@(negedge clk);reset=0;
    // trigger 必须跨过第一个 sample_tick 才被采到；只拉高一拍会丢。
    @(negedge clk);gate=1;trigger=1;
    wait(sample_count==1);
    @(negedge clk);trigger=0;
    wait(sample_count==2048);          // 42 ms bowed, settled
    @(negedge clk);gate=0;
    wait(sample_count==4096);          // 42 ms after the bow leaves
    $display("DONE blocks=%0d",blocks);
    $finish;
end
endmodule
