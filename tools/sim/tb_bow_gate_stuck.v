//-----------------------------------------------------------------------------
// tb_bow_gate_stuck.v — 复现并验证「某一根弦一直自己响」的根因
//
// 根因（src/paw3395_driver.v 的 S_MOTION_WAIT index=0 分支）：
//   Motion 寄存器 bit7 (MOT) = 0 表示"这一轮没有位移"，
//   但原代码直接跳去读 SQUAL，**不清 delta_x/delta_y**，
//   于是它们保留上一次运弓结束时的值；S_QUALITY_WAIT 又无条件
//   `sample_valid<=1'b1`。下游本模块每 2 ms 收到一个"位移 = 旧大值"的假样本。
//
// 本测试台直接验证后半段：
//   ① dx 恒 30 持续 40 个样本        -> gate 开（正常运弓）
//   ② dx 仍恒 30 再持续 600 个样本   -> gate **一直保持 1**（= 实板自鸣）
//   ③ dx 归零（修复后 MOT=0 的行为） -> gate 在 21 个样本内关闭（修复生效）
//
// 说明：本测试台不例化 SPI，所以它验证的是"假样本 -> gate 卡死"这条机理，
//       而不是 driver 改动本身；driver 改动是让 ③ 的条件真正成立。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_bow_gate_stuck;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg sample_valid = 1'b0;
    reg ready = 1'b0;
    reg signed [15:0] dx = 16'sd0;
    reg signed [15:0] dy = 16'sd0;

    wire gate, direction, lifted, bounce;
    wire [7:0] speed;
    wire signed [23:0] position;

    // CLOCK_HZ 缩小 1000 倍，让 8 ms 看门狗在仿真里是 400 拍
    bow_motion_tracker #(.CLOCK_HZ(50000), .WATCHDOG_MS(8)) dut (
        .clk(clk), .reset(reset), .sample_valid(sample_valid), .ready(ready),
        .motion(8'h00), .dx(dx), .dy(dy),
        .gate(gate), .direction(direction), .lifted(lifted),
        .speed(speed), .bounce(bounce), .position(position)
    );

    always #10 clk = ~clk;      // 20 ns 一拍

    integer i;
    integer errors = 0;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (5) tick;
        reset = 1'b0;
        ready = 1'b1;
        sample_valid = 1'b1;
        repeat (3) tick;

        // ---- ① 运弓：dx = 30 ----
        dx = 16'sd30;
        for (i = 0; i < 40; i = i + 1) tick;
        if (gate !== 1'b1) begin
            $display("FAIL 1: dx=30 应开弓，gate=%b", gate);
            errors = errors + 1;
        end else
            $display("ok  1  gate opened, dx=30, speed=%0d", speed);

        // ---- ② 关键：驱动继续送旧 dx=30（MOT=0 且未清零时的实际波形） ----
        for (i = 0; i < 600; i = i + 1) tick;
        if (gate !== 1'b1) begin
            $display("FAIL 2: 假样本应让 gate 卡在 1（实板自鸣），got %b", gate);
            errors = errors + 1;
        end else
            $display("ok  2  gate STUCK at 1 with stale dx=30, speed=%0d  <-- 实板现象", speed);

        // ---- ③ 修复后：MOT=0 时 delta 清零 ----
        dx = 16'sd0;
        for (i = 0; i < 40; i = i + 1) tick;
        if (gate !== 1'b0) begin
            $display("FAIL 3: delta 归零后 gate 应关闭，got %b speed=%0d", gate, speed);
            errors = errors + 1;
        end else
            $display("ok  3  gate closed after delta=0, speed=%0d  <-- 修复生效", speed);

        // ---- ④ 再运弓一次，确认关得掉也开得起来 ----
        dx = 16'sd25;
        for (i = 0; i < 40; i = i + 1) tick;
        if (gate !== 1'b1) begin
            $display("FAIL 4: 再次运弓应能重新开弓，got %b", gate);
            errors = errors + 1;
        end else
            $display("ok  4  gate re-opened after resume");

        if (errors == 0) $display("PASS bow gate stuck");
        else             $display("FAIL bow gate stuck, errors=%0d", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL timeout");
        $finish;
    end
endmodule

`default_nettype wire
