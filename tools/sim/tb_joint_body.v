`timescale 1ns/1ps
module tb_joint_body;
parameter PRESERVE=1;
reg clk=0,reset=1,start=0;
reg [1:0] trigger=0,bypass=0,instrument=0;
reg [35:0] samples=0;
wire [35:0] a,b;wire [31:0] ga,gb,ca,cb;wire va,vb,ra,rb;
integer frame=0,k,j,seed=32'h7211366,valids=0,accepted=-1,cycle=0;
reg signed [33:0] x;
always #10 clk=~clk;
`define PARAMS .PRESERVE_BYPASS_STATE(PRESERVE)
`define PORTS(S,G,C,V,R) .i_clk(clk),.i_reset(reset),.i_start(start),.i_trigger(trigger),.i_bypass(bypass),.i_instrument(instrument),.i_sample_bus(samples),.o_sample_bus(S),.o_guard_count(G),.o_clip_count(C),.o_valid(V),.o_ready(R)
instrument_body_resonator_tdm_gold #(`PARAMS) bg(`PORTS(a,ga,ca,va,ra));
instrument_body_resonator_tdm #(`PARAMS) bd(`PORTS(b,gb,cb,vb,rb));
`undef PARAMS
`undef PORTS
always @(posedge clk)begin
 cycle=cycle+1;
 if(reset)accepted=-1;
 else if(start && ra)accepted=cycle;
 if(!reset && $time>100)begin
  // GENERATED_MONITORS
  for(j=0;j<12;j=j+1) if(bg.r_position_q8[j]!==bd.r_position_q8[j] || bg.r_velocity_q8[j]!==bd.r_velocity_q8[j])$fatal(1,"body RAM %0d",j);
 end
 #1;
 if({a,ga,ca,va,ra}!=={b,gb,cb,vb,rb})$fatal(1,"body output frame=%0d",frame);
 if(!reset && va)begin
  if(cycle-accepted!=78)$fatal(1,"body latency %0d",cycle-accepted);
  valids=valids+1;
 end
end
initial begin
 // Complete selector domain, extreme signed operands and random low bits.
 // Check functions separately so later saturation cannot mask a difference.
 for(frame=0;frame<20000;frame=frame+1)begin
  case(frame%8)
   0:x=34'sh1ffffffff;1:x=34'sh200000000;2:x=-1;3:x=0;
   default:x={$random(seed),$random(seed)};
  endcase
  for(k=0;k<16;k=k+1)begin
   if(bg.spring(k[2:0],k[3],x)!==bd.spring(k[2:0],k[3],x))$fatal(1,"spring selector %0d x=%0d",k,x);
   if(bg.radiation(k[2:0],k[3],x)!==bd.radiation(k[2:0],k[3],x))$fatal(1,"radiation selector %0d x=%0d",k,x);
  end
 end
 repeat(5)@(negedge clk);reset=0;
 for(frame=0;frame<12000;frame=frame+1)begin
  @(negedge clk);start=1;
  samples={$random(seed),$random(seed)};
  trigger=frame%127==0 ? 3 : 0;bypass=frame%19==0 ? frame%4 : 0;instrument=frame%4;
  repeat(90)begin
   @(negedge clk);
   // Busy starts/input changes must not alter captured inputs.
   start=$random(seed);samples={$random(seed),$random(seed)};
   reset=(frame%997==996 && bd.r_phase==5);
  end
  start=0;reset=0;
  while(!ra)@(negedge clk);
 end
 if(valids<10000)$fatal(1,"body insufficient commits %0d",valids);
 $display("PASS tb_joint_body preserve=%0d valids=%0d",PRESERVE,valids);$finish;
end
initial begin #200000000;$fatal(1,"timeout");end
endmodule
