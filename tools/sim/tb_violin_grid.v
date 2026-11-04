`timescale 1ns/1ps
//=============================================================================
// tb_violin_grid.v — 小提琴波导的音色扫描台（R22）
//
// 与 tb_violin_bridge.v 的区别：那个台子只验音准（单一工况、短窗口），
// 这个台子按网格扫 弓速 × 弓压 × 弓位，用来把"锯感"量化成指标：
//   * 谐波幅度表 h1..h24 与**相位**（理想锯齿 = 全部同相；真实弓弦 = 不同相）
//   * Helmholtz corner 宽度（半个周期内从峰到谷跨多少个采样）
//   * 包络稳定性（分段 RMS 的起伏）
//   * 非谐波残差（总能量减去谐波能量）
//
// 驱动严格对齐 instrument_bank_core 的真实接法（同 tb_violin_bridge.v）：
//   每帧 1024 clk，i_prepare_tick @55，i_sample_tick @88，
//   SEPARATE_CONTROL_PREPARE=1 / ENABLE_MOVING_BOW_POSITION=1 /
//   ENABLE_FINE_PITCH=1 / SHARE_INTERPOLATION_MULTIPLIER=1
//
// 跑法（参数用 plusargs，不用 -g，-g 在本工程不可靠）：
//   vsim -c -lib work tb_violin_grid -do "run -all; quit -f" \
//        +out=g.txt +speed=64 +vel=192 +pos=0 +note=69 +nsamp=24000
//=============================================================================
module tb_violin_grid;
`ifdef COMP_Q16_DEF
    parameter integer COMP_Q16 = `COMP_Q16_DEF;
`else
    parameter integer COMP_Q16 = 154010;
`endif
    localparam integer FRAME      = 1024;
    localparam integer PREPARE_PH = 55;
    localparam integer SAMPLE_PH  = 88;

    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    integer phase = 0;
    integer nsent = 0;
    reg prepare_tick = 0, sample_tick = 0;
    reg stop = 0, gate = 0, started = 0;
    reg [6:0]  midi  = 7'd69;
    reg [7:0]  vel   = 8'd192;
    reg signed [15:0] speed = 16'sd64;
    reg        dir   = 1'b0;
    reg [23:0] pos   = 24'd0;
    reg [31:0] period_q16 = 32'd7272705;

    // 运行期可改的持续时间
    integer nsamp = 24000;

    wire signed [15:0] audio;
    wire ready;

    wire trigger = ready && !started && sample_tick;

    violin_waveguide_voice #(
        .SAMPLE_RATE_MILLIHZ(48828125),
        .SEPARATE_CONTROL_PREPARE(1),
        .ENABLE_MOVING_BOW_POSITION(1),
        .ENABLE_FINE_PITCH(1),
        .SHARE_INTERPOLATION_MULTIPLIER(1),
        .BOW_IIR_DELAY_Q16(COMP_Q16)
`ifdef PROFILE_DEF
        , .BOW_CONTROL_PROFILE(`PROFILE_DEF)
`endif
`ifdef RATIO_DEF
        , .BOW_RATIO_BASE(`RATIO_DEF)
`endif
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
    integer arg_note, arg_period, arg_speed, arg_vel, arg_pos, arg_nsamp;

    initial begin
        if (!$value$plusargs("out=%s", outfile))   outfile = "grid.txt";
        if ($value$plusargs("note=%d", arg_note))     midi = arg_note[6:0];
        if ($value$plusargs("period=%d", arg_period)) period_q16 = arg_period;
        if ($value$plusargs("speed=%d", arg_speed))   speed = arg_speed[15:0];
        if ($value$plusargs("vel=%d", arg_vel))       vel = arg_vel[7:0];
        if ($value$plusargs("pos=%d", arg_pos))       pos = arg_pos[23:0];
        if ($value$plusargs("nsamp=%d", arg_nsamp))   nsamp = arg_nsamp;
        fd = $fopen(outfile, "w");
        if (fd == 0) begin
            $display("FATAL cannot open output file");
            $finish;
        end
        repeat (20) @(negedge clk);
        $display("CFG note=%0d speed=%0d vel=%0d pos=%0d nsamp=%0d period=%0d comp=%0d",
                 midi, speed, vel, pos, nsamp, period_q16, COMP_Q16);
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
                gate    <= 1'b1;
            end

            if (phase == SAMPLE_PH + 8 && started) begin
                $fwrite(fd, "%0d\n", audio);
                if (nsent >= nsamp) begin
                    $fclose(fd);
                    $display("DONE samples=%0d", nsent + 1);
                    $finish;
                end
                nsent <= nsent + 1;
            end
        end
    end

    initial begin
        #2000000000;
        $display("TIMEOUT samples=%0d", nsent);
        $fclose(fd);
        $finish;
    end
endmodule
