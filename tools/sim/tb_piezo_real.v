// tb_piezo_real.v —— 用真实录音回放验证 piezo_string_det 的 RTL 行为
//
// 为什么必须做这一步：
//   g21_sweep_lp310.py 标定出的 90% 拒绝率是 **Python 模型** 的结果。
//   参考文件夹的 g16_out.txt 已经证明 rh6 的 RTL 与 Python 并不一致
//   （上扫 36 vs 42，多报 17%）。所以「Python 说 90%」不能当作
//   「RTL 也 90%」，必须用同一份录音回放 RTL 才算数。
//
// 数据口径与 g13_vectors.py 完全一致：四通道按 ch0,ch1,ch2,ch3 轮转，
// 每通道一个样本，值是 12 位原始码。模块内部所有时间量都按 sample_valid
// 计数，所以这里一个时钟喂一个样本，等价于真实 24.9 kSPS 时序。
//
// 用法：vsim -c tb_piezo_real +VEC=<path>.bin +FS=24704 +LIMIT=<n> -do "run -all"
`timescale 1ns/1ps
`default_nettype none

module tb_piezo_real;
    localparam integer AW = 21;              // 2M 交错样本

    reg clk = 0;
    reg reset = 1;
    reg [11:0] value = 0;
    reg [1:0] channel = 0;
    reg sample_valid = 0;

    wire [3:0]  trigger;
    wire [31:0] velocity;
    wire        ev_valid;
    wire [3:0]  ev_strings;
    wire [14:0] ev_peak;
    wire [15:0] ev_total;
    wire [63:0] dbg_ay;
    wire [3:0]  dbg_warm;
    wire [7:0]  vibrato;
    wire [15:0] rej_total;

    piezo_string_det dut(
        .clk(clk),.reset(reset),.sample_valid(sample_valid),.healthy(1'b1),
        .channel(channel),.value(value),
        .trigger(trigger),.velocity(velocity),
        .ev_valid(ev_valid),.ev_strings(ev_strings),.ev_peak(ev_peak),
        .ev_total(ev_total),.dbg_ay(dbg_ay),.dbg_warm(dbg_warm),
        .vibrato_depth(vibrato),.rej_total(rej_total));

    always #10 clk = ~clk;

    reg [15:0] mem [0:(1<<AW)-1];
    reg [1023:0] vecpath;
    integer fd, r, idx, nsamp, limit, fs, loaded;
    real t_ms;

    initial begin
        if (!$value$plusargs("VEC=%s", vecpath)) begin
            $display("FATAL no +VEC=");
            $finish;
        end
        if (!$value$plusargs("FS=%d", fs)) fs = 24704;
        if (!$value$plusargs("LIMIT=%d", limit)) limit = 0;

        fd = $fopen(vecpath, "rb");
        if (fd == 0) begin
            $display("FATAL cannot open %0s", vecpath);
            $finish;
        end
        idx = 0;
        r = $fread(mem[idx], fd);
        while (r > 0 && idx < (1<<AW)-1) begin
            idx = idx + 1;
            r = $fread(mem[idx], fd);
        end
        $fclose(fd);
        nsamp = idx;
        if (limit > 0 && nsamp > limit) nsamp = limit;
        $display("VEC %0s  samples=%0d  fs=%0d", vecpath, nsamp, fs);
        loaded = 1;
    end

    // reset 释放后再开始喂数据
    integer n;
    initial begin
        loaded = 0;
        repeat(20) @(negedge clk);
        wait (loaded == 1);
        reset = 0;
        @(negedge clk);
        for (n = 0; n < nsamp; n = n + 1) begin
            channel = n[1:0];
            value   = mem[n][11:0];
            sample_valid = 1'b1;
            @(negedge clk);
        end
        sample_valid = 1'b0;
        repeat(2000) @(negedge clk);
        $display("RESULT ev=%0d rej=%0d vib=%0d", ev_total, rej_total, vibrato);
        $display("DONE");
        $finish;
    end

    // 逐事件打印（时刻按通道样本数换算）
    always @(posedge clk) begin
        if (ev_valid) begin
            t_ms = (n / 4) * 1000.0 / fs;
            $display("EVT %0.2f %0d %0d", t_ms, ev_strings, ev_peak);
        end
    end
endmodule
`default_nettype wire
