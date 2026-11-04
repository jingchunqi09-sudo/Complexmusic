`timescale 1ns/1ps
module tb_audio_video_equivalence_20261018;
reg clk=0,reset=1;
wire [10:0] x0,x1;wire [9:0] y0,y1;
wire de0,de1,hs0,hs1,vs0,vs1,fs0,fs1;
integer n,checks=0,frames=0;
reg [31:0] seed=32'h10318;
reg sampled0=0,sampled1=0;
always #5 clk=~clk;
always @(posedge clk)begin
 if(reset)begin sampled0<=0;sampled1<=0;end
 else begin sampled0<=fs0;sampled1<=fs1;end
 if(!reset&&((x0==1649&&y0==719)||(x0==0&&y0==720)))
  $display("PRE_NBA x=%0d y=%0d baseline_pulse=%0d candidate_pulse=%0d",x0,y0,fs0,fs1);
end
video_timing_720p_baseline baseline(clk,reset,x0,y0,de0,hs0,vs0,fs0);
video_timing_720p candidate(clk,reset,x1,y1,de1,hs1,vs1,fs1);
always @(negedge clk)begin
 if({x0,y0,de0,hs0,vs0,fs0,sampled0}!=={x1,y1,de1,hs1,vs1,fs1,sampled1})$fatal(1,"video producer/consumer cycle mismatch at %0d",checks);
 checks=checks+1;if(fs0)frames=frames+1;
end
initial begin
 repeat(3)@(negedge clk);#1;reset=0;
 repeat(2475100)@(negedge clk);#1;
 if(frames!=2)$fatal(1,"must cover two full frame pulses");
 // Assert reset immediately before the predicted frame-start edge.
 while(!(x0==1649&&y0==719))begin @(negedge clk);#1;end
 reset=1;@(negedge clk);#1;reset=0;
 // Fixed-history reset stress; compare all video outputs every pixel cycle.
 for(n=0;n<20000;n=n+1)begin
  seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};reset=seed[4:0]==0;
  @(negedge clk);#1;
 end
 $display("PASS video timing exact checks=%0d complete_frame_pulses=%0d",checks,frames);$finish;
end
endmodule
