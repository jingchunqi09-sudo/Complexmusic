`timescale 1ns/1ps
// Compare pinned PNR4 math on every clock, including transient output wraps.
module revision6_expression_twin_tb;
parameter integer RATE=48828125,DELAY=1024;
reg clk=0,reset=1,tick=0,gate=0,auto_enable=0;
reg [6:0] note=0;
reg [7:0] depth=0,rate=0,glide=0;
wire [31:0] old_period,new_period;
always #10 clk=~clk;
`define EXPR_PORTS(P) .i_clk(clk),.i_reset(reset),.i_tick(tick),.i_gate(gate),.i_note(note), \
 .i_depth_cents(depth),.i_rate_decihz(rate),.i_glide_ms(glide),.i_auto(auto_enable),.o_period_q16(P)
violin_expression_pnr4 #(.SAMPLE_RATE_MILLIHZ(RATE),.DELAY_LINE_LENGTH(DELAY)) baseline(`EXPR_PORTS(old_period));
violin_expression #(.SAMPLE_RATE_MILLIHZ(RATE),.DELAY_LINE_LENGTH(DELAY)) candidate(`EXPR_PORTS(new_period));
`undef EXPR_PORTS
integer fd,checks=0,ticks=0,zero_difference_ticks=0,wrap_clocks=0;
integer corner_start,corner_goal,corner_note,corner_glide,corner_steps;
integer n,scan;
reg [31:0] random_state=32'h9a4c713b;
reg [1023:0] trace_path;
task settle;
 begin repeat(3)@(negedge clk);#1;end
endtask
task sample_tick;
 begin
  @(negedge clk);#1;tick=1;
  @(negedge clk);#1;tick=0;
  repeat(8)@(negedge clk);#1;
 end
endtask
task restart;
 input [6:0] initial_note;
 begin
  @(negedge clk);#1;reset=1;gate=0;tick=0;note=initial_note;
  repeat(3)@(negedge clk);#1;reset=0;
  settle;sample_tick;
  gate=1;sample_tick;
 end
endtask
always @(posedge clk)if(!reset)begin
 if(tick)begin
  ticks=ticks+1;
  if(baseline.r_target!=baseline.r_goal && baseline.r_target==baseline.r_current)
   zero_difference_ticks=zero_difference_ticks+1;
 end
 #1;
 if(old_period!==new_period || baseline.r_target!==candidate.r_target ||
    baseline.r_current!==candidate.r_current || baseline.r_goal!==candidate.r_goal ||
    baseline.r_step!==candidate.r_step || baseline.r_phase!==candidate.r_phase ||
    baseline.r_held!==candidate.r_held || baseline.r_gate!==candidate.r_gate ||
    baseline.r_span!==candidate.r_span || baseline.r_magnitude!==candidate.r_magnitude ||
    baseline.r_offset!==candidate.r_offset || baseline.r_magnitude_negative!==candidate.r_magnitude_negative ||
    baseline.seed!==candidate.seed || baseline.total!==candidate.total ||
    baseline.depth!==candidate.depth || baseline.rate!==candidate.rate ||
    baseline.glide!==candidate.glide || baseline.glide_shift!==candidate.glide_shift ||
    baseline.triangle_magnitude!==candidate.triangle_magnitude)
  $fatal(1,"FAIL expression every-clock math D=%0d RATE=%0d check=%0d oldperiod=%0d newperiod=%0d oldcurrent=%0d newcurrent=%0d",
   DELAY,RATE,checks,old_period,new_period,baseline.r_current,candidate.r_current);
 if(^new_period===1'bx)$fatal(1,"FAIL expression unknown output");
 if(old_period[31])wrap_clocks=wrap_clocks+1;
 $fwrite(fd,"%0d %0d %0d %0d\n",checks,old_period,new_period,tick);
 checks=checks+1;
end
initial begin
 if(!$value$plusargs("TRACE=%s",trace_path))$fatal(1,"FAIL missing TRACE");
 fd=$fopen(trace_path,"w");if(!fd)$fatal(1,"FAIL trace file");
 scan=$value$plusargs("CORNER_START=%d",corner_start);
 scan=$value$plusargs("CORNER_GOAL=%d",corner_goal);
 scan=$value$plusargs("CORNER_NOTE=%d",corner_note);
 scan=$value$plusargs("CORNER_GLIDE=%d",corner_glide);
 scan=$value$plusargs("CORNER_STEPS=%d",corner_steps);
 repeat(6)@(negedge clk);#1;reset=0;
 // A low-period note follows a large negative offset: preserve 32-bit wrap.
 depth=63;rate=255;glide=0;auto_enable=0;restart(0);
 repeat(1500)sample_tick;
 note=127;settle;sample_tick;repeat(5)sample_tick;
 if(DELAY>=1024 && wrap_clocks==0)$fatal(1,"FAIL negative-offset wrap scenario not exercised");
 // Reach target==current while the old goal differs using real note inputs.
 if(corner_steps>0)begin
  depth=0;rate=0;glide=0;auto_enable=0;restart(corner_start);
  note=corner_goal;glide=corner_glide;settle;
  repeat(corner_steps)sample_tick;
  note=corner_note;settle;
  if(baseline.r_current!==baseline.r_target || baseline.r_goal===baseline.r_target)
   $fatal(1,"FAIL reachable zero-difference precondition");
  sample_tick;
  if(baseline.r_current!=baseline.r_target-1 || candidate.r_current!=candidate.r_target-1)
   $fatal(1,"FAIL original one-LSB retarget corner changed");
  repeat(3)sample_tick;
 end
 // Automatic onset, mature depth and gate rearm at unchanged clock latency.
 depth=0;rate=0;glide=0;auto_enable=1;restart(69);
 repeat(RATE/3000+9000)sample_tick;
 gate=0;sample_tick;gate=1;sample_tick;repeat(16)sample_tick;
 // All note codes, depths/rates including 255, glide bands and gate changes.
 for(n=0;n<10000;n=n+1)begin
  random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
  note=n%128;depth=random_state[7:0];rate=random_state[15:8];
  glide=random_state[23:16];auto_enable=random_state[24];gate=random_state[25];
  sample_tick;
 end
 @(negedge clk);#2;
 if(corner_steps>0 && zero_difference_ticks==0)$fatal(1,"FAIL zero-difference coverage");
 $fclose(fd);
 $display("PASS revision6_expression_twin_tb: D=%0d RATE=%0d clocks=%0d ticks=%0d zero_difference_ticks=%0d wrap_clocks=%0d period_width=%0d step_width=%0d",
  DELAY,RATE,checks,ticks,zero_difference_ticks,wrap_clocks,candidate.PERIOD_WIDTH,candidate.STEP_WIDTH);
 $finish;
end
endmodule
