`timescale 1ns/1ps
// Audit boundary reproducer; this does not classify these values as legal
// instrument notes. It shows a missing fine-period input contract/guard.
module tb_independent_period_underflow;
reg clk=0,reset=1;
reg [31:0] period=0;
wire ready;
wire signed [15:0] pcm;
integer i,wraps=0;
always #10 clk=~clk;
violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.ENABLE_FINE_PITCH(1),
 .SEPARATE_CONTROL_PREPARE(1),.ENABLE_MOVING_BOW_POSITION(1),
 .SHARE_INTERPOLATION_MULTIPLIER(1),.BOW_CONTROL_PROFILE(2)) dut(
 .i_clk(clk),.i_reset(reset),.i_sample_tick(1'b0),.i_prepare_tick(1'b0),
 .i_period_q16(period),.i_stop(1'b0),.i_trigger(1'b0),.i_gate(1'b0),
 .i_midi_note(7'd69),.i_velocity(8'd192),.i_bow_speed(16'd64),
 .i_bow_direction(1'b0),.i_bow_position(24'd0),.o_audio_sample(pcm),.o_ready(ready));
initial begin
 repeat(4)@(negedge clk);reset=0;repeat(1100)@(negedge clk);
 for(i=0;i<7;i=i+1)begin
  case(i)0:period=0;1:period=1;2:period=32767;3:period=32768;
    4:period=65535;5:period=524288;6:period=606208;endcase
  repeat(32)@(negedge clk);
  $display("PERIOD q16=%0d delay_hex=%h integer=%0d bridge=%0d neck=%0d fraction=%0d",period,
    dut.w_delay_period_q16,dut.w_total_delay,dut.r_bridge_length_stage2,dut.r_neck_length_stage2,dut.r_delay_fraction_stage2);
  if(period<32768 && dut.w_total_delay>1024)wraps=wraps+1;
 end
 if(wraps!=3)$fatal(1,"expected 3 current-production underflow counterexamples, got %0d",wraps);
 $display("PASS reproduced 3 fine-period underflows; boundary bug confirmed, no claim of legal MIDI path failure");$finish;
end
endmodule
