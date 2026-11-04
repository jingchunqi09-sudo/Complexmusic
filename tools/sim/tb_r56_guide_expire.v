`timescale 1ns/1ps
//=============================================================================
// tb_r56_guide_expire.v — 曲谱"指引模式"验证
//
// 需求（用户明确）：曲谱导入是为了**指引演奏**，不是自动播放。
// 所以本测试断言两件事，缺一不可：
//   ① 曲谱播放期间 pcm 必须恒为 0（不发声）
//   ② 指引目标必须正确更新（弦号 + 品位，按定弦换算）
//
// 事件：
//   tick 0    PLUCK lane0 note 58  → 小提琴 1 弦，空弦 55，品 3
//   tick 100  PLUCK lane2 note 72  → 小提琴 3 弦，空弦 69，品 3
// tick_us = 10 us → tick100 = 1 ms
// 校验点：t≈0.6 ms 时应指向 lane0/fret3，t≈1.8 ms 时应指向 lane2/fret3。
//=============================================================================
module tb_r56_guide_expire;
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

    integer errors = 0, n = 0, nonzero = 0, pmax = 0, pabs;
    always @(posedge clk) if (dut.pcm_valid) begin
        n = n + 1;
        if (dut.pcm != 16'sd0) begin
            nonzero = nonzero + 1;
            if (nonzero < 4) $display("FAIL auto-play: pcm=%0d t=%0t", dut.pcm, $time);
        end
        pabs = (dut.pcm < 0) ? -dut.pcm : dut.pcm;
        if (pabs > pmax) pmax = pabs;
    end

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin $display("FAIL %0s (t=%0t)", msg, $time); errors = errors + 1; end
        end
    endtask

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

    reg [7:0] pay [0:63];
    task send_frame_n(input [7:0] cmd, input integer len);
        integer k; reg [15:0] c;
        begin
            c = 16'hFFFF;
            uart_send(8'hA5); uart_send(8'h5A);
            uart_send(cmd); c = crc16(cmd, c);
            uart_send(8'd0); c = crc16(8'd0, c);
            uart_send(len[7:0]); c = crc16(len[7:0], c);
            for (k = 0; k < len; k = k + 1) begin uart_send(pay[k]); c = crc16(pay[k], c); end
            uart_send(c[7:0]); uart_send(c[15:8]);
        end
    endtask

    initial begin
        $display("=== tb_r56_guide_expire: 曲谱只指引、不发声 ===");
        repeat (400) @(posedge clk);
        reset_n = 1;
        repeat (3000) @(posedge clk);

        // SCORE_BEGIN: count=2, tick_us=10
        pay[0]=8'd2; pay[1]=8'd0; pay[2]=8'd10; pay[3]=8'd0;
        send_frame_n(8'h20, 4);
        repeat (3000) @(posedge clk);

        // 事件0：lane0 note58 tick0      事件1：lane2 note72 tick100
        pay[0]=8'd0; pay[1]=8'd0; pay[2]=8'd58; pay[3]=8'd100; pay[4]=8'd0;   pay[5]=8'd0;
        pay[6]=8'd0; pay[7]=8'd2; pay[8]=8'd72; pay[9]=8'd100; pay[10]=8'd100;pay[11]=8'd0;
        send_frame_n(8'h21, 12);
        repeat (3000) @(posedge clk);

        // 播放（指引）
        pay[0] = 8'd1;
        send_frame_n(8'h23, 1);
        repeat (2000) @(posedge clk);

        // 第一个目标（tick 0 → 约 0.4 ms 处）
        repeat (6000) @(posedge clk);
        $display("G1  valid=%b lane=%0d fret=%0d pcm_nonzero=%0d",
                 dut.g_show, dut.g_lane, dut.g_fret, nonzero);
        check(dut.g_show == 1'b1, "guide target is active while score plays");
        check(dut.g_lane == 3'd0, "first target = lane0");
        check(dut.g_fret == 5'd3,  "first target fret = 3 (58-55)");

        // 第二个目标（tick 100 = 1 ms）
        repeat (60000) @(posedge clk);
        $display("G2  valid=%b lane=%0d fret=%0d pcm_nonzero=%0d",
                 dut.g_show, dut.g_lane, dut.g_fret, nonzero);
        check(dut.g_lane == 3'd2, "second target = lane2");
        check(dut.g_fret == 5'd3, "second target fret = 3 (72-69)");

        // ---- R56 新增：播完之后的收尾行为 ----
        // 曲谱 tick_us=10、最后一个事件 tick=100 -> 1 ms 播完，state 回 0。
        // 设计取"再保持 1 s"，所以这里分两个点验证：0.5 s 时还在、1.2 s 时必须没了。
        repeat (25_000_000) @(posedge clk);        // +0.5 s
        $display("E1  t=+0.50s  valid=%b stance=%0d", dut.g_show, dut.lk_score_state);
        check(dut.g_show == 1'b1, "guide must survive the 1 s follow-along window");

        repeat (35_000_000) @(posedge clk);        // +1.2 s 累计
        $display("E2  t=+1.20s  valid=%b stance=%0d", dut.g_show, dut.lk_score_state);
        check(dut.g_show == 1'b0, "guide must be cleared 1 s after score ends");

        $display("RESULT samples=%0d nonzero=%0d pmax=%0d errors=%0d frames_ok=%0d",
                 n, nonzero, pmax, errors, dut.lk_ok);
        check(nonzero == 0, "score playback must NOT produce audio");
        if (errors == 0) $display("PASS guide expire");
        else             $display("FAIL guide expire");
        $finish;
    end

    initial begin #2_500_000_000; $display("FAIL timeout"); $finish; end
endmodule
