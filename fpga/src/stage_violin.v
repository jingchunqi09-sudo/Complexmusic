//-----------------------------------------------------------------------------
// stage_violin.v —— 小提琴 + 琴弓方位图（右手反馈，2 拍流水绘制）
//
// 区域：x 440..735，y 88..480。上鼓/下鼓圆角矩形 + 收腰构成琴身（近似即可），
// 四根弦为竖线（颜色与琴颈一致）。琴弓为斜置长条（斜率 1/2），
// 弓心 X/Y 由鼠标位移积分驱动（bow_pos_x/bow_pos_y），
// 当前发声弦与弓线的交点画亮触弦点；底部弓速条带方向箭头。
//
// 时序（R7 修复视频域 Fmax）：拍 1 寄存各几何命中（圆角简化为矩形外框、
// 触弦点平行计算），拍 2 组合优先级选色。坐标→命中与命中→选色分拍。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_violin (
    input  wire        clk,
    input  wire [10:0] x,
    input  wire [9:0]  y,
    input  wire signed [15:0] bow_pos_x,
    input  wire signed [15:0] bow_pos_y,
    input  wire [3:0]  gate_bus,       // 当前运弓发声的弦
    input  wire [7:0]  bow_speed,
    input  wire        bow_dir,
    output reg         hit,
    output reg  [23:0] rgb
);

    // 琴身几何（矩形 + 收腰，外框统一判断；去掉圆角分段计算以缩短组合链）
    wire [10:0] dxu = (x > 588) ? x - 588 : 588 - x;   // |x-588|
    wire upper = (y >= 200) && (y < 292) && (dxu < 70);
    wire lower = (y >= 310) && (y < 442) && (dxu < 90);
    wire waist = (y >= 292) && (y < 310) && (dxu < 42);
    wire body = upper || lower || waist;
    wire body_edge = body && (
        (upper && (dxu > 66 || y < 204 || y >= 288)) ||
        (lower && (dxu > 86 || y < 314 || y >= 438)) ||
        (waist && (dxu > 38)));

    // 琴颈与弦纽
    wire neck = (x >= 578) && (x < 598) && (y >= 100) && (y < 204);
    wire pegbox = (x >= 570) && (x < 606) && (y >= 88) && (y < 102);

    // 四根弦（x 558/580/602/624，宽 2）
    wire string_line = (y >= 108) && (y < 420) &&
        ((x >= 558 && x < 560) || (x >= 580 && x < 582) ||
         (x >= 602 && x < 604) || (x >= 624 && x < 626));
    reg [1:0] string_idx;
    always @(*) begin
        if (x >= 558 && x < 560) string_idx = 0;
        else if (x >= 580 && x < 582) string_idx = 1;
        else if (x >= 602 && x < 604) string_idx = 2;
        else string_idx = 3;
    end
    reg [23:0] string_color;
    always @(*) begin
        case (string_idx)
            2'd0: string_color = 24'h00C8DC;
            2'd1: string_color = 24'hE6BE28;
            2'd2: string_color = 24'h3CC85A;
            default: string_color = 24'hDC46AA;
        endcase
    end

    // 琴弓：中心 (bx,by)，斜率 1/2，长 ±140，宽 5（弓毛 +2 白线）
    wire signed [15:0] bx = 16'sd588 + bow_pos_x;
    wire signed [15:0] by = 16'sd300 + bow_pos_y;
    wire signed [15:0] rx = $signed({1'b0,x}) - bx;
    wire signed [15:0] bow_line_y = by + (rx >>> 1);
    wire signed [15:0] bow_dy = $signed({1'b0,y}) - bow_line_y;
    wire in_bow_span = (rx >= -140) && (rx <= 140);
    wire bow_wood = in_bow_span && (bow_dy >= -2) && (bow_dy <= 2);
    wire bow_hair = in_bow_span && (bow_dy > 2) && (bow_dy <= 4);

    // 触弦点（平行计算，不用循环串联）：各弦独立求交点与命中，再合并
    wire signed [15:0] cx0 = 16'sd559, cx1 = 16'sd581, cx2 = 16'sd603, cx3 = 16'sd625;
    wire signed [15:0] cy0 = by + ((cx0 - bx) >>> 1);
    wire signed [15:0] cy1 = by + ((cx1 - bx) >>> 1);
    wire signed [15:0] cy2 = by + ((cx2 - bx) >>> 1);
    wire signed [15:0] cy3 = by + ((cx3 - bx) >>> 1);
    wire hit0 = gate_bus[0] && (x >= cx0-6) && (x <= cx0+6) && (y >= cy0-6) && (y <= cy0+6);
    wire hit1 = gate_bus[1] && (x >= cx1-6) && (x <= cx1+6) && (y >= cy1-6) && (y <= cy1+6);
    wire hit2 = gate_bus[2] && (x >= cx2-6) && (x <= cx2+6) && (y >= cy2-6) && (y <= cy2+6);
    wire hit3 = gate_bus[3] && (x >= cx3-6) && (x <= cx3+6) && (y >= cy3-6) && (y <= cy3+6);
    wire contact_hit = hit0 | hit1 | hit2 | hit3;
    wire [23:0] contact_color = hit0 ? 24'h00C8DC : hit1 ? 24'hE6BE28 :
                                hit2 ? 24'h3CC85A : 24'hDC46AA;

    // 弓速条：y 458..470，中心 588，长度=speed（0..255→0..127），方向决定左右
    wire [8:0] spd_len = bow_speed[7:1];
    wire speed_bar = (y >= 458) && (y < 470) &&
        (bow_dir ? ((x >= 588) && (x < 588+spd_len))
                 : ((x <= 588) && (x > 588-spd_len)));
    wire [23:0] speed_color = (bow_speed < 60) ? 24'h3CC85A :
                              (bow_speed < 150) ? 24'hE6BE28 : 24'hE05038;

    // 拍 1：寄存几何命中
    reg body_r, body_edge_r, neck_r, pegbox_r, string_line_r;
    reg [23:0] string_color_r;
    reg bow_wood_r, bow_hair_r, contact_hit_r;
    reg [23:0] contact_color_r;
    reg speed_bar_r;
    reg [23:0] speed_color_r;
    always @(posedge clk) begin
        body_r <= body; body_edge_r <= body_edge;
        neck_r <= neck; pegbox_r <= pegbox;
        string_line_r <= string_line; string_color_r <= string_color;
        bow_wood_r <= bow_wood; bow_hair_r <= bow_hair;
        contact_hit_r <= contact_hit; contact_color_r <= contact_color;
        speed_bar_r <= speed_bar; speed_color_r <= speed_color;
    end

    // 拍 2：组合优先级选色
    always @(*) begin
        hit = 1'b0; rgb = 24'h000000;
        if (body_r) begin
            hit = 1'b1;
            rgb = body_edge_r ? 24'h8A5A28 : 24'h5A3A18;
        end
        if (neck_r || pegbox_r) begin hit = 1'b1; rgb = 24'h4A3420; end
        if (string_line_r) begin hit = 1'b1; rgb = string_color_r; end
        if (bow_hair_r) begin hit = 1'b1; rgb = 24'hE8E8E0; end
        if (bow_wood_r) begin hit = 1'b1; rgb = 24'hA06A30; end
        if (contact_hit_r) begin hit = 1'b1; rgb = contact_color_r; end
        if (speed_bar_r) begin hit = 1'b1; rgb = speed_color_r; end
    end

endmodule

`default_nettype wire
