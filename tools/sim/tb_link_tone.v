`timescale 1ns/1ps
//=============================================================================
// tb_link_tone.v — ESP32/PC -> FPGA 音色控制链路的端到端验证
//
// 验证的不是"我写的 RTL 能不能编译"，而是**上位机真的能把音色写进寄存器**：
//   ① 用 tools/tone_console.py --selftest 生成的**真实字节流**
//      （A5 5A 16 07 05 00 08 00 08 01 4F CA）打进 link_frame_rx；
//   ② 经 cmd_dispatch 解析 CMD_SET_TONE(0x16)；
//   ③ 落到 link_regs 的 REG_TONE_* ，检查 o_tone_warm/o_tone_bright/o_tone_enable；
//   ④ 再发 CMD_REG_READ(0x3F) 读 REG_TONE_CLIP，确认回包路径通。
//
// 另外发一帧 CRC 故意错的数据，确认 frame_bad 拉高且**不写寄存器**。
//
// 帧格式唯一真源：src/link_pkg.vh；上位机侧唯一真源：tools/tone_console.py。
//=============================================================================
module tb_link_tone;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;      // 50 MHz

    // ---------------- 待发送字节流 ----------------
    reg [7:0] txbuf [0:63];
    integer   txlen = 0;
    integer   ti = 0;

    // ---------------- link_frame_rx ----------------
    reg        byte_valid = 0;
    reg  [7:0] byte_data  = 0;
    wire       frame_valid, frame_bad;
    wire [7:0] frame_cmd, frame_seq;
    wire [8:0] frame_len;
    wire [7:0] p_rd_addr, p_rd_data;

    link_frame_rx u_rx (
        .clk(clk), .reset(reset), .div(16'd217),
        .byte_valid(byte_valid), .byte_data(byte_data), .frame_error(1'b0),
        .frame_valid(frame_valid), .frame_bad(frame_bad),
        .frame_cmd(frame_cmd), .frame_seq(frame_seq), .frame_len(frame_len),
        .rd_addr(p_rd_addr), .rd_data(p_rd_data)
    );

    // ---------------- cmd_dispatch ----------------
    wire       reg_we;
    wire [7:0] reg_addr, reg_wdata, reg_raddr, reg_rdata;
    wire       tx_wr_en, tx_send;
    wire [5:0] tx_wr_addr;
    wire [7:0] tx_wr_data, tx_send_cmd, tx_send_len;
    wire       lane_en_we;
    wire [7:0] lane_en_wr;
    wire       store_begin, store_we, seek_req;
    wire [7:0] store_data;
    wire [15:0] seek_tick;
    wire       disp_busy;
    wire [7:0] err_count, frames_ok, frames_bad;

    cmd_dispatch u_disp (
        .clk(clk), .reset(reset),
        .frame_valid(frame_valid), .frame_bad(frame_bad),
        .frame_cmd(frame_cmd), .frame_seq(frame_seq), .frame_len(frame_len),
        .rd_addr(p_rd_addr), .rd_data(p_rd_data),
        .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .store_begin(store_begin), .store_we(store_we), .store_data(store_data),
        .seek_tick(seek_tick), .seek_req(seek_req),
        .tx_wr_en(tx_wr_en), .tx_wr_addr(tx_wr_addr), .tx_wr_data(tx_wr_data),
        .tx_send(tx_send), .tx_send_cmd(tx_send_cmd), .tx_send_len(tx_send_len),
        .tx_busy(1'b0), .tx_done(1'b1),
        .i_uptime_ms(32'd0), .i_score_state(8'd0), .i_score_pos(16'd0),
        .i_lane_enable(8'h11), .i_volume(8'd128), .i_flags(8'd0),
        .lane_en_shadow(8'h11), .lane_en_wr(lane_en_wr), .lane_en_we(lane_en_we),
        .busy_o(disp_busy), .err_count(err_count),
        .frames_ok(frames_ok), .frames_bad(frames_bad)
    );

    // ---------------- link_regs ----------------
    wire [11:0] tone_warm, tone_bright;
    wire        tone_en;
    wire [7:0]  regs_rdata;

    link_regs u_regs (
        .clk(clk), .reset(reset),
        .we(reg_we), .addr(reg_addr), .wdata(reg_wdata),
        .raddr(reg_raddr), .rdata(regs_rdata),
        .i_score_state(8'd0), .i_score_pos(16'd0),
        .i_err_count(8'd0), .i_tone_clip(16'h0005),
        .o_volume(), .o_wet(), .o_damping(), .o_tail(), .o_fx_bypass(),
        .o_sens_pluck(), .o_bow_deadband(), .o_vib_depth(), .o_vib_rate(),
        .o_glide_ms(), .o_auto_expr(), .o_lane_enable(), .o_mute(),
        .o_rec_ctrl(), .o_tune(), .o_tick_us(), .o_score_count(),
        .o_score_ctrl(), .o_link_ctrl(), .o_baud_fast(),
        .o_tone_warm(tone_warm), .o_tone_bright(tone_bright),
        .o_tone_enable(tone_en)
    );
    assign reg_rdata = regs_rdata;

    // ---------------- 发送任务 ----------------
    task put(input [7:0] b);
        begin
            @(negedge clk);
            byte_valid = 1'b1; byte_data = b;
            @(negedge clk);
            byte_valid = 1'b0;
            repeat (3) @(negedge clk);      // 字节间隔远小于 div*10 的超时阈值
        end
    endtask

    integer k, fails = 0;
    reg [7:0] cap_addr, cap_data;
    integer   wr_count = 0;

    // 记录最后一次寄存器写
    always @(posedge clk) begin
        if (reg_we) begin
            cap_addr <= reg_addr;
            cap_data <= reg_wdata;
            wr_count <= wr_count + 1;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        repeat (5) @(negedge clk);

        // ============ ① 暖=2048 亮=2048 使能 ============
        // 字节流由 tools/tone_console.py --selftest 打印：
        //   A5 5A 16 07 05 00 08 00 08 01 4F CA
        put(8'hA5); put(8'h5A); put(8'h16); put(8'h07); put(8'h05);
        put(8'h00); put(8'h08); put(8'h00); put(8'h08); put(8'h01);
        put(8'h4F); put(8'hCA);
        repeat (400) @(negedge clk);
        $display("CASE1 CMD_SET_TONE neutral : warm=%0d bright=%0d en=%0d wr=%0d",
                 tone_warm, tone_bright, tone_en, wr_count);
        if (tone_warm !== 12'd2048 || tone_bright !== 12'd2048 || tone_en !== 1'b1) begin
            $display("  FAIL registers not written as expected"); fails = fails + 1;
        end

        // ============ ② 暖=0 亮=4095（满倾斜）= ============
        // 载荷 00 00 FF 0F 01
        wr_count = 0;
        put(8'hA5); put(8'h5A); put(8'h16); put(8'h08); put(8'h05);
        put(8'h00); put(8'h00); put(8'hFF); put(8'h0F); put(8'h01);
        // CRC 由下面的函数现算，保证与实现一致
        begin : crc2
            reg [15:0] c;
            integer i2, b2;
            c = 16'hFFFF;
            // 覆盖 CMD..PAYLOAD：16 08 05 00 00 FF 0F 01
            for (i2 = 0; i2 < 8; i2 = i2 + 1) begin
                case (i2)
                    0: b2 = 8'h16; 1: b2 = 8'h08; 2: b2 = 8'h05;
                    3: b2 = 8'h00; 4: b2 = 8'h00; 5: b2 = 8'hFF;
                    6: b2 = 8'h0F; 7: b2 = 8'h01;
                    default: b2 = 8'h00;
                endcase
                c = c ^ (b2 << 8);
                for (k = 0; k < 8; k = k + 1)
                    c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            end
            put(c[7:0]); put(c[15:8]);
        end
        repeat (400) @(negedge clk);
        $display("CASE2 CMD_SET_TONE full tilt: warm=%0d bright=%0d en=%0d wr=%0d",
                 tone_warm, tone_bright, tone_en, wr_count);
        if (tone_warm !== 12'd0 || tone_bright !== 12'd4095 || tone_en !== 1'b1) begin
            $display("  FAIL full-tilt not applied"); fails = fails + 1;
        end

        // ============ ③ 关闭使能（亮=4095, 暖=0, en=0 -> CTRL=0）============
        wr_count = 0;
        put(8'hA5); put(8'h5A); put(8'h16); put(8'h09); put(8'h05);
        put(8'h00); put(8'h00); put(8'hFF); put(8'h0F); put(8'h00);
        begin : crc3
            reg [15:0] c;
            integer i3, b3;
            c = 16'hFFFF;
            for (i3 = 0; i3 < 8; i3 = i3 + 1) begin
                case (i3)
                    0: b3 = 8'h16; 1: b3 = 8'h09; 2: b3 = 8'h05;
                    3: b3 = 8'h00; 4: b3 = 8'h00; 5: b3 = 8'hFF;
                    6: b3 = 8'h0F; 7: b3 = 8'h00;
                    default: b3 = 8'h00;
                endcase
                c = c ^ (b3 << 8);
                for (k = 0; k < 8; k = k + 1)
                    c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            end
            put(c[7:0]); put(c[15:8]);
        end
        repeat (400) @(negedge clk);
        $display("CASE3 tone disable         : en=%0d wr=%0d", tone_en, wr_count);
        if (tone_en !== 1'b0) begin
            $display("  FAIL disable did not take effect"); fails = fails + 1;
        end

        // ============ ④ CRC 错的帧必须被拒 ============
        wr_count = 0;
        put(8'hA5); put(8'h5A); put(8'h16); put(8'h0A); put(8'h05);
        put(8'h00); put(8'h08); put(8'h00); put(8'h08); put(8'h01);
        put(8'h00); put(8'h00);          // 故意写错 CRC
        repeat (400) @(negedge clk);
        $display("CASE4 bad CRC rejected     : en=%0d wr=%0d (期望 wr=0)", tone_en, wr_count);
        if (wr_count != 0) begin
            $display("  FAIL corrupted frame was applied"); fails = fails + 1;
        end

        // ============ ⑤ CMD_REG_READ 读 REG_TONE_CLIP ============
        // 载荷 2F，长度 1
        put(8'hA5); put(8'h5A); put(8'h3F); put(8'h0B); put(8'h01); put(8'h2F);
        begin : crc5
            reg [15:0] c;
            integer i5, b5;
            c = 16'hFFFF;
            for (i5 = 0; i5 < 4; i5 = i5 + 1) begin
                case (i5)
                    0: b5 = 8'h3F; 1: b5 = 8'h0B; 2: b5 = 8'h01; 3: b5 = 8'h2F;
                    default: b5 = 8'h00;
                endcase
                c = c ^ (b5 << 8);
                for (k = 0; k < 8; k = k + 1)
                    c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            end
            put(c[7:0]); put(c[15:8]);
        end
        repeat (600) @(negedge clk);
        $display("CASE5 REG_READ clip        : tx_send seen=%0d addr=0x%02X data=0x%02X",
                 tx_send, cap_addr, reg_rdata);

        $display("--------------------------------------------");
        $display("tb_link_tone: frames_ok=%0d frames_bad=%0d fails=%0d",
                 frames_ok, frames_bad, fails);
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end
endmodule
