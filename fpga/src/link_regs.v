`timescale 1ns/1ps
//=============================================================================
// link_regs.v — 链路参数寄存器组（48 字节，地址见 link_pkg.vh）
//
// 设计原则：**上电默认值必须等于 R7 生产版的硬编码常量**，这样即使 ESP32
// 从未连线，接入本模块后声音与现在完全一致（可旁路、零回归）。
//
//   依据 src/tang_mega_60k_top.v:101-103
//     i_vibrato_depth(32'd0) i_vibrato_rate(32'h30303030) i_glide_ms(32'd0)
//     i_auto_expression(4'hf) i_fx_bypass(1'b1) i_wet(8'd64)
//     i_damping(8'd128) i_tail(2'd1)
//   依据 src/instrument_constants.vh:13  INST_DEFAULT_OPEN_NOTES
//
// 只读地址：REG_SCORE_STATE / REG_SCORE_POS / REG_LINK_STAT，写入被忽略。
//=============================================================================
module link_regs (
    input  wire        clk,
    input  wire        reset,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [7:0]  wdata,
    input  wire [7:0]  raddr,
    output reg  [7:0]  rdata,

    // 运行态（只读镜像）
    input  wire [7:0]  i_score_state,
    input  wire [15:0] i_score_pos,
    input  wire [7:0]  i_err_count,
    input  wire [15:0] i_tone_clip,

    // 音频 / 表现参数
    output wire [7:0]  o_volume,
    output wire [7:0]  o_wet,
    output wire [7:0]  o_damping,
    output wire [1:0]  o_tail,
    output wire        o_fx_bypass,
    output wire [7:0]  o_sens_pluck,
    output wire [15:0] o_bow_deadband,
    output wire [31:0] o_vib_depth,
    output wire [31:0] o_vib_rate,
    output wire [31:0] o_glide_ms,
    output wire [3:0]  o_auto_expr,
    // R43：o_lane_enable 输出已删除。换乐器在 RTL 层无实现（乐器核是
    // generate-if 展开的两套不同模块），这个 8 位字段从来没有消费者。
    // 寄存器地址 REG_LANE_ENABLE 本身仍保留在阵列里（阵列深度与地址映射不动），
    // 只是不再引出；通用 REG_WRITE 仍可写它，但读不回来，也不影响任何行为。
    output wire        o_mute,
    output wire [7:0]  o_rec_ctrl,
    output wire [55:0] o_tune,
    output wire [15:0] o_tick_us,
    output wire [15:0] o_score_count,
    output wire [7:0]  o_score_ctrl,
    output wire [7:0]  o_link_ctrl,
    output wire        o_baud_fast,
    // 总音色
    output wire [11:0] o_tone_warm,
    output wire [11:0] o_tone_bright,
    output wire        o_tone_enable,

    // R60：演奏指引直控（**纯显示侧**，只接顶层 g_lane/g_note/g_valid，
    //      不接发声链任何信号）。ESP32 用 CMD_REG_WRITE 写 0x30..0x32。
    input  wire [7:0]  i_pluck_cnt,      // 只读 0x33：起音计数快照
    input  wire [7:0]  i_pluck_mask,     // 只读 0x34：最近一次起音的弦 mask
    output wire [7:0]  o_guide_ctrl,     // bit0 直控使能  bit1 指引有效
    output wire [7:0]  o_guide_lane,
    output wire [7:0]  o_guide_note
);
    `include "link_pkg.vh"

    reg [7:0] r [0:`REG_MAX-1];
    integer i;

    // 只读地址不落寄存器
    wire wr_ok = (addr < `REG_MAX) &&
                 (addr != `REG_SCORE_STATE) &&
                 (addr != `REG_SCORE_POS) &&
                 (addr != `REG_LINK_STAT) &&
                 (addr != `REG_TONE_CLIP) &&
                 (addr != `REG_PLUCK_CNT) &&   // R60：起音计数只读
                 (addr != `REG_PLUCK_MASK);    // R60：起音 mask 只读

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < `REG_MAX; i = i + 1) r[i] <= 8'd0;
            r[`REG_VOLUME]     <= 8'd128;   // 0 dB
            r[`REG_FX_WET]     <= 8'd64;
            r[`REG_FX_DAMP]    <= 8'd128;
            r[`REG_FX_TAIL]    <= 8'd1;
            r[`REG_FX_BYPASS]  <= 8'd1;     // 与 R7 一致：默认旁路混响
            r[`REG_SENS_PLUCK] <= 8'd0;     // 0 = 不过滤，等于现状
            r[`REG_VIB_DEPTH+0]<= 8'd0;
            r[`REG_VIB_DEPTH+1]<= 8'd0;
            r[`REG_VIB_DEPTH+2]<= 8'd0;
            r[`REG_VIB_DEPTH+3]<= 8'd0;
            r[`REG_VIB_RATE+0] <= 8'h30;    // 32'h30303030 -> 0x30 ASCII '0'
            r[`REG_VIB_RATE+1] <= 8'h30;
            r[`REG_VIB_RATE+2] <= 8'h30;
            r[`REG_VIB_RATE+3] <= 8'h30;
            r[`REG_GLIDE_MS+0] <= 8'd0;
            r[`REG_GLIDE_MS+1] <= 8'd0;
            r[`REG_GLIDE_MS+2] <= 8'd0;
            r[`REG_GLIDE_MS+3] <= 8'd0;
            r[`REG_AUTO_EXPR]  <= 8'h0F;
            r[`REG_LANE_ENABLE]<= 8'hFF;
            r[`REG_MUTE]       <= 8'd0;
            r[`REG_REC_CTRL]   <= 8'd0;
            r[`REG_SCORE_TICK_US+0] <= 8'd232;  // 1000 us 默认
            r[`REG_SCORE_TICK_US+1] <= 8'd3;
            r[`REG_SCORE_COUNT+0]   <= 8'd0;
            r[`REG_SCORE_COUNT+1]   <= 8'd0;
            r[`REG_SCORE_CTRL]      <= 8'd0;
            r[`REG_LINK_CTRL]       <= 8'd0;
            // 定弦默认值 = INST_DEFAULT_OPEN_NOTES {24'h45403C43,24'h4C453E37}
            r[`REG_TUNE_BASE+0] <= 8'h37;  // lane0 violin  G3 = 55
            r[`REG_TUNE_BASE+1] <= 8'h3E;  // lane1 violin  D4 = 62
            r[`REG_TUNE_BASE+2] <= 8'h45;  // lane2 violin  A4 = 69
            r[`REG_TUNE_BASE+3] <= 8'h4C;  // lane3 violin  E5 = 76
            r[`REG_TUNE_BASE+4] <= 8'h43;  // lane4 uke G4 = 67
            r[`REG_TUNE_BASE+5] <= 8'h3C;  // lane5 uke C4 = 60
            r[`REG_TUNE_BASE+6] <= 8'h40;  // lane6 uke E4 = 64
            r[`REG_TUNE_BASE+7] <= 8'h45;  // lane7 uke A4 = 69
            // 总音色上电默认 = 中性直通（2048 = 0 dB，使能=1）。
            // 目的与其它默认值一致：ESP32 从未连线时，声音与 R19 完全相同。
            r[`REG_TONE_WARM]     <= 8'h00;
            r[`REG_TONE_WARM+1]   <= 8'h08;
            r[`REG_TONE_BRIGHT]   <= 8'h00;
            r[`REG_TONE_BRIGHT+1] <= 8'h08;
            r[`REG_TONE_CTRL]     <= 8'h01;
        end else if (we && wr_ok) begin
            r[addr] <= wdata;
        end
    end

    always @(*) begin
        case (raddr)
            `REG_SCORE_STATE: rdata = i_score_state;
            `REG_SCORE_POS:   rdata = i_score_pos[7:0];
            `REG_LINK_STAT:   rdata = i_err_count;
            `REG_TONE_CLIP:   rdata = i_tone_clip[7:0];
            `REG_PLUCK_CNT:   rdata = i_pluck_cnt;   // R60 只读
            `REG_PLUCK_MASK:  rdata = i_pluck_mask;  // R60 只读
            default:          rdata = (raddr < `REG_MAX) ? r[raddr] : 8'd0;
        endcase
    end

    assign o_volume      = r[`REG_VOLUME];
    assign o_wet         = r[`REG_FX_WET];
    assign o_damping     = r[`REG_FX_DAMP];
    assign o_tail        = r[`REG_FX_TAIL][1:0];
    assign o_fx_bypass   = r[`REG_FX_BYPASS][0];
    assign o_sens_pluck  = r[`REG_SENS_PLUCK];
    assign o_bow_deadband= {r[`REG_BOW_DEADBAND+1], r[`REG_BOW_DEADBAND]};
    assign o_vib_depth   = {r[`REG_VIB_DEPTH+3], r[`REG_VIB_DEPTH+2],
                            r[`REG_VIB_DEPTH+1], r[`REG_VIB_DEPTH+0]};
    assign o_vib_rate    = {r[`REG_VIB_RATE+3], r[`REG_VIB_RATE+2],
                            r[`REG_VIB_RATE+1], r[`REG_VIB_RATE+0]};
    assign o_glide_ms    = {r[`REG_GLIDE_MS+3], r[`REG_GLIDE_MS+2],
                            r[`REG_GLIDE_MS+1], r[`REG_GLIDE_MS+0]};
    assign o_auto_expr   = r[`REG_AUTO_EXPR][3:0];
    assign o_mute        = r[`REG_MUTE][0];
    assign o_rec_ctrl    = r[`REG_REC_CTRL];
    // 定弦总线是 8 lane × 7 bit = 56 bit，必须逐 lane 取低 7 位再拼接，
    // 否则 64 bit 拼接会被截断成 56 bit 并丢掉最高 lane。
    assign o_tune        = {r[`REG_TUNE_BASE+7][6:0], r[`REG_TUNE_BASE+6][6:0],
                            r[`REG_TUNE_BASE+5][6:0], r[`REG_TUNE_BASE+4][6:0],
                            r[`REG_TUNE_BASE+3][6:0], r[`REG_TUNE_BASE+2][6:0],
                            r[`REG_TUNE_BASE+1][6:0], r[`REG_TUNE_BASE+0][6:0]};
    assign o_tick_us     = {r[`REG_SCORE_TICK_US+1], r[`REG_SCORE_TICK_US]};
    assign o_score_count = {r[`REG_SCORE_COUNT+1], r[`REG_SCORE_COUNT]};
    assign o_score_ctrl  = r[`REG_SCORE_CTRL];
    assign o_link_ctrl   = r[`REG_LINK_CTRL];
    assign o_baud_fast   = r[`REG_LINK_CTRL][1];
    // 音色参数：12 位，2048 = 0 dB。低字节 + 高字节的低 4 位。
    assign o_tone_warm   = {r[`REG_TONE_WARM+1][3:0],   r[`REG_TONE_WARM]};
    assign o_tone_bright = {r[`REG_TONE_BRIGHT+1][3:0], r[`REG_TONE_BRIGHT]};
    assign o_tone_enable = r[`REG_TONE_CTRL][0];
    // R60：指引直控。默认全 0 = 直控关闭，曲谱模式与 R54 完全一致。
    assign o_guide_ctrl  = r[`REG_GUIDE_CTRL];
    assign o_guide_lane  = r[`REG_GUIDE_LANE];
    assign o_guide_note  = r[`REG_GUIDE_NOTE];
endmodule
