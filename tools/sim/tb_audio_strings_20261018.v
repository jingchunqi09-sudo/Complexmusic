`timescale 1ns/1ps
module tb_audio_strings_20261018;
parameter integer RATE=48828125, CASES=210, KIND=0, DYNAMIC=0, PROFILE=2, FIX_COLOR=0, WEAK_ONLY=0;
parameter integer FINE_SWEEP=0, U_FRAMES=48000, U_LONG=0, CONTROL_GRID=0;
localparam integer SAMPLE_RATE_MILLIHZ=RATE,DELAY_LINE_LENGTH=1024;
reg clk=0,reset=1,prepare=0,tick=0,trigger=0,stop=0,gate=0,direction=0;
reg [6:0] note=69;reg [31:0] period;reg [7:0] pressure=128;
reg signed [15:0] speed=64;reg [23:0] position=24'h800000;
wire signed [15:0] pcm;wire ready;wire [31:0] guards;
integer n,c,sc,fd,trace,frames=0,ratio,bridge,neck,blend,age,prior_age,slip,index_v,injection;
reg [2047:0] output_path,trace_path;
always #10 clk=~clk;
`include "src/instrument_pitch.vh"
generate if(KIND==0)begin:V
violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SEPARATE_CONTROL_PREPARE(1),.SAMPLE_RATE_MILLIHZ(RATE),
`ifdef AUDIO_MOVING_GEOMETRY
.ENABLE_MOVING_BOW_POSITION(1),
`endif
.ENABLE_FINE_PITCH(1),.BOW_CONTROL_PROFILE(PROFILE),.SHARE_INTERPOLATION_MULTIPLIER(1)) dut(
.i_clk(clk),.i_reset(reset),.i_prepare_tick(prepare),.i_period_q16(period),.i_sample_tick(tick),.i_trigger(trigger),
.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
.i_bow_direction(direction),.i_bow_position(position),.o_audio_sample(pcm),.o_ready(ready));
assign guards=0;
initial if(FIX_COLOR)force dut.r_performance_position=8'd128;
always @(negedge clk)if(tick&&ready&&!reset)begin
 if(dut.w_bridge_read_address>=dut.BRIDGE_MEMORY_DEPTH||dut.w_neck_read_address>=dut.NECK_MEMORY_DEPTH||
    dut.w_bridge_old_read_address>=dut.BRIDGE_MEMORY_DEPTH||dut.w_neck_old_read_address>=dut.NECK_MEMORY_DEPTH)
  $fatal(1,"geometric read address outside RAM");
 if(dut.r_bridge_length_stage2<2||dut.r_bridge_length_stage2>dut.BRIDGE_MEMORY_DEPTH||
    dut.r_neck_length_stage2<6||dut.r_neck_length_stage2>dut.NECK_MEMORY_DEPTH)$fatal(1,"geometric length");
 if(dut.r_bridge_length_stage2+dut.r_neck_length_stage2 != (((period-32768)>>16)<8?8:((period-32768)>>16)))
  $fatal(1,"prepared geometry must preserve requested total delay");
