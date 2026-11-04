`timescale 1ns/1ps
//=============================================================================
// score_store.v — 曲谱事件存储（BSRAM）
//
// 容量：WORD_DEPTH × 16 bit。默认 4096 字 = 8 KB = 1365 个 6 字节事件。
//       4096×16 bit = 65536 bit，由 2 块 18 Kbit BSRAM 级联（Gowin 自动）。
//
// 写侧按字节推进：每 2 字节拼 1 字并自动递增字地址，天然对齐 6 字节事件
// （6 = 3 字）。写指针由 SCORE_BEGIN 复位。
//
// 读侧只给出字地址 → 1 拍同步读数据，供 score_player 顺序取 3 字/事件。
//
// 资源依据：00_首页_最新版本/tang_mega_60k.rpt.txt:59 BSRAM 57/118 已用，
//           R17 基线：98/118 已用，只剩 20 块；本模块占 2 块（10% 剩余量）。
//           需要 2730 事件时把 WORD_DEPTH 改回 8192（占 4 块）。
//=============================================================================
module score_store #(
    parameter integer WORD_DEPTH  = 4096,
    parameter integer WORD_AWIDTH = 13
)(
    input  wire        clk,
    input  wire        reset,

    input  wire        begin_pulse,     // 回到写指针 0，清奇偶相位
    input  wire        wr_byte,
    input  wire [7:0]  wr_data,

    input  wire [WORD_AWIDTH-1:0] rd_addr,
    output reg  [15:0] rd_data,
    output wire        wr_full,
    output wire [WORD_AWIDTH-1:0] wr_word_addr
);
    reg [15:0] mem [0:WORD_DEPTH-1];
    reg [WORD_AWIDTH-1:0] r_wa;
    reg        r_hi;                // 0 = 等低字节, 1 = 等高字节
    reg [7:0]  r_low;

    wire [WORD_AWIDTH-1:0] next_wa = r_wa + {{(WORD_AWIDTH-1){1'b0}}, 1'b1};
    assign wr_full      = r_hi && (r_wa >= WORD_DEPTH - 1);
    assign wr_word_addr = r_wa;

    always @(posedge clk) begin
        if (reset || begin_pulse) begin
            r_wa <= {WORD_AWIDTH{1'b0}};
            r_hi <= 1'b0;
        end else if (wr_byte && !wr_full) begin
            if (!r_hi) begin
                r_low <= wr_data;
                r_hi  <= 1'b1;
            end else begin
                mem[r_wa] <= {wr_data, r_low};
                r_hi      <= 1'b0;
                r_wa      <= next_wa;
            end
        end
    end

    // 独立读口 → Simple Dual Port BSRAM
    always @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end
endmodule
