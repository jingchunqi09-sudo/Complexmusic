//-----------------------------------------------------------------------------
// tb_stage.v —— 显示子模块像素级验证（琴颈/小提琴/字体/文本/数字/波形RAM）
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_stage;
    integer errors = 0;
    integer checks = 0;

    // 字体
    reg [7:0] fc;
    reg [2:0] fr;
    wire [4:0] fbits;
    stage_font u_font(.char_code(fc), .row(fr), .bits(fbits));

    // 琴颈
    reg [10:0] x;
    reg [9:0]  y;
    reg [19:0] fret_bus = 0;
    reg [3:0]  lvalid = 4'hf, lfault = 0;
    wire fb_hit;
    wire [23:0] fb_rgb;
    stage_fretboard u_fb(.x(x), .y(y), .fret_bus(fret_bus), .valid_mask(lvalid),
        .fault_mask(lfault), .hit(fb_hit), .rgb(fb_rgb));

    // 小提琴
    reg vclk = 0;
    always #10 vclk = ~vclk;
    reg signed [15:0] bpx = 0, bpy = 0;
    reg [3:0] bgates = 0;
    reg [7:0] bspeed = 0;
    reg bdir = 0;
    wire vn_hit;
    wire [23:0] vn_rgb;
    stage_violin u_vn(.clk(vclk), .x(x), .y(y), .bow_pos_x(bpx), .bow_pos_y(bpy),
        .gate_bus(bgates), .bow_speed(bspeed), .bow_dir(bdir), .hit(vn_hit), .rgb(vn_rgb));

    // 文本与数字
    wire t_hit, n_hit;
    stage_text #(.TEXT("CH1"), .LEN(3), .X0(100), .Y0(100)) u_txt(.x(x), .y(y), .hit(t_hit));
    stage_number #(.DIGITS(4), .X0(200), .Y0(100)) u_num(.x(x), .y(y), .bcd(20'h01234), .hit(n_hit));

    // 波形 RAM（双时钟）
    reg wr_clk = 0, rd_clk = 0;
    always #10 wr_clk = ~wr_clk;
    always #7 rd_clk = ~rd_clk;
    reg reset = 1;
    reg sv = 0;
    reg [1:0] sch = 0;
    reg [15:0] ay = 0;
    reg [7:0] ra = 0;
    wire [15:0] rd0, rd1, rd2, rd3;
    piezo_wave_bank u_wb(.wr_clk(wr_clk), .rd_clk(rd_clk), .reset(reset),
        .sample_valid(sv), .channel(sch), .ay(ay), .rd_addr(ra),
        .rd_data0(rd0), .rd_data1(rd1), .rd_data2(rd2), .rd_data3(rd3));

    task check;
        input cond;
        input [8*80-1:0] msg;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL stage: %0s", msg);
            end
        end
    endtask

    integer i;
    initial begin
        // ---- 字体 ----
        fc = "A"; fr = 0; #1;
        check(fbits == 5'b01110, "font A row0");
        fc = "A"; fr = 3; #1;
        check(fbits == 5'b11111, "font A row3 full bar");
        fc = "0"; fr = 0; #1;
        check(fbits == 5'b01110, "font 0 row0");
        fc = " "; fr = 0; #1;
        check(fbits == 5'b00000, "font space blank");

        // ---- 琴颈：弦0按品3（fret=3）→ 第3格中心为青色 ----
        fret_bus[4:0] = 5'd3;
        x = 24 + 2*24 + 12; y = 100 + 22; #1;   // 第3品中央
        check(fb_hit && fb_rgb == 24'h00C8DC, "fretboard string0 fret3 cyan");
        x = 24 + 4*24 + 12; y = 100 + 22; #1;   // 第5品（未按）
        check(!(fb_hit && fb_rgb == 24'h00C8DC), "fretboard other fret not highlighted");
        // 弦1按品5 → 黄色
        fret_bus[9:5] = 5'd5;
        x = 24 + 4*24 + 12; y = 100 + 64 + 22; #1;
        check(fb_hit && fb_rgb == 24'hE6BE28, "fretboard string1 fret5 yellow");
        // 空弦：弦0 fret=0 → nut 块亮
        fret_bus[4:0] = 5'd0;
        x = 10; y = 100 + 22; #1;
        check(fb_hit && fb_rgb == 24'h00C8DC, "fretboard open string nut block");
        // 品号数字区存在笔画（品3 的 '3' 在某列有 hit）
        fret_bus[4:0] = 5'd3;

        // ---- 小提琴：弓心(588,300) 弓木命中（内部 2 拍流水，等 2 拍） ----
        x = 588; y = 300; #1;
        repeat(2) @(posedge vclk); #1;
        check(vn_hit && vn_rgb == 24'hA06A30, "violin bow wood at center");
        // 弦线 x=580（弦1）为黄色
        x = 580; y = 200; #1;
        repeat(2) @(posedge vclk); #1;
        check(vn_hit && vn_rgb == 24'hE6BE28, "violin string1 yellow line");
        // 琴身内部
        x = 588; y = 250; #1;
        repeat(2) @(posedge vclk); #1;
        check(vn_hit, "violin body present");
        // 触弦点：gate 弦0（x=559）在弓线上应亮
        bgates = 4'b0001;
        x = 559; y = 300 + ((559-588)/2); #1;
        repeat(2) @(posedge vclk); #1;
        check(vn_hit && vn_rgb == 24'h00C8DC, "violin contact point on bowed string0");
        bgates = 0;

        // ---- 文本 'C'（CH1 首字符）在笔画上有 hit ----
        x = 100 + 1; y = 100 + 1; #1;           // 'C' 的左上圆弧区
        // 'C' row1 = 10001，bit4(左)=1 → col0 命中
        x = 100; y = 101; #1;
        check(t_hit, "text CH1 C stroke");
        // 数字 1234 的第一位 '1'：'1' row0=00100（中央竖），col2 命中
        x = 200 + 2; y = 100; #1;
        check(n_hit, "number 1234 leading 1 stroke");

        // ---- 波形 RAM：ch0 写 16 个样本（峰值 500）→ 产生 1 点 ----
        reset = 0;
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge wr_clk); sv = 1; sch = 0; ay = 500;
            @(negedge wr_clk); sv = 0;
        end
        // 再写 ch0 第二个 16 样本（峰值 300）
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge wr_clk); sv = 1; sch = 0; ay = 300;
            @(negedge wr_clk); sv = 0;
        end
        // rd_addr=255 为最新点（第 2 点 =300），rd_addr=254 为前一点（500）
        ra = 255; @(posedge rd_clk); @(posedge rd_clk); #1;
        check(rd0 == 300, "wave bank newest point = 300");
        ra = 254; @(posedge rd_clk); @(posedge rd_clk); #1;
        check(rd0 == 500, "wave bank previous point = 500 (peak held)");

        if (errors == 0) $display("PASS tb_stage: %0d checks", checks);
        else $display("FAIL tb_stage: %0d errors of %0d checks", errors, checks);
        $finish;
    end
    initial begin #1000000; $display("FAIL tb_stage timeout"); $finish; end
endmodule

`default_nettype wire
