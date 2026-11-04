`timescale 1ns/1ps
// Dock KEY1 (AB13): short release cycles the display; hold 1 s requests
// left-hand recalibration once. No mode or calibration action resets audio.
module stage_mode_button #(
    parameter integer DEBOUNCE_TICKS=500000,
    parameter integer LONG_TICKS=50000000
)(
    input wire clk,reset,key_n,
    output reg [1:0] mode,
    output reg recalib
);
    function integer width;
        input integer n;
        begin width=1; while(n>1)begin n=n>>1; width=width+1; end end
    endfunction
    localparam DW=width(DEBOUNCE_TICKS-1), HW=width(LONG_TICKS-1);
    (* ASYNC_REG="TRUE" *) reg [1:0] key_sync;
    reg key_level,long_sent;
    reg [DW-1:0] debounce_count;
    reg [HW-1:0] hold_count;
    wire accept_edge=(key_sync[1]!=key_level && debounce_count==DEBOUNCE_TICKS-1);
    always @(posedge clk)begin
        recalib<=0;
        if(reset)begin
            key_sync<=2'b11; key_level<=1; debounce_count<=0;
            hold_count<=0; long_sent<=0; mode<=0;
        end else begin
            key_sync<={key_sync[0],key_n};
            if(key_sync[1]==key_level) debounce_count<=0;
            else if(accept_edge)begin
                debounce_count<=0; key_level<=key_sync[1];
            end else debounce_count<=debounce_count+1'b1;
            if(accept_edge)begin
                hold_count<=0;
                if(key_sync[1])begin
                    if(!long_sent)mode<=(mode==2)?2'd0:mode+1'b1;
                end else long_sent<=0;
            end else if(!key_level && !long_sent)begin
                if(hold_count==LONG_TICKS-1)begin
                    recalib<=1; long_sent<=1;
                end else hold_count<=hold_count+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(DEBOUNCE_TICKS<1 || LONG_TICKS<2)
        $fatal(1,"invalid mode-button timing parameters");
    // synthesis translate_on
endmodule
