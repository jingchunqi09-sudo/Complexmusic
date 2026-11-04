`timescale 1ns/1ps
//=============================================================================
// rec_tap_u8.v — 极简录音抽头（R40）
//
// 为什么不用 rec_ladpcm 了：
//   R38（pcm 经寄存器进链路）S1/S2 自鸣；R39（录音从 DAC 末端取、pcm 扇出回到 1）
//   变成 S2/S3 自鸣。两次都不是逻辑错——仿真逐样本相同。
//   真正的约束是：本设计 CLS 已 84%，布局余量为零（R30 只换 place 策略就出过
//   "第二弦异常"）。rec_ladpcm 要 250+ LUT，挂在 pt8211_tx 的输出寄存器上，
//   等于在音频核旁边硬塞一块组合逻辑，把布局挤走。
//
//   所以这一版把录音抽头的逻辑量砍到约 1/20：
//     不做自适应差分，只做「抽取 + 8 位截断」，全部是计数器和一根 8 位寄存器。
//   代价：录音从 24.4 kSPS/4 bit 变成 12.2 kSPS/8 bit（带宽低一半），
//   换来的是音频核边上几乎不新增东西。
//
// 编码：偏移二进制（0x80 = 静音），取 pcm[15:8] 再翻符号位。
//       ESP32 侧解码：sample = (int8_t)b << 8，即 byte 直接当有符号高字节用。
//=============================================================================
module rec_tap_u8 (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,
    input  wire [2:0]  decim,           // 0=1x,1=2x,2=4x,3=8x
    input  wire        pcm_valid,
    input  wire signed [15:0] pcm,
    output reg         byte_valid,
    output reg  [7:0]  byte_data
);
    reg [2:0] r_dec;

    wire [3:0] dec_span = (decim == 3'd0) ? 4'd1 :
                          (decim == 3'd1) ? 4'd2 :
                          (decim == 3'd2) ? 4'd4 : 4'd8;
    wire take = enable && pcm_valid && (r_dec + 3'd1 >= dec_span);

    always @(posedge clk) begin
        if (reset || !enable) begin
            r_dec      <= 3'd0;
            byte_valid <= 1'b0;
            byte_data  <= 8'h80;
        end else begin
            byte_valid <= 1'b0;
            if (pcm_valid) begin
                r_dec <= (r_dec + 3'd1 >= dec_span) ? 3'd0 : r_dec + 3'd1;
            end
            if (take) begin
                // pcm[15] 是符号位；翻成偏移二进制后 0x80 = 0
                byte_data  <= {~pcm[15], pcm[14:8]};
                byte_valid <= 1'b1;
            end
        end
    end
endmodule
