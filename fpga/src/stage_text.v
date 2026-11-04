//-----------------------------------------------------------------------------
// stage_text.v —— 参数化文本行绘制（5×7 字体，每字符 6×8 像素含间距）
// TEXT 为右对齐字符串字面量，LEN 为字符数，X0/Y0 为左上角。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_text #(
    parameter [127:0] TEXT = "CH1",
    parameter integer LEN = 3,
    parameter integer X0 = 0,
    parameter integer Y0 = 0,
    parameter integer SCALE = 1
) (
    input  wire [10:0] x,
    input  wire [9:0]  y,
    output wire        hit
);
    wire in_zone = (x >= X0) && (x < X0 + LEN*8*SCALE) && (y >= Y0) && (y < Y0 + 7*SCALE);
    wire [10:0] rx = (x - X0) / SCALE;   // SCALE=1 或 2（/2 为移位）
    wire [9:0]  ry = (y - Y0) / SCALE;
    // 每字符 8 像素（5 位字 + 3 间距）：除法全部变移位，零 DSP
    wire [3:0] idx = rx[6:3];
    wire [2:0] col = rx[2:0];
    wire [2:0] row = ry[2:0];
    wire [7:0] ch = TEXT[(LEN-1-idx)*8 +: 8];
    wire [4:0] bits;
    stage_font u_font(.char_code(ch), .row(row), .bits(bits));
    assign hit = in_zone && (col < 5) && bits[4-col];
endmodule

`default_nettype wire
