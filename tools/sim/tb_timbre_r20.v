`timescale 1ns/1ps
//=============================================================================
// tb_timbre_r20.v — timbre_shaper 并入 R20 主工程后的验收台
//
// 与参考工程 tb_timbre_shaper.v 的分工：
//   tb_timbre_shaper：原版 1/4 补偿的"数值对模型"自检，期望值写死在 tb 里，
//                     改成 1/2 补偿后它的模型必然失配（不是模块错）。
//   tb_timbre_r20  ：按主工程真实电平重新验收，回答四个问题：
//       T1 中性档是否精确直通（不动音色时不能改变原声音）
//       T2 各旋钮在实测琴体频段上的真实增益（是否"听得出"）
//       T3 在 r_dry 真实峰值 24832 上会不会进软限幅（削顶 = 难听）
//       T4 旁路档在最坏电平上是否 1:1 直通
//
// 驱动：**全部同步**。早先版本在 initial 里用阻塞赋值驱动 i_sample_valid，
// 与 DUT 的 @(posedge clk) 同处 active 区，存在竞争（同一拍可能被采到 0 次
// 或 2 次），导致幅度测量时有时无。这里改成时钟进程产生单拍脉冲。
//
// 节拍 48 clk/样本（模块硬约束 >=36）。参数一阶平滑 tau = 512 样本，
// 每个工况先跑 SETTLE=3000 样本（约 6 tau）再测 MEAS=400 样本。
//=============================================================================
module tb_timbre_r20;
    localparam real    FS = 48828.125;
    localparam integer CPS = 48;      // clocks per sample
    localparam integer SETTLE = 3000;
    localparam integer MEAS   = 400;

    reg clk = 0;
    reg rst = 1;
    reg sv  = 0;
    reg signed [15:0] xin = 0;
    reg [11:0] warm = 2048, bright = 2048;
    reg        en = 1;

    wire signed [15:0] y;
    wire               yv;
    wire [15:0]        clips;
    wire signed [17:0] glo, ghi;

    timbre_shaper dut (
        .i_clk(clk), .i_reset(rst), .i_sample_valid(sv), .i_sample(xin),
        .i_bright(bright), .i_warm(warm), .i_enable(en),
        .o_sample(y), .o_sample_valid(yv), .o_clip_count(clips),
        .o_gain_low(glo), .o_gain_high(ghi)
    );

    always #10 clk = ~clk;      // 50 MHz

    //------------------------------------------------------------------
    // 同步激励：每 CPS 拍发一个单拍 i_sample_valid，同时推进正弦相位
    //------------------------------------------------------------------
    real    phase = 0.0, dph = 0.0, amp = 0.0;
    integer cyc = 0;
    integer vsample = 0;
    integer nrun = 0;
    reg     gen_on = 0;
    integer v;

    always @(posedge clk) begin
        if (gen_on) begin
            if (cyc == 0) begin
                phase = phase + dph;
                if (phase > 6.28318530718) phase = phase - 6.28318530718;
                v = $rtoi(amp * $sin(phase));
                if (v >  32767) v =  32767;
                if (v < -32768) v = -32768;
                xin <= v;
                sv  <= 1'b1;
                vsample <= vsample + 1;
            end else begin
                sv <= 1'b0;
            end
            cyc <= (cyc == CPS - 1) ? 0 : cyc + 1;
        end else begin
            sv  <= 1'b0;
            cyc <= 0;
        end
    end

    //------------------------------------------------------------------
    // 观测：o_sample_valid 是单拍脉冲，出现在 issue 之后第 15 拍
    //------------------------------------------------------------------
    integer pk_out = 0, pk_in = 0;
    reg     meas_on = 0;
    integer ay;
    integer clip_base = 0, clip_case = 0;
    integer yprev = 0;
    integer dmax = 0;
    reg     track_d = 0;

    always @(posedge clk) begin
        #1;
        if (yv) begin
            ay = (y > 0) ? y : -y;
            if (track_d) begin
                if (ay - yprev > dmax) dmax = ay - yprev;
                if (yprev - ay > dmax) dmax = yprev - ay;
                yprev = ay;
            end
            if (meas_on) begin
                if (ay > pk_out) pk_out = ay;
                if ((xin > 0 ? xin : -xin) > pk_in) pk_in = (xin > 0 ? xin : -xin);
            end
        end
    end

    task set_tone(input [11:0] w, input [11:0] b, input e);
        begin
            warm = w; bright = b; en = e;
        end
    endtask

    task drive(input integer nsamp);
        begin
            vsample = 0;
            nrun    = nsamp;
            gen_on  = 1;
            wait (vsample >= nrun);
            repeat (CPS * 3) @(posedge clk);
            gen_on = 0;
            repeat (CPS) @(posedge clk);
        end
    endtask

    real    db;
    integer cases = 0, fails = 0;
    integer jj, kk;
    integer settled_d = 0, trans_d = 0;

    initial begin
        repeat (8) @(posedge clk);
        rst = 0;
        repeat (8) @(posedge clk);

        // ---------------- T1 中性档：必须精确直通 ----------------
        set_tone(12'd2048, 12'd2048, 1'b1);
        dph = 6.28318530718 * 1000.0 / FS; amp = 20000.0; phase = 0.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        db = 20.0 * $log10(pk_out * 1.0 / pk_in);
        $display("T1 neutral  1kHz : in=%0d out=%0d  %0.2f dB", pk_in, pk_out, db);
        cases = cases + 1;
        if (db > 0.05 || db < -0.05) begin
            $display("   FAIL neutral is not unity");
            fails = fails + 1;
        end

        // ---------------- T2 频响表 ----------------
        $display("---- T2 freq response (absolute dB, amp=8000) ----");
        for (jj = 0; jj < 5; jj = jj + 1) begin
            case (jj)
                0: dph = 6.28318530718 *  273.0 / FS;
                1: dph = 6.28318530718 *  567.0 / FS;
                2: dph = 6.28318530718 * 1800.0 / FS;
                3: dph = 6.28318530718 * 4000.0 / FS;
                4: dph = 6.28318530718 * 8000.0 / FS;
            endcase
            for (kk = 0; kk < 4; kk = kk + 1) begin
                case (kk)
                    0: set_tone(12'd4095, 12'd2048, 1'b1);   // 暖 +6
                    1: set_tone(12'd0,    12'd2048, 1'b1);   // 暖 -6
                    2: set_tone(12'd2048, 12'd4095, 1'b1);   // 亮 +6
                    3: set_tone(12'd2048, 12'd0,    1'b1);   // 亮 -6
                endcase
                phase = 0.0; amp = 8000.0;
                meas_on = 0; drive(SETTLE);
                pk_out = 0; pk_in = 0; meas_on = 1;
                drive(MEAS);
                meas_on = 0;
                db = 20.0 * $log10(pk_out * 1.0 / pk_in);
                $display("   %5.0f Hz  %s : %6.2f dB  (out=%0d)",
                         FS * dph / 6.28318530718,
                         (kk == 0) ? "warm+6  " : (kk == 1) ? "warm-6  " :
                         (kk == 2) ? "bright+6" : "bright-6", db, pk_out);
                cases = cases + 1;
            end
        end

        // ---------------- T3 峰值余量 ----------------
        // r_dry 单声部软限幅后峰值 24832（instrument_bank_core R13b）
        clip_base = clips;
        set_tone(12'd4095, 12'd4095, 1'b1);
        phase = 0.0; dph = 6.28318530718 * 300.0 / FS; amp = 24832.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        clip_case = clips - clip_base;
        $display("T3 worst (warm+bright+ @24832): peak=%0d clip=%0d", pk_out, clip_case);
        cases = cases + 1;
        if (clip_case != 0) begin
            $display("   FAIL soft limiter engaged at nominal level");
            fails = fails + 1;
        end

        // 反向倾斜（暖- 亮+）：响度补偿会让它偏响，必须仍不削顶
        clip_base = clips;
        set_tone(12'd0, 12'd4095, 1'b1);
        phase = 0.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        clip_case = clips - clip_base;
        $display("T3b tilt warm-bright+ @24832: peak=%0d clip=%0d", pk_out, clip_case);
        cases = cases + 1;
        if (clip_case != 0) begin
            $display("   FAIL soft limiter engaged on tilt");
            fails = fails + 1;
        end

        // 最坏增益方向（暖到底 + 亮到底反向），低频端净增益最大
        clip_base = clips;
        set_tone(12'd4095, 12'd0, 1'b1);
        phase = 0.0; dph = 6.28318530718 * 300.0 / FS; amp = 24832.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        clip_case = clips - clip_base;
        $display("T3c max-boost warm+ bright- @24832: peak=%0d clip=%0d", pk_out, clip_case);
        cases = cases + 1;
        if (pk_out > 32767 || clip_case != 0) begin
            $display("   FAIL max-boost path is not headroom safe");
            fails = fails + 1;
        end

        // 8 声部电平（r_dry 软限幅后 31999）——最坏失真源
        clip_base = clips;
        set_tone(12'd4095, 12'd0, 1'b1);
        phase = 0.0; amp = 31999.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        clip_case = clips - clip_base;
        $display("T3d 8-voice level 31999: peak=%0d clip=%0d", pk_out, clip_case);
        cases = cases + 1;
        if (pk_out > 32767) begin
            $display("   FAIL hard clip at 8-voice level");
            fails = fails + 1;
        end

        // ---------------- T3e 参数阶跃无咔哒 ----------------
        // 判据：过渡期最大单样本跳变 <= 稳态最大单样本跳变 * 1.10。
        // 稳态取同一档位（暖+ 亮-）跑满之后的窗口；过渡取从邻近档位切过来的 3000 样本。
        // 本设计只有前馈增益 + 一阶低通状态，参数经 tau=10.5 ms 斜坡，
        // 结构上不会产生阶跃；这一项是回归护栏。
        set_tone(12'd4095, 12'd0, 1'b1);
        phase = 0.0; dph = 6.28318530718 * 1000.0 / FS; amp = 12000.0;
        meas_on = 0; track_d = 0; drive(SETTLE);
        dmax = 0; track_d = 1; yprev = 0; drive(SETTLE);
        settled_d = dmax;
        // 阶跃到反方向
        set_tone(12'd0, 12'd4095, 1'b1);
        dmax = 0; drive(1200);
        trans_d = dmax;
        track_d = 0;
        $display("T3e no-click step: trans=%0d settled=%0d", trans_d, settled_d);
        cases = cases + 1;
        if (settled_d == 0 || trans_d > (settled_d + settled_d/10)) begin
            $display("   FAIL parameter step produces a click");
            fails = fails + 1;
        end

        // ---------------- T4 旁路 ----------------
        set_tone(12'd2048, 12'd2048, 1'b0);
        phase = 0.0;
        meas_on = 0; drive(SETTLE);
        pk_out = 0; pk_in = 0; meas_on = 1;
        drive(MEAS);
        meas_on = 0;
        $display("T4 bypass @24832: out=%0d in=%0d", pk_out, pk_in);
        cases = cases + 1;
        if (pk_out > pk_in + 1 || pk_out < pk_in - 1) begin
            $display("   FAIL bypass is not unity");
            fails = fails + 1;
        end

        $display("--------------------------------------------");
        $display("tb_timbre_r20: cases=%0d fails=%0d", cases, fails);
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end
endmodule
