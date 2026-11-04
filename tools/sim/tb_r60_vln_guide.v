//-----------------------------------------------------------------------------
// tb_r60_vln_guide.v — R60：小提琴品格指引（lane 0..3）必须真的画出来
//
// 背景：R54 的那段代码写的是 `i_guide_lane < 2'd4`，而 **2 位常量 2'd4 实际等于 0**，
// 条件恒假 —— 所以 R54 的小提琴指引框从来没显示过，综合器还把整块优化掉了。
// R58 干脆把小提琴指引整段删除。R60 按用户"只显示指引、不显示实时按压"的要求重建：
//   只用 i_guide_lane / i_guide_fret / i_guide_valid / i_mode + 像素坐标，
//   **不读 i_fret_bus / i_left_valid**（那会像 R44/R57 一样给左手总线加负载）。
//
// 本测试台只验证"画出来了、画在对的行、颜色对、关掉就没了"。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_r60_vln_guide;
    reg clk = 0, reset = 1, de = 1, hsync = 0, vsync = 0, frame_start = 0;
    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg [1:0]  mode = 0;
    reg [19:0] fret_bus = 0;
    reg [3:0]  left_valid = 0, left_fault = 0;
    reg signed [15:0] bow_x = 0, bow_y = 0;
    reg [7:0]  bow_speed = 0;
    reg [3:0]  bow_gates = 0;
    reg [27:0] notes = 0;
    reg [3:0]  gates = 0;
    reg [31:0] vel = 0;
    reg [15:0] ev_total = 0, peak = 0, rms = 0, crest = 0;
    reg [3:0]  fire_flash = 0, piezo_warm = 0;
    reg audio_ready = 1, capture_valid = 0;
    reg [1:0]  gain_shift = 0;
    reg [63:0] bands = 0;
    reg [2:0]  guide_lane = 0;
    reg [4:0]  guide_fret = 0;
    reg        guide_valid = 0;
    reg [3:0]  instruments = 0;
    reg signed [15:0] tmin = 0, tmax = 0;

    wire [8:0]  trace_addr;
    wire [7:0]  r, g, b;
    wire        o_de, o_hs, o_vs;

    localparam [23:0] AMBER = 24'hE9B353;
    localparam [23:0] YELLOW = 24'hF0C020;

    r9_stage_dashboard dut (
        .clk(clk), .reset(reset), .x(x), .y(y), .de(de),
        .hsync(hsync), .vsync(vsync), .frame_start(frame_start),
        .i_mode(mode),
        .i_fret_bus(fret_bus), .i_left_valid(left_valid), .i_left_fault(left_fault),
        .i_bow_x(bow_x), .i_bow_y(bow_y), .i_bow_speed(bow_speed), .i_bow_gates(bow_gates),
        .i_notes(notes), .i_gates(gates), .i_vel(vel),
        .i_ev_total(ev_total), .i_fire_flash(fire_flash), .i_piezo_warm(piezo_warm),
        .i_audio_ready(audio_ready), .i_capture_valid(capture_valid),
        .i_peak(peak), .i_rms(rms), .i_crest_tenths(crest),
        .i_gain_shift(gain_shift), .i_bands(bands),
        .i_guide_lane(guide_lane), .i_guide_fret(guide_fret), .i_guide_valid(guide_valid),
        .i_instruments(instruments),
        .o_trace_address(trace_addr),
        .i_trace_min(tmin), .i_trace_max(tmax),
        .o_red(r), .o_green(g), .o_blue(b),
        .o_de(o_de), .o_hsync(o_hs), .o_vsync(o_vs)
    );

    always #10 clk = ~clk;

    // guide_blink = gd_frame[3]，而 gd_frame 只在 frame_start 时 +1。
    // 不驱动 frame_start 的话闪烁位永远是 0，指引一笔都画不出来
    // （第一版测试台就是漏了这个，表现为"got 251a14"）。
    integer fs_cnt = 0;
    always @(posedge clk) begin
        fs_cnt      <= fs_cnt + 1;
        frame_start <= (fs_cnt[1:0] == 2'd0);   // 每 4 拍一个 1 拍宽的脉冲
    end

    integer errors = 0;
    integer i;
    reg [23:0] got;

    task tick; begin @(posedge clk); #1; end endtask

    // 打到某坐标后**保持不动**再读（x1/x2/y1/y2 是串联寄存，清零会读到 (0,0) 的颜色）
    task probe(input [10:0] px, input [9:0] py);
        begin
            x = px; y = py; tick;
            repeat (6) tick;
            got = {r, g, b};
        end
    endtask

    task expect_rgb(input [10:0] px, input [9:0] py, input [23:0] want, input [255:0] name);
        begin
            probe(px, py);
            if (got !== want) begin
                $display("FAIL %0s @(%0d,%0d) got %06X want %06X", name, px, py, got, want);
                errors = errors + 1;
            end else
                $display("ok   %0s @(%0d,%0d) = %06X", name, px, py, got);
        end
    endtask

    task expect_not(input [10:0] px, input [9:0] py, input [23:0] bad, input [255:0] name);
        begin
            probe(px, py);
            if (got === bad) begin
                $display("FAIL %0s @(%0d,%0d) 不该是 %06X", name, px, py, got);
                errors = errors + 1;
            end else
                $display("ok   %0s @(%0d,%0d) = %06X (not %06X)", name, px, py, got, bad);
        end
    endtask

    initial begin
        repeat (5) tick;
        reset = 0;
        mode  = 2'd0;              // GUIDE 页
        repeat (10) tick;

        // ---- 用例 1：第二弦空弦（lane=1, fret=0）→ 行 y=214，空弦区 x 46..112 填实 ----
        guide_lane = 3'd1; guide_fret = 5'd0; guide_valid = 1'b1;
        // 等闪烁位为 1 的半周期（指引只在 guide_blink=1 时画）
        for (i = 0; i < 40 && !dut.guide_blink; i = i + 1) tick;
        repeat (3) tick;
        expect_rgb(11'd70, 10'd220, AMBER, "vln 第二弦空弦 空弦区");
        // 同一行、但行外（y=200 属于上一行区间）不该是 AMBER
        expect_not(11'd70, 10'd200, AMBER, "vln 空弦行外");

        // ---- 用例 2：第三弦 2 品（lane=2, fret=2）→ 行 y=254，品格格填实 F0C020 ----
        guide_lane = 3'd2; guide_fret = 5'd2;
        repeat (3) tick;
        // 扫这一行，找到至少一个 F0C020 像素
        got = 24'h000000;
        begin : scan2
            integer xx;
            reg [23:0] c;
            for (xx = 46; xx < 560; xx = xx + 1) begin
                x = xx[10:0]; y = 10'd258; tick; repeat (2) tick;
                c = {r, g, b};
                if (c === YELLOW) got = c;
            end
        end
        if (got !== YELLOW) begin
            $display("FAIL 第三弦2品 品格格没画出来（扫整行无 F0C020）");
            errors = errors + 1;
        end else
            $display("ok   第三弦2品 品格格已画 (F0C020)");

        // ---- 用例 3：第一弦 5 品（lane=0, fret=5）→ 行 y=174 ----
        guide_lane = 3'd0; guide_fret = 5'd5;
        repeat (3) tick;
        got = 24'h000000;
        begin : scan3
            integer xx;
            reg [23:0] c;
            for (xx = 46; xx < 560; xx = xx + 1) begin
                x = xx[10:0]; y = 10'd178; tick; repeat (2) tick;
                c = {r, g, b};
                if (c === YELLOW) got = c;
            end
        end
        if (got !== YELLOW) begin
            $display("FAIL 第一弦5品 品格格没画出来");
            errors = errors + 1;
        end else
            $display("ok   第一弦5品 品格格已画 (F0C020)");

        // ---- 用例 4：关掉指引 → 什么都不该有 ----
        guide_valid = 1'b0;
        repeat (3) tick;
        expect_not(11'd70, 10'd220, AMBER, "vln 关闭后不画");
        expect_not(11'd70, 10'd180, YELLOW, "vln 关闭后无品格");

        // ---- 用例 5：lane>=4（尤克里里）不该走小提琴分支 ----
        guide_lane = 3'd4; guide_fret = 5'd0; guide_valid = 1'b1;
        repeat (3) tick;
        expect_not(11'd70, 10'd220, AMBER, "vln lane4 不误画");

        if (errors == 0) $display("PASS vln guide");
        else             $display("FAIL vln guide errors=%0d", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL timeout");
        $finish;
    end
endmodule

`default_nettype wire
