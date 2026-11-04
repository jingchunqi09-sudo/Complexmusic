`timescale 1ns/1ps
//=============================================================================
// tb_top_rest.v — 顶层"静止"测试：不演奏、不接 ESP32、无压电激励
//
// 用途：把 R24 与 R26 的顶层放进**同一套激励**，逐样本导出 pcm 再比对。
// 这是唯一能回答"R26 的音频输出到底和 R24 一样不一样"的方法——
// 靠读代码推断已经错了一次。
//
// 激励约定：
//   paw_miso / piezo_miso / left_adc*_out 全部 0  → 传感器读数恒 0，无运动、无压电
//   uart_rx_i = 1（空闲）                      → 链路收不到任何帧
//   mode_n = 1                                  → 不按键
//   ENABLE_HDMI = 0                             → 跳过视频域（避免厂商 PLL 原语）
//
// 输出：+dump=<file> 时每产生一个 pcm 样本写一行 "<序号> <有符号十进制>"
//=============================================================================
module tb_top_rest;
    reg clk = 0, reset_n = 0;
    always #10 clk = ~clk;          // 50 MHz

    reg mode_n   = 1'b1;
    reg uart_rx  = 1'b1;
    reg paw_miso = 1'b0, piezo_miso = 1'b0;
    reg left1_out = 1'b0, left2_out = 1'b0;
    reg audio_bck_in = 1'b0;
    reg piezo_busy_n = 1'b1;

    wire uart_tx_o, hp_bck, hp_ws, hp_din, pa_en;
    wire paw_ncs, paw_sclk, paw_mosi;
    wire left_adc_sclk, left_adc_din, left_adc1_cs_n, left_adc2_cs_n;
    wire left_tx1, left_tx2, left_tx3, left_tx4, left_sk_clk, left_sk_data;
    wire piezo_sclk, piezo_mosi, piezo_cs_n, piezo_convst_n, piezo_reset_n;
    wire [2:0] hdmi_data_p, hdmi_data_n;
    wire hdmi_clock_p, hdmi_clock_n, hdmi_tx_enable;

    tang_mega_60k_top #(.ENABLE_HDMI(0)) dut (
        .clk_50m(clk), .audio_bck_in(audio_bck_in), .reset_n(reset_n), .mode_n(mode_n),
        .uart_rx_i(uart_rx), .uart_tx_o(uart_tx_o),
        .hp_bck(hp_bck), .hp_ws(hp_ws), .hp_din(hp_din), .pa_en(pa_en),
        .paw_ncs(paw_ncs), .paw_sclk(paw_sclk), .paw_mosi(paw_mosi), .paw_miso(paw_miso),
        .left_adc_sclk(left_adc_sclk), .left_adc_din(left_adc_din),
        .left_adc1_cs_n(left_adc1_cs_n), .left_adc1_out(left1_out),
        .left_adc2_cs_n(left_adc2_cs_n), .left_adc2_out(left2_out),
        .left_tx1(left_tx1), .left_tx2(left_tx2), .left_tx3(left_tx3), .left_tx4(left_tx4),
        .left_sk_clk(left_sk_clk), .left_sk_data(left_sk_data),
        .piezo_sclk(piezo_sclk), .piezo_mosi(piezo_mosi), .piezo_miso(piezo_miso),
        .piezo_cs_n(piezo_cs_n), .piezo_convst_n(piezo_convst_n),
        .piezo_reset_n(piezo_reset_n), .piezo_busy_n(piezo_busy_n),
        .hdmi_data_p(hdmi_data_p), .hdmi_data_n(hdmi_data_n),
        .hdmi_clock_p(hdmi_clock_p), .hdmi_clock_n(hdmi_clock_n), .hdmi_tx_enable(hdmi_tx_enable)
    );

    integer fd = 0;
    integer n  = 0;
    integer nonzero = 0;
    integer first_nonzero_t = -1;
    reg [1023:0] dump_file;

    initial begin
        if ($value$plusargs("dump=%s", dump_file)) begin
            fd = $fopen(dump_file, "w");
            $display("dumping pcm to %0s", dump_file);
        end
        $display("=== tb_top_rest: 静止激励（无运动/无压电/无 ESP32）===");
        repeat (400) @(posedge clk);
        reset_n = 1;
        // 10 ms 仿真（约 488 个音频样本）足够看清"静音还是有声"
        repeat (480_000) @(posedge clk);
        $display("RESULT samples=%0d nonzero=%0d first_nonzero_t=%0d",
                 n, nonzero, first_nonzero_t);
        if (nonzero == 0) $display("PASS top rest silence");
        else              $display("FAIL top rest silence: %0d nonzero samples", nonzero);
        if (fd != 0) $fclose(fd);
        $finish;
    end

    // 每个音频样本记一行
    always @(posedge clk) begin
        if (dut.pcm_valid) begin
            n = n + 1;
            if (dut.pcm != 16'sd0) begin
                nonzero = nonzero + 1;
                if (first_nonzero_t < 0) first_nonzero_t = $time;
            end
            if (fd != 0) $fdisplay(fd, "%0d %0d", n, dut.pcm);
        end
    end
endmodule
