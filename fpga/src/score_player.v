`timescale 1ns/1ps
//=============================================================================
// score_player.v — 曲谱自主播放器（按字节对齐的 6 字节事件）
//
// 为什么由 FPGA 播放而不是 ESP32 逐音下发：
//   ESP32 走 WiFi，单包投递抖动可达数十毫秒，曲谱时间精度直接取决于抖动。
//   本模块用 50 MHz 计数器把 tick 量化到 20 ns 以内（默认 tick = 1 ms），
//   完全不受链路抖动影响。ESP32 只负责存谱与起停。
//
// 事件在存储中必须按 tick 升序排列，因此顺序推进即可，无需排序或搜索。
//
// 事件格式（6 字节，按字节对齐，ESP32 侧可直接结构体 memcpy）：
//   b0 = kind  0 PLUCK / 1 BOW / 2 STOP / 3 END
//   b1 = lane  0..7
//   b2 = note  0..127
//   b3 = vel   0..127
//   b4..b5 = tick  LE16（单位 = tick_us）
// 存储成 3 个 16 bit 字：w0={b1,b0}  w1={b3,b2}  w2={b5,b4}
//
// !!! 取数时序：score_store 是同步读，地址寄存器 1 拍 + 数据寄存器 1 拍，
//     因此"设地址"到"数据可用"隔 2 拍。每个字都用 FETCH -> WAITD -> TAKE
//     三拍完成，宁可慢也不允许错位（错位会让整首曲子的 lane/note 全串）。
//     本坑在 2026-10-31 仿真中实际踩到并修正，见 06_EVIDENCE/。
//=============================================================================
module score_player #(
    parameter integer CLOCK_HZ   = 50000000,
    parameter integer WORD_DEPTH = 8192
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  ctrl,            // 0 停止 1 播放 2 暂停 3 回起点
    input  wire [15:0] seek_tick,
    input  wire        seek_req,
    input  wire [15:0] count,           // 事件总数
    input  wire [15:0] tick_us,
    input  wire [7:0]  lane_enable,
    input  wire        mute,

    output reg  [12:0] rd_addr,
    input  wire [15:0] rd_data,

    output reg         ev_valid,
    output reg  [1:0]  ev_kind,
    output reg  [2:0]  ev_lane,
    output reg  [6:0]  ev_note,
    output reg  [6:0]  ev_vel,

    output reg  [7:0]  state,           // 0 空闲 1 播放 2 暂停
    output reg  [15:0] pos_tick
);
    localparam integer CLK_PER_US = CLOCK_HZ / 1000000;

    localparam [3:0] S_IDLE   = 4'd0,
                     S_LOAD   = 4'd1,
                     S_FETCH  = 4'd2,
                     S_WAITD  = 4'd3,
                     S_TAKE   = 4'd4,
                     S_CMP    = 4'd5,
                     S_SCAN   = 4'd6,
                     S_SCAN_D = 4'd7,
                     S_SCAN_W = 4'd8;

    reg [15:0] r_tick;
    reg [5:0]  r_us;
    reg [15:0] r_tacc;
    reg [15:0] r_ptr;
    reg [1:0]  r_word;
    reg [3:0]  r_state;
    reg [15:0] w0, w1, w2;
    reg [15:0] r_target;
    reg [7:0]  r_ctrl_prev;
    // r_tick 只允许在时基块内驱动（Gowin 综合禁止同一 net 多驱动），
    // 控制逻辑通过 req/val 请求重载。
    reg        r_tick_req;
    reg [15:0] r_tick_val;

    // 字节解包（避免二次切片，Verilog-2001 合法写法）
    wire [7:0] ev_kind_b = w0[7:0];
    wire [7:0] ev_lane_b = w0[15:8];
    wire [7:0] ev_note_b = w1[7:0];
    wire [7:0] ev_vel_b  = w1[15:8];

    wire [12:0] ptr13     = r_ptr[12:0];
    wire [12:0] ptr3      = ptr13 + ptr13 + ptr13;
    wire [12:0] word_addr = ptr3 + {11'd0, r_word};
    wire        playing   = (state == 8'd1);
    wire [15:0] tick_cmp  = (tick_us == 16'd0) ? 16'd1 : tick_us;
    wire        play_rise = (ctrl == 8'd1) && (r_ctrl_prev != 8'd1);

    // ---------- tick 时基：每 tick_cmp 微秒加一 ----------
    always @(posedge clk) begin
        if (reset) begin
            r_tick <= 16'd0;
            r_us   <= 6'd0;
            r_tacc <= 16'd0;
        end else if (r_tick_req) begin
            r_tick <= r_tick_val;
            r_us   <= 6'd0;
            r_tacc <= 16'd0;
        end else if (!playing) begin
            r_us   <= 6'd0;
            r_tacc <= 16'd0;
        end else begin
            if (r_us >= CLK_PER_US - 1) begin
                r_us <= 6'd0;
                if (r_tacc + 16'd1 >= tick_cmp) begin
                    r_tacc <= 16'd0;
                    r_tick <= r_tick + 16'd1;
                end else begin
                    r_tacc <= r_tacc + 16'd1;
                end
            end else begin
                r_us <= r_us + 6'd1;
            end
        end
    end

    // ---------- 控制与播放状态机 ----------
    always @(posedge clk) begin
        if (reset) begin
            r_state     <= S_IDLE;
            r_ptr       <= 16'd0;
            r_word      <= 2'd0;
            r_target    <= 16'd0;
            r_tick_req  <= 1'b0;
            r_tick_val  <= 16'd0;
            state       <= 8'd0;
            pos_tick    <= 16'd0;
            rd_addr     <= 13'd0;
            ev_valid    <= 1'b0;
            ev_kind     <= 2'd0;
            ev_lane     <= 3'd0;
            ev_note     <= 7'd0;
            ev_vel      <= 7'd0;
            w0 <= 16'd0; w1 <= 16'd0; w2 <= 16'd0;
            r_ctrl_prev <= 8'd0;
        end else begin
            ev_valid    <= 1'b0;
            pos_tick    <= r_tick;
            r_ctrl_prev <= ctrl;
            r_tick_req  <= 1'b0;

            if (ctrl == 8'd0 || ctrl == 8'd3) begin
                r_state <= S_IDLE;
                state   <= 8'd0;
                r_ptr   <= 16'd0;
                r_word  <= 2'd0;
                if (ctrl == 8'd3) begin
                    r_tick_req <= 1'b1;
                    r_tick_val <= 16'd0;
                end
            end else if (seek_req) begin
                r_state    <= S_SCAN;
                r_target   <= seek_tick;
                r_ptr      <= 16'd0;
                r_tick_req <= 1'b1;
                r_tick_val <= seek_tick;
                state      <= 8'd1;
            end else begin
                case (r_state)
                    S_IDLE: begin
                        state <= 8'd0;
                        if (play_rise) begin
                            r_ptr      <= 16'd0;
                            r_tick_req <= 1'b1;
                            r_tick_val <= 16'd0;
                            r_state    <= S_LOAD;
                            state      <= 8'd1;
                        end
                    end

                    S_LOAD: begin
                        if (ctrl == 8'd2) begin
                            state <= 8'd2;              // 暂停
                        end else if (r_ptr >= count || count == 16'd0) begin
                            r_state <= S_IDLE;
                            state   <= 8'd0;
                        end else begin
                            state   <= 8'd1;
                            r_word  <= 2'd0;
                            r_state <= S_FETCH;
                        end
                    end

                    S_FETCH: begin
                        rd_addr <= word_addr;
                        r_state <= S_WAITD;
                    end

                    S_WAITD: r_state <= S_TAKE;

                    S_TAKE: begin
                        case (r_word)
                            2'd0: begin w0 <= rd_data; r_word <= 2'd1; r_state <= S_FETCH; end
                            2'd1: begin w1 <= rd_data; r_word <= 2'd2; r_state <= S_FETCH; end
                            default: begin w2 <= rd_data; r_state <= S_CMP; end
                        endcase
                    end

                    S_CMP: begin
                        if (w2 <= r_tick) begin
                            if (ev_kind_b == 8'd3) begin           // END
                                r_state <= S_IDLE;
                                state   <= 8'd0;
                            end else begin
                                if (!mute && lane_enable[ev_lane_b[2:0]]) begin
                                    ev_valid <= 1'b1;
                                    ev_kind  <= ev_kind_b[1:0];
                                    ev_lane  <= ev_lane_b[2:0];
                                    ev_note  <= ev_note_b[6:0];
                                    ev_vel   <= ev_vel_b[6:0];
                                end
                                r_ptr   <= r_ptr + 16'd1;
                                r_state <= S_LOAD;
                            end
                        end
                        // 未到点：原地等待，r_tick 继续走
                    end

                    S_SCAN: begin
                        if (r_ptr >= count) r_state <= S_LOAD;
                        else begin
                            rd_addr <= ptr3 + 13'd2;
                            r_state <= S_SCAN_D;
                        end
                    end

                    S_SCAN_D: r_state <= S_SCAN_W;

                    S_SCAN_W: begin
                        if (rd_data >= r_target) r_state <= S_LOAD;
                        else begin
                            r_ptr   <= r_ptr + 16'd1;
                            r_state <= S_SCAN;
                        end
                    end

                    default: r_state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