end
always @*begin ratio=dut.r_contact_ratio_q8;bridge=dut.r_committed_bridge_length;neck=dut.r_committed_neck_length;
blend=dut.r_retune_blend;age=dut.r_samples_since_trigger;slip=dut.r_slip_for_gain;index_v=dut.r_normalized_slip>>9;injection=dut.r_bow_injection;end
end else begin:U
ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE)) dut(
.i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_stop(stop),
.i_external_period_q16(32'd0),.i_external_excitation_step(16'd0),.o_audio_sample(pcm),.o_ready(ready),.o_guard_count(guards));
end endgenerate
initial begin
 if(!$value$plusargs("OUTPUT=%s",output_path)||!$value$plusargs("TRACE=%s",trace_path))$fatal(1,"paths");
 fd=$fopen(output_path,"w");trace=$fopen(trace_path,"w");if(!fd||!trace)$fatal(1,"file");
 for(c=0;c<CASES;c=c+1)begin
  sc=WEAK_ONLY ? 82+(c/8)*32+((c%8)/2)*8+c%2 : c;
  reset=1;gate=0;trigger=0;stop=0;direction=0;position=24'h800000;
  repeat(4)@(negedge clk);reset=0;repeat(1100)@(negedge clk);if(!ready)$fatal(1,"init");
  if(KIND==0)begin
   note=55+(sc/12)*7;pressure=64+((sc/4)%3)*64;
   case(sc%4)0:speed=16;1:speed=32;2:speed=64;3:speed=192;endcase
   if(sc>=48&&sc<82)begin note=55+sc-48;pressure=128;speed=64;end
   if(sc>=82)begin
    note=55+((sc-82)/32)*7;
    case(((sc-82)/8)%4)0:pressure=1;1:pressure=32;2:pressure=128;3:pressure=255;endcase
    case(((sc-82)/2)%4)0:speed=1;1:speed=16;2:speed=128;3:speed=255;endcase
    position=((sc-82)%2)==0?0:24'hffffff;
   end
   if(CONTROL_GRID)begin
    note=55+c/6;position=c%2?24'hffffff:0;
    case((c/2)%3)
     0:begin pressure=32;speed=1;end
     1:begin pressure=128;speed=64;end
     2:begin pressure=255;speed=255;end
    endcase
   end
   if(DYNAMIC)begin
    note=55+(c%4)*7;if(c==4)note=88;if(c==5)note=0;if(c==6)note=127;
    pressure=128;speed=64;position=0;
   end
  end else begin
   note=55+c%34;pressure=c<34?128:c<68?32:255;
   if(U_LONG)begin case(c%3)0:note=55;1:note=69;2:note=88;endcase pressure=c<3?32:255;end
  end
  period=midi_period_q16(note);gate=1;trigger=1;
  for(n=0;n<(KIND==0?(DYNAMIC?20000:10000):U_FRAMES);n=n+1)begin
   if(n==1)trigger=0;
   if(KIND==0)begin
    if(n==6500)begin note=note<126?note+2:126;period=midi_period_q16(note);end
    if(n==7000)trigger=1;if(n==7001)trigger=0;
    if(n==7250)direction=1;
    if(n==8000)begin gate=0;stop=1;end if(n==8001)stop=0;
    if(n==8500)begin gate=1;trigger=1;end if(n==8501)trigger=0;
    if(n==9000)pressure=0;if(n==9200)begin pressure=128;speed=0;end
    if(n==9400)begin speed=255;position=24'hffffff;end
    if(DYNAMIC)begin
     if(n==8)position=24'hffffff;if(n==16)position=0;
     if(n>=2000&&n<4000)position=(n-2000)*8388;
     if(n==4000)position=24'hffffff;if(n==4500)position=0;if(n==4516)position=24'hffffff;
     if(n==5000)position=0;
    end
   end
   if(KIND==0&&FINE_SWEEP&&n>=2000&&n<6500)
    period=midi_period_q16(note)-(midi_period_q16(note)/128)*((n-2000)%1000)/1000;
   @(negedge clk);prepare=1;@(negedge clk);prepare=0;
   repeat(32)@(negedge clk);prior_age=age;tick=1;@(negedge clk);tick=0;
   if(KIND==0&&n>1&&n<8000&&age!=(prior_age<960?prior_age+1:960))$fatal(1,"geometry reset RAM age");
   if(^pcm===1'bx||guards!=0)$fatal(1,"unknown/guard c=%0d n=%0d",c,n);
   $fwrite(fd,"%0d %0d %0d %0d %0d %0d\n",sc,n,note,pressure,speed,pcm);
   if(KIND==0&&(DYNAMIC||n%64==0))$fwrite(trace,"%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",sc,n,ratio,bridge,neck,blend,age,slip,index_v,injection);
   repeat(29)@(negedge clk);frames=frames+1;
  end
  $display("CASE=%0d PASS",c);
 end
 $fclose(fd);$fclose(trace);$display("PASS audio_strings kind=%0d frames=%0d",KIND,frames);$finish;
end
endmodule
