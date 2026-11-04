`timescale 1ns/1ps
//=============================================================================
// tb_timbre_r48.v — timbre_shaper R48（拐点交叉 + +-12 dB + 亮方向回补）验收台
//
// 与 tb_timbre_r20 的区别：
//   R20 的期望值写死在 tb 里（1/2 补偿时代的模型），改补偿律后必然失配，
//   所以 R48 不复用它的断言，只复用它的**计时约定**（48 clk/样本、同步激励）。
//
// 本台回答六个问题：
//   T1 中性档是否**逐样本**直通（不是峰值相等，是每一位都相同）
//   T2 频响表：12 个频点 x 5 个档位，用来证明"暖"方向终于落到有能量的频段
//   T3 最坏电平峰值：单声部 24832 / 八声部 31999，九种极端档位组合全部不许削顶
//   T4 谐波信号（真实波形，不是单音）上的峰值与软限幅计数
//   T5 参数阶跃无咔哒
//   T6 旁路档 1:1
//
// 激励全部同步产生：每 CPS 拍一个单拍 i_sample_valid，相位在时钟进程里推进。
// 参数一阶平滑 tau = 512 样本，工况先跑 SETTLE=3000 样本（约 6 tau）再测。
//=============================================================================
module tb_timbre_r48;
    localparam real    FS  = 48828.125;
    localparam integer CPS = 48;
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
    // 激励：mode 0 = 单音；mode 1 = 196 Hz 八次谐波（1/n 幅度）
    //------------------------------------------------------------------
    real    phase = 0.0, dph = 0.0, amp = 0.0;
    integer gen_mode = 0;
    integer cyc = 0;
    integer vsample = 0;
    integer nrun = 0;
    reg     gen_on = 0;
    integer v, n;
    real    acc, pn;

    // 逐样本直通比对用的输入历史
    integer xarr [0:8191];
    integer xwr = 0, xrd = 0;
    integer passthru_bad = 0;

    always @(posedge clk) begin
        if (gen_on) begin
            if (cyc == 0) begin
                phase = phase + dph;
                if (phase > 6.28318530718) phase = phase - 6.28318530718;
                if (gen_mode == 0) begin
                    acc = amp * $sin(phase);
                end else begin
                    acc = 0.0;
                    for (n = 1; n <= 8; n = n + 1) begin
                        pn = phase * n;
                        pn = pn - 6.28318530718 * $floor(pn / 6.28318530718);
                        acc = acc + (amp / n) * $sin(pn);
                    end
                    acc = acc * 0.36;      // 归一化到约 1.0 峰值
                end
                v = $rtoi(acc);
                if (v >  32767) v =  32767;
                if (v < -32768) v = -32768;
                xin <= v;
                sv  <= 1'b1;
                xarr[xwr] = v;
                xwr = (xwr == 8191) ? 0 : xwr + 1;
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
    // 观测
    //------------------------------------------------------------------
    integer pk_out = 0, pk_in = 0;
    reg     meas_on = 0;
    integer ay, ax;
    integer clip_base = 0, clip_case = 0;
    integer yprev = 0, dmax = 0;
    reg     track_d = 0;
    reg     cmp_on = 0;

    always @(posedge clk) begin
        #1;
        if (yv) begin
            ay = (y > 0) ? y : -y;
            if (cmp_on) begin
                if (y != xarr[xrd]) passthru_bad = passthru_bad + 1;
                xrd = (xrd == 8191) ? 0 : xrd + 1;
            end
            if (track_d) begin
                if (ay - yprev > dmax) dmax = ay - yprev;
                if (yprev - ay > dmax) dmax = yprev - ay;
                yprev = ay;
            end
            if (meas_on) begin
                if (ay > pk_out) pk_out = ay;
                ax = (xin > 0) ? xin : -xin;
                if (ax > pk_in) pk_in = ax;
            end
        end
    end

    task set_tone(input [11:0] w, input [11:0] b, input e);
        begin warm = w; bright = b; en = e; end
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

    task measure(input integer nsamp);
        begin
            pk_out = 0; pk_in = 0; meas_on = 1;
            drive(nsamp);
            meas_on = 0;
        end
    endtask

    real    db;
    integer cases = 0, fails = 0;
    integer jj, kk;
    integer settled_d = 0, trans_d = 0;

    // 频点表
    real flist [0:11];
    integer FIDX;

    initial begin
        flist[0]=100.0;  flist[1]=196.0;  flist[2]=273.0;  flist[3]=392.0;
        flist[4]=567.0;  flist[5]=800.0;  flist[6]=1200.0; flist[7]=1800.0;
        flist[8]=2500.0; flist[9]=4000.0; flist[10]=8000.0; flist[11]=12000.0;

        repeat (8) @(posedge clk);
        rst = 0;
        repeat (8) @(posedge clk);

        // =============== T1 中性档逐样本直通 ===============
        set_tone(12'd2048, 12'd2048, 1'b1);
        gen_mode = 1; dph = 6.28318530718 * 196.0 / FS; amp = 20000.0; phase = 0.0;
        meas_on = 0; cmp_on = 0; drive(SETTLE);
        passthru_bad = 0; xwr = 0; xrd = 0; cmp_on = 1;
        drive(2000);
        cmp_on = 0;
        $display("T1 neutral passthrough: mismatched samples = %0d / 2000", passthru_bad);
        cases = cases + 1;
        if (passthru_bad != 0) begin
            $display("   FAIL neutral is not bit-exact");
            fails = fails + 1;
        end

        // =============== T2 频响表 ===============
        $display("---- T2 freq response (dB, amp=8000, 单音) ----");
        $display("     Hz |  暖满  暖半  中性  亮半  亮满");
        for (jj = 0; jj < 12; jj = jj + 1) begin
            FIDX = jj;
            $write("%7.0f |", flist[jj]);
            for (kk = 0; kk < 5; kk = kk + 1) begin
                case (kk)
                    0: set_tone(12'd4095, 12'd0,    1'b1);   // 暖满 +12
                    1: set_tone(12'd3072, 12'd1024, 1'b1);   // 暖半 +6
                    2: set_tone(12'd2048, 12'd2048, 1'b1);   // 中性
                    3: set_tone(12'd1024, 12'd3072, 1'b1);   // 亮半 -6
                    default: set_tone(12'd0, 12'd4095, 1'b1);// 亮满 -12
                endcase
                gen_mode = 0;
                dph = 6.28318530718 * flist[jj] / FS;
                phase = 0.0; amp = 8000.0;
                meas_on = 0; drive(SETTLE);
                measure(MEAS);
                db = 20.0 * $log10(pk_out * 1.0 / pk_in);
                $write(" %6.2f", db);
                cases = cases + 1;
            end
            $write("\n");
        end

        // =============== T3 最坏电平峰值（单音 273 Hz，能量最集中的频点） ===============
        $display("---- T3 peak safety @ single tone ----");
        for (kk = 0; kk < 9; kk = kk + 1) begin
            case (kk)
                0: set_tone(12'd4095, 12'd4095, 1'b1);   // 双升
                1: set_tone(12'd0,    12'd0,    1'b1);   // 双降
                2: set_tone(12'd4095, 12'd0,    1'b1);   // 暖满(升) 亮满(降)
                3: set_tone(12'd0,    12'd4095, 1'b1);   // 亮满(升) 暖满(降) = tilt 亮
                4: set_tone(12'd4095, 12'd2048, 1'b1);   // 只暖满
                5: set_tone(12'd2048, 12'd4095, 1'b1);   // 只亮满
                6: set_tone(12'd0,    12'd2048, 1'b1);   // 只暖降
                7: set_tone(12'd2048, 12'd0,    1'b1);   // 只亮降
                default: set_tone(12'd2048, 12'd2048, 1'b1);
            endcase
            gen_mode = 0;
            dph = 6.28318530718 * 273.0 / FS; phase = 0.0; amp = 24832.0;
            meas_on = 0; drive(SETTLE);
            clip_base = clips;
            measure(MEAS);
            clip_case = clips - clip_base;
            $display("   case%0d @24832: peak=%0d clip=%0d", kk, pk_out, clip_case);
            cases = cases + 1;
            if (pk_out > 32767 || clip_case != 0) begin
                $display("   FAIL peak/clip at 24832 case%0d", kk);
                fails = fails + 1;
            end
        end

        // 八声部 31999，只测最危险的三种
        for (kk = 0; kk < 3; kk = kk + 1) begin
            case (kk)
                0: set_tone(12'd4095, 12'd4095, 1'b1);
                1: set_tone(12'd4095, 12'd0,    1'b1);
                default: set_tone(12'd0, 12'd4095, 1'b1);
            endcase
            gen_mode = 0;
            dph = 6.28318530718 * 273.0 / FS; phase = 0.0; amp = 31999.0;
            meas_on = 0; drive(SETTLE);
            clip_base = clips;
            measure(MEAS);
            clip_case = clips - clip_base;
            $display("   case%0d @31999: peak=%0d clip=%0d", kk, pk_out, clip_case);
            cases = cases + 1;
            if (pk_out > 32767) begin
                $display("   FAIL hard clip at 31999 case%0d", kk);
                fails = fails + 1;
            end
        end

        // =============== T4 谐波信号（真实波形） ===============
        $display("---- T4 harmonic signal (196 Hz x8, 1/n) ----");
        for (kk = 0; kk < 5; kk = kk + 1) begin
            case (kk)
                0: set_tone(12'd2048, 12'd2048, 1'b1);   // 中性
                1: set_tone(12'd0,    12'd4095, 1'b1);   // 亮满
                2: set_tone(12'd4095, 12'd0,    1'b1);   // 暖满
                3: set_tone(12'd4095, 12'd4095, 1'b1);   // 双升
                default: set_tone(12'd0, 12'd0, 1'b1);   // 双降
            endcase
            gen_mode = 1;
            dph = 6.28318530718 * 196.0 / FS; phase = 0.0; amp = 31999.0;
            meas_on = 0; drive(SETTLE);
            clip_base = clips;
            measure(MEAS);
            clip_case = clips - clip_base;
            $display("   harm case%0d: peak_in=%0d peak_out=%0d clip=%0d",
                     kk, pk_in, pk_out, clip_case);
            cases = cases + 1;
            if (pk_out > 32767) begin
                $display("   FAIL hard clip on harmonic signal case%0d", kk);
                fails = fails + 1;
            end
        end

        // =============== T5 参数阶跃无咔哒 ===============
        gen_mode = 0;
        dph = 6.28318530718 * 800.0 / FS; amp = 12000.0;
        set_tone(12'd0, 12'd4095, 1'b1);        // 亮满
        meas_on = 0; track_d = 0; phase = 0.0; drive(SETTLE);
        dmax = 0; track_d = 1; yprev = 0; drive(SETTLE);
        settled_d = dmax;
        set_tone(12'd4095, 12'd0, 1'b1);        // 阶跃到暖满
        dmax = 0; drive(1200);
        trans_d = dmax;
        track_d = 0;
        $display("T5 no-click step: trans=%0d settled=%0d", trans_d, settled_d);
        cases = cases + 1;
        if (settled_d == 0 || trans_d > (settled_d + settled_d/10)) begin
            $display("   FAIL parameter step produces a click");
            fails = fails + 1;
        end

        // =============== T6 旁路 ===============
        gen_mode = 0;
        dph = 6.28318530718 * 273.0 / FS; phase = 0.0; amp = 24832.0;
        set_tone(12'd2048, 12'd2048, 1'b0);
        meas_on = 0; drive(SETTLE);
        measure(MEAS);
        $display("T6 bypass @24832: out=%0d in=%0d", pk_out, pk_in);
        cases = cases + 1;
        if (pk_out > pk_in + 1 || pk_out < pk_in - 1) begin
            $display("   FAIL bypass is not unity");
            fails = fails + 1;
        end

        $display("--------------------------------------------");
        $display("tb_timbre_r48: cases=%0d fails=%0d", cases, fails);
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end
endmodule
