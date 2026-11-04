`timescale 1ns/1ps
//=============================================================================
// audio_volume.v — 音量控制（Q7.8，128 = 0 dB）
//
// 位置：必须插在 instrument_bank_core.o_audio_sample 与 pt8211_tx.i_sample 之间。
// 依据 src/tang_mega_60k_top.v:91-109 与 :140-151 的信号链。
//
// vol = 0..255，增益 = vol/128：
//   0   -> 静音
//   128 -> 原始增益（默认值，与 R7 完全一致）
//   255 -> +6 dB（会削顶，内部硬饱和，不会溢出成噪）
//
// 渐变：每 256 个样本把 vol_cur 向 vol 移动 1 LSB，避免调音量时爆音。
// 满量程 128 级台阶，256 样本 × 128 = 32768 样本 ≈ 671 ms（48.8 kHz）。
//
// 时序代价：路径上新增 1 个 18×18 DSP 乘法（DSP 已用 57/118，余量充足），
// 输出打一拍，总延迟 1 个样本周期。
//=============================================================================
module audio_volume (
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  vol,             // 目标音量
    input  wire signed [15:0] pcm_in,
    input  wire        valid_in,
    output reg  signed [15:0] pcm_out,
    output reg         valid_out
);
    reg [7:0] r_vol;
    reg [7:0] r_slew;

    wire signed [23:0] prod = pcm_in * $signed({1'b0, r_vol});
    wire signed [23:0] shifted = prod >>> 7;

    always @(posedge clk) begin
        if (reset) begin
            r_vol     <= 8'd128;
            r_slew    <= 8'd0;
            pcm_out   <= 16'sd0;
            valid_out <= 1'b0;
        end else begin
            // 音量渐变
            if (vol != r_vol) begin
                if (r_slew >= 8'd255) begin
                    r_slew <= 8'd0;
                    r_vol  <= vol > r_vol ? r_vol + 8'd1 : r_vol - 8'd1;
                end else begin
                    r_slew <= r_slew + 8'd1;
                end
            end else begin
                r_slew <= 8'd0;
            end

            valid_out <= valid_in;
            // R36：valid_in=0 时**保持**上一次的样本，不再强制清零。
            // 原来那行 `if (!valid_in) pcm_out <= 0;` 会让输出只在选通那一拍有效，
            // 与 pcm 自身"保持到下一帧"的语义不一致。任何按电平取样的下游
            // （例如 pt8211_tx 的帧装载）都会因此拿到 0 而不是上一个样本。
            // 注意：本模块已不在 DAC 通路上（音量搬进 pt8211_tx），
            // 这里修的是语义本身，避免以后复用踩同一个坑。
            if (valid_in)
                if (shifted > 24'sd32767)  pcm_out <= 16'sh7FFF;
                else if (shifted < -24'sd32768) pcm_out <= 16'sh8000;
                else                            pcm_out <= shifted[15:0];
        end
    end
endmodule
