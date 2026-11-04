`timescale 1ns/1ps
//=============================================================================
// tb_violin_probe.v — 单个 violin_waveguide_voice 的量化探针
//
// 目的：把"小提琴声音好不好"变成可测的数字。只驱动 1 个声部、参数全部由
// plusargs 给，输出 sample_index / pcm 两列，交给 scripts/analyze_violin.py 分析：
//   f0、各次谐波的 T60、频谱重心随时间、起振时间、峰值、直流。
//
// 驱动时序完全照抄 sim/physical_20261025/tb_independent_violin_range.v（生产配置）：
//   prepare 1 拍 → 32 拍 → tick 1 拍 → 29 拍，共 64 拍/样本。
//   与 bank 里 w_prepare_tick=r_phase==55 / w_model_tick=r_phase==88 的间隔等价。
//
// 用法：
//   vsim -c tb_violin_probe -gNOTE=69 -gVEL=192 -gSPEED=64 -gSAMPLES=4000 \
//        -do "run -all; quit -f" +OUTPUT=out.txt [+STOP_AT=2000]
//=============================================================================
module tb_violin_probe;
    parameter integer RATE      = 48828125;
    parameter integer SAMPLES   = 4000;   // 采集样本数（48.8 kSPS，4000 ≈ 82 ms）
    parameter integer NOTE      = 69;     // MIDI（69 = A4 440 Hz）
    parameter integer VEL       = 192;    // 弓压代理
    parameter integer SPEED     = 64;     // 弓速代理
    parameter integer STOP_AT   = 0;      // >0 时在该样本号抬弓（测余音）
    parameter integer DELAY_LEN = 1024;   // 与 bank 的 DELAY_LINE_LENGTH 默认值一致

    // instrument_pitch.vh 是函数库，展开时要求这两个名字已在作用域内
    localparam integer DELAY_LINE_LENGTH = DELAY_LEN;
    localparam integer SAMPLE_RATE_MILLIHZ = RATE;

    reg clk = 0, reset = 1, prepare = 0, tick = 0, trigger = 0, gate = 0, stop = 0;
    reg [31:0] period_q16;
    wire [15:0] pcm;
    wire ready;

    always #10 clk = ~clk;          // 50 MHz

    `include "src/instrument_pitch.vh"

    // 生产配置（与 instrument_bank_core.v:126-131 完全一致）
    violin_waveguide_voice #(
        .DELAY_LINE_LENGTH(DELAY_LEN), .SAMPLE_RATE_MILLIHZ(RATE),
        .SEPARATE_CONTROL_PREPARE(1), .ENABLE_MOVING_BOW_POSITION(1),
        .ENABLE_FINE_PITCH(1), .SHARE_INTERPOLATION_MULTIPLIER(1),
        .BOW_CONTROL_PROFILE(2)
    ) dut (
        .i_clk(clk), .i_reset(reset), .i_sample_tick(tick), .i_prepare_tick(prepare),
        .i_period_q16(period_q16), .i_stop(stop), .i_trigger(trigger), .i_gate(gate),
        .i_midi_note(NOTE[6:0]), .i_velocity(VEL[7:0]),
        .i_bow_speed(SPEED[15:0]), .i_bow_direction(1'b0),
        .i_bow_position(24'd0),
        .o_audio_sample(pcm), .o_ready(ready)
    );

    integer fd, n;
    reg [2047:0] output_path;

    initial begin
        if (!$value$plusargs("OUTPUT=%s", output_path)) $fatal(1, "OUTPUT required");
        fd = $fopen(output_path, "w");
        if (!fd) $fatal(1, "fopen failed");

        period_q16 = midi_period_q16(NOTE);

        reset = 1; gate = 0; trigger = 0; stop = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        repeat (1100) @(negedge clk);        // 等延迟线初始化
        if (ready !== 1'b1) $fatal(1, "voice not ready");

        gate = 1; trigger = 1;
        for (n = 0; n < SAMPLES; n = n + 1) begin
            if (n == 1)    trigger = 0;
            if (STOP_AT > 0 && n == STOP_AT) begin
                gate = 0; stop = 1;          // 抬弓：进入 BOW_OFF_DAMP 分支
            end
            @(negedge clk); prepare = 1; @(negedge clk); prepare = 0;
            repeat (32) @(negedge clk);
            tick = 1; @(negedge clk); tick = 0;
            if (^pcm === 1'bx) $fatal(1, "X in pcm");
            $fwrite(fd, "%0d %0d\n", n, $signed(pcm));
            repeat (29) @(negedge clk);
        end
        $fclose(fd);
        $display("PROBE note=%0d vel=%0d speed=%0d samples=%0d stop_at=%0d",
                 NOTE, VEL, SPEED, SAMPLES, STOP_AT);
        $finish;
    end
endmodule
