`timescale 1ns/1ps
module tb_audio_body_20261018;
parameter integer RATE=48828125;
reg clk=0,reset=1,start=0;reg [35:0] samples=0;
wire [35:0] outputs;wire valid,ready;wire [31:0] guards,clips;
integer fi,fo,rc,x0,x1,n=0,latency,bank,phase;
reg [2047:0] input_path,output_path;
always #10 clk=~clk;
instrument_body_resonator_tdm dut(.i_clk(clk),.i_reset(reset),.i_start(start),.i_trigger(2'b00),.i_bypass(2'b00),.i_instrument(2'b10),
.i_sample_bus(samples),.o_sample_bus(outputs),.o_guard_count(guards),.o_clip_count(clips),.o_valid(valid),.o_ready(ready));
always @(posedge clk)if(!reset&&dut.r_phase==8)
 $fwrite(fo,"%0d %0d %0d %0d %0d %0d\n",n,dut.r_bank,$signed(dut.r_drive),$signed(dut.w_dry),$signed(dut.w_modal),$signed(dut.w_dry)+$signed(dut.w_modal));
initial begin
 if(!$value$plusargs("INPUT=%s",input_path)||!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"paths");
 fi=$fopen(input_path,"r");fo=$fopen(output_path,"w");if(!fi||!fo)$fatal(1,"file");
 repeat(4)@(negedge clk);reset=0;
 while(!$feof(fi))begin
  rc=$fscanf(fi,"%d %d\n",x0,x1);if(rc!=2)$fatal(1,"input");
  samples={x1[17:0],x0[17:0]};start=1;@(negedge clk);start=0;latency=0;
  while(!valid)begin @(negedge clk);latency=latency+1;if(latency>80)$fatal(1,"deadline");end
  if(latency!=78||^outputs===1'bx)$fatal(1,"body latency/unknown");
  $fwrite(fo,"%0d 2 %0d %0d %0d %0d\n",n,$signed(outputs[17:0]),$signed(outputs[35:18]),guards,clips);
  @(negedge clk);n=n+1;
 end
 $fclose(fi);$fclose(fo);$display("PASS audio_body transactions=%0d",n);$finish;
end
endmodule
