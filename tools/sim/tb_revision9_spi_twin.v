`timescale 1ns/1ps
module tb_revision9_spi_twin;
reg clk=0,reset=1,req=0,cpol=0,cpha=0,miso=0;
reg [15:0] div=4;
reg [5:0] cmd_bits=8,rx_bits=16;
reg [31:0] command=32'hc35aa596,rng=32'h7a9145bc;
wire [1:0] mosi,sck,cs,busy,done;
wire [31:0] rx[0:1];
always #10 clk=~clk;
`define PORT(K) .i_clk(clk),.i_reset(reset),.i_req(req),.i_cpol(cpol),.i_cpha(cpha), \
.i_clk_div(div),.i_cmd_bits(cmd_bits),.i_rx_bits(rx_bits),.i_cmd(command),.i_miso(miso), \
.o_mosi(mosi[K]),.o_sck(sck[K]),.o_cs_n(cs[K]),.o_busy(busy[K]),.o_done(done[K]),.o_rx_data(rx[K])
spi_master_runtime dut(`PORT(0));
spi_master_runtime_r8 reference_dut(`PORT(1));
`undef PORT
integer mode,a,b,cycles,checks=0,cases=0;
function [5:0] width_value;
input integer i;
begin case(i)0:width_value=0;1:width_value=1;2:width_value=7;3:width_value=8;
4:width_value=16;5:width_value=31;6:width_value=32;7:width_value=33;default:width_value=63;endcase end
endfunction
always @(posedge clk)begin
#1;
if(!reset)begin
 if({mosi[0],sck[0],cs[0],busy[0],done[0],rx[0]} !== {mosi[1],sck[1],cs[1],busy[1],done[1],rx[1]})
 $fatal(1,"SPI mismatch mode=%d widths=%d/%d cycle=%d",mode,a,b,cycles);
 checks=checks+1;
end
end
initial begin
repeat(4)@(negedge clk);reset=0;
for(mode=0;mode<4;mode=mode+1)
for(a=0;a<9;a=a+1)
for(b=0;b<9;b=b+1)begin
 @(negedge clk);cpol=mode[1];cpha=mode[0];cmd_bits=width_value(a);rx_bits=width_value(b);
 div=(a+b)%3==0 ? 2 : (a+b)%3==1 ? 4 : 9;command=rng;req=1;
 @(negedge clk);req=0;cycles=0;
 while(!done[0] && cycles<2000)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};miso=rng[0];
  // In-flight configuration changes must have no effect on either controller.
  if(cycles==10)begin cpol=~cpol;cpha=~cpha;cmd_bits=3;rx_bits=5;command=~command;div=100;end
  @(negedge clk);cycles=cycles+1;
 end
 if(!done[0])$fatal(1,"SPI timeout");cases=cases+1;
 @(negedge clk);
end
$display("PASS R9 SPI cycle twin cases=%d clocks=%d",cases,checks);$finish;
end
endmodule
