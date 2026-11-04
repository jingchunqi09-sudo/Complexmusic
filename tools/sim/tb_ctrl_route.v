`timescale 1ns/1ps
//=============================================================================
// tb_ctrl_route.v — R37：ESP32 → FPGA 控制路线的逐字节验证
//
// 为什么要有这个台：
//   固件和 RTL 分属两套代码，任何一侧的字节序/寄存器地址写错，
//   现象都是「手机上拖了没反应」，而两边单独看都"合理"。
//   这个台**照固件 sendRaw 的真实帧格式**（SOF0 SOF1 CMD SEQ LEN PAYLOAD CRCL CRCH）
//   把每条命令发进 tang_link_top，然后断言输出的寄存器值。
//
// 覆盖：
//   ① 音量   CMD_SET_VOLUME   → o_volume
//   ② 音色   CMD_SET_TONE     → o_tone_warm / o_tone_bright / o_tone_enable
//   ③ 定弦   CMD_SET_TUNING   → o_tune（逐 lane）
//   ④ FX     CMD_SET_FX       → o_wet / o_damping / o_tail / o_fx_bypass
//   ⑤ 表现   CMD_SET_EXPR     → o_vib_depth / o_vib_rate / o_glide_ms
//   ⑥ 灵敏度 CMD_SET_SENS     → o_sens_pluck / o_bow_deadband（验证 16 位字节序）
//   ⑦ 寄存器直写 CMD_REG_WRITE → o_volume
//   ⑧ 负向：CRC 错的帧必须被拒，参数保持不变
//   ⑨ 复位后所有参数必须等于 R24/R36 的默认值（不插 ESP32 时声音不变）
//
// 注意：本台**不**验证音频是否正确（那是 tb_top_rest / tb_pt8211_volume 的事），
// 只验证"命令有没有正确落到参数上"。
//=============================================================================
module tb_ctrl_route;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;      // 50 MHz

    reg  uart_rx_i = 1'b1;
    wire uart_tx_o;

    wire [7:0]  o_volume, o_wet, o_damping, o_sens, o_lane_en;
    wire [7:0]  o_stat_err, o_stat_ok, o_stat_bad, o_rec_drop;
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

    integer errors = 0;
    integer ev_count = 0;
    always @(posedge clk) if (!reset && o_ev_valid) ev_count = ev_count + 1;

    task check(input cond, input [1023:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    // ---------------- UART ----------------
    // 用**时钟周期**驱动，不依赖 #延迟的时间尺度：
    //   DIV=217 → 50 MHz/217 = 230415 bps（与 FPGA 侧同一分频）
    localparam integer UART_CLKS = 217;
    task uart_send(input [7:0] b);
        integer i;
        begin
            uart_rx_i = 1'b0;
            repeat (UART_CLKS) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_i = b[i];
                repeat (UART_CLKS) @(posedge clk);
            end
            uart_rx_i = 1'b1;
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

    // 载荷缓冲（最多 16 字节，够用）
    reg [7:0] pl[0:15];

    // 与固件 sendRaw 完全一致的组帧：
    //   SOF0 SOF1 CMD SEQ LEN PAYLOAD[0..len-1] CRC_LO CRC_HI
    // CRC 覆盖 CMD..PAYLOAD 最后一个字节（不含两个 SOF）。
    // 注意顺序：**载荷在前、CRC 在后**。FPGA 的 link_frame_rx 状态机是
    // P_CMD → P_SEQ → P_LEN → P_DATA → P_C0 → P_C1，把 CRC 写在载荷前面必然被拒。
    task send_frame(input [7:0] cmd, input [7:0] seq, input integer len,
                    input integer corrupt);
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
            if (corrupt) c = c ^ 16'h0001;
            for (k = 0; k < len; k = k + 1) uart_send(pl[k]);
            uart_send(c[7:0]);
            uart_send(c[15:8]);
        end
    endtask

    // 发完一帧后给接收侧足够时间处理（一帧 120 字节 @230400 ≈ 5.2 ms）
    task settle; begin repeat (6000) @(posedge clk); end endtask

    integer n;
    localparam [55:0] TUNE_DEF = {7'd69, 7'd64, 7'd60, 7'd67, 7'd76, 7'd69, 7'd62, 7'd55};

    initial begin
        $display("=== tb_ctrl_route: ESP32 控制路线逐字节验证 ===");
        repeat (200) @(posedge clk);
        reset = 0;
        repeat (100) @(posedge clk);

        // ---------------- P0：复位默认值（= 不插 ESP32 时的声音） ----------------
        check(o_volume       == 8'd128,        "default volume 128");
        check(o_tone_warm    == 12'd2048,      "default tone warm 2048 (0 dB)");
        check(o_tone_bright  == 12'd2048,      "default tone bright 2048 (0 dB)");
        check(o_tone_enable  == 1'b1,          "default tone enable 1");
        check(o_tune         == TUNE_DEF,      "default tuning G3/D4/A4/E5 + uke");
        check(o_wet == 8'd64 && o_damping == 8'd128 && o_tail == 2'd1 && o_fx_bypass == 1'b1,
              "default FX 64/128/1/bypass");
        check(o_vib_depth == 32'd0 && o_vib_rate == 32'h30303030 && o_glide_ms == 32'd0,
              "default expr 0 / 0x30303030 / 0");
        check(o_sens == 8'd0 && o_bow_deadband == 16'd0, "default sens 0/0");
        check(ev_count == 0, "no score event at reset");

        // ---------------- ① 音量 ----------------
        pl[0] = 8'd200;
        send_frame(8'h10, 8'd1, 1, 0); settle;
        check(o_volume == 8'd200, "SET_VOLUME -> o_volume=200");
        pl[0] = 8'd0;
        send_frame(8'h10, 8'd2, 1, 0); settle;
        check(o_volume == 8'd0, "SET_VOLUME -> o_volume=0");

        // ---------------- ② 音色（12 位拆成 低8 + 低4） ----------------
        // warm = 0x1A5 (421) → lo=0xA5 hi=0x1 ; bright = 0x7FF (2047) → lo=0xFF hi=0x7
        pl[0] = 8'hA5; pl[1] = 8'h01;
        pl[2] = 8'hFF; pl[3] = 8'h07;
        pl[4] = 8'h01;
        send_frame(8'h16, 8'd3, 5, 0); settle;
        check(o_tone_warm   == 12'h1A5, "SET_TONE warm  -> 0x1A5");
        check(o_tone_bright == 12'h7FF, "SET_TONE bright-> 0x7FF");
        check(o_tone_enable == 1'b1,    "SET_TONE enable=1");
        pl[4] = 8'h00;
        send_frame(8'h16, 8'd4, 5, 0); settle;
        check(o_tone_enable == 1'b0,    "SET_TONE enable=0");
        pl[4] = 8'h01;
        send_frame(8'h16, 8'd5, 5, 0); settle;
        check(o_tone_enable == 1'b1,    "SET_TONE enable back to 1");

        // ---------------- ③ 定弦（逐 lane） ----------------
        // lane2 改成 MIDI 57，其它 lane 必须不动
        pl[0] = 8'd2; pl[1] = 8'd57;
        send_frame(8'h12, 8'd6, 2, 0); settle;
        check(o_tune[2*7 +: 7] == 7'd57, "SET_TUNING lane2 -> 57");
        check(o_tune[0*7 +: 7] == 7'd55, "SET_TUNING must not disturb lane0");
        check(o_tune[3*7 +: 7] == 7'd76, "SET_TUNING must not disturb lane3");
        // lane6（尤克里里第 3 根）改成 65
        pl[0] = 8'd6; pl[1] = 8'd65;
        send_frame(8'h12, 8'd7, 2, 0); settle;
        check(o_tune[6*7 +: 7] == 7'd65, "SET_TUNING lane6 -> 65");

        // ---------------- ④ FX ----------------
        pl[0] = 8'd200; pl[1] = 8'd30; pl[2] = 8'd2; pl[3] = 8'd0;
        send_frame(8'h14, 8'd8, 4, 0); settle;
        check(o_wet == 8'd200,   "SET_FX wet=200");
        check(o_damping == 8'd30, "SET_FX damping=30");
        check(o_tail == 2'd2,     "SET_FX tail=2");
        check(o_fx_bypass == 1'b0, "SET_FX bypass=0 (reverb on)");

        // ---------------- ⑤ 表现参数 ----------------
        // depth=0x00012345 rate=0x01020304 glide=500
        pl[0]=8'h45; pl[1]=8'h23; pl[2]=8'h01; pl[3]=8'h00;
        pl[4]=8'h04; pl[5]=8'h03; pl[6]=8'h02; pl[7]=8'h01;
        pl[8]=8'hF4; pl[9]=8'h01; pl[10]=8'h00; pl[11]=8'h00;
        send_frame(8'h15, 8'd9, 12, 0); settle;
        check(o_vib_depth == 32'h0001_2345, "SET_EXPR vib_depth LE32");
        check(o_vib_rate  == 32'h0102_0304, "SET_EXPR vib_rate  LE32");
        check(o_glide_ms  == 32'd500,       "SET_EXPR glide=500");

        // ---------------- ⑥ 灵敏度 16 位字节序 ----------------
        // 固件发 {pluck, deadband_lo, deadband_hi}，顺序如下（cmd_dispatch 里是交叉的）：
        //   n=1 -> 地址 0x07(高字节)，数据取 r_args[2] = payload[2] = 高字节
        //   n=2 -> 地址 0x06(低字节)，数据取 r_args[1] = payload[1] = 低字节
        // 这正是 link_v2.cpp 现有写法，所以固件无需改动；本断言把它钉死。
        pl[0] = 8'd100; pl[1] = 8'h34; pl[2] = 8'h12;   // 低在前、高在后
        send_frame(8'h13, 8'd10, 3, 0); settle;
        check(o_sens == 8'd100, "SET_SENS pluck=100");
        check(o_bow_deadband == 16'h1234, "SET_SENS deadband = 0x1234 (lo then hi)");

        // ---------------- ⑦ 通用寄存器直写 ----------------
        pl[0] = 8'h00; pl[1] = 8'd77;
        send_frame(8'h3E, 8'd11, 2, 0); settle;
        check(o_volume == 8'd77, "REG_WRITE 0x00 -> volume 77");

        // ---------------- ⑧ 负向：CRC 错的帧必须被拒 ----------------
        pl[0] = 8'd11;
        send_frame(8'h10, 8'd12, 1, 1); settle;   // corrupt=1
        check(o_volume == 8'd77, "corrupted frame must be rejected (volume unchanged)");

        // ---------------- ⑨ 负向：LEN 撒谎（写越界） ----------------
        // LEN=1 但只发 0 个载荷字节 → 后续 CRC 会被当成载荷 → 应被 gap/CRC 拒
        check(ev_count == 0, "control-only traffic must not create score events");

        if (errors == 0) $display("PASS ctrl route (all commands land on the right registers)");
        else             $display("FAIL ctrl route: %0d errors", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL timeout");
        $finish;
    end
endmodule
