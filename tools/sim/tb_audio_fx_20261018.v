`timescale 1ns/1ps
module tb_audio_fx_20261018;
parameter integer RATE=48828125;
reg clk=0,reset=1,clear=0,tick=0,bypass=0;
reg signed [15:0] sample=0;
reg [7:0] wet=255,damping=96;
reg [1:0] tail=3;
wire signed [15:0] pcm;
wire valid,ready;wire [31:0] guards;
integer fd,fi,rc,n,latency,epoch=0,tx=0;
integer si,bi,wi,di,ti,ci;
reg signed [15:0] captured_g[0:3];
reg [2047:0] input_path,output_path;
always #10 clk=~clk;
small_room_reverb #(.SAMPLE_RATE_MILLIHZ(RATE)) dut(
.i_clk(clk),.i_reset(reset),.i_clear(clear),.i_sample_tick(tick),.i_sample(sample),
.i_bypass(bypass),.i_wet(wet),.i_damping(damping),.i_tail(tail),
.o_sample(pcm),.o_sample_valid(valid),.o_ready(ready),.o_guard_count(guards));
always @(posedge clk)if(!reset&&!clear&&dut.r_state==7)captured_g[dut.r_bank]<=dut.r_mult_b;
initial begin
 if(!$value$plusargs("INPUT=%s",input_path)||!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"paths");
 fi=$fopen(input_path,"r");fd=$fopen(output_path,"w");if(!fi||!fd)$fatal(1,"files");
 repeat(4)@(negedge clk);reset=0;while(!ready)@(negedge clk);
 while(!$feof(fi))begin
  rc=$fscanf(fi,"%d %d %d %d %d %d\n",si,bi,wi,di,ti,ci);
  if(rc!=6)$fatal(1,"stimulus");
  if(ci)begin
   clear=1;@(negedge clk);if(valid||ready||pcm!==0)$fatal(1,"clear");
   clear=0;epoch=epoch+1;while(!ready)@(negedge clk);
  end
  sample=si;bypass=bi;wet=wi;damping=di;tail=ti;
  tick=1;@(negedge clk);tick=0;latency=0;
  while(!valid)begin @(negedge clk);latency=latency+1;if(latency>80)$fatal(1,"deadline");end
  if(^pcm===1'bx)$fatal(1,"unknown");
  $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",tx,epoch,pcm,latency,guards,dut.r_wet,dut.r_lp0,dut.r_lp1,dut.r_lp2,dut.r_lp3,dut.r_damping,captured_g[0],captured_g[1],captured_g[2],captured_g[3]);
  @(negedge clk);if(valid)$fatal(1,"duplicate valid");tx=tx+1;
 end
 $fclose(fi);$fclose(fd);$display("PASS audio_fx transactions=%0d",tx);$finish;
end
endmodule
