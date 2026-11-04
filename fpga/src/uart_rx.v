`timescale 1ns/1ps
//=============================================================================
// uart_rx.v — 8N1 接收器（起始位中心采样）
//
// 与 archive/physical_20261025/legacy_uart_src/uart_rx_receiver.v 结构一致，
// 但把分频改为运行时可切换（BAUD_DIV 由 link_regs 提供），以支持 230400
// 与 921600 两档。分频值只在总线空闲且切换请求锁存后生效，避免半字节切换。
//
// 采样策略：检测到下降沿后等 HALF_DIV 个时钟进入数据位中心，此后每 DIV 采样
// 一次，共 8 位，再等 DIV 检查停止位为高。全程无内部生成时钟。
//=============================================================================
module uart_rx #(
    parameter integer DIV_INIT = 217
)(
    input  wire       clk,
    input  wire       reset,
    input  wire       rx,               // 异步串口输入（空闲高）
    input  wire [15:0] div,             // 当前位宽（时钟数），>=8
    output reg        byte_valid,
    output reg  [7:0] byte_data,
    output reg        frame_error
);
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [2:0]  r_meta;
    reg [1:0]  r_state;
    reg [2:0]  r_bit;
    reg [7:0]  r_shift;
    reg [15:0] r_cnt;
    reg [15:0] r_div_lat;

    wire rx_sync = r_meta[2];
    wire [15:0] half = {1'b0, r_div_lat[15:1]};

    always @(posedge clk) begin
        r_meta <= {r_meta[1:0], rx};
    end

    // 分频锁存：仅在接收空闲时更新
    always @(posedge clk) begin
        if (reset) r_div_lat <= DIV_INIT[15:0];
        else if (r_state == S_IDLE && r_meta[2]) r_div_lat <= div;
    end

    always @(posedge clk) begin
        if (reset) begin
            r_state     <= S_IDLE;
            r_cnt       <= 16'd0;
            r_bit       <= 3'd0;
            r_shift     <= 8'd0;
            byte_valid  <= 1'b0;
            byte_data   <= 8'd0;
            frame_error <= 1'b0;
        end else begin
            byte_valid  <= 1'b0;
            frame_error <= 1'b0;
            case (r_state)
                S_IDLE: begin
                    r_cnt <= 16'd0;
                    r_bit <= 3'd0;
                    if (!rx_sync) r_state <= S_START;
                end
                S_START: begin
                    // 半位处仍为低才确认起始位，抑制毛刺
                    if (r_cnt >= half - 16'd1) begin
                        r_cnt   <= 16'd0;
                        r_state <= rx_sync ? S_IDLE : S_DATA;
                    end else r_cnt <= r_cnt + 16'd1;
                end
                S_DATA: begin
                    if (r_cnt >= r_div_lat - 16'd1) begin
                        r_cnt        <= 16'd0;
                        r_shift[r_bit] <= rx_sync;
                        if (r_bit == 3'd7) r_state <= S_STOP;
                        else               r_bit   <= r_bit + 3'd1;
                    end else r_cnt <= r_cnt + 16'd1;
                end
                S_STOP: begin
                    if (r_cnt >= r_div_lat - 16'd1) begin
                        r_cnt   <= 16'd0;
                        r_state <= S_IDLE;
                        if (rx_sync) begin
                            byte_data  <= r_shift;
                            byte_valid <= 1'b1;
                        end else begin
                            frame_error <= 1'b1;
                        end
                    end else r_cnt <= r_cnt + 16'd1;
                end
                default: r_state <= S_IDLE;
            endcase
        end
    end
endmodule
