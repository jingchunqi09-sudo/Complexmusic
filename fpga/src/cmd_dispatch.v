`timescale 1ns/1ps
//=============================================================================
// cmd_dispatch.v — 命令分发：帧 -> 寄存器写序列 / 曲谱字节流 / 应答帧
//
// 为什么没有独立"心跳发送器"：
//   状态上报走 QUERY_STATUS 应答（ESP32 每 50~100 ms 轮询一次即可），
//   这样全链路只有一个发送者（本模块 + 录音流），不存在多模块抢发送缓冲
//   的仲裁问题。12 字节 × 20 Hz = 240 B/s，对 23 KB/s 链路可忽略。
//
// 读时序（关键，BSRAM 同步读滞后一拍）：
//   IDLE 设 rd_addr=0 → PRE 空转一拍（数据落到 rd_data）→ RD 每拍取 1 字节，
//   同时把 rd_addr 预取为 i+2。SCORE_DATA 在 RD 阶段直接透写曲谱存储。
//
// 应答长度：QUERY_STATUS=12 字节，REG_READ=2 字节，其余=1 字节（状态码）。
//=============================================================================
module cmd_dispatch (
    input  wire        clk,
    input  wire        reset,
    // 帧输入
    input  wire        frame_valid,
    input  wire        frame_bad,
    input  wire [7:0]  frame_cmd,
    input  wire [7:0]  frame_seq,
    input  wire [8:0]  frame_len,
    output reg  [7:0]  rd_addr,
    input  wire [7:0]  rd_data,
    // 寄存器写口
    output reg         reg_we,
    output reg  [7:0]  reg_addr,
    output reg  [7:0]  reg_wdata,
    output wire [7:0]  reg_raddr,
    input  wire [7:0]  reg_rdata,
    // 曲谱存储 / 播放控制
    output reg         store_begin,
    output reg         store_we,
    output reg  [7:0]  store_data,
    output reg  [15:0] seek_tick,
    output reg         seek_req,
    // 发送缓冲
    output reg         tx_wr_en,
    output reg  [5:0]  tx_wr_addr,
    output reg  [7:0]  tx_wr_data,
    output reg         tx_send,
    output reg  [7:0]  tx_send_cmd,
    output reg  [7:0]  tx_send_len,
    input  wire        tx_busy,
    input  wire        tx_done,
    // 状态镜像（供 STATUS 应答与统计）
    input  wire [31:0] i_uptime_ms,
    input  wire [7:0]  i_score_state,
    input  wire [15:0] i_score_pos,
    input  wire [7:0]  i_volume,
    input  wire [7:0]  i_flags,
    // R43：lane_en_shadow / lane_en_wr / lane_en_we 三根线已删除。
    // 原因见 tang_mega_60k_top.v 的 REC_TAP 上方说明：换乐器在 RTL 层做不到
    // （instrument_bank_core 是 generate-if 展开的两套不同模块，没有运行时端口），
    // SET_TIMBRE 原本只是"读-改-写一个没人消费的 8 位寄存器"，纯死逻辑。
    output wire        busy_o,
    output reg  [7:0]  err_count,
    output reg  [7:0]  frames_ok,
    output reg  [7:0]  frames_bad
);
    `include "link_pkg.vh"

    localparam [3:0] D_IDLE = 4'd0, D_PRE = 4'd1, D_RD = 4'd2, D_APPLY = 4'd3,
                     D_ACK = 4'd4, D_STAT = 4'd5, D_TXW = 4'd6, D_TXW1 = 4'd7,
                     D_TX = 4'd8;

    reg [3:0]  r_state;
    reg [7:0]  r_cmd;
    reg [8:0]  r_len;
    reg [7:0]  r_args [0:15];
    reg [7:0]  r_i;
    reg [7:0]  r_tx_i;
    reg [3:0]  r_wr;
    reg [7:0]  r_status;
    reg        r_is_score_data;

    assign reg_raddr = r_args[0];
    assign busy_o    = (r_state != D_IDLE);

    function [3:0] n_writes;
        input [7:0] cmd;
        begin
            case (cmd)
                `CMD_SET_VOLUME:  n_writes = 4'd1;
                // R43：SET_TIMBRE 不再写任何寄存器（换乐器无实现）。
                // n_writes=0 → D_APPLY 直接进 else 分支 → 照常回 ACK，
                // 所以固件若误发这条命令不会超时，只是什么也不发生。
                `CMD_SET_TIMBRE:  n_writes = 4'd0;
                `CMD_SET_TUNING:  n_writes = 4'd1;
                `CMD_SET_SENS:    n_writes = 4'd3;
                `CMD_SET_FX:      n_writes = 4'd4;
                `CMD_SET_EXPR:    n_writes = 4'd12;
                `CMD_SET_TONE:    n_writes = 4'd5;
                `CMD_SCORE_BEGIN: n_writes = 4'd4;
                `CMD_SCORE_CTRL:  n_writes = 4'd1;
                `CMD_REC_CTRL:    n_writes = 4'd1;
                `CMD_REG_WRITE:   n_writes = 4'd1;
                default:          n_writes = 4'd0;
            endcase
        end
    endfunction

    function [7:0] waddr;
        input [7:0] cmd;
        input [3:0] n;
        begin
            case (cmd)
                `CMD_SET_VOLUME:  waddr = `REG_VOLUME;
                // R43：SET_TIMBRE 的 waddr 分支删除（n_writes=0，永不取址）
                `CMD_SET_TUNING:  waddr = `REG_TUNE_BASE + r_args[0];
                `CMD_SET_SENS:    waddr = (n == 4'd0) ? `REG_SENS_PLUCK
                                        : (`REG_BOW_DEADBAND + {7'd0, n[0]});
                `CMD_SET_FX:      waddr = `REG_FX_WET + {4'd0, n};
                `CMD_SET_EXPR:    waddr = `REG_VIB_DEPTH + {4'd0, n};
                // 音色 5 字节在寄存器表里是连续的 0x2A..0x2E（warm 2 + bright 2 + ctrl 1）
                `CMD_SET_TONE:    waddr = `REG_TONE_WARM + {4'd0, n};
                `CMD_SCORE_BEGIN: waddr = (n < 4'd2) ? (`REG_SCORE_COUNT + {4'd0, n})
                                        : (`REG_SCORE_TICK_US + {6'd0, n[1:0]} - 8'd2);
                `CMD_SCORE_CTRL:  waddr = `REG_SCORE_CTRL;
                `CMD_REC_CTRL:    waddr = `REG_REC_CTRL;
                `CMD_REG_WRITE:   waddr = r_args[0];
                default:          waddr = 8'd0;
            endcase
        end
    endfunction

    function [7:0] wdata;
        input [7:0] cmd;
        input [3:0] n;
        begin
            case (cmd)
                `CMD_SET_VOLUME:  wdata = r_args[0];
                // R43：SET_TIMBRE 的"换组"写值表达式删除。
                // 原式 ((shadow & ~(0x01<<lane)) | (0x10<<lane)) 等，需要读影子值
                // 才能算新值，因此额外占了两级 8 位 MUX + 一套独立写使能。
                // 换乐器在 RTL 层无实现（乐器核是 generate-if 两套模块），
                // 这段算出来的 8 位值没有任何消费者，一并删除。
                `CMD_SET_TUNING:  wdata = r_args[1];
                `CMD_SET_SENS:    wdata = (n == 4'd0) ? r_args[0] : r_args[1 + {7'd0, n[0]}];
                `CMD_SET_FX:      wdata = r_args[{4'd0, n}];
                `CMD_SET_EXPR:    wdata = r_args[{4'd0, n}];
                `CMD_SET_TONE:    wdata = r_args[{4'd0, n}];
                `CMD_SCORE_BEGIN: wdata = r_args[{4'd0, n}];
                `CMD_SCORE_CTRL:  wdata = r_args[0];
                `CMD_REC_CTRL:    wdata = r_args[0];
                `CMD_REG_WRITE:   wdata = r_args[1];
                default:          wdata = 8'd0;
            endcase
        end
    endfunction

    function [7:0] stat_byte;
        input [7:0] n;
        begin
            case (n)
                8'd0: stat_byte = i_uptime_ms[7:0];
                8'd1: stat_byte = i_uptime_ms[15:8];
                8'd2: stat_byte = i_uptime_ms[23:16];
                8'd3: stat_byte = i_uptime_ms[31:24];
                8'd4: stat_byte = i_score_state;
                8'd5: stat_byte = i_score_pos[7:0];
                8'd6: stat_byte = i_score_pos[15:8];
                // R43：byte 7 原来是 lane_enable，随死逻辑一起变成常量。
                // 位置不能动 —— 12 字节布局是固件解析契约（link_v2.cpp 按 p[7] 取值）。
                8'd7: stat_byte = 8'hFF;
                8'd8: stat_byte = i_volume;
                8'd9: stat_byte = frames_ok;
                8'd10: stat_byte = frames_bad;
                8'd11: stat_byte = i_flags;
                default: stat_byte = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            r_state         <= D_IDLE;
            r_cmd           <= 8'd0;
            r_len           <= 9'd0;
            r_i             <= 8'd0;
            r_tx_i          <= 8'd0;
            r_wr            <= 4'd0;
            r_status        <= `LINK_OK;
            r_is_score_data <= 1'b0;
            rd_addr         <= 8'd0;
            reg_we          <= 1'b0;
            reg_addr        <= 8'd0;
            reg_wdata       <= 8'd0;
            store_begin     <= 1'b0;
            store_we        <= 1'b0;
            store_data      <= 8'd0;
            seek_tick       <= 16'd0;
            seek_req        <= 1'b0;
            tx_wr_en        <= 1'b0;
            tx_wr_addr      <= 6'd0;
            tx_wr_data      <= 8'd0;
            tx_send         <= 1'b0;
            tx_send_cmd     <= 8'd0;
            tx_send_len     <= 8'd0;
            err_count       <= 8'd0;
            frames_ok       <= 8'd0;
            frames_bad      <= 8'd0;
        end else begin
            reg_we      <= 1'b0;
            store_we    <= 1'b0;
            tx_wr_en    <= 1'b0;
            tx_send     <= 1'b0;
            store_begin <= 1'b0;
            seek_req    <= 1'b0;

            if (frame_bad) begin
                frames_bad <= frames_bad + 8'd1;
                err_count  <= err_count + 8'd1;
            end

            case (r_state)
                D_IDLE: begin
                    if (frame_valid) begin
                        r_cmd           <= frame_cmd;
                        r_len           <= frame_len;
                        r_i             <= 8'd0;
                        r_tx_i          <= 8'd0;
                        r_wr            <= 4'd0;
                        r_status        <= `LINK_OK;
                        r_is_score_data <= (frame_cmd == `CMD_SCORE_DATA);
                        frames_ok       <= frames_ok + 8'd1;
                        rd_addr         <= 8'd0;
                        r_state         <= D_PRE;
                    end
                end

                D_PRE: begin
                    r_i     <= 8'd0;
                    rd_addr <= 8'd1;
                    r_state <= (r_len == 9'd0) ? D_APPLY : D_RD;
                end

                D_RD: begin
                    if (r_i < 8'd16) r_args[r_i[3:0]] <= rd_data;
                    if (r_is_score_data) begin
                        store_we   <= 1'b1;
                        store_data <= rd_data;
                    end
                    if ({1'b0, r_i} + 9'd1 >= r_len) begin
                        r_state <= D_APPLY;
                    end else begin
                        r_i     <= r_i + 8'd1;
                        rd_addr <= r_i + 8'd2;
                    end
                end

                D_APPLY: begin
                    if (r_wr < n_writes(r_cmd)) begin
                        reg_we    <= 1'b1;
                        reg_addr  <= waddr(r_cmd, r_wr);
                        reg_wdata <= wdata(r_cmd, r_wr);
                        r_wr <= r_wr + 4'd1;
                    end else begin
                        if (r_cmd == `CMD_SCORE_BEGIN) store_begin <= 1'b1;
                        if (r_cmd == `CMD_SCORE_SEEK) begin
                            seek_tick <= {r_args[1], r_args[0]};
                            seek_req  <= 1'b1;
                        end
                        r_state <= D_ACK;
                    end
                end

                D_ACK: begin
                    if (!tx_busy) begin
                        tx_wr_en   <= 1'b1;
                        tx_wr_addr <= 6'd0;
                        if (r_cmd == `CMD_QUERY_STATUS) begin
                            tx_wr_data <= stat_byte(8'd0);
                            r_tx_i     <= 8'd1;
                            r_state    <= D_STAT;
                        end else if (r_cmd == `CMD_REG_READ) begin
                            tx_wr_data <= r_args[0];      // 回显寄存器地址
                            r_tx_i     <= 8'd1;
                            r_state    <= D_TXW;
                        end else begin
                            tx_wr_data <= r_status;
                            r_state    <= D_TXW1;
                        end
                    end
                end

                D_STAT: begin
                    tx_wr_en   <= 1'b1;
                    tx_wr_addr <= r_tx_i[5:0];
                    tx_wr_data <= stat_byte(r_tx_i);
                    if (r_tx_i >= 8'd11) r_state <= D_TXW1;
                    else                 r_tx_i  <= r_tx_i + 8'd1;
                end

                D_TXW: begin
                    tx_wr_en   <= 1'b1;
                    tx_wr_addr <= 6'd1;
                    tx_wr_data <= reg_rdata;
                    r_state    <= D_TXW1;
                end

                D_TXW1: begin
                    tx_send     <= 1'b1;
                    tx_send_cmd <= (r_cmd == `CMD_QUERY_STATUS) ? `CMD_STATUS :
                                   (r_cmd == `CMD_REG_READ)     ? `CMD_REG_VALUE : `CMD_ACK;
                    tx_send_len <= (r_cmd == `CMD_QUERY_STATUS) ? 8'd12 :
                                   (r_cmd == `CMD_REG_READ)     ? 8'd2  : 8'd1;
                    r_state     <= D_TX;
                end

                D_TX: begin
                    if (tx_done || !tx_busy) r_state <= D_IDLE;
                end

                default: r_state <= D_IDLE;
            endcase
        end
    end
endmodule
