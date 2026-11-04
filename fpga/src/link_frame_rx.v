`timescale 1ns/1ps
//=============================================================================
// link_frame_rx.v — 帧解析器（A5 5A / CMD / SEQ / LEN / PAYLOAD / CRC16）
//
// 设计要点
//  1) 载荷先进 128 字节暂存，**CRC16 通过后才置 frame_valid**，因此上层
//     never 见到半截帧；CRC 错误只输出 frame_bad，不改任何状态。
//  2) 128×8 暂存推断为 1 块 Simple Dual Port BSRAM（Gowin SDPB）。
//     读口交给 cmd_dispatch 顺序取用，同步读延迟 1 拍。
//  3) 字节间隔超时保护：连续 div*256 个时钟没有新字节则丢弃当前帧并回空闲，
//     避免 LEN 撒谎导致状态机卡死。
//  4) SOF1 状态收到新的 A5 时停留原地，可容忍前导垃圾字节。
//=============================================================================
module link_frame_rx (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] div,             // 波特率分频，用于超时阈值
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    input  wire        frame_error,     // UART 停止位错误，丢弃当前帧

    output reg         frame_valid,     // 单拍，CRC 正确
    output reg         frame_bad,       // 单拍，CRC/长度错误
    output reg  [7:0]  frame_cmd,
    output reg  [7:0]  frame_seq,
    output reg  [8:0]  frame_len,       // 0..252

    // 载荷读口（dispatch 侧）
    input  wire [7:0]  rd_addr,
    output reg  [7:0]  rd_data
);
    `include "link_pkg.vh"

    localparam [2:0] P_SOF0 = 3'd0, P_SOF1 = 3'd1, P_CMD = 3'd2, P_SEQ = 3'd3,
                     P_LEN  = 3'd4, P_DATA = 3'd5, P_C0  = 3'd6, P_C1 = 3'd7;

    reg [7:0]  mem [0:127];
    reg [2:0]  r_state;
    reg [8:0]  r_len;
    reg [8:0]  r_idx;          // 写入索引 / 已收载荷数
    reg [7:0]  r_cmd, r_seq;
    wire [15:0] r_crc;
    reg [7:0]  r_crc_l;
    reg [15:0] r_gap;          // 字节间隔计数
    reg        r_over;         // 载荷超长（>252）

    wire [15:0] crc_next;
    reg        r_crc_step;
    reg        r_crc_init;
    reg  [7:0] r_crc_byte;

    link_crc u_crc (
        .clk(clk), .reset(reset), .step(r_crc_step), .init(r_crc_init), .data(r_crc_byte),
        .crc16(r_crc), .crc16_next(crc_next)
    );

    // 写口与读口分开描述，保证被推断为 Simple Dual Port BSRAM（SDPB）
    always @(posedge clk) begin
        if (r_state == P_DATA && byte_valid && !r_over && r_idx < 9'd120)
            mem[r_idx[7:0]] <= byte_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    wire gap_timeout = (r_gap >= {div[7:0], 8'h00});

    always @(posedge clk) begin
        if (reset) begin
            r_state     <= P_SOF0;
            r_len       <= 9'd0;
            r_idx       <= 9'd0;
            r_cmd       <= 8'd0;
            r_seq       <= 8'd0;
            r_crc_l     <= 8'd0;
            r_gap       <= 16'd0;
            r_over      <= 1'b0;
            r_crc_step  <= 1'b0;
            r_crc_init  <= 1'b0;
            r_crc_byte  <= 8'd0;
            frame_valid <= 1'b0;
            frame_bad   <= 1'b0;
            r_crc_init  <= 1'b0;
            frame_cmd   <= 8'd0;
            frame_seq   <= 8'd0;
            frame_len   <= 9'd0;
        end else begin
            frame_valid <= 1'b0;
            frame_bad   <= 1'b0;
            r_crc_init  <= 1'b0;

            // CRC 每拍最多并入一个字节
            // CRC 由 link_crc 内部寄存器维护，本层只负责给出单拍 step
            if (r_crc_step) r_crc_step <= 1'b0;

            if (byte_valid) r_gap <= 16'd0;
            else if (r_gap != 16'hFFFF) r_gap <= r_gap + 16'd1;

            if (frame_error && r_state != P_SOF0) begin
                r_state  <= P_SOF0;
                frame_bad <= 1'b1;
            end else if (gap_timeout && r_state != P_SOF0) begin
                r_state  <= P_SOF0;
                frame_bad <= 1'b1;
            end else begin
                case (r_state)
                    P_SOF0: begin
                        r_idx  <= 9'd0;
                        r_over <= 1'b0;
                        if (byte_valid && byte_data == `LINK_SOF0) r_state <= P_SOF1;
                    end
                    P_SOF1: begin
                        if (byte_valid) begin
                            if (byte_data == `LINK_SOF1) begin
                                r_state    <= P_CMD;
                                r_crc_init <= 1'b1;
                                r_crc_step <= 1'b0;
                            end else if (byte_data != `LINK_SOF0) begin
                                r_state <= P_SOF0;
                            end
                        end
                    end
                    P_CMD: begin
                        if (byte_valid) begin
                            r_cmd      <= byte_data;
                            r_crc_byte <= byte_data;
                            r_crc_step <= 1'b1;
                            r_state    <= P_SEQ;
                        end
                    end
                    P_SEQ: begin
                        if (byte_valid) begin
                            r_seq      <= byte_data;
                            r_crc_byte <= byte_data;
                            r_crc_step <= 1'b1;
                            r_state    <= P_LEN;
                        end
                    end
                    P_LEN: begin
                        if (byte_valid) begin
                            r_len      <= {1'b0, byte_data};
                            r_over     <= (byte_data > `LINK_MAX_PAYLOAD);
                            r_idx      <= 9'd0;
                            r_crc_byte <= byte_data;
                            r_crc_step <= 1'b1;
                            r_state    <= (byte_data == 8'd0) ? P_C0 : P_DATA;
                        end
                    end
                    P_DATA: begin
                        if (byte_valid) begin
                            r_crc_byte <= byte_data;
                            r_crc_step <= 1'b1;
                            r_idx      <= r_idx + 9'd1;
                            if (r_idx + 9'd1 >= r_len) r_state <= P_C0;
                        end
                    end
                    P_C0: begin
                        if (byte_valid) begin
                            r_crc_l <= byte_data;
                            r_state <= P_C1;
                        end
                    end
                    P_C1: begin
                        if (byte_valid) begin
                            r_state <= P_SOF0;
                            // r_crc 已含 CMD..末尾载荷（本拍之前最后一次 step 已提交）
                            if (!r_over && {byte_data, r_crc_l} == r_crc) begin
                                frame_valid <= 1'b1;
                                frame_cmd   <= r_cmd;
                                frame_seq   <= r_seq;
                                frame_len   <= r_len;
                            end else begin
                                frame_bad   <= 1'b1;
                            end
                        end
                    end
                    default: r_state <= P_SOF0;
                endcase
            end
        end
    end
endmodule
