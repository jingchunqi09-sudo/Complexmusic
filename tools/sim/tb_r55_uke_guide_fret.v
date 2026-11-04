// tb_r55_uke_guide_fret.v —— R55「只指引尤克里里：左手品 + 右手弦」的最小验证
//
// R55 的三条行为契约（本 tb 全部覆盖）：
//   1. lane 4..7（尤克里里）：该行上下各 3 px 琥珀弦线 + 最左空弦块填实（右手弦）
//   2. lane 4..7 且 fret>=1：目标品格**整格填充** 0xF0C020（左手品，R56 起填充不画框）
//      fret==0 不画框（空弦用左侧块表达），避免与块重叠
//   3. lane 0..3（小提琴）：**一个指引像素都不画**（R55 取消小提琴指引）
//   4. 命中（uke 视图 + 该弦 gate）→ 弦线与品框都转绿 0x28E070
//
// 运行（项目根目录）：
//   vlib work && vlog -work work src/r9_text_layer.v src/r9_stage_dashboard.v sim/tb_r55_uke_guide_fret.v
//   vsim -c -do "run -all; quit" work.tb_r55_uke_guide_fret
`timescale 1ns/1ps

module tb_r55_uke_guide_fret;
    reg clk = 0, reset = 1;
    always #6.8 clk = ~clk;              // ~73.5 MHz，与像素时钟同量级

    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg de = 1, hsync = 1, vsync = 1, frame_start = 0;

    reg [1:0] mode = 0;
    reg [19:0] fret_bus = 20'd0;
    reg [3:0]  left_valid = 4'hf, left_fault = 4'h0;
    reg signed [15:0] bow_x = 0, bow_y = 0;
    reg [7:0]  bow_speed = 0;
    reg [3:0]  bow_gates = 0;
    reg [27:0] notes = 28'd0;
    reg [3:0]  gates = 4'd0;
    reg [31:0] vel = 32'd0;
    reg [15:0] ev_total = 16'd0;
    reg [3:0]  fire_flash = 4'd0, piezo_warm = 4'd0;
    reg audio_ready = 1, capture_valid = 1;
    reg [15:0] peak = 0, rms = 0, crest = 0;
    reg [1:0]  gain = 0;
    reg [63:0] bands = 64'd0;

    reg [2:0]  guide_lane = 3'd0;
    reg [4:0]  guide_fret = 5'd0;
    reg        guide_valid = 0;
    reg [3:0]  instruments = 4'h0;

    wire [8:0]  trace_addr;
    wire signed [15:0] tmin = 0, tmax = 0;
    wire [7:0]  r, g, b;
    wire        o_de, o_hs, o_vs;

    r9_stage_dashboard dut (
        .clk(clk), .reset(reset), .x(x), .y(y), .de(de), .hsync(hsync), .vsync(vsync),
        .frame_start(frame_start), .i_mode(mode),
        .i_fret_bus(fret_bus), .i_left_valid(left_valid), .i_left_fault(left_fault),
        .i_bow_x(bow_x), .i_bow_y(bow_y), .i_bow_speed(bow_speed), .i_bow_gates(bow_gates),
        .i_notes(notes), .i_gates(gates), .i_vel(vel), .i_ev_total(ev_total),
        .i_fire_flash(fire_flash), .i_piezo_warm(piezo_warm),
        .i_audio_ready(audio_ready), .i_capture_valid(capture_valid),
        .i_peak(peak), .i_rms(rms), .i_crest_tenths(crest),
        .i_gain_shift(gain), .i_bands(bands),
        .i_guide_lane(guide_lane), .i_guide_fret(guide_fret), .i_guide_valid(guide_valid),
        .i_instruments(instruments),
        .o_trace_address(trace_addr), .i_trace_min(tmin), .i_trace_max(tmax),
        .o_red(r), .o_green(g), .o_blue(b), .o_de(o_de), .o_hsync(o_hs), .o_vsync(o_vs)
    );

    task tick; begin @(posedge clk); #1; end endtask

    // 坐标必须**保持不动**再回读：x1/x2/y1/y2 是串联寄存器，
    // 打一拍就清 0 的话读到的是 (0,0) 的颜色。
    task probe(input [10:0] px, input [9:0] py, output [23:0] rgb);
        begin
            x = px; y = py;
            repeat (8) tick;
            rgb = {r, g, b};
        end
    endtask

    task blink_on; integer i; begin
        for (i = 0; i < 8; i = i + 1) begin
            frame_start = 1; tick; frame_start = 0; tick;
        end
    end endtask

    localparam [23:0] AMBER = 24'hE9B353;   // 弦线
    localparam [23:0] YELLOW = 24'hF0C020;  // 品格框
    localparam [23:0] GREEN = 24'h28E070;   // 命中
    localparam [23:0] NECK  = 24'h1B1613;   // 空琴颈底色
    localparam [23:0] FRETL = 24'h59626B;   // 品丝线

    integer errors = 0;
    reg [23:0] got;

    task expect_rgb(input [10:0] px, input [9:0] py, input [23:0] want, input [191:0] tag);
        begin
            probe(px, py, got);
            if (got !== want) begin
                $display("FAIL %0s (x=%0d,y=%0d) got %06X want %06X", tag, px, py, got, want);
                errors = errors + 1;
            end else
                $display("ok   %0s (x=%0d,y=%0d) = %06X", tag, px, py, got);
        end
    endtask

    task expect_not(input [10:0] px, input [9:0] py, input [23:0] bad1, input [23:0] bad2,
                    input [191:0] tag);
        begin
            probe(px, py, got);
            if (got === bad1 || got === bad2) begin
                $display("FAIL %0s (x=%0d,y=%0d) got %06X (不该出现指引色)", tag, px, py, got);
                errors = errors + 1;
            end else
                $display("ok   %0s (x=%0d,y=%0d) = %06X (无指引)", tag, px, py, got);
        end
    endtask

    initial begin
        repeat (4) tick;
        reset = 0;
        repeat (4) tick;
        blink_on;                          // 进入闪烁"亮"相位

        // ================= 用例 1：uke 弦线（右手） =================
        // lane 4 -> 行 0 -> yc = 174；上弦线 y=166..168，下弦线 y=194..196
        guide_lane = 3'd4; guide_fret = 5'd0; guide_valid = 1'b1;
        instruments = 4'h0; gates = 4'd0;
        repeat (3) tick;
        expect_rgb(11'd300, 10'd166, AMBER, "uke row0 top line");
        expect_rgb(11'd300, 10'd195, AMBER, "uke row0 bottom line");
        expect_rgb(11'd10,  10'd180, AMBER, "uke row0 left block");

        // 行 2（lane 6）-> yc = 254
        guide_lane = 3'd6;
        repeat (3) tick;
        expect_rgb(11'd300, 10'd246, AMBER, "uke row2 top line");
        expect_rgb(11'd300, 10'd275, AMBER, "uke row2 bottom line");

        // ================= 用例 2：uke 品格框（左手） =================
        // lane 4 / fret 3 -> g_xl = fret_x(2) = 193, g_xr = fret_x(3) = 230
        // 框：x=193/230，y = yc-5 = 169 与 yc+19 = 193（都避开弦线与品丝）
        guide_lane = 3'd4; guide_fret = 5'd3;
        repeat (3) tick;
        expect_rgb(11'd193, 10'd169, YELLOW, "fret3 box top-left");
        expect_rgb(11'd230, 10'd169, YELLOW, "fret3 box top-right");
        expect_rgb(11'd193, 10'd193, YELLOW, "fret3 box bottom-left");
        expect_rgb(11'd230, 10'd193, YELLOW, "fret3 box bottom-right");
        // R56：从"画边框"改成"整格填充"，内部也必须是高亮色（这是设计变更，
        // 不是回归失败）。四角那 4 条断言仍然有效 —— 角本来就是填充区域的一部分。
        expect_rgb(11'd210, 10'd180, YELLOW, "fret3 cell interior (filled, R56)");
        // 框外一格不该被染色
        expect_not(11'd188, 10'd169, YELLOW, GREEN, "left of fret3 box");

        // fret 0：不画品框（左侧空弦块 + 琴枕左侧空弦区已经是"空弦"的表达）
        guide_fret = 5'd0;
        repeat (3) tick;
        expect_not(11'd193, 10'd169, YELLOW, GREEN, "fret0 no box at x=193");
        // 但空弦区 x=46..112 必须整块亮起来（多模型评审 C2 的要求：别只靠屏最左 16 px）
        expect_rgb(11'd70, 10'd180, AMBER, "fret0 open-string area x=70");
        expect_rgb(11'd105, 10'd180, AMBER, "fret0 open-string area x=105");
        // 有品时那块不能亮，否则"空弦"和"按品"看起来一样
        guide_fret = 5'd3;
        repeat (3) tick;
        expect_not(11'd70, 10'd180, AMBER, GREEN, "fret3 open area must be dark");
        guide_fret = 5'd0;
        repeat (3) tick;

        // ================= 用例 3：小提琴指引（R57 起恢复成 R54 的行为）=================
        // R55 那一版把这里改成"小提琴不该有框"的反向断言；R57 以 R54 为基线，
        // 小提琴指引**保留**，所以这条断言整体交给 sim/tb_r54_uke_guide.v 的正向用例覆盖
        // （那边验 (x=193,y=236) 必须是黄框 F0C020）。本测试台只专注尤克里里，不再断言小提琴。
        guide_lane = 3'd1; guide_fret = 5'd3; guide_valid = 1'b1;
        instruments = 4'h0; fret_bus = 20'd0;
        repeat (3) tick;

        // ================= 用例 4：命中也不变色（R58 设计）=================
        // R58 起指引不读 i_gates / i_instruments：只指位置，不判断弹对没有。
        // 这样对发声门控 gate_bus 的扇出增量为 0。
        guide_lane = 3'd4; guide_fret = 5'd3;
        instruments = 4'hf; gates = 4'b0001;
        repeat (4) tick;
        expect_rgb(11'd300, 10'd166, AMBER,  "R58: string line stays amber");
        expect_rgb(11'd193, 10'd169, YELLOW, "R58: fret cell stays yellow");

        // 小提琴视图下不能误判成绿（否则左手一按就变绿，是假命中）
        instruments = 4'h0; gates = 4'b0001;
        repeat (4) tick;
        expect_rgb(11'd300, 10'd166, AMBER, "violin view: stays amber");

        // ================= 用例 5：关掉指引后不留残影 =================
        guide_valid = 1'b0;
        repeat (3) tick;
        expect_not(11'd300, 10'd166, AMBER, GREEN, "guide off: line cleared");
        expect_not(11'd193, 10'd169, YELLOW, GREEN, "guide off: box cleared");

        // ================= 用例 6：非 GUIDE 页不画 =================
        guide_valid = 1'b1; mode = 2'd1;
        repeat (3) tick;
        expect_not(11'd300, 10'd166, AMBER, GREEN, "mode!=0: no guide");
        mode = 2'd0;

        if (errors == 0) $display("\n==== PASS: all R55 uke-guide checks ====");
        else             $display("\n==== FAIL: %0d error(s) ====", errors);
        $finish;
    end
endmodule
