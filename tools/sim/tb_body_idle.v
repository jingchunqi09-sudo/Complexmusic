`timescale 1ns/1ps
//=============================================================================
// tb_body_idle.v — 琴体谐振器"零输入自激"检查（R22）
//
// 为什么要测：instrument_body_resonator_tdm 的每个模态是
//     error       = drive - position
//     velocity'   = velocity - damping*velocity + spring*error
//     position'   = position + velocity'
// 传递函数 H(z) = g(1-z^-1) / [1 - (2-d)z^-1 + (1-d+g)z^-2]，
// 极点半径 r = sqrt(1-d+g)。**稳定要求 spring < damping**。
// 按源码里的移位系数算出来：
//   小提琴分支 mode3  g=d      -> r=1.0000（临界）
//   小提琴分支 mode4  g>d      -> r=1.0232（2147 Hz）
//   小提琴分支 mode5  g>d      -> r=1.0607（3259 Hz）
//   尤克里里分支 mode1 临界，mode2..5 全部 r>1
// 如果这个推导成立，body 会在没有输入时持续自激，靠 position/velocity 的
// STATE_MAX 饱和限幅——那是一个持续的 1.4/2.1/3.3 kHz 蜂鸣，
// 会吃掉动态余量并产生非谐波成分（实测 inharm 9.5%）。
//
// 跑法：
//   vsim -c -lib work tb_body_idle -do "run -all; quit -f" +out=body_idle.txt
//=============================================================================
module tb_body_idle;
    localparam integer FRAME = 1024;
    localparam integer NFRAME = 400;

    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg start = 0;
    reg [35:0] sample_bus = 36'd0;
    reg [1:0]  trig = 2'b00;
    reg [1:0]  bypass = 2'b00;
    reg [1:0]  instrument = 2'b10;   // 与 instrument_bank_core 一致：bank1 = 小提琴分支
    wire [35:0] out_bus;
    wire [31:0] guards, clips;
    wire valid, ready;

    instrument_body_resonator_tdm #(
        .SAMPLE_WIDTH(18), .PRESERVE_BYPASS_STATE(1),
        .BODY0_VIOLIN_RADIATION_MIX(2), .BODY1_VIOLIN_RADIATION_MIX(0)
    ) u (
        .i_clk(clk), .i_reset(reset), .i_start(start),
        .i_trigger(trig), .i_bypass(bypass), .i_instrument(instrument),
        .i_sample_bus(sample_bus), .o_sample_bus(out_bus),
        .o_guard_count(guards), .o_clip_count(clips),
        .o_valid(valid), .o_ready(ready)
    );

    integer fd, f, phase;
    reg [1023:0] outfile;
    reg signed [17:0] b0, b1;
    integer b1_max = 0, b0_max = 0, nz = 0;

    initial begin
        if (!$value$plusargs("out=%s", outfile)) outfile = "body_idle.txt";
        fd = $fopen(outfile, "w");
        repeat (20) @(negedge clk);
        reset = 0;
        @(negedge clk);
    end

    // 每帧一次 start（等 ready），输入恒定 0
    always @(posedge clk) begin
        if (reset) begin
            phase <= 0; start <= 0;
        end else begin
            start <= 0;
            // 第 1 帧给一个 2000 的脉冲，之后恒 0：不稳定模态会把这个脉冲
            // 放大成持续振荡（零输入时零是平衡点，测不出来）
            sample_bus <= (f == 0) ? {18'sd2000, 18'sd2000} : 36'd0;
            phase <= (phase == FRAME - 1) ? 0 : phase + 1;
            if (phase == 100 && ready && f < NFRAME) start <= 1'b1;
            if (valid) begin
                b0 = out_bus[17:0];
                b1 = out_bus[35:18];
                $fwrite(fd, "%0d %0d\n", b0, b1);
                if (b0 > 0 ? b0 > b0_max : -b0 > b0_max) b0_max = (b0 > 0) ? b0 : -b0;
                if (b1 > 0 ? b1 > b1_max : -b1 > b1_max) b1_max = (b1 > 0) ? b1 : -b1;
                if (b1 != 0) nz = nz + 1;
                f = f + 1;
                if (f >= NFRAME) begin
                    $fclose(fd);
                    $display("DONE frames=%0d  bank0(uke)_max=%0d  bank1(violin)_max=%0d  nonzero_b1=%0d  guards=%0d clips=%0d",
                             f, b0_max, b1_max, nz, guards, clips);
                    $finish;
                end
            end
        end
    end

    initial begin
        f = 0; phase = 0;
        #2000000000;
        $display("TIMEOUT frames=%0d bank0_max=%0d bank1_max=%0d", f, b0_max, b1_max);
        $fclose(fd);
        $finish;
    end
endmodule
