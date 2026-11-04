`timescale 1ns/1ps
// Small deterministic contract test for the 16-key decoder.  It exercises
// baseline tracking, two-frame debounce, release, and multi-key diagnostics.
module tb_left_hand_fret_decoder;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg reset = 1'b1;
    reg [191:0] snapshot = 192'd0;
    reg snapshot_valid = 1'b0;
    wire [3:0] fret;
    wire fret_valid, changed, multi_key;
    integer k;
    integer change_count = 0;
    always @(negedge clk) if (changed) change_count = change_count + 1;

    left_hand_fret_decoder #(.TOUCH_DELTA_THRESHOLD(96), .DEBOUNCE_FRAMES(2)) dut (
        .clk_50m(clk), .reset(reset), .snapshot(snapshot),
        .snapshot_valid(snapshot_valid), .fret(fret), .fret_valid(fret_valid),
        .changed(changed), .multi_key(multi_key)
    );

    task send_frame;
        input integer key0;
        input integer key1;
        begin
            for (k=0; k<16; k=k+1) snapshot[k*12 +: 12] = 12'd2048;
            if (key0 >= 0) snapshot[key0*12 +: 12] = 12'd2200;
            if (key1 >= 0) snapshot[key1*12 +: 12] = 12'd2200;
            snapshot_valid = 1'b1;
            @(posedge clk); #1;
            snapshot_valid = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 1'b0;
        send_frame(-1, -1);       // establish the nominal baseline
        send_frame(6, -1);        // first candidate frame
        if (fret_valid) $fatal(1, "fret became valid before debounce");
        send_frame(6, -1);        // second stable frame accepts key 6
        if (!fret_valid || fret != 4'd6 || change_count != 1)
            $fatal(1, "debounced key 6 was not accepted");
        send_frame(6, 9);         // two simultaneous keys are diagnosed
        if (!multi_key) $fatal(1, "multi_key diagnostic did not assert");
        send_frame(-1, -1);       // release returns to no-key state
        if (fret_valid || change_count != 2) $fatal(1, "key release was not reported");
        $display("PASS: left_hand_fret_decoder baseline/debounce/multi-key/release");
        $finish;
    end
endmodule
