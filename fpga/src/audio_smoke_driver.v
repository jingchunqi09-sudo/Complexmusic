`timescale 1ns/1ps
// Explicit diagnostic stimulus, not a normal performance input and not PCM.
// Drives the real waveguide bank to isolate sensor gating from DAC operation.
module audio_smoke_driver #(parameter integer CLOCK_HZ=50000000)(
    input wire clk,reset,
    output wire [55:0] note_bus,output reg [7:0] gate_bus,trigger_bus,stop_bus,
    output reg event_valid,output reg [31:0] event_sequence,
    output reg [63:0] event_clock
);
    reg [31:0] counter;
    reg [1:0] phrase;
    wire [6:0] step={5'd0,phrase};
    assign note_bus={7'd69+step,7'd64+step,7'd60+step,7'd67+step,
        7'd76,7'd69,7'd62,7'd55};
    always @(posedge clk)begin
        event_valid<=0;trigger_bus<=0;stop_bus<=0;
        if(reset)begin
            counter<=0;phrase<=0;gate_bus<=0;event_sequence<=0;event_clock<=0;
        end else begin
            counter<=counter+1'b1;event_clock<=event_clock+1'b1;
            if(counter==CLOCK_HZ)begin
                gate_bus<=8'h0f;trigger_bus<=8'h0f;
                event_valid<=1;event_sequence<=event_sequence+1'b1;
            end else if(counter==3*CLOCK_HZ)begin
                gate_bus<=0;stop_bus<=8'h0f;
                event_valid<=1;event_sequence<=event_sequence+1'b1;
            end else if(counter==3*CLOCK_HZ+CLOCK_HZ/2)begin
                counter<=0;phrase<=phrase+1'b1;
            end
        end
    end
endmodule
