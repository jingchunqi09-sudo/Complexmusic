// tb_r54_uke_guide.v —— R54 尤克里里弦指引的最小球验证
//
// 目标：证明 GUIDE 页在 i_guide_lane >= 4 时，琴颈对应行的上下各出现 3 px
//       琥珀提示线（0xE9B353），而 lane 0..3 的原有品位框行为不变。
//
// 做法：直接驱动 r9_stage_dashboard 的 x/y 扫描坐标，等 4 级流水后读 RGB。
//       gd_frame[3] 是闪烁位，需要 8 个 frame_start 才置 1 —— 先跑 8 帧再测。
//
// 运行（项目根目录）：
//   vlib work && vlog -work work src/r9_text_layer.v src/r9_stage_dashboard.v sim/tb_r54_uke_guide.v
//   vsim -c -do "run -all; quit" work.tb_r54_uke_guide
`timescale 1ns/1ps

module tb_r54_uke_guide;
    reg clk = 0, reset = 1;
    always #6.8 clk = ~clk;          // ~73.5 MHz，与实际像素时钟同量级

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

    // 打到某一坐标并**保持不动**，等流水填满后回读颜色。
    // 注意不能"打一拍再清 0"：x1/x2/y1/y2 是串联寄存，清 0 后输出拿的是 (0,0) 的颜色。
    task probe(input [10:0] px, input [9:0] py, output [23:0] rgb);
        begin
            x = px; y = py;
            repeat (8) tick;
            rgb = {r, g, b};
        end
    endtask

    // 8 个 frame_start，让 gd_frame[3] 置 1（闪烁"亮"相位）
    task blink_on; integer i; begin
        for (i = 0; i < 8; i = i + 1) begin
            frame_start = 1; tick; frame_start = 0; tick;
        end
    end endtask

    localparam [23:0] AMBER = 24'hE9B353;
    localparam [23:0] GREEN = 24'h28E070;
    localparam [23:0] NECK  = 24'h1B1613;   // 空琴颈底色

    integer errors = 0;
    reg [23:0] got;

    task check_amber(input [10:0] px, input [9:0] py, input [127:0] tag);
        begin
            probe(px, py, got);
            if (got !== AMBER) begin
                $display("FAIL %0s  (x=%0d,y=%0d) got %06X want %06X", tag, px, py, got, AMBER);
                errors = errors + 1;
            end else
                $display("ok   %0s  (x=%0d,y=%0d) = %06X", tag, px, py, got);
        end
    endtask

    initial begin
        repeat (4) tick;
        reset = 0;
        repeat (4) tick;

        blink_on;      // 进入闪烁"亮"相位

        // ---- 用例 1：uke lane 4（第 0 行，yc=174），上边线在 y = 174-8 = 166 ----
        guide_lane = 3'd4; guide_fret = 5'd0; guide_valid = 1'b1;
        instruments = 4'h0; gates = 4'd0;     // 还没在弹 uke -> 应为琥珀
        repeat (3) tick;
        check_amber(11'd300, 10'd166, "uke row0 top edge");
        check_amber(11'd300, 10'd195, "uke row0 bottom edge");
        check_amber(11'd10,  10'd180, "uke row0 left block");

        // ---- 用例 2：uke lane 6（第 2 行，yc=174+80=254） ----
        guide_lane = 3'd6;
        repeat (3) tick;
        check_amber(11'd300, 10'd246, "uke row2 top edge");
        check_amber(11'd300, 10'd275, "uke row2 bottom edge");

        // ---- 用例 3：命中也不变色（R58 设计：指引不读 i_gates / i_instruments）----
        // 这是刻意的：指引只负责"告诉你该弹哪根弦、哪个品"，不判断弹对没有。
        // 这样对发声门控 gate_bus 的扇出增量为 0，与发声链彻底无关。
        guide_lane = 3'd4; instruments = 4'hf; gates = 4'b0001;
        repeat (3) tick;
        probe(11'd300, 10'd166, got);
        if (got !== AMBER) begin
            $display("FAIL R58 起命中也不该变色（指引不参与发声判断），got %06X", got);
            errors = errors + 1;
        end else
            $display("ok   guide stays amber even when string rings (R58) %06X", got);

        // ---- 用例 4：小提琴视图下同样保持琥珀（不再有"误判成绿"的可能）----
        instruments = 4'h0; gates = 4'b0001;
        repeat (3) tick;
        probe(11'd300, 10'd166, got);
        if (got !== AMBER) begin
            $display("FAIL violin view must stay amber, got %06X", got);
            errors = errors + 1;
        end else
            $display("ok   violin view stays amber %06X", got);

        // ---- 用例 5：小提琴指引（**R58 已删除**，这里断言"不该有任何指引色"） ----
        // 删除理由是硬的：它的命中判定读 i_fret_bus[i_guide_lane*5 +: 5] 与
        // i_left_valid[i_guide_lane]，等于给左手选品总线加负载（R44 同型事故）。
        // 所以 lane=1 / fret=3 在 x=193、y=222..236 这一带必须回到品丝色 59626B 或底色。
        guide_lane = 3'd1; guide_fret = 5'd3; guide_valid = 1'b1;
        instruments = 4'h0; fret_bus = 20'd0;
        blink_on;
        while (!dut.guide_blink) blink_on;
        repeat (3) tick;
        probe(11'd193, 10'd236, got);
        if (got === 24'hF0C020 || got === 24'h28E070 || got === AMBER) begin
            $display("FAIL R58 起小提琴不该再有指引色，got %06X", got);
            errors = errors + 1;
        end else
            $display("ok   violin guide removed (R58), got %06X", got);
        probe(11'd230, 10'd222, got);
        if (got === 24'hF0C020 || got === 24'h28E070) begin
            $display("FAIL 小提琴右上角仍有余色，got %06X", got);
            errors = errors + 1;
        end else
            $display("ok   violin top-right corner clear (R58), got %06X", got);

        // ---- 用例 6：uke 关掉后不该留下残影 ----
        guide_valid = 1'b0;
        repeat (3) tick;
        probe(11'd300, 10'd166, got);
        if (got === AMBER || got === GREEN) begin
            $display("FAIL uke guide should disappear, got %06X", got);
            errors = errors + 1;
        end else
            $display("ok   uke guide cleared (%06X)", got);

        if (errors == 0) $display("\n==== PASS: all uke-guide checks ====");
        else             $display("\n==== FAIL: %0d error(s) ====", errors);
        $finish;
    end
endmodule
