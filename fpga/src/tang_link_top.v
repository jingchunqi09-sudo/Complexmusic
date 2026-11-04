`timescale 1ns/1ps
//=============================================================================
// tang_link_top.v — FPGA <-> ESP32 链路子系统顶层
//
// 对外只暴露：2 根 UART 引脚、一组参数输出、曲谱事件输出、PCM 输入输出。
// 因此可以整体作为一个"黑盒外设"挂到 R7/R8 主工程上，不改动任何现有模块的
// 内部逻辑（除 performer_pitch_map 的定弦常量改为端口，见集成指南）。
//
// 引脚（依据 esp32_wifi_console/README.md 与 R5 约束 cst:78）：
//   ESP_TX -> R6 33R -> FPGA E14  = uart_rx_i
//   ESP_RX <- R5 33R <- FPGA E13  = uart_tx_o
//
// 资源预估：LUT ≈ 1.4 k（Logic 39% -> 41%），FF ≈ 1.1 k（26% -> 28%），
//           BSRAM 7 块（rx 256B / score 16KB / rec 1KB），DSP +1（音量）。
//           未使用 DDR3 / SD 卡，理由见 04_DOCS/FPGA集成指南.md 的内存核算。
//=============================================================================
module tang_link_top #(
    parameter integer CLK_HZ          = 50000000,
    parameter integer DIV_DEFAULT     = 217,
    parameter integer SCORE_WORD_DEPTH = 4096
)(
    input  wire        clk,
    input  wire        reset,
    // UART
    input  wire        uart_rx_i,
    output wire        uart_tx_o,
    // 参数输出（接 instrument_bank_core 的对应输入）
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
    output wire [7:0]  o_lane_enable,
    output wire        o_mute,
    output wire [55:0] o_tune,
    // 总音色（接 instrument_bank_core 的 i_tone_*）
    output wire [11:0] o_tone_warm,
    output wire [11:0] o_tone_bright,
    output wire        o_tone_enable,
    // R52：选弦控制（REG_SEL_*），默认全中性
    output wire        o_sel_manual,
    output wire        o_sel_freeze,
    output wire [2:0]  o_sel_force,
    output wire [7:0]  o_sel_thr,
    input  wire [7:0]  i_sel_stat,
    input  wire [15:0] i_tone_clip,   // 音色模块软限幅计数（只读回传）
    // 曲谱事件（可选接入 lane_arbiter）
    output wire        o_ev_valid,
    output wire [1:0]  o_ev_kind,
    output wire [2:0]  o_ev_lane,
    output wire [6:0]  o_ev_note,
    output wire [6:0]  o_ev_vel,
    output wire [7:0]  o_score_state,
    // 音频（音量控制）—— i_pcm 只喂 audio_volume，输出 o_pcm 给 DAC
    input  wire        i_pcm_valid,
    input  wire signed [15:0] i_pcm,
    output wire        o_pcm_valid,
    output wire signed [15:0] o_pcm,
    // 录音源（R39 起只收字节流，不再收 PCM）
    // 为什么又改一次：R38 把 16 根 50 MHz 持续翻转的 pcm 网络拉进本模块，
    // 实板出现 S1/S2 随机自鸣（仿真逐样本相同，所以是物理层问题）。
    // R39 把 rec_ladpcm 搬到顶层、紧挨 u_audio_core 例化，本模块只收
    // byte_valid + byte_data[7:0] 共 9 根低频线（12.2 KB/s 更新率），
    // 音频总线物理上不再进入链路区域。
    input  wire        i_rec_byte_valid,
    input  wire [7:0]  i_rec_byte_data,
    // 录音控制寄存器引出，给顶层那颗 rec_ladpcm 当 enable/decim
    output wire [7:0]  o_rec_ctrl,
    // 统计
    output wire [7:0]  o_stat_err,
    output wire [7:0]  o_stat_ok,
    output wire [7:0]  o_stat_bad,
    output wire [7:0]  o_rec_drop
);
    `include "link_pkg.vh"

    // ---------------- 提前声明的跨模块连线 ----------------
    wire [15:0] o_bow_deadband_inner;
    reg  [31:0] uptime_ms;

    // ---------------- 波特率 ----------------
    wire baud_fast;
    wire [15:0] div_normal = DIV_DEFAULT;
    wire [15:0] uart_div = baud_fast ? 16'd54 : div_normal;

    // ---------------- UART ----------------
    wire       rx_valid, rx_ferr;
    wire [7:0] rx_byte;

    uart_rx #(.DIV_INIT(DIV_DEFAULT)) u_rx (
        .clk(clk), .reset(reset), .rx(uart_rx_i), .div(uart_div),
        .byte_valid(rx_valid), .byte_data(rx_byte), .frame_error(rx_ferr)
    );

    wire       tx_ready;
    wire [7:0] tx_byte;
    wire       tx_valid;

    uart_tx #(.DIV_INIT(DIV_DEFAULT)) u_tx (
        .clk(clk), .reset(reset), .div(uart_div),
        .in_valid(tx_valid), .in_data(tx_byte), .in_ready(tx_ready),
        .tx(uart_tx_o), .busy()
    );

    // ---------------- 帧接收 ----------------
    wire        fr_valid, fr_bad;
    wire [7:0]  fr_cmd, fr_seq;
    wire [8:0]  fr_len;
    wire [7:0]  fr_rd_addr, fr_rd_data;

    link_frame_rx u_frx (
        .clk(clk), .reset(reset), .div(uart_div),
        .byte_valid(rx_valid), .byte_data(rx_byte), .frame_error(rx_ferr),
        .frame_valid(fr_valid), .frame_bad(fr_bad),
        .frame_cmd(fr_cmd), .frame_seq(fr_seq), .frame_len(fr_len),
        .rd_addr(fr_rd_addr), .rd_data(fr_rd_data)
    );

    // ---------------- 曲谱存储 ----------------
    wire        st_begin, st_we;
    wire [7:0]  st_data;
    wire [12:0] sc_rd_addr;
    wire [15:0] sc_rd_data;
    wire [15:0] seek_tick;
    wire        seek_req;

    score_store #(.WORD_DEPTH(SCORE_WORD_DEPTH),
                  .WORD_AWIDTH(13)) u_score (
        .clk(clk), .reset(reset),
        .begin_pulse(st_begin), .wr_byte(st_we), .wr_data(st_data),
        .rd_addr(sc_rd_addr), .rd_data(sc_rd_data),
        .wr_full(), .wr_word_addr()
    );

    // ---------------- 寄存器组 ----------------
    wire        d_reg_we;
    wire [7:0]  d_reg_addr, d_reg_wdata;
    wire [7:0]  d_reg_raddr, d_reg_rdata;

    // R43：原来这里有第二个写源 —— SET_TIMBRE 的"影子读-改-写"，
    // 用 d_lane_en_we 把 reg_addr/reg_wdata 覆盖成 REG_LANE_ENABLE 与算出来的组位。
    // 换乐器在 RTL 层无实现，这个写源连同两级 8 位 MUX 一并删除，
    // 寄存器组现在只有一个写口（cmd_dispatch 的 d_reg_*）。
    wire [7:0]  r_volume, r_wet, r_damp, r_sens, r_rec_ctrl;
    wire [1:0]  r_tail;
    wire        r_bypass, r_mute;
    wire [31:0] r_vdep, r_vrate, r_glide;
    wire [3:0]  r_auto;
    wire [55:0] r_tune;
    wire [15:0] r_tick_us, r_count;
    wire [7:0]  r_score_ctrl, r_link_ctrl;
    wire [11:0] r_tone_warm, r_tone_bright;
    wire        r_tone_enable;
    // R52：选弦控制内部线
    wire        r_sel_manual, r_sel_freeze;
    wire [2:0]  r_sel_force;
    wire [7:0]  r_sel_thr;
    wire [7:0]  sc_state;
    wire [15:0] sc_pos;

    link_regs u_regs (
        .clk(clk), .reset(reset),
        .we(d_reg_we), .addr(d_reg_addr), .wdata(d_reg_wdata),
        .raddr(d_reg_raddr), .rdata(d_reg_rdata),
        .i_score_state(sc_state), .i_score_pos(sc_pos),
        .i_err_count(o_stat_err),
        .i_tone_clip(i_tone_clip),
        .o_volume(r_volume), .o_wet(r_wet), .o_damping(r_damp),
        .o_tail(r_tail), .o_fx_bypass(r_bypass),
        .o_sens_pluck(r_sens), .o_bow_deadband(o_bow_deadband_inner),
        .o_vib_depth(r_vdep), .o_vib_rate(r_vrate), .o_glide_ms(r_glide),
        .o_auto_expr(r_auto), .o_mute(r_mute),
        .o_rec_ctrl(r_rec_ctrl), .o_tune(r_tune),
        .o_tick_us(r_tick_us), .o_score_count(r_count),
        .o_score_ctrl(r_score_ctrl), .o_link_ctrl(r_link_ctrl),
        .o_baud_fast(baud_fast),
        .o_tone_warm(r_tone_warm), .o_tone_bright(r_tone_bright),
        .o_tone_enable(r_tone_enable),
        .o_sel_manual(r_sel_manual), .o_sel_freeze(r_sel_freeze),
        .o_sel_force(r_sel_force), .o_sel_thr(r_sel_thr),
        .i_sel_stat(i_sel_stat)
    );

    assign o_bow_deadband = o_bow_deadband_inner;
    // ---------------- 发送缓冲（单一写口，dispatch 优先） ----------------
    wire        d_tx_wr_en, d_tx_send;
    wire [5:0]  d_tx_wr_addr;
    wire [7:0]  d_tx_wr_data, d_tx_send_cmd, d_tx_send_len;
    wire        r_tx_wr_en, r_tx_send;
    wire [5:0]  r_tx_wr_addr;
    wire [7:0]  r_tx_wr_data;
    wire        tx_busy, tx_done;

    wire        tx_wr_en   = d_tx_wr_en | r_tx_wr_en;
    wire [5:0]  tx_wr_addr = d_tx_wr_en ? d_tx_wr_addr : r_tx_wr_addr;
    wire [7:0]  tx_wr_data = d_tx_wr_en ? d_tx_wr_data : r_tx_wr_data;
    wire        tx_send    = d_tx_send | r_tx_send;
    wire [7:0]  tx_send_cmd = d_tx_send ? d_tx_send_cmd : `CMD_REC_AUDIO;
    wire [7:0]  tx_send_len = d_tx_send ? d_tx_send_len : 8'd56;

    link_frame_tx u_ftx (
        .clk(clk), .reset(reset), .div(uart_div),
        .wr_en(tx_wr_en), .wr_addr(tx_wr_addr), .wr_data(tx_wr_data),
        .send(tx_send), .send_cmd(tx_send_cmd), .send_len(tx_send_len),
        .tx_valid(tx_valid), .tx_data(tx_byte), .tx_ready(tx_ready),
        .busy(tx_busy), .done(tx_done), .seq_out()
    );

    // ---------------- 命令分发 ----------------
    wire        disp_busy;
    wire [7:0]  stat_flags = {4'd0, baud_fast, r_rec_ctrl[0], r_mute, r_bypass};

    cmd_dispatch u_disp (
        .clk(clk), .reset(reset),
        .frame_valid(fr_valid), .frame_bad(fr_bad),
        .frame_cmd(fr_cmd), .frame_seq(fr_seq), .frame_len(fr_len),
        .rd_addr(fr_rd_addr), .rd_data(fr_rd_data),
        .reg_we(d_reg_we), .reg_addr(d_reg_addr), .reg_wdata(d_reg_wdata),
        .reg_raddr(d_reg_raddr), .reg_rdata(d_reg_rdata),
        .store_begin(st_begin), .store_we(st_we), .store_data(st_data),
        .seek_tick(seek_tick), .seek_req(seek_req),
        .tx_wr_en(d_tx_wr_en), .tx_wr_addr(d_tx_wr_addr), .tx_wr_data(d_tx_wr_data),
        .tx_send(d_tx_send), .tx_send_cmd(d_tx_send_cmd), .tx_send_len(d_tx_send_len),
        .tx_busy(tx_busy), .tx_done(tx_done),
        .i_uptime_ms(uptime_ms), .i_score_state(sc_state), .i_score_pos(sc_pos),
        .i_volume(r_volume), .i_flags(stat_flags),
        .busy_o(disp_busy),
        .err_count(o_stat_err), .frames_ok(o_stat_ok), .frames_bad(o_stat_bad)
    );

    // ---------------- 运行时间（毫秒） ----------------
    reg [15:0] ms_cnt;
    localparam integer CLK_PER_MS = CLK_HZ / 1000;
    always @(posedge clk) begin
        if (reset) begin
            uptime_ms <= 32'd0;
            ms_cnt    <= 16'd0;
        end else if (ms_cnt >= CLK_PER_MS - 1) begin
            ms_cnt    <= 16'd0;
            uptime_ms <= uptime_ms + 32'd1;
        end else begin
            ms_cnt <= ms_cnt + 16'd1;
        end
    end

    // ---------------- 曲谱播放 ----------------
    wire [15:0] seek_lo = seek_tick;

    score_player #(.CLOCK_HZ(CLK_HZ), .WORD_DEPTH(SCORE_WORD_DEPTH)) u_player (
        .clk(clk), .reset(reset),
        .ctrl(r_score_ctrl), .seek_tick(seek_lo), .seek_req(seek_req),
        .count(r_count), .tick_us(r_tick_us),
        .lane_enable(8'hFF), .mute(r_mute),
        .rd_addr(sc_rd_addr), .rd_data(sc_rd_data),
        .ev_valid(o_ev_valid), .ev_kind(o_ev_kind), .ev_lane(o_ev_lane),
        .ev_note(o_ev_note), .ev_vel(o_ev_vel),
        .state(sc_state), .pos_tick(sc_pos)
    );

    // ---------------- 录音 ----------------
    // R39：rec_ladpcm 已搬到 tang_mega_60k_top 顶层（紧邻 u_audio_core），
    // 这里只拿到编码后的字节流。本模块因此**看不到任何音频总线**。
    wire        lad_valid = i_rec_byte_valid;
    wire [7:0]  lad_byte  = i_rec_byte_data;
    assign o_rec_ctrl = r_rec_ctrl;

    rec_stream u_rstream (
        .clk(clk), .reset(reset),
        .allow(!disp_busy && !tx_busy),
        .byte_valid(lad_valid), .byte_data(lad_byte),
        .drop_count(o_rec_drop),
        .tx_wr_en(r_tx_wr_en), .tx_wr_addr(r_tx_wr_addr), .tx_wr_data(r_tx_wr_data),
        .tx_send(r_tx_send), .tx_busy(tx_busy), .tx_done(tx_done)
    );

    // ---------------- 音量 ----------------
    audio_volume u_vol (
        .clk(clk), .reset(reset), .vol(r_volume),
        .pcm_in(i_pcm), .valid_in(i_pcm_valid),
        .pcm_out(o_pcm), .valid_out(o_pcm_valid)
    );

    // ---------------- 参数直出 ----------------
    assign o_volume       = r_volume;
    assign o_wet          = r_wet;
    assign o_damping      = r_damp;
    assign o_tail         = r_tail;
    assign o_fx_bypass    = r_bypass;
    assign o_sens_pluck   = r_sens;
    assign o_vib_depth    = r_vdep;
    assign o_vib_rate     = r_vrate;
    assign o_glide_ms     = r_glide;
    assign o_auto_expr    = r_auto;
    // R43：端口保留（4 个测试台连了它，且 tb_link_boot 断言它必须 0xFF），
    //      但背后已无寄存器，直接输出常量。
    assign o_lane_enable  = 8'hFF;
    assign o_mute         = r_mute;
    assign o_tune         = r_tune;
    assign o_score_state  = sc_state;
    assign o_tone_warm    = r_tone_warm;
    assign o_tone_bright  = r_tone_bright;
    assign o_tone_enable  = r_tone_enable;
    // R52：选弦控制
    assign o_sel_manual = r_sel_manual;
    assign o_sel_freeze = r_sel_freeze;
    assign o_sel_force  = r_sel_force;
    assign o_sel_thr    = r_sel_thr;

endmodule
