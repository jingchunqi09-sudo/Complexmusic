`timescale 1ns/1ps
// 同一段采集数据并行喂给 R23（旧）与 R24（新）的 bow_motion_tracker，
// 逐样本 dump speed / gate / direction，供 compare_replay.py 量化差异。
//
// vsim -c -lib work tb_bow_replay -do "run -all; quit -f" \
//      +hex=replay_3.hex +n=36456 +out=fast_up.csv
module tb_bow_replay;
    reg clk = 0, reset = 1, sample_valid = 0, ready = 1;
    always #10 clk = ~clk;

    reg signed [15:0] dx = 0, dy = 0;
    reg [7:0] motion = 8'h88;

    wire g0, dir0, l0, b0;
    wire [7:0] s0;
    wire signed [23:0] p0;
    wire g1, dir1, l1, b1;
    wire [7:0] s1;
    wire signed [23:0] p1;

    bow_motion_tracker_r23 #(
        .CLOCK_HZ(50000000), .WATCHDOG_MS(8), .AXIS_Y(1), .DZ(1), .WIN(9),
        .OPEN_TH(32), .CLOSE_TH(12), .OPEN_CONFIRM(3), .RELEASE_SAMPLES(22),
        .ATTACK_D(6), .ATTACK_N(3), .TURN_H(252)
    ) u_old (
        .clk(clk), .reset(reset), .sample_valid(sample_valid), .ready(ready),
        .motion(motion), .dx(dx), .dy(dy),
        .gate(g0), .direction(dir0), .lifted(l0), .speed(s0), .bounce(b0), .position(p0)
    );

    bow_motion_tracker #(
        .CLOCK_HZ(50000000), .WATCHDOG_MS(8), .AXIS_Y(1), .DZ(1), .WIN(9),
        .OPEN_TH(32), .CLOSE_TH(12), .OPEN_CONFIRM(3), .RELEASE_SAMPLES(22),
        .ATTACK_D(5), .ATTACK_N(3), .TURN_H(252),
        .AXIS_HYST_N(16), .SPEED_SLOW_SHIFT(2)
    ) u_new (
        .clk(clk), .reset(reset), .sample_valid(sample_valid), .ready(ready),
        .motion(motion), .dx(dx), .dy(dy),
        .gate(g1), .direction(dir1), .lifted(l1), .speed(s1), .bounce(b1), .position(p1)
    );

    reg [31:0] mem [0:65535];
    reg [511:0] hexfile, outfile;
    integer n = 0, i, fd;

    initial begin
        if (!$value$plusargs("hex=%s", hexfile)) begin
            $display("FAIL need +hex=<file>"); $finish;
        end
        if (!$value$plusargs("n=%d", n)) begin
            $display("FAIL need +n=<count>"); $finish;
        end
        if (!$value$plusargs("out=%s", outfile)) outfile = "out.csv";
        if (n > 65536) begin $display("FAIL n too large"); $finish; end

        $readmemh(hexfile, mem);
        fd = $fopen(outfile, "w");
        if (fd == 0) begin $display("FAIL cannot open %0s", outfile); $finish; end
        $fdisplay(fd, "i,old_speed,old_gate,new_speed,new_gate,new_dir,old_dir");

        reset = 1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;

        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            dx = mem[i][15:0];
            dy = mem[i][31:16];
            sample_valid = 1'b1;
            @(posedge clk);
            #1;
            sample_valid = 1'b0;
            $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                      i, s0, g0, s1, g1, dir1, dir0);
            @(posedge clk);
        end

        $fclose(fd);
        $display("PASS replay n=%0d out=%0s", n, outfile);
        $finish;
    end

    // 超时保护：正常 36k 样本只需要 ~150k clk
    initial begin
        #200000000;
        $display("FAIL replay timeout at i=%0d", i);
        $finish;
    end
endmodule
