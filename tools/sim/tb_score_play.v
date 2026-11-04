`timescale 1ns/1ps
//=============================================================================
// tb_score_play.v — 曲谱通路功能验证：真的能下发并播出声
//
// 背景：R18 版本的曲谱是"能存不能播"——事件进得去，但小提琴波导的
// i_bow_speed 同时决定 w_bow_target_velocity，speed=0 时不发声。
// R26 修了两个点（曲谱弓速按力度映射、BOW 用门控电平），但一直没做过
// "整首曲子上传 → 出声" 的端到端验证，只验证过"没有事件时静音"。
//
// 本测试走完整链路：
//   UART 合法帧 → cmd_dispatch → score_store → score_player
//   → lane_arbiter → instrument_bank_core → pcm
//
// 上传 4 个事件（2 根弦同时拉 3 ms，然后一起 STOP）：
//   tick 0   BOW  lane0 note 55 vel 100
//   tick 0   BOW  lane2 note 69 vel 100
//   tick 300 STOP lane0
//   tick 300 STOP lane2
// tick_us = 10 us → 300 tick = 3 ms
//
// 断言：
//   1. 播放后声部总线的 gate 恰好是 0x05（lane0 + lane2），lane1/lane3 不响
//   2. 曲谱 lane 的弓速非 0（vel+32=132 → 0x0084）
//   3. pcm 出现非 0 样本（真出声）
//   4. STOP 之后 gate 归零
//=============================================================================
module tb_score_play;
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
    integer pmax = 0, pabs;
    always @(posedge clk) if (dut.pcm_valid) begin
        n = n + 1;
        if (dut.pcm != 16'sd0) nonzero = nonzero + 1;
        pabs = (dut.pcm < 0) ? -dut.pcm : dut.pcm;
        if (pabs > pmax) pmax = pabs;
    end

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("FAIL %0s  (t=%0t)", msg, $time);
                errors = errors + 1;
            end
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

    // 任意长度载荷（曲谱 DATA 帧需要 12 字节 = 2 个事件）
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

    integer i;
    initial begin
        $display("=== tb_score_play: 曲谱端到端发声验证 ===");
        repeat (400) @(posedge clk);
        reset_n = 1;
        repeat (3000) @(posedge clk);

        // ---- 1. SCORE_BEGIN: count=4, tick_us=10 ----
        pay[0] = 8'd4;  pay[1] = 8'd0;
        pay[2] = 8'd10; pay[3] = 8'd0;
        send_frame_n(8'h20, 4);
        repeat (3000) @(posedge clk);

        // ---- 2. SCORE_DATA: 2 个事件（12 字节）----
        // 事件 0: BOW lane0 note55 vel100 tick0
        pay[0]=8'd1; pay[1]=8'd0; pay[2]=8'd55; pay[3]=8'd100; pay[4]=8'd0; pay[5]=8'd0;
        // 事件 1: BOW lane2 note69 vel100 tick0
        pay[6]=8'd1; pay[7]=8'd2; pay[8]=8'd69; pay[9]=8'd100; pay[10]=8'd0; pay[11]=8'd0;
        send_frame_n(8'h21, 12);
        repeat (3000) @(posedge clk);

        // ---- 3. SCORE_DATA: 2 个 STOP 事件 tick=3000 (30 ms @tick_us=10) ----
        // 事件 2: STOP lane0 tick2000
        pay[0]=8'd2; pay[1]=8'd0; pay[2]=8'd0; pay[3]=8'd0; pay[4]=8'd184; pay[5]=8'd11;
        // 事件 3: STOP lane2 tick2000
        pay[6]=8'd2; pay[7]=8'd2; pay[8]=8'd0; pay[9]=8'd0; pay[10]=8'd184; pay[11]=8'd11;
        send_frame_n(8'h21, 12);
        repeat (3000) @(posedge clk);

        // ---- 4. 播放 ----
        pay[0] = 8'd1;
        send_frame_n(8'h23, 1);
        repeat (2000) @(posedge clk);

        // 播放中（约 0.4 ms 处）检查 gate 与弓速
        repeat (18000) @(posedge clk);
        $display("PLAY  aud_gate=%h aud_note=%h bank_gate=%h bank_note0=%0d bank_note2=%0d",
                 dut.aud_gate, dut.aud_note,
                 dut.u_audio_core.r_gate, dut.u_audio_core.r_note[6:0],
                 dut.u_audio_core.r_note[20:14]);
        $display("PLAY  aud_spd=%h pmax=%0d samples=%0d", dut.aud_spd, pmax, n);
        $display("DBG   r_gate=%h r_spd0=%h r_vel0=%h voice0=%0d env0=%0d mix=%0d dry=%0d",
                 dut.u_audio_core.r_gate, dut.u_audio_core.r_speed[15:0],
                 dut.u_audio_core.r_velocity[7:0], dut.u_audio_core.w_voice[0],
                 dut.u_audio_core.w_envelope[0], dut.u_audio_core.r_mix, dut.u_audio_core.r_dry);
        check(dut.aud_gate[3:0] == 4'b0101, "score gates = lane0 + lane2 only");
        check(dut.aud_spd[15:0] != 16'd0 && dut.aud_spd[47:32] != 16'd0,
              "score lanes have non-zero bow speed (vel+32)");
        check(dut.aud_spd[31:16] == 16'd0 && dut.aud_spd[63:48] == 16'd0,
              "idle score lanes keep zero bow speed");

        // 等 STOP 生效（tick 3000 = 30 ms），其间每 2 ms 打印一次幅度
        for (i = 0; i < 17; i = i + 1) begin
            repeat (100000) @(posedge clk);
            $display("AMP   t=%0dus pmax=%0d nonzero=%0d", 400 + (i+1)*2000, pmax, nonzero);
        end
        $display("AFTER aud_gate=%h nonzero=%0d samples=%0d pmax=%0d", dut.aud_gate, nonzero, n, pmax);
        check(dut.aud_gate == 8'h0, "score STOP releases all lanes");
        check(nonzero > 100, "score playback actually produces audio");
        check(pmax > 400, "score playback level is usable (not a whisper)");

        $display("RESULT samples=%0d nonzero=%0d errors=%0d frames_ok=%0d frames_bad=%0d",
                 n, nonzero, errors, dut.lk_ok, dut.lk_bad);
        if (errors == 0 && nonzero > 100) $display("PASS score play");
        else                              $display("FAIL score play");
        $finish;
    end

    initial begin #400_000_000; $display("FAIL timeout"); $finish; end
endmodule
