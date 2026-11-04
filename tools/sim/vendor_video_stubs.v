// Behavioural CLOCK / PHY substitutes for joint audio+video logic simulation.
// This does NOT validate Gowin PLL lock electrical behaviour or TMDS encoding.
`timescale 1ns/1ps
module TMDS_PLL(output reg lock, output reg clkout0, output reg clkout1,input clkin);
    initial
    begin
    lock=0;clkout0=0;clkout1=0;#100 lock=1;
    end
    always #1.363636 clkout0=~clkout0;
    always #6.818182 clkout1=~clkout1;
endmodule
module DVI_TX_Top(input I_rst_n,input I_serial_clk,input I_rgb_clk,
    input I_rgb_vs,input I_rgb_hs,input I_rgb_de,
    input [7:0] I_rgb_r,input [7:0] I_rgb_g,input [7:0] I_rgb_b,
    output O_tmds_clk_p,output O_tmds_clk_n,output [2:0] O_tmds_data_p,output [2:0] O_tmds_data_n);
    assign O_tmds_clk_p=I_rgb_clk;
    assign O_tmds_clk_n=~I_rgb_clk;
    assign O_tmds_data_p={I_rgb_r[7],I_rgb_g[7],I_rgb_b[7]} & {3{I_rgb_de && I_rst_n}};
    assign O_tmds_data_n=~O_tmds_data_p;
endmodule
