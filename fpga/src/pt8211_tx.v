// PT8211 专用三线发送：16位右对齐、MSB先发，不带标准I2S延迟位。
// WS=1 左声道，WS=0 右声道；每帧32个BCK，两侧复制同一单声道样本。
// DIN/WS在BCK下降沿准备，PT8211在上升沿采样；内部仅使用i_clk。
`include "instrument_constants.vh"

module pt8211_tx #(
parameter integer CLOCK_HZ = `INST_CLOCK_HZ,
parameter integer BCLK_HZ  = `INST_PT8211_BCLK_HZ,
parameter integer USE_VALID_MAILBOX = 0
) (
input                i_clk,                  // 系统时钟，默认50 MHz。
input                i_reset,                // 同步、高有效复位，清零音频。
input signed [15:0]  i_sample,               // 二补码PCM；只在新帧装载，帧内保持。
input i_sample_valid,
// R36：音量（0..255，128 = 0 dB）。
// 为什么音量放在发送模块内部而不是外面另建一级：
//   放到模块外会把 16 根 pcm 网络从音频核绕出去再折回来，同时在
//   i_sample_valid 上多插一拍寄存器。而本模块的 mailbox 装载是**边沿敏感**的
//   （r_requested/r_pending 握手），valid 比样本晚一拍就会系统性错位：
//   要么漏样本（underrun）、要么同一帧被重复装载（overrun），
//   听感是持续的粗糙噪声 —— 这正是 R34「只加了音量却出声」的真实原因。
//   放在这里，valid 与样本仍然同拍，走线也与 R33 完全一致。
input wire [7:0] i_volume,
input i_sample_event,
input i_sample_ready,
input [31:0] i_sample_first_sequence, input [15:0] i_sample_event_count,
output reg [31:0] o_frame_first_sequence, output reg [15:0] o_frame_event_count,
input [31:0] i_sample_sequence,
input [63:0] i_sample_event_clock,
output reg o_event_frame_complete,
output reg [31:0] o_frame_event_sequence,
output reg [63:0] o_frame_event_clock,
output reg [31:0] o_underrun_count,
output reg [31:0] o_overrun_count,
output reg [31:0] o_frame_sequence,
output reg           o_hp_bck,
output reg           o_hp_ws,
output reg           o_hp_din,
output reg           o_sample_tick,          // 当前帧起始请求下一帧计算，留完整帧预算。
output reg           o_first_sample,         // 左字MSB采样标记；不代表模拟起音。
output reg           o_left_word_complete,   // 左字LSB已送达。
output reg signed [15:0] o_frame_pcm,         // 本帧原子PCM，供只读观察。
output reg           o_frame_pcm_valid,
output reg           o_frame_word_complete   // 右字LSB已送达，两侧完整。
);
localparam integer REQUESTED_HALF_BCLK_DIV =
(BCLK_HZ > 0) ? CLOCK_HZ / (BCLK_HZ * 2) : 0;
localparam integer HALF_BCLK_DIV =
(REQUESTED_HALF_BCLK_DIV < 1) ? 1 : REQUESTED_HALF_BCLK_DIV;
function integer counter_width;
    input integer maximum_count;
    integer remaining;
    begin
        counter_width = 1;
        remaining = maximum_count - 1;
        while (remaining > 1)
        begin
            counter_width = counter_width + 1;
            remaining = remaining >> 1;
        end
    end
endfunction
localparam integer CLOCK_DIVIDER_WIDTH = counter_width(HALF_BCLK_DIV);
reg [CLOCK_DIVIDER_WIDTH-1:0] r_clock_divider; // 半BCK周期计数，单位系统clk。
reg [4:0] r_next_frame_bit; // 下一次下降沿准备的帧位号：0..31。
reg [15:0] r_frame_sample;  // 原子锁存的本帧PCM，供右字重复发送。
reg [15:0] r_serial_shift;  // 当前字剩余位，按MSB顺序移出。

reg signed [15:0] r_pcm_hold;
reg r_pending, r_requested, r_started, r_event_hold, r_frame_event;
reg [31:0] r_sequence_hold, r_first_hold;
reg [63:0] r_clock_hold;
reg [15:0] r_count_hold;
wire signed [15:0] w_load_sample;
assign w_load_sample = USE_VALID_MAILBOX != 0 ?
(r_pending && i_sample_ready ? r_pcm_hold : 16'sd0) : i_sample;

// ---- R36：音量 ----
// vol = 128（上电默认）时**逐位直通**，所以默认构建的 DAC 输出与 R33 完全相同。
// 其余值按 vol/128 缩放，内部饱和，不会溢出成噪。
wire signed [23:0] w_vol_prod = $signed(w_load_sample) * $signed({1'b0, i_volume});
wire signed [23:0] w_vol_sh   = w_vol_prod >>> 7;
wire signed [15:0] w_vol_sat  = (w_vol_sh > 24'sd32767)  ? 16'sh7FFF :
                                (w_vol_sh < -24'sd32768) ? 16'sh8000 :
                                w_vol_sh[15:0];
wire signed [15:0] w_out_sample = (i_volume == 8'd128) ? w_load_sample : w_vol_sat;

always @(posedge i_clk)
begin
    if (i_reset)
    begin
        r_pcm_hold<=0; r_pending<=0; r_requested<=0; r_started<=0;
        r_event_hold<=0; r_frame_event<=0; r_sequence_hold<=0; r_clock_hold<=0; r_first_hold<=0; r_count_hold<=0;
        o_event_frame_complete<=0; o_frame_event_sequence<=0; o_frame_event_clock<=0;
        o_frame_first_sequence<=0; o_frame_event_count<=0;
        o_underrun_count<=0; o_overrun_count<=0; o_frame_sequence<=0;
        r_clock_divider <= 0;
        r_next_frame_bit <= 0;
        r_frame_sample <= 0;
        o_frame_pcm <= 0;
        o_frame_pcm_valid <= 0;
        r_serial_shift <= 0;
        o_hp_bck <= 1'b1;
        o_hp_ws <= 0;
        o_hp_din <= 0;
        o_sample_tick <= 0;
        o_first_sample <= 0;
        o_left_word_complete <= 0;
        o_frame_word_complete <= 0;
    end
    else
    begin
        o_event_frame_complete<=0;
        if(USE_VALID_MAILBOX != 0 && i_sample_valid)
        begin
            if(r_requested && !r_pending)
            begin
                r_pcm_hold<=i_sample; r_event_hold<=i_sample_event;
                r_sequence_hold<=i_sample_sequence; r_clock_hold<=i_sample_event_clock;
                r_first_hold<=i_sample_first_sequence; r_count_hold<=i_sample_event_count;
                r_pending<=1; r_requested<=0;
            end
            else o_overrun_count<=o_overrun_count+1'b1;
        end
        o_sample_tick <= 1'b0;
        o_frame_pcm_valid <= 0;
        o_first_sample <= 1'b0;
        o_left_word_complete <= 1'b0;
        o_frame_word_complete <= 1'b0;
        if (r_clock_divider >= HALF_BCLK_DIV - 1)
        begin
            r_clock_divider <= 0;
            o_hp_bck <= ~o_hp_bck;
            if (o_hp_bck)
            begin
                // 装载与移位分支互斥；锁存整帧样本，防止左右字撕裂。
                if (r_next_frame_bit == 5'd0)
                begin
                    r_frame_sample <= w_out_sample;
                    o_frame_pcm <= w_out_sample;
                    o_frame_pcm_valid <= 1;
                    r_serial_shift <= {w_out_sample[14:0], 1'b0};
                    o_hp_din <= w_out_sample[15];
                    o_frame_sequence<=o_frame_sequence+1'b1;
                    if(USE_VALID_MAILBOX != 0)
                    begin
                        r_pending<=0; r_requested<=i_sample_ready;
                        r_frame_event<=r_pending && i_sample_ready && r_event_hold;
                        o_frame_event_sequence<=r_pending ? r_sequence_hold : 0;
                        o_frame_event_clock<=r_pending ? r_clock_hold : 0;
                        o_frame_first_sequence<=r_pending ? r_first_hold : 0;
                        o_frame_event_count<=r_pending ? r_count_hold : 0;
                        if(r_pending && i_sample_ready) r_started<=1;
                        else if(r_started && i_sample_ready) o_underrun_count<=o_underrun_count+1'b1;
                    end
                    o_hp_ws <= 1'b1;
                end
                else if (r_next_frame_bit == 5'd16)
                begin
                    r_serial_shift <= {r_frame_sample[14:0], 1'b0};
                    o_hp_din <= r_frame_sample[15];
                    o_hp_ws <= 1'b0;
                end
                else
                begin
                    o_hp_din <= r_serial_shift[15];
                    r_serial_shift <= {r_serial_shift[14:0], 1'b0};
                end
                if (r_next_frame_bit == 5'd0)
                o_sample_tick <= 1'b1;
                r_next_frame_bit <= r_next_frame_bit + 1'b1;
            end
            else
            begin
                if (r_next_frame_bit == 5'd1)
                o_first_sample <= 1'b1;
                if (r_next_frame_bit == 5'd16)
                o_left_word_complete <= 1'b1;
                if (r_next_frame_bit == 5'd0)
                begin
                    o_frame_word_complete <= 1'b1;
                    o_event_frame_complete <= r_frame_event;
                end
            end
        end
        else
        begin
            r_clock_divider <= r_clock_divider + 1'b1;
        end
    end
end
endmodule
