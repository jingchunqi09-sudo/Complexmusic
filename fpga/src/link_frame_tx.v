`timescale 1ns/1ps
//=============================================================================
// link_frame_tx.v — 组帧发送器（A5 5A / CMD / SEQ / LEN / PAYLOAD / CRC16）
//
// 结构选择说明：发送载荷上限只有 56 字节（录音帧），因此用 64×8 寄存器组
// 直接组合读，避免 BSRAM 同步读带来的一拍取指间隙与额外状态机。
// 64×8 = 512 FF，约占 60780 的 0.8%（依据 tang_mega_60k.rpt.txt 的 FF 总量）。
//
// 发送流程：索引进 0..6+LEN，逐字节交给 uart_tx，CMD..payload 每字节并入 CRC。
// busy 期间上层不得写 buffer（上层负责），send 只在 !busy 时被接受。
//=============================================================================
module link_frame_tx (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] div,
    // buffer 写口（上层）
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire [7:0]  wr_data,
    // 发送请求
    input  wire        send,
    input  wire [7:0]  send_cmd,
    input  wire [7:0]  send_len,        // 0..56
    // UART
    output reg         tx_valid,
    output reg  [7:0]  tx_data,
    input  wire        tx_ready,
    // 状态
    output reg         busy,
    output reg         done,
    output reg  [7:0]  seq_out
);
    `include "link_pkg.vh"

    reg [7:0] tbuf [0:63];
    integer   bi;

    reg [7:0]  r_cmd;
    reg [7:0]  r_len;
    reg [7:0]  r_seq;
    reg [7:0]  r_idx;
    wire [15:0] r_crc;
    reg        r_crc_step;
    reg        r_crc_init;
    reg  [7:0] r_crc_byte;

    wire [15:0] crc_next;
    link_crc u_crc (
        .clk(clk), .reset(reset), .step(r_crc_step), .init(r_crc_init), .data(r_crc_byte),
        .crc16(r_crc), .crc16_next(crc_next)
    );

    // 组合读（寄存器组）
    wire [7:0] pay_index = r_idx - 8'd5;
    wire [7:0] pay_byte  = tbuf[pay_index[5:0]];
    wire [7:0] out_byte  =
        (r_idx == 8'd0) ? `LINK_SOF0 :
        (r_idx == 8'd1) ? `LINK_SOF1 :
        (r_idx == 8'd2) ? r_cmd :
        (r_idx == 8'd3) ? r_seq :
        (r_idx == 8'd4) ? r_len :
        (r_idx < 8'd5 + r_len) ? pay_byte :
        (r_idx == 8'd5 + r_len) ? r_crc[7:0] : r_crc[15:8];

    wire in_crc_zone = (r_idx >= 8'd2) && (r_idx < 8'd5 + r_len);

    always @(posedge clk) begin
        if (wr_en) tbuf[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        if (reset) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            tx_valid   <= 1'b0;
            tx_data    <= 8'd0;
            r_idx      <= 8'd0;
            r_cmd      <= 8'd0;
            r_len      <= 8'd0;
            r_seq      <= 8'd0;
            r_crc_step <= 1'b0;
            r_crc_init <= 1'b0;
            r_crc_byte <= 8'd0;
            seq_out    <= 8'd0;
        end else begin
            done     <= 1'b0;
            tx_valid <= 1'b0;
            r_crc_init <= 1'b0;

            // CRC 由 link_crc 内部寄存器维护，本层只负责给出单拍 step
            if (r_crc_step) r_crc_step <= 1'b0;

            if (!busy) begin
                if (send) begin
                    busy <= 1'b1;
                    r_cmd <= send_cmd;
                    r_len <= (send_len > 8'd56) ? 8'd56 : send_len;
                    r_seq <= r_seq + 8'd1;
                    seq_out <= r_seq + 8'd1;
                    r_idx <= 8'd0;
                    r_crc_init <= 1'b1;
                end
            end else begin
                if (tx_ready && (r_idx < 8'd7 + r_len) && !tx_valid) begin
                    tx_valid   <= 1'b1;
                    tx_data    <= out_byte;
                    r_crc_byte <= out_byte;
                    r_crc_step <= in_crc_zone;
                    r_idx      <= r_idx + 8'd1;
                end else if (tx_valid && tx_ready) begin
                    tx_valid <= 1'b0;
                end
                if (r_idx >= 8'd7 + r_len && !tx_valid) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    // 复位 buffer（仅仿真/初始化用；综合器会忽略 initial 块）
    // synthesis translate_off
    initial for (bi = 0; bi < 64; bi = bi + 1) tbuf[bi] = 8'd0;
    // synthesis translate_on
endmodule
