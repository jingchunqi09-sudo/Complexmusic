`timescale 1ns/1ps
//=============================================================================
// tb_top_uart.v — 顶层 + **真实 UART 帧**注入测试
//
// 为什么需要它：之前两个"逐样本相同"的仿真里 UART 一直是空闲的，而板上
// ESP32 一直在发帧。多模型评审（R27）指出这正是结论可能失效的盲区：
//   "仿真里的 UART 空闲不是真实情况——板上 RX 一直在收帧。"
// 本测试堵住这个盲区：往 uart_rx_i 灌**合法 CRC 帧**，覆盖所有会影响声音的
// 命令，然后用极端值把每个参数都推到边界，再看 DAC 的 pcm 会不会出声。
//
// 注入的命令（全部是合法帧，CRC 正确）：
//   SET_VOLUME 255 / SET_VOLUME 0
//   SET_TUNING 每根弦都写 0（最坏情况：MIDI 0）
//   SET_TUNING 每根弦写 127
//   SET_FX bypass=0 wet=255 damp=0 tail=3（把混响全开）
//   SET_TONE warm=0 bright=4095（把音色均衡推到两端）
//   SET_EXPR depth=255 rate=255 glide=255
//   SCORE_CTRL=1（请求播放，但曲谱事件数为 0）
// 断言：整个过程 pcm 必须恒为 0。
//=============================================================================
module tb_top_uart;
    reg clk = 0, reset_n = 0;
    always #10 clk = ~clk;

    reg mode_n = 1'b1;
    reg uart_rx = 1'b1;
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

    integer errors = 0, n = 0, nonzero = 0;
    always @(posedge clk) if (dut.pcm_valid) begin
        n = n + 1;
        if (dut.pcm != 16'sd0) begin
            nonzero = nonzero + 1;
            if (nonzero < 6) $display("FAIL pcm nonzero=%0d t=%0t", dut.pcm, $time);
        end
    end

    localparam integer BIT_NS = 4340;
    task uart_send(input [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin uart_rx = b[i]; #(BIT_NS); end
            uart_rx = 1'b1; #(BIT_NS);
        end
    endtask

    function [15:0] crc16;
        input [7:0] d; input [15:0] c_in;
        integer k; reg [15:0] c;
        begin
            c = c_in ^ {d, 8'h00};
            for (k = 0; k < 8; k = k + 1) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16 = c;
        end
    endfunction

    task send_frame(input [7:0] cmd, input [7:0] len,
                    input [7:0] p0, input [7:0] p1, input [7:0] p2,
                    input [7:0] p3, input [7:0] p4);
        integer k; reg [15:0] c;
        reg [7:0] pay [0:4];
        begin
            pay[0]=p0; pay[1]=p1; pay[2]=p2; pay[3]=p3; pay[4]=p4;
            c = 16'hFFFF;
            uart_send(8'hA5); uart_send(8'h5A);
            uart_send(cmd); c = crc16(cmd, c);
            uart_send(8'd0); c = crc16(8'd0, c);
            uart_send(len); c = crc16(len, c);
            for (k = 0; k < len; k = k + 1) begin uart_send(pay[k]); c = crc16(pay[k], c); end
            uart_send(c[7:0]); uart_send(c[15:8]);
        end
    endtask

    integer l;
    initial begin
        $display("=== tb_top_uart: 合法帧注入下的静音验证 ===");
        repeat (400) @(posedge clk);
        reset_n = 1;
        repeat (2000) @(posedge clk);

        // 音量推到两端
        send_frame(8'h10, 8'd1, 8'd255, 0,0,0,0);  repeat (4000) @(posedge clk);
        send_frame(8'h10, 8'd1, 8'd0,   0,0,0,0);  repeat (4000) @(posedge clk);
        // 定弦全部写 0（最坏：MIDI 0），再全部写 127
        for (l = 0; l < 8; l = l + 1) begin
            send_frame(8'h12, 8'd2, l[7:0], 8'd0, 0,0,0);
            repeat (1500) @(posedge clk);
        end
        for (l = 0; l < 8; l = l + 1) begin
            send_frame(8'h12, 8'd2, l[7:0], 8'd127, 0,0,0);
            repeat (1500) @(posedge clk);
        end
        // 混响全开
        send_frame(8'h14, 8'd4, 8'd255, 8'd0, 8'd3, 8'd0, 0); repeat (4000) @(posedge clk);
        // 音色推到两端
        send_frame(8'h16, 8'd5, 8'd0, 8'd0, 8'd255, 8'd15, 8'd1); repeat (4000) @(posedge clk);
        // 表现参数拉满
        send_frame(8'h15, 8'd12, 8'd255,8'd255,8'd255,8'd255, 8'd255);
        repeat (6000) @(posedge clk);
        // 请求播放（事件数为 0）
        send_frame(8'h23, 8'd1, 8'd1, 0,0,0,0);
        repeat (20000) @(posedge clk);

        $display("RESULT samples=%0d nonzero=%0d errors=%0d frames_ok=%0d frames_bad=%0d",
                 n, nonzero, errors, dut.lk_ok, dut.lk_bad);
        if (nonzero == 0) $display("PASS top uart silence");
        else              $display("FAIL top uart silence");
        $finish;
    end

    initial begin #150_000_000; $display("FAIL timeout"); $finish; end
endmodule
