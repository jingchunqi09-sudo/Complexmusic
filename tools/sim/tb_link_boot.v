`timescale 1ns/1ps
//=============================================================================
// tb_link_boot.v — 上电静音验证（R26）
//
// 目的：证明"不接 ESP32 / 接上但只说合法帧"时，链路子系统**不会**产出任何
// 会让 8 个波导声部发声的东西。这是 R25 上板"上电就乱响"之后加的守门测试。
//
// 三个阶段：
//   P1 复位释放后 5 ms，UART 线保持空闲高电平：
//      所有参数必须等于 R24 的硬编码常量；o_ev_valid 必须一次都不脉冲。
//   P2 往 UART 灌 20000 字节随机垃圾（模拟悬空引脚噪声 / 波特率不匹配的旧固件）：
//      o_ev_valid 仍必须一次都不脉冲，参数一个都不许变。
//   P3 灌一帧**合法** PING（A5 5A 01 00 00 <CRC>）：
//      必须回 ACK（证明链路是通的，排除"测试台根本没接对"）。
//
// 音频直通：P1 里同时喂 48.8 kSPS 的已知斜坡，检查 o_pcm 在 vol=128 时
// 逐样本等于输入（只允许晚 1 拍）。这条用来抓 audio_volume 的增益错。
//=============================================================================
module tb_link_boot;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;      // 50 MHz

    reg  uart_rx_i = 1'b1;
    wire uart_tx_o;

    wire [7:0]  o_volume, o_wet, o_damping, o_sens, o_lane_en, o_stat_err, o_stat_ok, o_stat_bad, o_rec_drop;
    wire [7:0]  o_rec_ctrl;
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

    reg         i_pcm_valid = 1'b0;
    reg  signed [15:0] i_pcm = 16'sd0;

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
        .i_pcm_valid(i_pcm_valid), .i_pcm(i_pcm),
        // R31：录音源与音量源已拆成两组端口（见 tang_link_top 端口注释）。
        // 本台只验证"音量直通 + 上电静音"，录音不接。
        .i_rec_byte_valid(1'b0), .i_rec_byte_data(8'd0), .o_rec_ctrl(o_rec_ctrl),
        .o_pcm_valid(o_pcm_valid), .o_pcm(o_pcm),
        .o_stat_err(o_stat_err), .o_stat_ok(o_stat_ok), .o_stat_bad(o_stat_bad),
        .o_rec_drop(o_rec_drop)
    );

    integer errors = 0;
    integer ev_count = 0;
    integer pcm_checks = 0;

    task check(input cond, input [1023:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    // 事件计数器：任何一拍 ev_valid 都要记
    always @(posedge clk) if (!reset && o_ev_valid) begin
        ev_count = ev_count + 1;
        $display("FAIL spurious score event kind=%0d lane=%0d note=%0d vel=%0d t=%0t",
                 o_ev_kind, o_ev_lane, o_ev_note, o_ev_vel, $time);
    end

    // 音符参数期望值（与 link_regs 复位值 / R24 常量一致）
    localparam [55:0] TUNE_DEF = {7'd69, 7'd64, 7'd60, 7'd67, 7'd76, 7'd69, 7'd62, 7'd55};

    // ---------------- 音频直通检查 ----------------
    // 在 posedge 采输入，下一拍比较输出（audio_volume 打一拍）
    reg signed [15:0] exp_pcm;
    reg               exp_vld;
    always @(posedge clk) begin
        exp_pcm <= i_pcm;
        exp_vld <= i_pcm_valid;
        if (!reset && exp_vld) begin
            pcm_checks = pcm_checks + 1;
            // vol=128（复位默认）时增益恰为 1，输出必须逐样本等于输入。
            // 注意不能写 (exp_pcm*128)>>>7：16 位乘 128 会先溢出截断。
            if (o_pcm !== exp_pcm) begin
                if (pcm_checks < 6)
                    $display("FAIL pcm passthrough: in=%0d out=%0d t=%0t", exp_pcm, o_pcm, $time);
                errors = errors + 1;
            end
        end
    end

    // ---------------- UART 发送任务（230400，DIV=217）----------------
    localparam integer BIT_NS = 4340;   // 1/230400 = 4.34 us
    task uart_send(input [7:0] b);
        integer i;
        begin
            uart_rx_i = 1'b0;
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_i = b[i];
                #(BIT_NS);
            end
            uart_rx_i = 1'b1;
            #(BIT_NS);
        end
    endtask

    // CRC16-CCITT-FALSE（与 link_crc.v 同多项式）
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

    task send_frame(input [7:0] cmd, input [7:0] seq, input [7:0] len);
        integer k;
        reg [15:0] c;
        begin
            // CRC 覆盖范围是 CMD..payload（idx 2 .. 4+LEN），**不含** SOF 两个字节
            c = 16'hFFFF;
            uart_send(8'hA5);
            uart_send(8'h5A);
            uart_send(cmd);   c = crc16(cmd,   c);
            uart_send(seq);   c = crc16(seq,   c);
            uart_send(len);   c = crc16(len,   c);
            uart_send(c[7:0]);
            uart_send(c[15:8]);
            for (k = 0; k < len; k = k + 1) uart_send(8'h00);  // 本测试只发空载荷帧
        end
    endtask

    integer n;
    reg [31:0] lfsr;

    initial begin
        $display("=== tb_link_boot: R26 上电静音验证 ===");
        repeat (200) @(posedge clk);
        reset = 0;
        repeat (50) @(posedge clk);

        // ---------------- P1：参数默认值 ----------------
        check(o_volume        == 8'd128, "o_volume must be 128 (0 dB)");
        check(o_wet           == 8'd64,  "o_wet must be 64");
        check(o_damping       == 8'd128, "o_damping must be 128");
        check(o_tail          == 2'd1,   "o_tail must be 1");
        check(o_fx_bypass     == 1'b1,   "o_fx_bypass must be 1 (reverb off)");
        check(o_sens          == 8'd0,   "o_sens must be 0");
        check(o_bow_deadband  == 16'd0,  "o_bow_deadband must be 0");
        check(o_vib_depth     == 32'd0,  "o_vib_depth must be 0");
        check(o_vib_rate      == 32'h30303030, "o_vib_rate must be 0x30303030");
        check(o_glide_ms      == 32'd0,  "o_glide_ms must be 0");
        check(o_auto_expr     == 4'hf,   "o_auto_expr must be 0xF");
        check(o_lane_en       == 8'hff,  "o_lane_enable must be 0xFF");
        check(o_mute          == 1'b0,   "o_mute must be 0");
        check(o_tune          == TUNE_DEF, "o_tune must equal default tuning");
        check(o_score_state   == 8'd0,   "o_score_state must be idle");
        check(ev_count        == 0,      "no score event before any frame");

        // P1 音频直通：喂 200 个样本
        for (n = 0; n < 40; n = n + 1) begin
            @(posedge clk);
            i_pcm_valid <= 1'b1;
            i_pcm       <= (n % 2) ? 16'sd12000 : -16'sd12000;
            @(posedge clk);
            i_pcm_valid <= 1'b0;
            repeat (900) @(posedge clk);      // ~48.8 kSPS
        end
        check(pcm_checks > 30, "P1 pcm passthrough had enough samples");
        $display("P1 done: pcm_checks=%0d errors=%0d", pcm_checks, errors);

        // ---------------- P2：随机垃圾字节 ----------------
        lfsr = 32'h1234_5678;
        for (n = 0; n < 200; n = n + 1) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            uart_send(lfsr[7:0]);
        end
        repeat (200) @(posedge clk);
        check(ev_count == 0, "garbage bytes must not create score events");
        check(o_volume == 8'd128 && o_fx_bypass == 1'b1 && o_lane_en == 8'hff &&
              o_tune == TUNE_DEF, "garbage bytes must not change parameters");
        check(o_stat_ok == 8'd0, "garbage must not produce a valid frame");
        $display("P2 done: bad=%0d ok=%0d errors=%0d", o_stat_bad, o_stat_ok, errors);

        // ---------------- P3：合法 PING ----------------
        send_frame(8'h01, 8'h01, 8'd0);
        repeat (4000) @(posedge clk);
        check(o_stat_ok != 8'd0, "a well-formed PING must be accepted (link alive)");
        check(ev_count == 0, "PING must not create score events");
        $display("P3 done: ok=%0d bad=%0d errors=%0d", o_stat_ok, o_stat_bad, errors);

        if (errors == 0) $display("PASS link boot silence: %0d checks", pcm_checks);
        else             $display("FAIL link boot silence: errors=%0d", errors);
        $finish;
    end

    initial begin
        #200_000_000;   // 200 ms 上限
        $display("FAIL timeout");
        $finish;
    end
endmodule
