`timescale 1ns/1ps
//=============================================================================
// uart_tx.v — 8N1 发送器，带单字节握手（in_ready / in_valid）
//
// 上游在 in_valid && in_ready 同拍交接一个字节；in_ready 在忙时为低。
// 停止位期间 in_ready 提前一拍拉高，可无缝背靠背发送（提高流帧吞吐）。
//=============================================================================
module uart_tx #(
    parameter integer DIV_INIT = 217
)(
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] div,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,
    output reg         tx,
    output reg         busy
);
    reg [1:0]  r_state;
    reg [3:0]  r_bit;
    reg [9:0]  r_shift;
    reg [15:0] r_cnt;
    reg [15:0] r_div_lat;

    localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_DATA = 2'd2, T_STOP = 2'd3;

    assign in_ready = (r_state == T_IDLE);

    always @(posedge clk) begin
        if (reset) r_div_lat <= DIV_INIT[15:0];
        else if (r_state == T_IDLE) r_div_lat <= div;
    end

    always @(posedge clk) begin
        if (reset) begin
            r_state <= T_IDLE;
            r_bit   <= 4'd0;
            r_shift <= 10'h3FF;
            r_cnt   <= 16'd0;
            tx      <= 1'b1;
            busy    <= 1'b0;
        end else begin
            case (r_state)
                T_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    r_cnt <= 16'd0;
                    if (in_valid) begin
                        r_shift <= {1'b1, in_data, 1'b0};  // 停止位 + 数据 + 起始位
                        r_bit   <= 4'd0;
                        r_state <= T_START;
                        busy    <= 1'b1;
                    end
                end
                T_START: begin
                    tx <= r_shift[0];
                    if (r_cnt >= r_div_lat - 16'd1) begin
                        r_cnt   <= 16'd0;
                        r_shift <= {1'b1, r_shift[9:1]};
                        r_bit   <= 4'd1;
                        r_state <= T_DATA;
                    end else r_cnt <= r_cnt + 16'd1;
                end
                T_DATA: begin
                    tx <= r_shift[0];
                    if (r_cnt >= r_div_lat - 16'd1) begin
                        r_cnt   <= 16'd0;
                        r_shift <= {1'b1, r_shift[9:1]};
                        if (r_bit == 4'd8) r_state <= T_STOP;
                        else               r_bit   <= r_bit + 4'd1;
                    end else r_cnt <= r_cnt + 16'd1;
                end
                T_STOP: begin
                    tx <= r_shift[0];   // 此时为停止位 1
                    if (r_cnt >= r_div_lat - 16'd1) begin
                        r_cnt   <= 16'd0;
                        r_state <= T_IDLE;
                        tx      <= 1'b1;
                        busy    <= 1'b0;
                    end else r_cnt <= r_cnt + 16'd1;
                end
                default: r_state <= T_IDLE;
            endcase
        end
    end
endmodule
