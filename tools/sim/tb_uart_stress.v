`timescale 1ns/1ps
//=============================================================================
// tb_uart_stress.v — 连续发 30 次 QUERY_STATUS，验证 FPGA 的 UART 不会累积偏移
//
// 为什么需要：tb_status_rsp 只发了 1 帧，只能证明"单帧能回"。
// 实板症状是"收到一些字节但拼不出帧"，必须排除"FPGA 连续发帧会漂/会丢"。
// 这里把 30 帧的全部字节 dump 到文件，由 Python 逐帧校验 CRC 和长度。
//=============================================================================
module tb_uart_stress;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg  uart_rx_i = 1'b1;
    wire uart_tx_o;

    wire [7:0]  o_volume, o_wet, o_damping, o_sens, o_lane_en;
    wire [7:0]  o_stat_err, o_stat_ok, o_stat_bad, o_rec_drop, o_rec_ctrl;
    wire [1:0]  o_tail;
    wire        o_fx_bypass, o_mute, o_ev_valid, o_pcm_valid;
    wire [15:0] o_bow_deadband;
    wire [31:0] o_vib_depth, o_vib_rate, o_glide_ms;
    wire [3:0]  o_auto_expr;
    wire [55:0] o_tune;
    wire [11:0] o_tone_warm, o_tone_bright;
    wire        o_tone_enable;
    wire [1:0]  o_ev_kind;
    wire [2:0]  o_ev_lane;
    wire [6:0]  o_ev_note, o_ev_vel;
    wire [7:0]  o_score_state;
    wire signed [15:0] o_pcm;

    tang_link_top #(.CLK_HZ(50000000), .DIV_DEFAULT(217), .SCORE_WORD_DEPTH(4096)) dut (
        .clk(clk), .reset(reset),
        .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
        .o_volume(o_volume), .o_wet(o_wet), .o_damping(o_damping), .o_tail(o_tail),
        .o_fx_bypass(o_fx_bypass), .o_sens_pluck(o_sens), .o_bow_deadband(o_bow_deadband),
        .o_vib_depth(o_vib_depth), .o_vib_rate(o_vib_rate), .o_glide_ms(o_glide_ms),
        .o_auto_expr(o_auto_expr), .o_lane_enable(o_lane_en), .o_mute(o_mute), .o_tune(o_tune),
        .o_tone_warm(o_tone_warm), .o_tone_bright(o_tone_bright), .o_tone_enable(o_tone_enable),
        .i_tone_clip(16'd0),
        .o_ev_valid(o_ev_valid), .o_ev_kind(o_ev_kind), .o_ev_lane(o_ev_lane),
        .o_ev_note(o_ev_note), .o_ev_vel(o_ev_vel), .o_score_state(o_score_state),
        .i_pcm_valid(1'b0), .i_pcm(16'sd0),
        .i_rec_byte_valid(1'b0), .i_rec_byte_data(8'd0), .o_rec_ctrl(o_rec_ctrl),
        .o_pcm_valid(o_pcm_valid), .o_pcm(o_pcm),
        .o_stat_err(o_stat_err), .o_stat_ok(o_stat_ok), .o_stat_bad(o_stat_bad),
        .o_rec_drop(o_rec_drop)
    );

    localparam integer CLKS = 217;

    task uart_send(input [7:0] b);
        integer i;
        begin
            uart_rx_i = 1'b0;
            repeat (CLKS) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_i = b[i];
                repeat (CLKS) @(posedge clk);
            end
            uart_rx_i = 1'b1;
            repeat (CLKS) @(posedge clk);
        end
    endtask

    function [15:0] crc16f;
        input [7:0] d;
        input [15:0] c_in;
        integer k;
        reg [15:0] c;
        begin
            c = c_in ^ {d, 8'h00};
            for (k = 0; k < 8; k = k + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16f = c;
        end
    endfunction

    task send_query(input [7:0] seq);
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            uart_send(8'hA5);
            uart_send(8'h5A);
            uart_send(8'h40);        c = crc16f(8'h40, c);
            uart_send(seq);          c = crc16f(seq,   c);
            uart_send(8'h00);        c = crc16f(8'h00, c);
            uart_send(c[7:0]);
            uart_send(c[15:8]);
        end
    endtask

    reg [7:0] rx_b;
    integer rx_i = 0, rx_cnt = 0, rx_state = 0, rx_total = 0;
    integer fd = 0;

    always @(posedge clk) begin
        case (rx_state)
            0: if (!uart_tx_o) begin rx_state <= 1; rx_cnt <= 0; end
            1: begin
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == CLKS + CLKS/2 - 1) begin
                       rx_b[0] <= uart_tx_o; rx_i <= 1; rx_cnt <= 0; rx_state <= 2;
                   end
               end
            2: begin
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == CLKS - 1) begin
                       rx_cnt <= 0;
                       rx_b[rx_i] <= uart_tx_o;
                       if (rx_i == 7) rx_state <= 3;
                       else           rx_i <= rx_i + 1;
                   end
               end
            3: begin
                   rx_cnt <= rx_cnt + 1;
                   if (rx_cnt == CLKS - 1) begin
                       rx_state <= 0; rx_cnt <= 0;
                       if (fd != 0) $fdisplay(fd, "%02x", rx_b);
                       rx_total = rx_total + 1;
                   end
               end
        endcase
    end

    integer k;
    initial begin
        fd = $fopen("build/r40_status/stress_rx.txt", "w");
        $display("=== tb_uart_stress: 连续 30 帧 QUERY_STATUS ===");
        repeat (400) @(posedge clk);
        reset = 0;
        repeat (3000) @(posedge clk);

        for (k = 0; k < 30; k = k + 1) begin
            send_query(k[7:0]);
            repeat (80000) @(posedge clk);   // 1.6 ms，够 19 字节
        end

        $display("RESULT total_bytes=%0d  (expect 30*19 = 570)", rx_total);
        if (rx_total == 570) $display("PASS 30 帧全部完整");
        else                 $display("FAIL 字节数不符：%0d", rx_total);
        $fclose(fd);
        $finish;
    end
endmodule
