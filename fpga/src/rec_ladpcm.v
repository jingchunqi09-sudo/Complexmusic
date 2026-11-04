`timescale 1ns/1ps
//=============================================================================
// rec_ladpcm.v — 录音前端：抽取 + 4 bit 自适应差分编码（LADPCM）
//
// 带宽现实（这是为什么必须压缩，而不是选型偏好）：
//   音频 Fs = 48.828 kHz（BCLK 1.5625 MHz / 32，依据 src/instrument_constants.vh
//   的 INST_PT8211_BCLK_HZ 与 src/tang_mega_60k_top.v:23-24 的 SAMPLE_RATE_MILLIHZ）
//   16 bit 裸 PCM = 97.7 KB/s；UART 230400 只有 23.04 KB/s，物理不可能。
//   抽取 2（24.4 kHz）+ 4 bit 编码 = 12.2 KB/s，占 53%，留出状态帧与曲谱余量。
//
// 编码规则（LADPCM，非标准 IMA，ESP32 侧必须用本文档给出的解码器）：
//   step = 1 << idx                (idx 0..15)
//   量化门限 = step 的 {8,4,2,1,1/2,1/4,1/8} 倍，取满足的最高档 mag(0..7)
//   重构值 recon = step * {0,1/8,1/4,1/2,1,2,4,8}[mag]
//   pred += sign ? -recon : +recon，再饱和到 [-32768, 32767]
//   idx += (mag>=6) ? +1 : (mag<=1) ? -1 : 0，钳位 0..15
//   code = {sign, mag[2:0]}，两个 code 拼一个字节（先到者放低半字节）
//
// 优点：全移位实现，无除法、无 DSP、无查找表 ROM；编解码严格自洽，
//       长期运行不漂移（pred 由同一 recon 更新）。
// 等效精度实测：仿真 SNR 见 06_EVIDENCE/。
//=============================================================================
module rec_ladpcm (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,
    input  wire [2:0]  decim,           // 0=1x,1=2x,2=4x,3=8x
    input  wire        pcm_valid,
    input  wire signed [15:0] pcm,
    output reg         byte_valid,
    output reg  [7:0]  byte_data
);
    reg [3:0]  r_dec;
    reg signed [15:0] r_pred;
    reg [3:0]  r_idx;
    reg        r_lo_pending;
    reg [3:0]  r_lo_nib;

    wire [3:0] dec_span = (decim == 3'd0) ? 4'd1 :
                          (decim == 3'd1) ? 4'd2 :
                          (decim == 3'd2) ? 4'd4 : 4'd8;
    wire take = enable && pcm_valid && (r_dec + 4'd1 >= dec_span);

    // ---- 差分与幅度 ----
    wire signed [16:0] d17 = {pcm[15], pcm} - {r_pred[15], r_pred};
    wire [16:0] ad = d17[16] ? (17'd0 - d17) : d17;
    wire [19:0] sbase = 20'd1 << r_idx;

    wire [22:0] ad1 = {6'd0, ad};
    wire [22:0] ad2 = ad1 << 1;
    wire [22:0] ad4 = ad1 << 2;
    wire [22:0] ad8 = ad1 << 3;
    wire [22:0] sb  = {3'd0, sbase};
    wire [22:0] sb2 = sb << 1;
    wire [22:0] sb4 = sb << 2;
    wire [22:0] sb8 = sb << 3;

    wire [2:0] mag = (ad1 >= sb8) ? 3'd7 :
                     (ad1 >= sb4) ? 3'd6 :
                     (ad1 >= sb2) ? 3'd5 :
                     (ad1 >= sb ) ? 3'd4 :
                     (ad2 >= sb ) ? 3'd3 :
                     (ad4 >= sb ) ? 3'd2 :
                     (ad8 >= sb ) ? 3'd1 : 3'd0;

    wire [22:0] recon = (mag == 3'd0) ? 23'd0  :
                        (mag == 3'd1) ? (sb >> 3) :
                        (mag == 3'd2) ? (sb >> 2) :
                        (mag == 3'd3) ? (sb >> 1) :
                        (mag == 3'd4) ? sb        :
                        (mag == 3'd5) ? sb2       :
                        (mag == 3'd6) ? sb4       : sb8;

    // ---- 预测更新（32 bit 中间量，短路径） ----
    wire signed [31:0] p_s = {{16{r_pred[15]}}, r_pred};
    wire signed [31:0] r_s = {9'd0, recon};
    wire signed [31:0] psum = d17[16] ? (p_s - r_s) : (p_s + r_s);
    wire signed [15:0] pclamp = (psum > 32'sd32767)  ? 16'sh7FFF :
                                (psum < -32'sd32768) ? 16'sh8000 : psum[15:0];

    wire [3:0] idx_next = (mag >= 3'd6) ? ((r_idx == 4'd15) ? 4'd15 : r_idx + 4'd1) :
                          (mag <= 3'd1) ? ((r_idx == 4'd0)  ? 4'd0  : r_idx - 4'd1) : r_idx;

    wire [3:0] code = {d17[16], mag};

    always @(posedge clk) begin
        if (reset || !enable) begin
            r_dec        <= 4'd0;
            r_pred       <= 16'sd0;
            r_idx        <= 4'd0;
            r_lo_pending <= 1'b0;
            r_lo_nib     <= 4'd0;
            byte_valid   <= 1'b0;
            byte_data    <= 8'd0;
        end else begin
            byte_valid <= 1'b0;
            if (pcm_valid) begin
                r_dec <= (r_dec + 4'd1 >= dec_span) ? 4'd0 : r_dec + 4'd1;
            end
            if (take) begin
                r_pred <= pclamp;
                r_idx  <= idx_next;
                if (!r_lo_pending) begin
                    r_lo_nib     <= code;
                    r_lo_pending <= 1'b1;
                end else begin
                    byte_data    <= {code, r_lo_nib};
                    byte_valid   <= 1'b1;
                    r_lo_pending <= 1'b0;
                end
            end
        end
    end
endmodule
