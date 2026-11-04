`timescale 1ns/1ps
module tb_audio_pt_patterns_20261018;
reg clk=0,reset=1;reg signed [15:0] pcm=0;wire bck,ws,din;
integer n,k,frames=0;reg [15:0] word,expected;reg [15:0] pattern[0:7];
always #10 clk=~clk;
pt8211_tx dut(.i_clk(clk),.i_reset(reset),.i_sample(pcm),.o_hp_bck(bck),.o_hp_ws(ws),.o_hp_din(din));
task read_word;input slot;
begin word=0;for(k=0;k<16;k=k+1)begin @(posedge bck);if(ws!==slot)$fatal(1,"WS");word={word[14:0],din};end
if(word!==expected)$fatal(1,"PCM n=%0d slot=%0d got=%h expected=%h",n,slot,word,expected);end endtask
initial begin
pattern[0]=0;pattern[1]=1;pattern[2]=16'hffff;pattern[3]=16'h7fff;
pattern[4]=16'h8000;pattern[5]=16'haaaa;pattern[6]=16'h5555;pattern[7]=16'h8001;
repeat(4)@(negedge clk);reset=0;
for(n=0;n<8;n=n+1)begin
 @(negedge clk);pcm=pattern[n];expected=pattern[n];
 @(posedge ws);read_word(1);@(negedge clk);pcm=~pattern[n];
 @(negedge ws);read_word(0);frames=frames+1;
end
$display("PASS PT deterministic patterns frames=%0d words=%0d",frames,frames*2);$finish;
end
endmodule
