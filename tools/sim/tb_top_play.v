`timescale 1ns/1ps
//=============================================================================
// tb_top_play.v — 顶层"演奏态"对拍台（R38 录音抽头取证专用）
//
// 为什么需要它：tb_top_rest 的 pcm 恒为 0，只能证明"静音时没多出声音"，
// 无法证明"演奏时音频通路一个门都没变"。本台用相同的 force 序列（不改 RTL）
// 让 lane0 真的起振，然后把每个 pcm 样本导出，两份源码逐字节比 md5。
//
// 三种用法（+rec=1 才发 REC_CTRL，故可分别证明"默认态"与"录音中"）：
//   vsim ... tb_top_play +dump=a.txt            → 演奏但不开录音
//   vsim ... tb_top_play +dump=b.txt +rec=1     → 演奏中途开启录音
//
// 额外导出：
//   +rx=<file>  把 FPGA 从 UART 发出的字节按十六进制逐行写出（用于解帧 + LADPCM 解码）
//
// force 的是顶层内部 wire（gates/notes/speeds/...），与 physical_performer_frontend
// 的输出端口同网，等价于"人真的在拉弓"，且对 R36/R38 两份源码完全一样。
//=============================================================================
module tb_top_play;
    reg clk = 0, reset_n = 0;
    always #10 clk = ~clk;              // 50 MHz

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

    // ---------------- pcm 采样 ----------------
    integer fd = 0, n = 0, nz = 0, first_nz = -1;
    reg [1023:0] dump_file;
    reg [1023:0] rx_file;
    integer do_rec = 0;

    always @(posedge clk) begin
        if (dut.pcm_valid) begin
            n = n + 1;
            if (dut.pcm != 16'sd0) begin
                nz = nz + 1;
                if (first_nz < 0) first_nz = n;
            end
            if (fd != 0) $fdisplay(fd, "%0d", dut.pcm);
        end
    end

    // ---------------- UART 字节捕获（FPGA → ESP32） ----------------
    localparam integer UART_CLKS = 217;     // 与 FPGA 侧同一分频：50 MHz/217
    reg [7:0] rx_b = 8'd0;
    reg [3:0] rx_i = 4'd0;
    integer rx_cnt = 0, rx_state = 0, rx_total = 0;
    integer rfd = 0;

    always @(posedge clk) begin
        case (rx_state)
            0: if (!uart_tx_o) begin rx_state <= 1; rx_cnt <= 0; end
            1: begin                                    // 起始位：等 1.5 位，落点即 bit0 中点
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == UART_CLKS + UART_CLKS/2 - 1) begin
                       rx_b[0] <= uart_tx_o;
                       rx_i    <= 4'd1;
                       rx_cnt  <= 0;
                       rx_state <= 2;
                   end
               end
            2: begin
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == UART_CLKS - 1) begin
                       rx_cnt  <= 0;
                       rx_b[rx_i] <= uart_tx_o;
                       if (rx_i == 4'd7) rx_state <= 3;
                       else              rx_i <= rx_i + 4'd1;
                   end
               end
            3: begin
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == UART_CLKS - 1) begin
                       rx_state <= 0; rx_cnt <= 0;
                       if (rfd != 0) $fdisplay(rfd, "%02x", rx_b);
                       rx_total = rx_total + 1;
                   end
               end
            default: rx_state <= 0;
        endcase
    end

    // ---------------- ESP32 侧发帧（与 tb_ctrl_route 逐字节一致） ----------------
    task uart_send(input [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0;
            repeat (UART_CLKS) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                repeat (UART_CLKS) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (UART_CLKS) @(posedge clk);
        end
    endtask

    function [15:0] crc16;
        input [7:0] d;
        input [15:0] c_in;
        integer k;
        reg [15:0] c;
        begin
            c = c_in ^ {d, 8'h00};
            for (k = 0; k < 8; k = k + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16 = c;
        end
    endfunction

    reg [7:0] pl[0:15];

    task send_frame(input [7:0] cmd, input [7:0] seq, input integer len);
        integer k;
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            uart_send(8'hA5);
            uart_send(8'h5A);
            uart_send(cmd);         c = crc16(cmd,         c);
            uart_send(seq);         c = crc16(seq,         c);
            uart_send(len[7:0]);    c = crc16(len[7:0],    c);
            for (k = 0; k < len; k = k + 1) c = crc16(pl[k], c);
            for (k = 0; k < len; k = k + 1) uart_send(pl[k]);
            uart_send(c[7:0]);
            uart_send(c[15:8]);
        end
    endtask

    // ---------------- 录音链内部探针（只读，用于区分"没发"与"没收"） ----------------
    integer p_lad = 0, p_wr = 0, p_send = 0, p_allow = 0, p_en = 0;
    integer rifd = 0, lfd = 0;
    reg [1023:0] recin_file, lad_file;
    // R39：rec_ladpcm 已搬到顶层 generate 块 REC_TAP 里（不再在链路模块内部）
    wire signed [15:0] probe_rec_pcm = dut.REC_TAP.u_rec_tap.pcm;

    // 录音链真正"看到"的 PCM 序列：Python 侧用它独立复现 LADPCM，
    // 逐字节比对 RTL 发出的 56 字节，从而证明编码器与固件解码器严格自洽。
    always @(posedge clk) begin
        if (dut.REC_TAP.u_rec_tap.enable)          p_en    = p_en    + 1;
        if (dut.REC_TAP.u_rec_tap.byte_valid) begin
            p_lad = p_lad + 1;
            if (lfd != 0) $fdisplay(lfd, "%02x", dut.REC_TAP.u_rec_tap.byte_data);
        end
        if (dut.REC_TAP.u_rec_tap.pcm_valid && rifd != 0)
            $fdisplay(rifd, "%0d", probe_rec_pcm);
        if (dut.LINK_ON.u_link.u_rstream.tx_wr_en)    p_wr    = p_wr    + 1;
        if (dut.LINK_ON.u_link.u_rstream.tx_send)     p_send  = p_send  + 1;
        if (dut.LINK_ON.u_link.u_rstream.allow)       p_allow = p_allow + 1;
    end

    // ---------------- 主流程 ----------------
    initial begin
        if ($value$plusargs("dump=%s", dump_file)) begin
            fd = $fopen(dump_file, "w");
            $display("dumping pcm to %0s", dump_file);
        end
        if ($value$plusargs("rx=%s", rx_file)) begin
            rfd = $fopen(rx_file, "w");
            $display("dumping uart bytes to %0s", rx_file);
        end
        do_rec = 0;
        if ($value$plusargs("rec=%d", do_rec)) ;
        if ($value$plusargs("recin=%s", recin_file)) begin
            rifd = $fopen(recin_file, "w");
            $display("dumping rec input pcm to %0s", recin_file);
        end
        if ($value$plusargs("lad=%s", lad_file)) begin
            lfd = $fopen(lad_file, "w");
            $display("dumping ladpcm bytes to %0s", lad_file);
        end

        $display("=== tb_top_play: lane0 real bow, rec=%0d ===", do_rec);

        repeat (400) @(posedge clk);
        reset_n = 1;
        repeat (20_000) @(posedge clk);      // 等链路/前端就绪

        // ---- 起振：lane0 空弦 G3(55)，弓速 132，力度 100 ----
        // 小提琴波导要求 gate 为电平 + 单拍 trigger（R26 修的第 2 条）。
        force dut.notes[6:0]      = 7'd55;
        force dut.speeds[15:0]    = 16'd132;
        force dut.velocities[7:0] = 8'd100;
        force dut.directions[0]   = 1'b0;
        force dut.gates[0]        = 1'b1;
        force dut.triggers[0]     = 1'b1;
        repeat (4) @(posedge clk);
        force dut.triggers[0]     = 1'b0;

        // ---- 演奏 300k 拍（约 293 个样本） ----
        repeat (300_000) @(posedge clk);

        if (do_rec != 0) begin
            // ---- 演奏中途下发 REC_CTRL：enable=1, decim=1(2x) ----
            // 命令码是 CMD_REC_CTRL = 0x30（0x17 只是寄存器地址，不是命令）
            pl[0] = 8'h01 | (8'h01 << 1);
            send_frame(8'h30, 8'h01, 1);       // CMD_REC_CTRL
            $display("[rec] REC_CTRL sent at t=%0t (ctrl=%02x)", $time, pl[0]);
            // 留 400k 拍让 LADPCM + 56 字节帧把它发出去
            repeat (400_000) @(posedge clk);
            pl[0] = 8'h00;
            send_frame(8'h30, 8'h02, 1);
            repeat (20_000) @(posedge clk);
        end else begin
            repeat (100_000) @(posedge clk);
        end

        $display("RESULT samples=%0d nonzero=%0d first_nz=%0d uart_bytes=%0d",
                 n, nz, first_nz, rx_total);
        $display("PROBE en_clk=%0d lad_bytes=%0d stream_wr=%0d stream_send=%0d allow_clk=%0d",
                 p_en, p_lad, p_wr, p_send, p_allow);
        if (nz > 0) $display("PASS top play audible");
        else        $display("FAIL top play silent");
        if (fd != 0) $fclose(fd);
        if (rfd != 0) $fclose(rfd);
        if (rifd != 0) $fclose(rifd);
        if (lfd != 0) $fclose(lfd);
        $finish;
    end
endmodule
