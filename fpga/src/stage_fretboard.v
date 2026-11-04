//-----------------------------------------------------------------------------
// stage_fretboard.v —— 尤克里里左手琴颈图（4 弦 × 16 品，纯组合绘制）
//
// 区域：x 16..415，y 90..402。左为琴枕（空弦），右为 16 品。
// 每弦一行（行高 64），每品一格（格宽 24）。
// 当前按品格以该弦颜色填充；空弦时琴枕左侧色块亮；故障/未就绪该行为暗灰。
// 弦色：1 弦青、2 弦黄、3 弦绿、4 弦品红。品号在每格下方用 5×7 字体标注。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_fretboard (
    input  wire [10:0] x,
    input  wire [9:0]  y,
    input  wire [19:0] fret_bus,     // 4×5 位品位（0=空弦）
    input  wire [3:0]  valid_mask,
    input  wire [3:0]  fault_mask,
    output reg         hit,
    output reg  [23:0] rgb
);

    // 布局常量
    localparam integer X0 = 24;     // 第一品左缘
    localparam integer Y0 = 100;    // 第一弦行上缘
    localparam integer CW = 24;     // 品格宽
    localparam integer RH = 64;     // 弦行高

    wire in_region = (x >= 16) && (x < 416) && (y >= 90) && (y < 402);

    // 行列定位（列用阈值比较链，行用移位；零 DSP）
    wire [10:0] rx = x - X0;
    wire [9:0]  ry = y - Y0;
    wire [4:0] col = (rx>=360)?5'd15:(rx>=336)?5'd14:(rx>=312)?5'd13:(rx>=288)?5'd12:
                     (rx>=264)?5'd11:(rx>=240)?5'd10:(rx>=216)?5'd9:(rx>=192)?5'd8:
                     (rx>=168)?5'd7:(rx>=144)?5'd6:(rx>=120)?5'd5:(rx>=96)?5'd4:
                     (rx>=72)?5'd3:(rx>=48)?5'd2:(rx>=24)?5'd1:5'd0;
    wire [1:0]  row = ry[7:6];           // ry/64
    // cx = rx - col*24，col*24 = (col<<4)+(col<<3)（变量移位加）
    wire [10:0] col_x24 = (col<<4)+(col<<3);
    wire [10:0] cx = rx - col_x24;
    wire [9:0]  cy = ry - {row, 6'd0};   // ry - row*64（row=ry/64，ry<256）
    wire        in_grid = in_region && (rx < 16*CW) && (ry < 4*RH) && (x >= X0) && (y >= Y0);

    wire [4:0] fret_num = col + 1'b1;
    wire [4:0] fret_cur = fret_bus[row*5 +: 5];
    wire       row_ok   = valid_mask[row] && !fault_mask[row];

    // 每弦颜色
    reg [23:0] string_color;
    always @(*) begin
        case (row)
            2'd0: string_color = 24'h00C8DC;   // 青
            2'd1: string_color = 24'hE6BE28;   // 黄
            2'd2: string_color = 24'h3CC85A;   // 绿
            default: string_color = 24'hDC46AA; // 品红
        endcase
    end

    // 空弦指示块（琴枕左侧 x 4..20，独立于 in_region 的 x>=16 限制）
    wire nut_zone = (x >= 4) && (x < 20) && (y >= Y0) && (ry < 4*RH);
    wire nut_hit  = nut_zone && (fret_cur == 0) && row_ok && (cy >= 20) && (cy < 44);

    // 字体：品号（1..16）。品号 10..16 的高位恒为 '1'；个位用减法（无除法）
    wire [3:0] fret_lo_digit = (fret_num >= 11) ? (fret_num - 10) :
                               (fret_num == 10) ? 4'd0 : fret_num[3:0];
    wire [7:0] fret_char_hi = (fret_num >= 10) ? 8'd49 : 8'd32;   // '1' 或空格
    wire [7:0] fret_char_lo = 8'd48 + fret_lo_digit;
    wire digit_zone = in_grid && (cy >= 48) && (cy < 55);
    wire [2:0] font_row = cy - 48;
    wire [4:0] gbits_hi, gbits_lo;
    stage_font u_ghi(.char_code(fret_char_hi), .row(font_row), .bits(gbits_hi));
    stage_font u_glo(.char_code(fret_char_lo), .row(font_row), .bits(gbits_lo));
    wire digit_hit = digit_zone &&
        (((cx >= 6) && (cx < 11) && (fret_char_hi != 8'd32) && gbits_hi[4-(cx-6)]) ||
         ((cx >= 12) && (cx < 17) && gbits_lo[4-(cx-12)]));

    always @(*) begin
        hit = 1'b0;
        rgb = 24'h000000;
        if (in_grid) begin
            if (fret_cur == fret_num && row_ok && cy < 44) begin
                // 当前按品：整格填充（上部 44 像素）
                hit = 1'b1; rgb = string_color;
            end else if (cx == 0 && cy < 44) begin
                hit = 1'b1; rgb = 24'h5A6472;         // 品柱
            end else if (cy == 44) begin
                hit = 1'b1; rgb = row_ok ? string_color : 24'h3A3F46; // 弦线
            end else if (digit_hit) begin
                hit = 1'b1; rgb = 24'h8A94A0;         // 品号
            end
        end else if (nut_hit) begin
            hit = 1'b1; rgb = string_color;           // 空弦指示
        end
    end

endmodule

`default_nettype wire
