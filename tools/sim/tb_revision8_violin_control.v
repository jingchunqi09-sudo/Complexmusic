`timescale 1ns/1ps
module tb_revision8_violin_control;
parameter integer RATE=48828125;
parameter integer CASES=210;
localparam integer SAMPLE_RATE_MILLIHZ=RATE,DELAY_LINE_LENGTH=1024;
reg clk=0,reset=1,prepare=0,tick=0,trigger=0,stop=0,gate=0,body_tick=0,direction=0;
reg [6:0] note=69;reg [31:0] period;reg [7:0] pressure=128;
reg signed [15:0] speed=32;reg [23:0] position=24'h800000;
wire signed [15:0] bare[0:2];wire [2:0] ready;
wire signed [17:0] body[0:1];reg signed [17:0] drive[0:1];
wire [15:0] guards[0:1],clips[0:1];
integer n,c,j,fd,checks=0;reg [1023:0] output_path;
always #10 clk=~clk;
`include "src/instrument_pitch.vh"
genvar k; generate for(k=0;k<2;k=k+1) begin: LANE
violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SEPARATE_CONTROL_PREPARE(1),.SAMPLE_RATE_MILLIHZ(RATE),
.ENABLE_FINE_PITCH(1),.ENABLE_BODY_FILTER(0),.ENABLE_BODY_RESONATOR(0),.BOW_CONTROL_PROFILE(k)) string_voice(
.i_clk(clk),.i_reset(reset),.i_prepare_tick(prepare),.i_period_q16(period),.i_sample_tick(tick),.i_trigger(trigger),
.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
.i_bow_direction(direction),.i_bow_position(position),.o_audio_sample(bare[k]),.o_ready(ready[k]));
instrument_body_resonator_r7 #(.SAMPLE_WIDTH(18),.PRESERVE_BYPASS_STATE(1),.VIOLIN_RADIATION_MIX(2)) body_filter(
.i_clk(clk),.i_reset(reset),.i_sample_tick(body_tick),.i_trigger(1'b0),.i_bypass(1'b0),.i_instrument(1'b0),
.i_sample(drive[k]),.o_sample(body[k]),.o_guard_count(guards[k]),.o_clip_count(clips[k]));
end endgenerate
violin_waveguide_voice_r7 #(.DELAY_LINE_LENGTH(1024),.SEPARATE_CONTROL_PREPARE(1),.SAMPLE_RATE_MILLIHZ(RATE),
.ENABLE_FINE_PITCH(1),.ENABLE_BODY_FILTER(0),.ENABLE_BODY_RESONATOR(0)) reference_voice(
.i_clk(clk),.i_reset(reset),.i_prepare_tick(prepare),.i_period_q16(period),.i_sample_tick(tick),.i_trigger(trigger),
.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
.i_bow_direction(direction),.i_bow_position(position),.o_audio_sample(bare[2]),.o_ready(ready[2]));
task frame;begin
 @(negedge clk);prepare=1;@(negedge clk);prepare=0;repeat(24)@(negedge clk);
 tick=1;@(negedge clk);tick=0;
 if(bare[0] !== bare[2])$fatal(1,"R7 fallback mismatch case=%0d n=%0d",c,n);
 for(j=0;j<2;j=j+1)begin
  if(^bare[j]===1'bx)$fatal(1,"Unknown voice");
  drive[j]=$signed(bare[j]);
 end
 repeat(10)@(negedge clk);body_tick=1;@(negedge clk);body_tick=0;
 $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",c,n,note,pressure,speed,
 bare[0],bare[1],body[0],body[1]);
 checks=checks+1;repeat(26)@(negedge clk);
end endtask
initial begin
 if(!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"Missing OUTPUT");
 fd=$fopen(output_path,"w");if(!fd)$fatal(1,"Cannot open OUTPUT");
 for(c=0;c<CASES;c=c+1)begin
  gate=0;trigger=0;stop=0;reset=1;direction=0;
  for(j=0;j<2;j=j+1)drive[j]=0;
  repeat(4)@(negedge clk);reset=0;repeat(1030)@(negedge clk);if(!(&ready))$fatal(1,"Init");
  note=55+(c/12)*7;pressure=64+((c/4)%3)*64;
  case(c%4)0:speed=16;1:speed=32;2:speed=64;3:speed=192;endcase
  position=24'h800000;
  if(c>=48 && c<82)begin note=55+c-48;pressure=128;speed=64;end
  if(c>=82)begin
   note=55+((c-82)/32)*7;
   case(((c-82)/8)%4)0:pressure=1;1:pressure=32;2:pressure=128;3:pressure=255;endcase
   case(((c-82)/2)%4)0:speed=1;1:speed=16;2:speed=128;3:speed=255;endcase
   position=((c-82)%2)==0?24'h000000:24'hffffff;
  end
  period=midi_period_q16(note);gate=1;trigger=1;
  for(n=0;n<10000;n=n+1)begin
   if(n==1)trigger=0;
   if(n==6500)begin note=note+2;period=midi_period_q16(note);end
   if(n==7000)trigger=1;
   if(n==7001)trigger=0;
   if(n==7250)direction=1;
   if(n==8000)begin gate=0;stop=1;end
   if(n==8001)stop=0;
   if(n==8500)begin gate=1;trigger=1;end
   if(n==8501)trigger=0;
   if(n==9000)pressure=0;
   if(n==9200)begin pressure=128;speed=0;end
   if(n==9400)begin speed=255;position=24'hffffff;end
   frame;
  end
  for(j=0;j<2;j=j+1)if(guards[j]!=0||clips[j]!=0)$fatal(1,"Body guard/clip case=%0d profile=%0d %0d/%0d",c,j,guards[j],clips[j]);
  $display("CASE=%0d PASS",c);
 end
 $fclose(fd);$display("PASS tb_revision8_violin_control frames=%0d rate=%0d",checks,RATE);$finish;
end
endmodule
