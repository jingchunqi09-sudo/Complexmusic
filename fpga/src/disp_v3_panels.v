//=============================================================================
// disp_v3_panels —— v3.1 六个显示区域的绘制模块
//
// 约定（与 Project F 的 graphics 库一致）：
//   * 每个模块只输出「本拍该像素是不是我的 / 什么颜色」，无状态、无握手
//   * 纯组合（always @*），由顶层统一打拍，保证所有区域的延迟一致
//   * 不写任何存储器，故不需要行缓冲
//
// 时序预算：单模块组合深度 ≤ 5 级 LUT（16 路品丝比较是最深的一点）。
//=============================================================================
`include "disp_v3_defs.vh"

//-----------------------------------------------------------------------------
// A：尤克里里左手（指板 / 品丝 / 弦 / 按品高亮 / 品号刻度）
//   高亮分六层：外光晕(3 圈) + 格底 + 内芯 + 白边 + 弦位白点 + 起音闪白
//   亮度直接进 RGB，不做 >>2 压暗（R13b 的教训：实板看不清）
//-----------------------------------------------------------------------------
module disp_v3_ukulele (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire [1:0]  i_mode,
    input  wire [1:0]  i_sel,          // 最近起音弦：只用于“当前弦”强调，不决定谁亮
    input  wire [19:0] i_fret_bus,     // 四弦全量，[4:0]=弦0
    input  wire [3:0]  i_valid,
    input  wire [3:0]  i_fault,
    input  wire [15:0] i_flash,        // 四弦闪光全量，每弦 4 位
    input  wire [7:0]  i_breath,       // 0..15 呼吸相位，驱动高亮内芯的明暗
    input  wire [2:0]  i_guide_lane,   // 曲谱指引（R33 通道）
    input  wire [4:0]  i_guide_fret,
    input  wire        i_guide_valid,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire [3:0] core_w = 4'd7 + i_breath[3:1];      // 7..14，起音时再叠加闪光
    wire [3:0] body_w = 4'd5 + i_breath[4:1];      // 5..10

    wire in_head  = (i_x >= `NUT_X - 68) && (i_x < `NUT_X) &&
                    (i_y >= `NECK_TOP - 4) && (i_y <= `NECK_BOT + 4);
    wire in_board = (i_x >= `NUT_X) && (i_x <= `FRET16_X + 1) &&
                    (i_y >= `NECK_TOP) && (i_y <= `NECK_BOT);
    wire in_scale = (i_x >= `NUT_X) && (i_x <= `FRET16_X) &&
                    (i_y >= `NECK_BOT + 5) && (i_y <= `NECK_BOT + 9);

    // 音高轴（与文本层 C4/C5/C6/C7 同一行上方）
    wire in_paxis = (i_y >= 10'd404) && (i_y <= 10'd410) &&
                    (i_x >= 11'd36) && (i_x <= 11'd564);
    wire paxis_tick = in_paxis && ((i_x == 11'd48) || (i_x == 11'd216) ||
                                   (i_x == 11'd384) || (i_x == 11'd552));

    wire [1:0] row = (i_y < `STR_Y0 + 17) ? 2'd0 :
                     (i_y < `STR_Y0 + 51) ? 2'd1 :
                     (i_y < `STR_Y0 + 85) ? 2'd2 : 2'd3;
    wire [9:0] str_y = `STR_Y0 + (row * `STR_DY);

    // 品丝：16 路比较
    integer fi;
    reg fret_hit;
    always @(*) begin
        fret_hit = 1'b0;
        for (fi = 1; fi <= 16; fi = fi + 1)
            if (i_x == fret_x(fi[4:0])) fret_hit = 1'b1;
    end

    // 按品高亮几何 —— 逐行取自己的品号/闪光（R16 的做法：扫到哪一行就画哪一行）
    wire [4:0]  fret_row  = i_fret_bus[row * 5 +: 5];
    wire [3:0]  flash_row = i_flash[row * 4 +: 4];

    wire [4:0]  hf    = (fret_row == 5'd0) ? 5'd1 : fret_row;
    wire [10:0] hi_x0 = (fret_row == 5'd0) ? (`NUT_X - 58) : (fret_x(hf - 5'd1) + 11'd2);
    wire [10:0] hi_x1 = (fret_row == 5'd0) ? `NUT_X           : (fret_x(hf) - 11'd1);
    wire [9:0]  hi_y  = str_y;
    wire [3:0]  fl    = flash_row;
    wire        hl_on = (fret_row != 5'd0) && i_valid[row] && !i_fault[row];
    wire        hb_on = (fret_row == 5'd0) && i_valid[row] && !i_fault[row];

    //---- 曲谱指引目标（语义 1:1 对齐 r9_stage_dashboard 的黄/绿判定）----
    // guide_lane 是 3 位（曲谱最多 8 lane），琴颈只有 4 弦：
    // >3 视为“不在本面板”，避免像 R16 那样 i_fret_bus[i_guide_lane*5 +: 5] 越界。
    wire [1:0]  gl_row = i_guide_lane[1:0];
    wire        gl_ok  = i_guide_valid && (i_guide_lane <= 3'd3);
    wire [10:0] gf_x0  = (i_guide_fret == 5'd0) ? (`NUT_X - 58)
                                                : (fret_x(i_guide_fret - 5'd1) + 11'd2);
    wire [10:0] gf_x1  = (i_guide_fret == 5'd0) ? `NUT_X
                                                : (fret_x(i_guide_fret) - 11'd1);
    wire [9:0]  gf_y   = `STR_Y0 + (gl_row * `STR_DY);
    wire        g_hit  = gl_ok && (gl_row == row) &&
                         (i_x >= gf_x0) && (i_x < gf_x1) &&
                         (i_y + 11 >= gf_y) && (i_y < gf_y + 11);
    wire        g_ok   = gl_ok && (fret_row == i_guide_fret) &&
                         i_valid[row] && !i_fault[row];
    wire [23:0] g_col  = g_ok ? 24'h28E070 : 24'hF0C020;

    wire hl_pad11 = hl_on && (i_x + 11 >= hi_x0) && (i_x < hi_x1 + 11) &&
                    (i_y + 15 >= hi_y) && (i_y < hi_y + 15);
    wire hl_pad7  = hl_on && (i_x + 7 >= hi_x0) && (i_x < hi_x1 + 7) &&
                    (i_y + 12 >= hi_y) && (i_y < hi_y + 12);
    wire hl_pad3  = hl_on && (i_x + 3 >= hi_x0) && (i_x < hi_x1 + 3) &&
                    (i_y + 15 >= hi_y) && (i_y < hi_y + 15);
    wire hl_body  = hl_on && (i_x >= hi_x0) && (i_x < hi_x1) &&
                    (i_y + 15 >= hi_y) && (i_y < hi_y + 15);
    wire hl_core  = hl_body && (i_x >= hi_x0 + 4) && (i_x < hi_x1 - 4) &&
                    (i_y + 11 >= hi_y) && (i_y < hi_y + 11);
    wire hl_edge  = hl_body && ((i_y + 15 == hi_y) || (i_y + 14 == hi_y) ||
                                (i_y == hi_y + 14) || (i_y == hi_y + 13) ||
                                (i_x == hi_x0) || (i_x == hi_x1 - 1));
    wire [10:0] hcx = (hi_x0 + hi_x1) >> 1;
    wire hl_pt    = hl_body && (i_x + 3 >= hcx) && (i_x < hcx + 3) &&
                    (i_y + 2 >= hi_y) && (i_y < hi_y + 2);

    wire hb_body = hb_on && (i_x >= `NUT_X - 58) && (i_x < `NUT_X) &&
                   (i_y + 11 >= hi_y) && (i_y < hi_y + 11);
    wire hb_pt   = hb_on && (i_x + 6 >= `NUT_X - 28) && (i_x < `NUT_X - 22) &&
                   (i_y + 4 >= hi_y) && (i_y < hi_y + 4);

    wire [23:0] sc  = str_color(row);
    wire [23:0] hot = {lighten(sc[23:16], 4'd7), lighten(sc[15:8], 4'd7), lighten(sc[7:0], 4'd7)};

    // 指板木质：线性渐变（分段会在实板上看到横向色阶）
    wire [9:0]  by_off = (i_y >= `NECK_TOP) ? (i_y - `NECK_TOP) : 10'd0;
    reg  [15:0] pr, pg, pb;
    always @(*) begin
        pr = by_off * 16'd21;      // 144*21 = 3024 -> [15:8] = 0..11
        pg = by_off * 16'd16;
        pb = by_off * 16'd11;
    end
    wire [23:0] board_col = {8'h2B - pr[15:8], 8'h1E - pg[15:8], 8'h13 - pb[15:8]};

    wire scale_tick = in_scale &&
        ((i_x == fret_x(5'd1)) || (i_x == fret_x(5'd3)) || (i_x == fret_x(5'd5)) ||
         (i_x == fret_x(5'd7)) || (i_x == fret_x(5'd9)) || (i_x == fret_x(5'd12)) ||
         (i_x == fret_x(5'd15)));

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;

        if (in_head) begin
            o_hit = 1'b1;
            o_rgb = (i_y < `NECK_TOP) ? 24'h33261B : 24'h221912;
            if (((i_x - (`NUT_X - 54)) * (i_x - (`NUT_X - 54)) +
                 (i_y - `STR_Y0 - 34) * (i_y - `STR_Y0 - 34) <= 16) ||
                ((i_x - (`NUT_X - 28)) * (i_x - (`NUT_X - 28)) +
                 (i_y - `STR_Y0 - 68) * (i_y - `STR_Y0 - 68) <= 16))
                o_rgb = 24'h7C8B98;
        end else if (in_board) begin
            o_hit = 1'b1;
            o_rgb = board_col;
            if (i_y == `NECK_TOP) o_rgb = 24'h3E2C1D;
            if (i_y == `NECK_BOT) o_rgb = 24'h0A0603;

            if ((i_y >= `NECK_MID_Y - 2) && (i_y <= `NECK_MID_Y + 2) &&
                (((i_x >= 209) && (i_x <= 213)) || ((i_x >= 278) && (i_x <= 282)) ||
                 ((i_x >= 341) && (i_x <= 345)) || ((i_x >= 423) && (i_x <= 427)) ||
                 ((i_x >= 529) && (i_x <= 533))))
                o_rgb = 24'h5A6A76;

            if (fret_hit) o_rgb = 24'h3E4B56;
            if (fret_hit && (i_x == fret_x(5'd12))) o_rgb = 24'h55636E;
            if ((i_x >= `NUT_X - 2) && (i_x <= `NUT_X + 1)) o_rgb = 24'hAEBCC8;

            if (hl_pad11) o_rgb = {lighten(o_rgb[23:16], 4'd1), lighten(o_rgb[15:8], 4'd1), lighten(o_rgb[7:0], 4'd1)};
            if (hl_pad7)  o_rgb = {lighten(sc[23:16], 4'd3), lighten(sc[15:8], 4'd3), lighten(sc[7:0], 4'd3)};
            if (hl_pad3)  o_rgb = {lighten(sc[23:16], 4'd5), lighten(sc[15:8], 4'd5), lighten(sc[7:0], 4'd5)};
            if (hl_body)  o_rgb = {lighten(sc[23:16], body_w), lighten(sc[15:8], body_w), lighten(sc[7:0], body_w)};
            if (hl_core)  o_rgb = {lighten(sc[23:16], core_w), lighten(sc[15:8], core_w), lighten(sc[7:0], core_w)};
            if (hl_edge)  o_rgb = {lighten(hot[23:16], 4'd3), lighten(hot[15:8], 4'd3), lighten(hot[7:0], 4'd3)};
            if (hl_pt)    o_rgb = 24'hFFFFFF;
            if (hl_body && fl[3]) o_rgb = {lighten(o_rgb[23:16], 4'd4), lighten(o_rgb[15:8], 4'd4), lighten(o_rgb[7:0], 4'd4)};
            // 曲谱指引：目标品框。黄=待按，绿=已按对。
            // 闪烁用 i_breath[3]（帧节拍三角波），省掉一个帧计数器和一个新端口。
            if (g_hit) o_rgb = i_breath[3] ? g_col : 24'h6A5A20;

            // 弦覆盖在高亮之上
            if ((i_y + 2 >= str_y) && (i_y <= str_y + 2)) o_rgb = sc;
            if ((i_y + 1 == str_y) && (row == i_sel) && i_valid[row]) o_rgb = hot;
            if (i_y == str_y + 3) o_rgb = 24'h0A0603;
        end else if (in_board == 1'b0 && hb_on && hb_body) begin
            o_hit = 1'b1;
            o_rgb = hb_pt ? 24'hFFFFFF : {lighten(sc[23:16], 4'd7), lighten(sc[15:8], 4'd7), lighten(sc[7:0], 4'd7)};
        end else if (in_scale) begin
            o_hit = 1'b1;
            o_rgb = scale_tick ? 24'h5E6C78 : `C_EDGE_DIM;
        end else if (in_paxis) begin
            o_hit = 1'b1;
            if (paxis_tick) o_rgb = 24'h4E5C68;
            else            o_rgb = (i_y == 10'd408) ? 24'h2C3843 : 24'h000000;
            if (i_y != 10'd408) o_hit = paxis_tick;
        end
    end
endmodule


//-----------------------------------------------------------------------------
// B：小提琴（4bpp 掩模 + 严格水平弓 + 弓根/弓尖/触弦点）
//   弓必须画在掩模之外也能看见 —— v3.0 把弓画在 "body != 0" 分支里，
//   结果弓只有压在琴身上的一小段可见，实机上一整把弓是隐形的。
//-----------------------------------------------------------------------------
module disp_v3_violin (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire signed [15:0] i_bow_x,
    input  wire signed [15:0] i_bow_y,
    input  wire [3:0]  i_bow_gates,
    input  wire [3:0]  i_flash_cur,
    input  wire [1:0]  i_sel,
    output wire [15:0] o_mask_addr,
    input  wire [7:0]  i_mask_data,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire in_box = (i_x >= `VIO_X) && (i_x < `VIO_X + `VIO_W) &&
                  (i_y >= `VIO_Y) && (i_y < `VIO_Y + `VIO_H);
    wire [9:0] my = i_y - `VIO_Y;
    wire [7:0] mx = i_x - `VIO_X;
    // *128 写成移位：`* 10'd128` 会被综合成 DSP，而本工程 DSP 已近满
    assign o_mask_addr = ({6'd0, my} << 7) + {8'd0, mx[7:1]};
    wire [3:0] px4 = mx[0] ? i_mask_data[3:0] : i_mask_data[7:4];

    wire [9:0] my_off = (my >= 10'd84) ? (my - 10'd84) : 10'd0;
    wire [5:0] band_raw = my_off[8:3];
    wire [4:0] band = (band_raw > 6'd31) ? 5'd31 : band_raw[4:0];

    function [23:0] wood_grad;
        input [4:0] b;
        begin
            case (b)
                5'd0:  wood_grad = 24'h744E2C;  5'd1:  wood_grad = 24'h714C2B;
                5'd2:  wood_grad = 24'h6E4A2A;  5'd3:  wood_grad = 24'h6B4829;
                5'd4:  wood_grad = 24'h684628;  5'd5:  wood_grad = 24'h654427;
                5'd6:  wood_grad = 24'h624226;  5'd7:  wood_grad = 24'h5F4025;
                5'd8:  wood_grad = 24'h5C3E24;  5'd9:  wood_grad = 24'h593C23;
                5'd10: wood_grad = 24'h563A22;  5'd11: wood_grad = 24'h533821;
                5'd12: wood_grad = 24'h50361F;  5'd13: wood_grad = 24'h4D341E;
                5'd14: wood_grad = 24'h4A321D;  5'd15: wood_grad = 24'h47301C;
                5'd16: wood_grad = 24'h442E1B;  5'd17: wood_grad = 24'h412C1A;
                5'd18: wood_grad = 24'h3E2A19;  5'd19: wood_grad = 24'h3B2818;
                5'd20: wood_grad = 24'h382617;  5'd21: wood_grad = 24'h352417;
                5'd22: wood_grad = 24'h322216;  5'd23: wood_grad = 24'h2F2015;
                5'd24: wood_grad = 24'h2C1E14;  5'd25: wood_grad = 24'h291C13;
                5'd26: wood_grad = 24'h261A12;  5'd27: wood_grad = 24'h231811;
                5'd28: wood_grad = 24'h201610;  5'd29: wood_grad = 24'h1D140F;
                5'd30: wood_grad = 24'h1A120E;  default: wood_grad = 24'h17100D;
            endcase
        end
    endfunction

    wire [23:0] wbase = wood_grad(band);
    wire [1:0] sh = px4[3:2];
    wire [1:0] kd = px4[1:0];
    wire [7:0] kr = (sh == 2'd3) ? wbase[23:16] :
                    (sh == 2'd2) ? (wbase[23:16] - (wbase[23:16] >> 3)) :
                    (sh == 2'd1) ? (wbase[23:16] - (wbase[23:16] >> 2)) :
                                   (wbase[23:16] - (wbase[23:16] >> 2) - (wbase[23:16] >> 3));
    wire [7:0] kg = (sh == 2'd3) ? wbase[15:8] :
                    (sh == 2'd2) ? (wbase[15:8] - (wbase[15:8] >> 3)) :
                    (sh == 2'd1) ? (wbase[15:8] - (wbase[15:8] >> 2)) :
                                   (wbase[15:8] - (wbase[15:8] >> 2) - (wbase[15:8] >> 3));
    wire [7:0] kb = (sh == 2'd3) ? wbase[7:0] :
                    (sh == 2'd2) ? (wbase[7:0] - (wbase[7:0] >> 3)) :
                    (sh == 2'd1) ? (wbase[7:0] - (wbase[7:0] >> 2)) :
                                   (wbase[7:0] - (wbase[7:0] >> 2) - (wbase[7:0] >> 3));

    wire [23:0] body = (kd == 2'd1) ? {kr, kg, kb} :
                       (kd == 2'd2) ? 24'h22140B : (kd == 2'd3) ? 24'hCEB284 : 24'h000000;

    // 弓：严格水平；与琴身掩模完全解耦
    wire signed [11:0] bx = `BOW_CX + i_bow_x[11:0];
    wire signed [11:0] by = `BOW_CY + i_bow_y[11:0];
    wire signed [11:0] dx = $signed({1'b0, i_x}) - bx;
    wire signed [11:0] dy = $signed({2'b0, i_y}) - by;
    wire in_span = (dx >= -`BOW_HALF) && (dx <= `BOW_HALF);
    wire signed [11:0] ax = dx[11] ? (-dx) : dx;

    wire bow_hair = in_span && (dy >= 2) && (dy <= 4);
    wire bow_wood = in_span && (dy >= -6) && (dy <= -4);
    wire bow_frog = in_span && (dx <= -(`BOW_HALF - 17)) && (dy >= -7) && (dy <= 6);
    wire bow_tip  = in_span && (dx >= (`BOW_HALF - 10)) && (dy >= -5) && (dy <= 6);
    wire touch    = in_span && (ax <= 4) && (dy >= 2) && (dy <= 6) && (i_bow_gates != 4'd0);

    wire on_string = (i_x == 692) || (i_x == 704) || (i_x == 716) || (i_x == 728);
    wire on_bridge = (i_y >= 236) && (i_y <= 237) && (i_x >= 688) && (i_x <= 732);

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;

        // 1) 琴身（掩模）
        if (in_box && (body != 24'h000000)) begin
            o_hit = 1'b1;
            o_rgb = on_string ? 24'hCFC4A8 : body;
            if (on_bridge) o_rgb = 24'h7A6748;
        end

        // 2) 弓：独立判定，画在琴身之外也成立
        if (bow_hair) begin
            o_hit = 1'b1;
            o_rgb = (dy == 2) ? 24'hFCF8EE : 24'hE7DFCB;
        end
        if (bow_wood) begin
            o_hit = 1'b1;
            o_rgb = (dy == -6) ? 24'hC08B52 : 24'h8A5A33;
        end
        if (bow_frog) begin
            o_hit = 1'b1;
            o_rgb = (dx <= -(`BOW_HALF - 4)) ? 24'hCBD5DD : 24'h241608;
        end
        if (bow_tip) begin
            o_hit = 1'b1;
            o_rgb = 24'hC0A276;
        end
        if (touch) begin
            o_hit = 1'b1;
            o_rgb = i_flash_cur[3] ? 24'hFFFFFF : 24'h45D9C0;
        end
    end
endmodule


//-----------------------------------------------------------------------------
// C：电平（4 条）—— 长度=力度、厚度=基频、白色峰值刻线
//-----------------------------------------------------------------------------
module disp_v3_levels (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire [31:0] i_vpk,
    input  wire [3:0]  i_flash_cur,
    input  wire [1:0]  i_sel,
    input  wire [3:0]  i_gates,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire in_panel = (i_x > `C_X0) && (i_x < `C_X1) && (i_y > `C_Y0 + `HDR_H) && (i_y < `C_Y1 - 1);
    wire [1:0] row = (i_y < `C_Y0 + `HDR_H + 12 + 62)  ? 2'd0 :
                     (i_y < `C_Y0 + `HDR_H + 12 + 124) ? 2'd1 :
                     (i_y < `C_Y0 + `HDR_H + 12 + 186) ? 2'd2 : 2'd3;
    wire [9:0] ry = i_y - (`C_Y0 + `HDR_H + 12 + row * 62);
    wire [7:0] v = i_vpk[row*8 +: 8];
    wire [9:0] bar_x0 = 10'd936 - `C_X0;
    wire [9:0] bar_w  = 10'd224;
    wire [9:0] xl    = i_x - `C_X0;
    wire [9:0] fill  = ({2'd0, v} * 10'd224) >> 8;
    wire [3:0] thk   = 4'd3 + {1'b0, v[7:5]};

    wire in_bar  = (ry + 8 >= 10'd30) && (ry < 10'd46) && (xl >= bar_x0) && (xl < bar_x0 + bar_w);
    wire [9:0] half_t = {6'd0, thk} >> 1;
    wire in_fill = in_bar && (xl - bar_x0 < fill) && (ry + half_t >= 10'd30) && (ry < 10'd30 + thk);
    wire peak    = in_bar && ((xl - bar_x0) == fill) && (v > 8'd2);

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;
        if (in_panel) begin
            o_hit = 1'b1;
            o_rgb = `C_PANEL;
            if (row == i_sel && xl < 10'd6) o_rgb = str_color(row);
            if (in_bar)  o_rgb = `C_WELL;
            if (in_fill) o_rgb = str_color(row);
            if (peak)    o_rgb = 24'hE8F0F6;
        end
    end
endmodule


//-----------------------------------------------------------------------------
// D：曲谱（五线谱 + 历史音 + 当前音光晕 + 符干）
//-----------------------------------------------------------------------------
module disp_v3_score (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire [39:0] i_staff_y,       // 4 x 10 bit
    input  wire [29:0] i_hist_y,        // 3 x 10 bit
    input  wire [2:0]  i_hist_v,        // 历史音有效位
    input  wire [3:0]  i_flash_cur,
    input  wire [1:0]  i_sel,
    input  wire [3:0]  i_gates,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire in_panel = (i_x > `D_X0) && (i_x < `D_X1) && (i_y > `D_Y0 + `HDR_H) && (i_y < `D_Y1 - 1);

    // 五线：y = ST_YE4 - i*2*ST_HALF
    wire on_staff = (i_x >= `ST_X0) && (i_x <= `ST_X1) &&
                    ((i_y == `ST_YE4) || (i_y == `ST_YE4 - 14) || (i_y == `ST_YE4 - 28) ||
                     (i_y == `ST_YE4 - 42) || (i_y == `ST_YE4 - 56));
    wire on_bar = ((i_x == `ST_X0) || (i_x == `ST_X1)) &&
                  (i_y + 56 >= `ST_YE4) && (i_y <= `ST_YE4);

    wire [23:0] sc = str_color(i_sel);
    wire [9:0]  ny = i_staff_y[i_sel*10 +: 10];

    // 当前音符头 18x14（9x7 位图 2 倍）
    wire [10:0] hdx = i_x - (`NOTE_X0 - 11'd8);
    wire [10:0] hdy = i_y - (ny - 10'd7);
    wire in_head = (hdx < 11'd18) && (hdy < 11'd14);
    wire [2:0] hr = hdy[3:1];
    wire [3:0] hc = hdx[3:1];
    wire head_bit = in_head && ((note_head_row(hr) >> (4'd7 - hc)) & 1'b1);

    // 光晕
    wire in_glow = (i_x + 16 >= `NOTE_X0 - 11'd8) && (i_x < `NOTE_X0 + 11'd24) &&
                   (i_y + 14 >= ny - 10'd7) && (i_y < ny + 10'd22);

    // 符干
    wire stem = (i_x == `NOTE_X0 + 11'd9) && (i_y + 30 >= ny) && (i_y < ny + 10'd2);

    // 历史音（3 个，向左排开）
    wire [9:0] hy0 = i_hist_y[9:0];
    wire [9:0] hy1 = i_hist_y[19:10];
    wire [9:0] hy2 = i_hist_y[29:20];
    wire [10:0] hx0 = `NOTE_X0 - `NOTE_DX;
    wire [10:0] hx1 = `NOTE_X0 - (`NOTE_DX * 2);
    wire [10:0] hx2 = `NOTE_X0 - (`NOTE_DX * 3);

    function hist_head;
        input [10:0] px;
        input [9:0]  py;
        input [10:0] xx;
        input [9:0]  yy;
        reg [10:0] ddx;
        reg [9:0]  ddy;
        begin
            ddx = xx - (px - 11'd4);
            ddy = yy - (py - 10'd3);
            hist_head = (ddx < 11'd9) && (ddy < 10'd7) &&
                        ((note_head_row(ddy[2:0]) >> (4'd7 - ddx[2:0])) & 1'b1);
        end
    endfunction

    wire hist0 = i_hist_v[0] && hist_head(hx0, hy0, i_x, i_y);
    wire hist1 = i_hist_v[1] && hist_head(hx1, hy1, i_x, i_y);
    wire hist2 = i_hist_v[2] && hist_head(hx2, hy2, i_x, i_y);

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;
        if (in_panel) begin
            o_hit = 1'b1;
            o_rgb = `C_PANEL;
            if (on_staff) o_rgb = 24'h4E5C6A;
            if (on_bar)   o_rgb = 24'h5E6E7C;
            if (in_glow)  o_rgb = {lighten(o_rgb[23:16], i_flash_cur[3] ? 4'd3 : 4'd0),
                                   lighten(o_rgb[15:8],  i_flash_cur[3] ? 4'd3 : 4'd0),
                                   lighten(o_rgb[7:0],   i_flash_cur[3] ? 4'd3 : 4'd0)};
            if (hist0 || hist1 || hist2)
                o_rgb = {lighten(sc[23:16], 4'd1), lighten(sc[15:8], 4'd1), lighten(sc[7:0], 4'd1)};
            if (stem)     o_rgb = {lighten(sc[23:16], 4'd4), lighten(sc[15:8], 4'd4), lighten(sc[7:0], 4'd4)};
            if (head_bit) o_rgb = {lighten(sc[23:16], 4'd6), lighten(sc[15:8], 4'd6), lighten(sc[7:0], 4'd6)};
        end
    end
endmodule


//-----------------------------------------------------------------------------
// E：波形（网格 + 逐列 min/max 包络 + 中线）
//-----------------------------------------------------------------------------
module disp_v3_scope (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire signed [15:0] i_tmin,
    input  wire signed [15:0] i_tmax,
    input  wire [1:0]  i_gain_shift,
    input  wire        i_capture_valid,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire in_grid = (i_x >= `SC_GX) && (i_x < `SC_GX + `SC_GW) &&
                   (i_y >= `SC_GY) && (i_y < `SC_GY + `SC_GH);

    wire [10:0] rx = i_x - `SC_GX;
    wire [9:0]  ry = i_y - `SC_GY;

    wire grid_major = ((rx % 44) == 0) || ((ry % 44) == 0);
    wire grid_minor = ((rx % 22) == 0) || ((ry % 22) == 0);

    // 0.5 FS/div，6 格 -> 132 px；1 FS = 44 px。y = SC_MID - v*44
    wire signed [26:0] tmax_s = $signed(i_tmax) <<< i_gain_shift;
    wire signed [26:0] tmin_s = $signed(i_tmin) <<< i_gain_shift;
    wire signed [26:0] ytop   = 27'sd580 - ((tmax_s * 27'sd44) >>> 15);
    wire signed [26:0] ybot   = 27'sd580 - ((tmin_s * 27'sd44) >>> 15);
    wire on_trace = i_capture_valid && (i_y + 1 >= ytop[9:0]) && (i_y <= ybot[9:0] + 1);

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;
        if (in_grid) begin
            o_hit = 1'b1;
            o_rgb = 24'h08111A;
            if (i_y == `SC_MID) o_rgb = 24'h2E4553;
            if (grid_minor) o_rgb = 24'h101B23;
            if (grid_major) o_rgb = 24'h22333F;
            if (on_trace)   o_rgb = 24'h3FCBB4;
            if (on_trace && (i_y == ytop[9:0])) o_rgb = 24'hB8FFF0;
            if (on_trace && (i_y == ybot[9:0] + 1)) o_rgb = 24'h1E8C7C;
        end
    end
endmodule


//-----------------------------------------------------------------------------
// F：参数面板的图形部分（频谱柱 + 分栏线 + 行分隔线）
//   文字全部由文本层负责，本模块只画"线"和"柱"
//-----------------------------------------------------------------------------
module disp_v3_params (
    input  wire        i_clk,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire [63:0] i_bands,
    input  wire [63:0] i_band_pk,
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "disp_v3_funcs.vh"

    wire in_panel = (i_x > `F_X0) && (i_x < `F_X1) && (i_y > `F_Y0 + `HDR_H) && (i_y < `F_Y1 - 1);

    // 分栏下划线：UKULELE / VIOLIN 标题下沿
    wire under_a = (i_y == `PAR_Y0 - 10'd3) &&
                   (i_x >= `PAR_AX) && (i_x < `PAR_AX + `PAR_W + 8);
    wire under_b = (i_y == `PAR_Y0 - 10'd3) &&
                   (i_x >= `PAR_BX) && (i_x < `PAR_BX + `PAR_W + 8);
    // 行分隔
    wire [9:0] rr = i_y - `PAR_Y0;
    wire row_line = (i_y >= `PAR_Y0) && (i_y < `PAR_Y0 + 10'd64) && (rr[3:0] == 4'd15) &&
                    (((i_x >= `PAR_AX) && (i_x < `PAR_AX + `PAR_W + 8)) ||
                     ((i_x >= `PAR_BX) && (i_x < `PAR_BX + `PAR_W + 8)));
    // 分隔横线（参数区与频谱之间）
    wire sep = (i_y == 10'd596) && (i_x > `F_X0 + 10'd12) && (i_x < `F_X1 - 10'd12);

    // 频谱柱：8 段，每段 42 px（阈值链求索引，避免 10 位除法进组合路径）
    wire in_box = (i_x >= `SP_X) && (i_x < `SP_X + `SP_W) &&
                  (i_y >= `SP_Y) && (i_y < `SP_Y + `SP_H);
    wire [9:0] srx = i_x - `SP_X;
    wire [9:0] sry = i_y - `SP_Y;
    wire [9:0] sy  = sry + 10'd2;               // 柱区从 +2 开始，留 2 px 边距

    reg  [2:0] bi;
    always @(*) begin
        if      (srx >= 10'd294) bi = 3'd7;
        else if (srx >= 10'd252) bi = 3'd6;
        else if (srx >= 10'd210) bi = 3'd5;
        else if (srx >= 10'd168) bi = 3'd4;
        else if (srx >= 10'd126) bi = 3'd3;
        else if (srx >= 10'd84 ) bi = 3'd2;
        else if (srx >= 10'd42 ) bi = 3'd1;
        else                     bi = 3'd0;
    end

    wire [9:0] bofs = (bi << 5) + (bi << 3) + (bi << 1);      // bi*42
    wire [9:0] bs   = srx - bofs;
    wire [7:0] lev  = i_bands[bi*8 +: 8];
    wire [7:0] pk   = i_band_pk[bi*8 +: 8];
    wire [9:0] bh   = ({2'd0, lev} * 10'd36) >> 8;
    wire [9:0] ph   = ({2'd0, pk}  * 10'd36) >> 8;
    wire [9:0] btop = 10'd38 - bh;
    wire [9:0] ptop = 10'd38 - ph;

    wire in_bar = in_box && (bs >= 10'd3) && (bs < 10'd39) && (sy >= btop) && (sy < 10'd38);
    wire on_top = in_bar && (sy == btop);
    wire on_pk  = in_box && (bs >= 10'd3) && (bs < 10'd39) && (sy == ptop) && (pk > 8'd4);
    wire bar_div = in_box && ((sy == 10'd14) || (sy == 10'd30));

    always @(*) begin
        o_hit = 1'b0;
        o_rgb = 24'd0;
        if (in_panel) begin
            o_hit = 1'b1;
            o_rgb = `C_PANEL;
            if (under_a || under_b || row_line) o_rgb = `C_EDGE_DIM;
            if (sep) o_rgb = `C_EDGE_DIM;
        end
        if (in_box) begin
            o_hit = 1'b1;
            o_rgb = `C_WELL;
            if (bar_div) o_rgb = 24'h0E1720;
            if (in_bar)  o_rgb = (sy < 10'd16) ? `C_AMBER :
                                 (sy < 10'd30) ? 24'h7EE8B4 : `C_TEAL;
            if (on_top)  o_rgb = 24'hFFFFFF;
            if (on_pk)   o_rgb = 24'hC8D4DE;
        end
    end
endmodule
