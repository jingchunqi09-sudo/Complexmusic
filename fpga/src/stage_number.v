//-----------------------------------------------------------------------------
// stage_number.v —— 十进制数值显示（DIGITS 位，高位在左，常数除法）
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_number #(
    parameter integer DIGITS = 4,
    parameter integer X0 = 0,
    parameter integer Y0 = 0,
    parameter integer SCALE = 1
) (
    input  wire [10:0] x,
    input  wire [9:0]  y,
    input  wire [19:0] bcd,          // 5 位 BCD（由 stage_bcd 提供，无除法）
    output wire        hit
);
    wire in_zone = (x >= X0) && (x < X0 + DIGITS*8*SCALE) && (y >= Y0) && (y < Y0 + 7*SCALE);
    wire [10:0] rx = (x - X0) / SCALE;
    wire [9:0]  ry = (y - Y0) / SCALE;
    // 每字符 8 像素：除法变移位
    wire [3:0] idx = rx[6:3];          // 0=最高位
    wire [2:0] col = rx[2:0];
    wire [2:0] row = ry[2:0];

    // DIGITS<=5：直接取 BCD 位（0=个位 … 4=万位），高位在左
    wire [3:0] digit = bcd[(DIGITS-1-idx)*4 +: 4];
    wire [7:0] ch = 8'd48 + digit;
    wire [4:0] bits;
    stage_font u_font(.char_code(ch), .row(row), .bits(bits));
    assign hit = in_zone && (col < 5) && bits[4-col];
endmodule

`default_nettype wire
