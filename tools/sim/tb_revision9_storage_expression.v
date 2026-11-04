`timescale 1ns/1ps
module tb_revision9_storage_expression;
parameter D=1024, RATE=48828125;
reg clk=0,reset=1,start=0;
always #10 clk=~clk;
reg [27:0] note=0,pluck_note=0;
reg [3:0] gate=0,auto_on=0;
reg [31:0] depth=0,rate=0,glide=0;
wire [127:0] period[0:1];
wire [191:0] pluck[0:1];
wire [1:0] ready,valid;
`define PORTS(K) .i_clk(clk),.i_reset(reset),.i_start(start),.i_note(note),.i_pluck_note(pluck_note), \
.i_gate(gate),.i_auto(auto_on),.i_depth(depth),.i_rate(rate),.i_glide(glide), \
.o_period(period[K]),.o_pluck_parameters(pluck[K]),.o_ready(ready[K]),.o_valid(valid[K])
violin_expression_bank_gold #(.DELAY_LINE_LENGTH(D),.SAMPLE_RATE_MILLIHZ(RATE)) gold(`PORTS(0));
violin_expression_bank #(.DELAY_LINE_LENGTH(D),.SAMPLE_RATE_MILLIHZ(RATE)) dut(`PORTS(1));
`undef PORTS
integer seed=32'h34281abc,n,j,k,cy=0,accepted=0,completed=0,accepted_at=0,reset_cases=0;
reg inflight=0;
always @(posedge clk) begin
 if(reset)inflight=0;
 else if(start && ready[0])begin accepted=accepted+1;accepted_at=cy;inflight=1;end
 #1;
 if({ready[0],valid[0],period[0],pluck[0]} !== {ready[1],valid[1],period[1],pluck[1]})
  $fatal(1,"interface mismatch cycle=%0d phase=%0d lane=%0d",cy,gold.phase,gold.lane);
 if({gold.phase,gold.lane,gold.target,gold.origin,gold.old_goal,gold.old_step,gold.old_phase,
     gold.next_held,gold.distance,gold.new_step,gold.new_current,gold.new_phase,gold.magnitude,
     gold.product,gold.previous_gate} !==
    {dut.phase,dut.lane,dut.target,dut.origin,dut.old_goal,dut.old_step,dut.old_phase,
     dut.next_held,dut.distance,dut.new_step,dut.new_current,dut.new_phase,dut.magnitude,
     dut.product,dut.previous_gate})$fatal(1,"state mismatch cycle=%0d",cy);
 for(k=0;k<4;k=k+1)
  if({gold.current[k],gold.goal[k],gold.step[k],gold.oscillator[k],gold.held[k]} !==
     {dut.current[k],dut.goal[k],dut.step[k],dut.oscillator[k],dut.held[k]})
   $fatal(1,"lane state mismatch lane=%0d cycle=%0d",k,cy);
 // pluck_read may differ outside its consuming edge. Compare it immediately
 // before phase 11, not on irrelevant prefetch cycles.
 if(gold.phase==11 && gold.pluck_read !== dut.pluck_read)$fatal(1,"ROM consumer mismatch");
 if(valid[0])begin
  if(!inflight || cy-accepted_at!=48)$fatal(1,"48-clock transaction mismatch");
  completed=completed+1;inflight=0;
 end
 cy=cy+1;
end
task inputs_random;
begin
 note=$random(seed);pluck_note=$random(seed);gate=$random(seed);auto_on=$random(seed);
 depth=$random(seed);rate=$random(seed);glide=$random(seed);
end
endtask
task transaction;
input integer busy_noise;
begin
 start=1;@(negedge clk);start=0;
 for(j=0;j<48;j=j+1)begin
  if(busy_noise!=0 && !ready[0])begin inputs_random;start=$random(seed);end
  else start=0;
  @(negedge clk);
 end
 start=0;
end
endtask
initial begin
 repeat(4)@(negedge clk);reset=0;
 // Nonzero first request and distinct note streams catch stale lane-0 prefetch.
 for(n=0;n<128;n=n+1)begin
  note={4{n[6:0]}};pluck_note={4{7'd127-n[6:0]}};gate=15;depth=0;glide=0;
  transaction(1);
 end
 // Hold long enough to cover auto-vibrato onset/ramp and saturation.
 note={4{7'd69}};pluck_note={4{7'd60}};gate=15;auto_on=15;depth=0;rate=0;glide=0;
 for(n=0;n<RATE/3000+900;n=n+1)transaction(0);
 for(n=0;n<3000;n=n+1)begin inputs_random;transaction(1);end
 // Reset abort at each point, including acceptance and last-lane boundary.
 for(n=0;n<=48;n=n+1)begin
  inputs_random;start=1;@(negedge clk);start=0;
  repeat(n)@(negedge clk);
  reset=1;start=1;inputs_random;@(negedge clk);reset=0;
  transaction(1);reset_cases=reset_cases+1;
 end
 if($test$plusargs("INJECT_ERROR"))begin
  $display("INJECTED_ERROR target");force dut.target=32'hdeadbeef;@(negedge clk);release dut.target;
 end
 if(completed<3000 || reset_cases!=49)$fatal(1,"coverage missing");
 $display("PASS tb_revision9_storage_expression D=%0d RATE=%0d accepted=%0d completed=%0d resets=%0d",D,RATE,accepted,completed,reset_cases);
 $finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
