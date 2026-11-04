`timescale 1ns/1ps
// R16 verification: piezo-driven bow string selection.
// Drives the production frontend with forced sensor-side signals and checks
// that the bow gate only opens the string the piezo bank reports as loudest,
// while falling back to the fingered strings when the piezo has no opinion.
module tb_bow_string_select;
reg clk=0;always #10 clk=~clk;
reg reset=1;
wire [55:0] notes;
wire [7:0] gates,triggers,stops;
wire [3:0] ready,fault;
wire [31:0] event_sequence;
integer cases=0;

physical_performer_frontend dut(
    .clk_50m(clk),.reset(reset),.paw_miso(1'b0),
    .left_adc1_out(1'b0),.left_adc2_out(1'b0),
    .piezo_miso(1'b0),.piezo_busy_n(1'b1),
    .note_bus(notes),.gate_bus(gates),.trigger_bus(triggers),.stop_bus(stops),
    .sensor_ready(ready),.sensor_fault(fault),.event_sequence(event_sequence)
);
// ay[15:0]=string0 .. ay[63:48]=string3
task set_ay;input [15:0] s0,s1,s2,s3;begin
    force dut.piezo_ay={s3,s2,s1,s0};
end endtask
task expect_gate;input [3:0] want;input integer wait_clks;begin
    repeat(wait_clks)@(negedge clk);
    if(gates!=={4'd0,want})
        $fatal(1,"gate=%h want=%h case=%0d",gates,want,cases);
    cases=cases+1;
    $display("CASE %0d ok gate=%h",cases,want);
end endtask

initial begin
    force dut.p_trigger=4'd0;
    force dut.bow_speed=8'd0;
    set_ay(0,0,0,0);
    force dut.fingered_strings=4'b0000;
    repeat(6)@(negedge clk);reset=0;
    // 1) No fingering, piezo silent -> legal fallback: all four open strings.
    force dut.bow_gate=1'b1;
    expect_gate(4'hf,8);
    // 2) Piezo says string 1 is vibrating -> only string 1 is bowed.
    set_ay(0,1200,0,0);
    expect_gate(4'b0010,700000);
    // 3) Fingered string 0, piezo still on string 1 -> intersection empty,
    //    keep the fingered set (never silence a correctly fingered string).
    force dut.fingered_strings=4'b0001;
    expect_gate(4'b0001,8);
    // 4) Fingered string 0+1 -> intersection is string 1.
    force dut.fingered_strings=4'b0011;
    expect_gate(4'b0010,8);
    // 5) Hysteresis: string 3 must exceed 1.5x the current string for three
    //    consecutive evaluation windows (3 x 1.31 ms) before the bow moves.
    force dut.fingered_strings=4'b1000;
    set_ay(0,1200,0,6000);
    expect_gate(4'b1000,700000);
    // 6) Bow leaves: gate closes, selection is retained for the next stroke.
    force dut.bow_gate=1'b0;
    expect_gate(4'h0,8);
    $display("PASS bow string select: %0d cases",cases);
    $finish;
end
initial begin #60000000;$fatal(1,"timeout");end
endmodule
