`timescale 1ns/1ps
//=============================================================================
// tb_violin_bridge.v — 小提琴波导桥端滤波改造（R21）的 RTL 级验收台
//
// 为什么要有这个台子：
//   之前所有关于"锯木头"的结论都来自 Python 定点模型，RTL 一次都没测过音高/频谱。
//   这次改的是环路内部的滤波器，任何一点延迟对不齐都会体现为音高偏差，
//   所以必须在 RTL 上直接量 o_audio_sample。
//
// 驱动严格对齐 instrument_bank_core:131-138 的真实接法：
//   SAMPLE_RATE_MILLIHZ=48828125, SEPARATE_CONTROL_PREPARE=1,
//   ENABLE_MOVING_BOW_POSITION=1, ENABLE_FINE_PITCH=1, SHARE_INTERPOLATION_MULTIPLIER=1
//   每帧 1024 clk：i_prepare_tick @55，i_sample_tick @88（与 bank 的 55/88 一致）
//
// 两个必须注意的接法（踩过）：
//   1. trigger 必须与 i_sample_tick **同一拍**：模块只在 `else if (i_sample_tick)`
//      分支里采样 w_cold_trigger（violin_waveguide_voice.v:838,918），异步单拍会被丢掉。
//   2. gate 要等冷触发之后才有效：w_contact_allowed 里带 `!r_require_cold_start || i_trigger`。
//
// 跑法：
//   vsim -c -lib work tb_violin_bridge -do "run -all; quit -f" +out=wave.txt
//=============================================================================
module tb_violin_bridge;
    // 周期补偿扫描用编译期宏（vsim -g 对本工程不可靠，实测会被改写成别的值）：
    //   vlog +define+COMP_Q16_DEF=196608 tb_violin_bridge.v
`ifdef COMP_Q16_DEF
    parameter integer COMP_Q16 = `COMP_Q16_DEF;
`else
    parameter integer COMP_Q16 = 152906;
`endif
    localparam integer FRAME      = 1024;      // 50 MHz / 48828.125 Hz
    localparam integer NSAMP      = 12000;     // 0.245 s
    localparam integer PREPARE_PH = 55;
    localparam integer SAMPLE_PH  = 88;

    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    integer phase = 0;
    integer nsent = 0;
    reg prepare_tick = 0, sample_tick = 0;
    reg stop = 0, gate = 0, started = 0;
    reg [6:0]  midi  = 7'd69;          // A4 = 440 Hz
    reg [7:0]  vel   = 8'd192;
    reg signed [15:0] speed = 16'sd64;
    reg        dir   = 1'b0;
    reg [23:0] pos   = 24'd0;
    reg [31:0] period_q16 = 32'd7272705;   // (48828.125/440) * 65536

    wire signed [15:0] audio;
    wire ready;

    // 触发：与 sample_tick 同拍，只打一次
    wire trigger = ready && !started && sample_tick;

    violin_waveguide_voice #(
        .SAMPLE_RATE_MILLIHZ(48828125),
        .SEPARATE_CONTROL_PREPARE(1),
        .ENABLE_MOVING_BOW_POSITION(1),
        .ENABLE_FINE_PITCH(1),
        .SHARE_INTERPOLATION_MULTIPLIER(1),
        .BOW_IIR_DELAY_Q16(COMP_Q16)
    ) dut (
        .i_clk(clk), .i_reset(reset),
        .i_sample_tick(sample_tick), .i_prepare_tick(prepare_tick),
        .i_period_q16(period_q16),
        .i_trigger(trigger), .i_stop(stop), .i_gate(gate),
        .i_midi_note(midi), .i_velocity(vel),
        .i_bow_speed(speed), .i_bow_direction(dir), .i_bow_position(pos),
        .o_audio_sample(audio), .o_ready(ready)
    );

    integer fd;
    reg [1023:0] outfile;

    integer arg_note, arg_period;
    initial begin
        if (!$value$plusargs("out=%s", outfile)) outfile = "wave.txt";
        if ($value$plusargs("note=%d", arg_note))     midi = arg_note[6:0];
        if ($value$plusargs("period=%d", arg_period)) period_q16 = arg_period;
        fd = $fopen(outfile, "w");
        if (fd == 0) begin
            $display("FATAL cannot open output file");
            $finish;
        end
        repeat (20) @(negedge clk);
        $display("CFG COMP_Q16=%0d  dut.BOW_IIR_DELAY_Q16=%0d  period_q16=%0d  shift=%0d  note=%0d",
                 COMP_Q16, dut.BOW_IIR_DELAY_Q16, period_q16, dut.BOW_IIR_SHIFT, midi);
        reset = 0;
    end

    always @(posedge clk) begin
        if (reset) begin
            phase <= 0; prepare_tick <= 0; sample_tick <= 0; gate <= 0;
        end else begin
            prepare_tick <= 0;
            sample_tick  <= 0;
            phase <= (phase == FRAME - 1) ? 0 : phase + 1;
            if (phase == PREPARE_PH) prepare_tick <= 1'b1;
            if (phase == SAMPLE_PH)  sample_tick  <= 1'b1;

            if (trigger) begin
                started <= 1'b1;
                gate    <= 1'b1;      // 冷触发之后一直按住 gate（模拟持续运弓）
            end

            // 记录输出：sample_tick 之后 8 拍取（流水线已稳定）
            if (prepare_tick && started && nsent < 4)
                $display("PREP total=%0d frac=%0d bridge_len=%0d neck_len=%0d period_q16=%0d",
                         dut.w_total_delay, dut.w_delay_fraction_q8,
                         dut.r_bridge_length_stage2, dut.r_neck_length_stage2,
                         dut.r_note_period_stage1);
            if (phase == SAMPLE_PH + 8 && started) begin
                $fwrite(fd, "%0d\n", audio);
                if (nsent >= NSAMP) begin
                    $fclose(fd);
                    $display("DONE samples=%0d", nsent + 1);
                    $finish;
                end
                nsent <= nsent + 1;
            end
        end
    end

    initial begin
        #400000000;   // 400 ms 超时保护
        $display("TIMEOUT samples=%0d", nsent);
        $fclose(fd);
        $finish;
    end
endmodule
