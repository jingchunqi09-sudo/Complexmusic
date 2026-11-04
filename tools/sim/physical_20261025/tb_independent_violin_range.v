`timescale 1ns/1ps
// Audit only: freeze/copy source before compiling. Four real production-profile
// voices cover MIDI55..112. Sample-clock acceleration preserves 33clk prep gap;
// PCM is interpreted at declared SAMPLE_RATE_MILLIHZ, not at the TB wall clock.
module tb_independent_violin_range;
parameter integer RATE=48828125, SAMPLES=6000, SPEED=64, PRESSURE=192;
localparam integer SAMPLE_RATE_MILLIHZ=RATE,DELAY_LINE_LENGTH=1024;
reg clk=0,reset=1,prepare=0,tick=0,trigger=0,gate=0;
reg [27:0] notes;
reg [127:0] periods;
wire [3:0] ready;
wire [63:0] pcm;
integer c,n,lane,fd;
reg [2047:0] output_path;
always #10 clk=~clk;
`include "src/instrument_pitch.vh"
genvar v;
generate for(v=0;v<4;v=v+1)begin:V
violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),
 .SEPARATE_CONTROL_PREPARE(1),.ENABLE_MOVING_BOW_POSITION(1),.ENABLE_FINE_PITCH(1),
 .SHARE_INTERPOLATION_MULTIPLIER(1),.BOW_CONTROL_PROFILE(2)) dut(
 .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),
 .i_period_q16(periods[v*32 +:32]),.i_stop(1'b0),.i_trigger(trigger),.i_gate(gate),
 .i_midi_note(notes[v*7 +:7]),.i_velocity(PRESSURE[7:0]),
 .i_bow_speed(SPEED[15:0]),.i_bow_direction(1'b0),.i_bow_position(24'd0),
 .o_audio_sample(pcm[v*16 +:16]),.o_ready(ready[v]));
end endgenerate
initial begin
 if(!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"OUTPUT required");
 fd=$fopen(output_path,"w");if(!fd)$fatal(1,"fopen");
 for(c=0;c<15;c=c+1)begin
  reset=1;gate=0;trigger=0;
  for(lane=0;lane<4;lane=lane+1)begin
   notes[lane*7 +:7]=55+c*4+lane;
   periods[lane*32 +:32]=midi_period_q16(55+c*4+lane);
  end
  repeat(4)@(negedge clk);reset=0;repeat(1100)@(negedge clk);
  if(ready!=4'hf)$fatal(1,"memory ready");
  gate=1;trigger=1;
  for(n=0;n<SAMPLES;n=n+1)begin
   if(n==1)trigger=0;
   @(negedge clk);prepare=1;@(negedge clk);prepare=0;
   repeat(32)@(negedge clk);tick=1;@(negedge clk);tick=0;
   for(lane=0;lane<4;lane=lane+1)begin
    if(^pcm[lane*16 +:16]===1'bx)$fatal(1,"X pcm");
    if(notes[lane*7 +:7]<=112)
     $fwrite(fd,"%0d %0d %0d\n",notes[lane*7 +:7],n,$signed(pcm[lane*16 +:16]));
   end
   repeat(29)@(negedge clk);
  end
  $display("RANGE group=%0d notes=%0d..%0d samples=%0d",c,55+c*4,58+c*4,SAMPLES);
 end
 $fclose(fd);$display("PASS independent violin range syntax/state only: inspect PCM metrics for acoustic support");$finish;
end
endmodule
