`timescale 1ns/1ps
`include "instrument_protocol.vh"
// 直接激励调弦寄存器边界，避免只依赖串口帧间隔而遗漏同周期写/提交。
module instrument_config_bank_tb;
    reg clock = 0;
    reg reset = 1;
    reg write_valid = 0;
    reg [2:0] write_address = 0;
    reg [7:0] write_note = 0;
    reg commit = 0;
    wire [63:0] active_notes;
    wire commit_ack;
    integer errors = 0;

    always #5 clock = ~clock;
    instrument_config_bank dut
    (
        .i_clk(clock),
        .i_reset(reset),
        .i_write_valid(write_valid),
        .i_write_addr(write_address),
        .i_write_data(write_note),
        .i_commit(commit),
        .o_active_open_notes(active_notes),
        .o_commit_ack(commit_ack)
    );
    task check;
        input condition;
        input [767:0] description;
        begin
            if (condition)
                $display("PASS: %0s", description);
            else
            begin
                $display("FAIL: %0s", description);
                errors = errors + 1;
            end
        end
    endtask
    initial
    begin
        repeat (3) @(negedge clock);
        reset = 0;
        check(active_notes == `INST_DEFAULT_OPEN_NOTES, "shared default tuning table is used consistently");
        write_valid = 1;
        write_address = 0;
        write_note = 60;
        @(negedge clock);
        write_valid = 0;
        check(active_notes[7:0] == 55, "writing shadow does not change active pitch");
        write_valid = 1;
        write_address = 4;
        write_note = 43;
        commit = 1;
        @(negedge clock);
        write_valid = 0;
        commit = 0;
        check(active_notes[7:0] == 60 && active_notes[39:32] == 43 && commit_ack,
              "write and commit on same edge include newest byte without torn tuning");
        @(negedge clock);
        check(!commit_ack, "commit acknowledgement lasts one system cycle");
        write_valid = 1;
        write_note = 200;
        commit = 1;
        @(negedge clock);
        write_valid = 0;
        commit = 0;
        check(active_notes[39:32] == 43, "MIDI values above 127 cannot corrupt the tuning table");
        $display("INSTRUMENT_CONFIG_RESULT: errors=%0d", errors);
        $finish;
    end
endmodule
