`timescale 1ns/1ps
//=============================================================================
// left_hand_press_detector.v  —— 左手按品判定（单弦 16 铜极）
//
// 数据依据：.workbuddy/lh_press_analysis_20261031/reports/01_数据分析报告_20261031.md
//   通道 ch 对应品 ch+1；ch5 恒为 2049（无效，已排除）
//   静止态（共模扣除后）全通道峰值 p99.99 = 43..93 码 → T_ON=150 有 1.6x 余量
//   按压平台 320..1830 码；一品饱和至 4095（硬件需降增益）
//
// 判决链：
//   rel[ch] = code[ch] - min(code[!5])          共模扣除，消除 600 码级偏置漂移
//   d[ch]   = rel[ch] - base[ch]                base 上电自标定 256 帧
//   peak/second = max/次大(d)，pch = argmax
//   trig    = (peak>T_FAST) 或 (peak>T_ON 且 4 帧内>=2 帧超阈)
//             且 超阈通道数 < COMMON  且 3*second <= 2*peak
//   fret    = max{ch | d[ch] > max(T_ON, 5/8*peak)} + 1
//   release = peak < T_OFF 连续 MREL 帧
//
// 流水：6 拍状态机，每拍 <= 15 级组合；单弦 278 帧/秒，处理占用 0.003% 时间。
//=============================================================================
module left_hand_press_detector #(
    parameter [11:0] T_ON        = 12'd150,
    parameter [11:0] T_OFF       = 12'd100,
    parameter [11:0] T_FAST      = 12'd700,
    parameter integer WIN        = 4,
    parameter integer R_CNT      = 2,
    parameter integer COMMON     = 10,
    parameter integer MREL       = 8,
    parameter integer CAL_FRAMES = 256
) (
    input  wire         clk_50m,
    input  wire         reset,
    input  wire [191:0] codes,
    input  wire         frame_valid,
    input  wire         recalib,
    output reg          pressed,
    output reg  [4:0]   fret,
    output reg          multi,
    output reg          common_mode,
    output reg          calib_done,
    output wire [11:0]  dbg_peak,
    output wire [15:0]  dbg_d,
    output wire [15:0]  dbg_hit
);
    localparam signed [12:0] NEG = -13'sd4096;
    localparam integer AW = $clog2(WIN);

    //------------------------------------------------ 帧锁存
    reg  [11:0] c0,c1,c2,c3,c4,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15;

    wire [11:0] n0  = (c0  < c1 ) ? c0  : c1;
    wire [11:0] n1  = (c2  < c3 ) ? c2  : c3;
    wire [11:0] n2  = (c4  < c6 ) ? c4  : c6;
    wire [11:0] n3  = (c7  < c8 ) ? c7  : c8;
    wire [11:0] n4  = (c9  < c10) ? c9  : c10;
    wire [11:0] n5  = (c11 < c12) ? c11 : c12;
    wire [11:0] n6  = (c13 < c14) ? c13 : c14;
    wire [11:0] n7  = (n0  < n1 ) ? n0  : n1;
    wire [11:0] n8  = (n2  < n3 ) ? n2  : n3;
    wire [11:0] n9  = (n4  < n5 ) ? n4  : n5;
    wire [11:0] n10 = (n6  < c15) ? n6  : c15;
    wire [11:0] n11 = (n7  < n8 ) ? n7  : n8;
    wire [11:0] n12 = (n9  < n10) ? n9  : n10;
    wire [11:0] cmin = (n11 < n12) ? n11 : n12;

    reg  [11:0] cmin_r;
    reg  [191:0] rel_r;
    reg  signed [12:0] d_r [0:15];

    reg  [11:0] base [0:15];

    reg signed [12:0] peak_r, second_r;
    reg [3:0]  pch_r;
    reg [4:0]  nov_r;
    reg [15:0] hit_r, sig_r;
    reg [4:0]  fret_c_r;
    reg [3:0]  nsig_r;

    reg [2:0]  st;
    reg [15:0] win_sh;
    reg [7:0]  rel_cnt;
    reg [20:0] cal_sum [0:15];
    reg [8:0]  cal_cnt;
    reg        cal_busy;

    //------------------------------------------------ 最大值 / 超阈计数（基于 d_r）
    // 树形 max + argmax（4 级）
    wire signed [12:0] a0 = (d_r[0]  > d_r[1])  ? d_r[0]  : d_r[1];
    wire signed [12:0] a1 = (d_r[2]  > d_r[3])  ? d_r[2]  : d_r[3];
    wire signed [12:0] a2 = (d_r[4]  > d_r[6])  ? d_r[4]  : d_r[6];
    wire signed [12:0] a3 = (d_r[7]  > d_r[8])  ? d_r[7]  : d_r[8];
    wire signed [12:0] a4 = (d_r[9]  > d_r[10]) ? d_r[9]  : d_r[10];
    wire signed [12:0] a5 = (d_r[11] > d_r[12]) ? d_r[11] : d_r[12];
    wire signed [12:0] a6 = (d_r[13] > d_r[14]) ? d_r[13] : d_r[14];
    wire [3:0] i0 = (d_r[0]  > d_r[1])  ? 4'd0  : 4'd1;
    wire [3:0] i1 = (d_r[2]  > d_r[3])  ? 4'd2  : 4'd3;
    wire [3:0] i2 = (d_r[4]  > d_r[6])  ? 4'd4  : 4'd6;
    wire [3:0] i3 = (d_r[7]  > d_r[8])  ? 4'd7  : 4'd8;
    wire [3:0] i4 = (d_r[9]  > d_r[10]) ? 4'd9  : 4'd10;
    wire [3:0] i5 = (d_r[11] > d_r[12]) ? 4'd11 : 4'd12;
    wire [3:0] i6 = (d_r[13] > d_r[14]) ? 4'd13 : 4'd14;
    wire signed [12:0] b0 = (a0 > a1) ? a0 : a1;
    wire signed [12:0] b1 = (a2 > a3) ? a2 : a3;
    wire signed [12:0] b2 = (a4 > a5) ? a4 : a5;
    wire [3:0] j0 = (a0 > a1) ? i0 : i1;
    wire [3:0] j1 = (a2 > a3) ? i2 : i3;
    wire [3:0] j2 = (a4 > a5) ? i4 : i5;
    wire signed [12:0] e0 = (b0 > b1) ? b0 : b1;
    wire signed [12:0] e1 = (b2 > a6) ? b2 : a6;
    wire [3:0] k0 = (b0 > b1) ? j0 : j1;
    wire [3:0] k1 = (b2 > a6) ? j2 : i6;
    wire signed [12:0] peak_c = (e0 > e1) ? e0 : e1;
    wire [3:0] pch_c = (e0 > e1) ? k0 : k1;
    reg signed [12:0] mx;   // 兼容旧引用
    reg [3:0] mxch;

    wire [15:0] hit_w;
    assign hit_w[0]  = (d_r[0]  > $signed({1'b0, T_ON}));
    assign hit_w[1]  = (d_r[1]  > $signed({1'b0, T_ON}));
    assign hit_w[2]  = (d_r[2]  > $signed({1'b0, T_ON}));
    assign hit_w[3]  = (d_r[3]  > $signed({1'b0, T_ON}));
    assign hit_w[4]  = (d_r[4]  > $signed({1'b0, T_ON}));
    assign hit_w[5]  = 1'b0;
    assign hit_w[6]  = (d_r[6]  > $signed({1'b0, T_ON}));
    assign hit_w[7]  = (d_r[7]  > $signed({1'b0, T_ON}));
    assign hit_w[8]  = (d_r[8]  > $signed({1'b0, T_ON}));
    assign hit_w[9]  = (d_r[9]  > $signed({1'b0, T_ON}));
    assign hit_w[10] = (d_r[10] > $signed({1'b0, T_ON}));
    assign hit_w[11] = (d_r[11] > $signed({1'b0, T_ON}));
    assign hit_w[12] = (d_r[12] > $signed({1'b0, T_ON}));
    assign hit_w[13] = (d_r[13] > $signed({1'b0, T_ON}));
    assign hit_w[14] = (d_r[14] > $signed({1'b0, T_ON}));
    assign hit_w[15] = (d_r[15] > $signed({1'b0, T_ON}));
    wire [1:0] q0 = hit_w[0]+hit_w[1];   wire [1:0] q1 = hit_w[2]+hit_w[3];
    wire [1:0] q2 = hit_w[4]+hit_w[6];   wire [1:0] q3 = hit_w[7]+hit_w[8];
    wire [1:0] q4 = hit_w[9]+hit_w[10];  wire [1:0] q5 = hit_w[11]+hit_w[12];
    wire [1:0] q6 = hit_w[13]+hit_w[14]; wire [1:0] q7 = {1'b0, hit_w[15]};
    wire [2:0] r0 = q0+q1;  wire [2:0] r1 = q2+q3;
    wire [2:0] r2 = q4+q5;  wire [2:0] r3 = q6+q7;
    wire [3:0] t0 = r0+r1;  wire [3:0] t1 = r2+r3;
    wire [4:0] nov_c = t0+t1;

    // 次大值：top2 归并树（4 级，每级 3 次比较）
    wire signed [12:0] h0 = (d_r[0]  >= d_r[1])  ? d_r[0]  : d_r[1];
    wire signed [12:0] l0 = (d_r[0]  >= d_r[1])  ? d_r[1]  : d_r[0];
    wire signed [12:0] h1 = (d_r[2]  >= d_r[3])  ? d_r[2]  : d_r[3];
    wire signed [12:0] l1 = (d_r[2]  >= d_r[3])  ? d_r[3]  : d_r[2];
    wire signed [12:0] h2 = (d_r[4]  >= d_r[6])  ? d_r[4]  : d_r[6];
    wire signed [12:0] l2 = (d_r[4]  >= d_r[6])  ? d_r[6]  : d_r[4];
    wire signed [12:0] h3 = (d_r[7]  >= d_r[8])  ? d_r[7]  : d_r[8];
    wire signed [12:0] l3 = (d_r[7]  >= d_r[8])  ? d_r[8]  : d_r[7];
    wire signed [12:0] h4 = (d_r[9]  >= d_r[10]) ? d_r[9]  : d_r[10];
    wire signed [12:0] l4 = (d_r[9]  >= d_r[10]) ? d_r[10] : d_r[9];
    wire signed [12:0] h5 = (d_r[11] >= d_r[12]) ? d_r[11] : d_r[12];
    wire signed [12:0] l5 = (d_r[11] >= d_r[12]) ? d_r[12] : d_r[11];
    wire signed [12:0] h6 = (d_r[13] >= d_r[14]) ? d_r[13] : d_r[14];
    wire signed [12:0] l6 = (d_r[13] >= d_r[14]) ? d_r[14] : d_r[13];
    wire signed [12:0] h7 = d_r[15];
    wire signed [12:0] l7 = NEG;

    wire signed [12:0] H0 = (h0 >= h1) ? h0 : h1;
    wire signed [12:0] qa0 = (h0 >= h1) ? h1 : h0;
    wire signed [12:0] md0 = (qa0 >= l0) ? ((qa0 >= l1) ? qa0 : l1) : ((l0 >= l1) ? l0 : l1);
    wire signed [12:0] H1 = (h2 >= h3) ? h2 : h3;
    wire signed [12:0] qa1 = (h2 >= h3) ? h3 : h2;
    wire signed [12:0] md1 = (qa1 >= l2) ? ((qa1 >= l3) ? qa1 : l3) : ((l2 >= l3) ? l2 : l3);
    wire signed [12:0] H2 = (h4 >= h5) ? h4 : h5;
    wire signed [12:0] qa2 = (h4 >= h5) ? h5 : h4;
    wire signed [12:0] md2 = (qa2 >= l4) ? ((qa2 >= l5) ? qa2 : l5) : ((l4 >= l5) ? l4 : l5);
    wire signed [12:0] H3 = (h6 >= h7) ? h6 : h7;
    wire signed [12:0] qa3 = (h6 >= h7) ? h7 : h6;
    wire signed [12:0] md3 = (qa3 >= l6) ? ((qa3 >= l7) ? qa3 : l7) : ((l6 >= l7) ? l6 : l7);

    wire signed [12:0] P0 = (H0 >= H1) ? H0 : H1;
    wire signed [12:0] rb0 = (H0 >= H1) ? H1 : H0;
    wire signed [12:0] nc0 = (rb0 >= md0) ? ((rb0 >= md1) ? rb0 : md1) : ((md0 >= md1) ? md0 : md1);
    wire signed [12:0] P1 = (H2 >= H3) ? H2 : H3;
    wire signed [12:0] rb1 = (H2 >= H3) ? H3 : H2;
    wire signed [12:0] nc1 = (rb1 >= md2) ? ((rb1 >= md3) ? rb1 : md3) : ((md2 >= md3) ? md2 : md3);

    wire signed [12:0] Pk = (P0 >= P1) ? P0 : P1;
    wire signed [12:0] rx = (P0 >= P1) ? P1 : P0;
    wire signed [12:0] sd = (rx >= nc0) ? ((rx >= nc1) ? rx : nc1) : ((nc0 >= nc1) ? nc0 : nc1);

    wire signed [12:0] thr2_w = peak_c - (peak_c >>> 1) + (peak_c >>> 3);  // 与本帧 peak 同拍

    wire [15:0] sig_w;
    assign sig_w[0]  = (d_r[0]  > thr2_w) && (d_r[0]  > $signed({1'b0, T_ON}));
    assign sig_w[1]  = (d_r[1]  > thr2_w) && (d_r[1]  > $signed({1'b0, T_ON}));
    assign sig_w[2]  = (d_r[2]  > thr2_w) && (d_r[2]  > $signed({1'b0, T_ON}));
    assign sig_w[3]  = (d_r[3]  > thr2_w) && (d_r[3]  > $signed({1'b0, T_ON}));
    assign sig_w[4]  = (d_r[4]  > thr2_w) && (d_r[4]  > $signed({1'b0, T_ON}));
    assign sig_w[5]  = 1'b0;
    assign sig_w[6]  = (d_r[6]  > thr2_w) && (d_r[6]  > $signed({1'b0, T_ON}));
    assign sig_w[7]  = (d_r[7]  > thr2_w) && (d_r[7]  > $signed({1'b0, T_ON}));
    assign sig_w[8]  = (d_r[8]  > thr2_w) && (d_r[8]  > $signed({1'b0, T_ON}));
    assign sig_w[9]  = (d_r[9]  > thr2_w) && (d_r[9]  > $signed({1'b0, T_ON}));
    assign sig_w[10] = (d_r[10] > thr2_w) && (d_r[10] > $signed({1'b0, T_ON}));
    assign sig_w[11] = (d_r[11] > thr2_w) && (d_r[11] > $signed({1'b0, T_ON}));
    assign sig_w[12] = (d_r[12] > thr2_w) && (d_r[12] > $signed({1'b0, T_ON}));
    assign sig_w[13] = (d_r[13] > thr2_w) && (d_r[13] > $signed({1'b0, T_ON}));
    assign sig_w[14] = (d_r[14] > thr2_w) && (d_r[14] > $signed({1'b0, T_ON}));
    assign sig_w[15] = (d_r[15] > thr2_w) && (d_r[15] > $signed({1'b0, T_ON}));

    wire [15:0] win_next = {win_sh[14:0], (peak_r > $signed({1'b0, T_ON}))};
    reg  [AW:0] win_cnt;
    integer wi;
    always @(*) begin
        win_cnt = {(AW+1){1'b0}};
        for (wi = 0; wi < WIN; wi = wi + 1)
            if (win_next[wi]) win_cnt = win_cnt + 1'b1;
    end

    // 品号：4 组各 4 位求最高，组间再取最高（约 7 级）
    wire [3:0] sg0 = sig_w[3:0];    wire [3:0] sg1 = sig_w[7:4];
    wire [3:0] sg2 = sig_w[11:8];   wire [3:0] sg3 = sig_w[15:12];
    wire g0 = |sg0, g1 = |sg1, g2 = |sg2, g3 = |sg3;
    wire [1:0] p0 = sg0[3] ? 2'd3 : sg0[2] ? 2'd2 : sg0[1] ? 2'd1 : 2'd0;
    wire [1:0] p1 = sg1[3] ? 2'd3 : sg1[2] ? 2'd2 : sg1[1] ? 2'd1 : 2'd0;
    wire [1:0] p2 = sg2[3] ? 2'd3 : sg2[2] ? 2'd2 : sg2[1] ? 2'd1 : 2'd0;
    wire [1:0] p3 = sg3[3] ? 2'd3 : sg3[2] ? 2'd2 : sg3[1] ? 2'd1 : 2'd0;
    wire [4:0] fret_w = g3 ? (5'd13 + {3'd0, p3}) :
                        g2 ? (5'd9  + {3'd0, p2}) :
                        g1 ? (5'd5  + {3'd0, p1}) :
                        g0 ? (5'd1  + {3'd0, p0}) : 5'd0;
    wire [3:0] nsig_w = {3'd0, g0} + {3'd0, g1} + {3'd0, g2} + {3'd0, g3} +
                        {3'd0, (sg0[3]+sg0[2]+sg0[1]+sg0[0])} +
                        {3'd0, (sg1[3]+sg1[2]+sg1[1]+sg1[0])} +
                        {3'd0, (sg2[3]+sg2[2]+sg2[1]+sg2[0])} +
                        {3'd0, (sg3[3]+sg3[2]+sg3[1]+sg3[0])} - {3'd0, g0} - {3'd0, g1} - {3'd0, g2} - {3'd0, g3};

    //------------------------------------------------ 主流水
    always @(posedge clk_50m) begin
        if (reset) begin
            st <= 3'd0;
            pressed <= 1'b0; fret <= 5'd0; multi <= 1'b0; common_mode <= 1'b0;
            win_sh <= 16'd0; rel_cnt <= 8'd0; calib_done <= 1'b0;
            cal_busy <= 1'b0; cal_cnt <= 9'd0;
            peak_r <= NEG; second_r <= NEG; pch_r <= 4'd0; nov_r <= 5'd0;
            hit_r <= 16'd0; sig_r <= 16'd0; fret_c_r <= 5'd0; nsig_r <= 4'd0;
            cmin_r <= 12'd0; rel_r <= 192'd0;
            c0<=0;c1<=0;c2<=0;c3<=0;c4<=0;c6<=0;c7<=0;c8<=0;c9<=0;
            c10<=0;c11<=0;c12<=0;c13<=0;c14<=0;c15<=0;
            for (wi = 0; wi < 16; wi = wi + 1) begin
                base[wi] <= 12'd0; cal_sum[wi] <= 21'd0; d_r[wi] <= NEG;
            end
        end else if (recalib) begin
            cal_busy <= 1'b1; cal_cnt <= 9'd0; calib_done <= 1'b0;
            for (wi = 0; wi < 16; wi = wi + 1) cal_sum[wi] <= 21'd0;
        end else if (cal_busy) begin
            if (st == 3'd0) begin
                if (frame_valid) begin
                    c0  <= codes[0*12  +: 12]; c1  <= codes[1*12  +: 12];
                    c2  <= codes[2*12  +: 12]; c3  <= codes[3*12  +: 12];
                    c4  <= codes[4*12  +: 12]; c6  <= codes[6*12  +: 12];
                    c7  <= codes[7*12  +: 12]; c8  <= codes[8*12  +: 12];
                    c9  <= codes[9*12  +: 12]; c10 <= codes[10*12 +: 12];
                    c11 <= codes[11*12 +: 12]; c12 <= codes[12*12 +: 12];
                    c13 <= codes[13*12 +: 12]; c14 <= codes[14*12 +: 12];
                    c15 <= codes[15*12 +: 12];
                    st <= 3'd1;
                end
            end else if (st == 3'd1) begin
                cal_sum[0]  <= cal_sum[0]  + (c0  - cmin);
                cal_sum[1]  <= cal_sum[1]  + (c1  - cmin);
                cal_sum[2]  <= cal_sum[2]  + (c2  - cmin);
                cal_sum[3]  <= cal_sum[3]  + (c3  - cmin);
                cal_sum[4]  <= cal_sum[4]  + (c4  - cmin);
                cal_sum[6]  <= cal_sum[6]  + (c6  - cmin);
                cal_sum[7]  <= cal_sum[7]  + (c7  - cmin);
                cal_sum[8]  <= cal_sum[8]  + (c8  - cmin);
                cal_sum[9]  <= cal_sum[9]  + (c9  - cmin);
                cal_sum[10] <= cal_sum[10] + (c10 - cmin);
                cal_sum[11] <= cal_sum[11] + (c11 - cmin);
                cal_sum[12] <= cal_sum[12] + (c12 - cmin);
                cal_sum[13] <= cal_sum[13] + (c13 - cmin);
                cal_sum[14] <= cal_sum[14] + (c14 - cmin);
                cal_sum[15] <= cal_sum[15] + (c15 - cmin);
                cal_cnt <= cal_cnt + 9'd1;
                if (cal_cnt == (CAL_FRAMES-1)) begin
                    cal_busy <= 1'b0; calib_done <= 1'b1;
                    base[0]  <= (cal_sum[0]  + (c0  - cmin)) >> $clog2(CAL_FRAMES);
                    base[1]  <= (cal_sum[1]  + (c1  - cmin)) >> $clog2(CAL_FRAMES);
                    base[2]  <= (cal_sum[2]  + (c2  - cmin)) >> $clog2(CAL_FRAMES);
                    base[3]  <= (cal_sum[3]  + (c3  - cmin)) >> $clog2(CAL_FRAMES);
                    base[4]  <= (cal_sum[4]  + (c4  - cmin)) >> $clog2(CAL_FRAMES);
                    base[6]  <= (cal_sum[6]  + (c6  - cmin)) >> $clog2(CAL_FRAMES);
                    base[7]  <= (cal_sum[7]  + (c7  - cmin)) >> $clog2(CAL_FRAMES);
                    base[8]  <= (cal_sum[8]  + (c8  - cmin)) >> $clog2(CAL_FRAMES);
                    base[9]  <= (cal_sum[9]  + (c9  - cmin)) >> $clog2(CAL_FRAMES);
                    base[10] <= (cal_sum[10] + (c10 - cmin)) >> $clog2(CAL_FRAMES);
                    base[11] <= (cal_sum[11] + (c11 - cmin)) >> $clog2(CAL_FRAMES);
                    base[12] <= (cal_sum[12] + (c12 - cmin)) >> $clog2(CAL_FRAMES);
                    base[13] <= (cal_sum[13] + (c13 - cmin)) >> $clog2(CAL_FRAMES);
                    base[14] <= (cal_sum[14] + (c14 - cmin)) >> $clog2(CAL_FRAMES);
                    base[15] <= (cal_sum[15] + (c15 - cmin)) >> $clog2(CAL_FRAMES);
                end
                st <= 3'd0;
            end
        end else begin
            case (st)
                3'd0: if (frame_valid) begin
                    c0  <= codes[0*12  +: 12]; c1  <= codes[1*12  +: 12];
                    c2  <= codes[2*12  +: 12]; c3  <= codes[3*12  +: 12];
                    c4  <= codes[4*12  +: 12]; c6  <= codes[6*12  +: 12];
                    c7  <= codes[7*12  +: 12]; c8  <= codes[8*12  +: 12];
                    c9  <= codes[9*12  +: 12]; c10 <= codes[10*12 +: 12];
                    c11 <= codes[11*12 +: 12]; c12 <= codes[12*12 +: 12];
                    c13 <= codes[13*12 +: 12]; c14 <= codes[14*12 +: 12];
                    c15 <= codes[15*12 +: 12];
                    st <= 3'd1;
                end
                3'd1: begin cmin_r <= cmin; st <= 3'd2; end
                3'd2: begin
                    rel_r[0*12   +: 12] <= c0  - cmin_r;
                    rel_r[1*12   +: 12] <= c1  - cmin_r;
                    rel_r[2*12   +: 12] <= c2  - cmin_r;
                    rel_r[3*12   +: 12] <= c3  - cmin_r;
                    rel_r[4*12   +: 12] <= c4  - cmin_r;
                    rel_r[5*12   +: 12] <= 12'd0;
                    rel_r[6*12   +: 12] <= c6  - cmin_r;
                    rel_r[7*12   +: 12] <= c7  - cmin_r;
                    rel_r[8*12   +: 12] <= c8  - cmin_r;
                    rel_r[9*12   +: 12] <= c9  - cmin_r;
                    rel_r[10*12  +: 12] <= c10 - cmin_r;
                    rel_r[11*12  +: 12] <= c11 - cmin_r;
                    rel_r[12*12  +: 12] <= c12 - cmin_r;
                    rel_r[13*12  +: 12] <= c13 - cmin_r;
                    rel_r[14*12  +: 12] <= c14 - cmin_r;
                    rel_r[15*12  +: 12] <= c15 - cmin_r;
                    st <= 3'd3;
                end
                3'd3: begin
                    d_r[0]  <= $signed({1'b0, rel_r[0*12  +: 12]}) - $signed({1'b0, base[0]});
                    d_r[1]  <= $signed({1'b0, rel_r[1*12  +: 12]}) - $signed({1'b0, base[1]});
                    d_r[2]  <= $signed({1'b0, rel_r[2*12  +: 12]}) - $signed({1'b0, base[2]});
                    d_r[3]  <= $signed({1'b0, rel_r[3*12  +: 12]}) - $signed({1'b0, base[3]});
                    d_r[4]  <= $signed({1'b0, rel_r[4*12  +: 12]}) - $signed({1'b0, base[4]});
                    d_r[5]  <= NEG;
                    d_r[6]  <= $signed({1'b0, rel_r[6*12  +: 12]}) - $signed({1'b0, base[6]});
                    d_r[7]  <= $signed({1'b0, rel_r[7*12  +: 12]}) - $signed({1'b0, base[7]});
                    d_r[8]  <= $signed({1'b0, rel_r[8*12  +: 12]}) - $signed({1'b0, base[8]});
                    d_r[9]  <= $signed({1'b0, rel_r[9*12  +: 12]}) - $signed({1'b0, base[9]});
                    d_r[10] <= $signed({1'b0, rel_r[10*12 +: 12]}) - $signed({1'b0, base[10]});
                    d_r[11] <= $signed({1'b0, rel_r[11*12 +: 12]}) - $signed({1'b0, base[11]});
                    d_r[12] <= $signed({1'b0, rel_r[12*12 +: 12]}) - $signed({1'b0, base[12]});
                    d_r[13] <= $signed({1'b0, rel_r[13*12 +: 12]}) - $signed({1'b0, base[13]});
                    d_r[14] <= $signed({1'b0, rel_r[14*12 +: 12]}) - $signed({1'b0, base[14]});
                    d_r[15] <= $signed({1'b0, rel_r[15*12 +: 12]}) - $signed({1'b0, base[15]});
                    st <= 3'd4;
                end
                3'd4: begin
                    peak_r   <= peak_c;
                    pch_r    <= pch_c;
                    nov_r    <= nov_c;
                    hit_r    <= hit_w;
                    sig_r    <= sig_w;
                    fret_c_r <= fret_w;
                    nsig_r   <= nsig_w;
                    st <= 3'd5;
                end
                3'd5: begin
                    second_r <= sd;          // 次大值单独一拍（15 级链）
                    st <= 3'd6;
                end
                3'd6: begin
                    win_sh <= win_next;
                    common_mode <= (nov_r >= COMMON);
                    if (pressed) begin
                        if (peak_r < $signed({1'b0, T_OFF})) begin
                            if (rel_cnt >= MREL-1) begin
                                pressed <= 1'b0; fret <= 5'd0; multi <= 1'b0; rel_cnt <= 8'd0;
                            end else rel_cnt <= rel_cnt + 8'd1;
                        end else rel_cnt <= 8'd0;
                        if (fret_c_r != 5'd0) begin
                            fret  <= fret_c_r;
                            multi <= (nsig_r > 4'd1);
                        end
                    end else begin
                        if (((peak_r > $signed({1'b0, T_FAST})) ||
                             ((peak_r > $signed({1'b0, T_ON})) && (win_cnt >= R_CNT))) &&
                            (nov_r < COMMON) && (second_r * 13'sd3 <= peak_r * 13'sd2)) begin
                            pressed <= 1'b1; rel_cnt <= 8'd0;
                            fret <= fret_c_r; multi <= (nsig_r > 4'd1);
                        end
                    end
                    st <= 3'd0;
                end
                default: st <= 3'd0;
            endcase
        end
    end

    assign dbg_peak = (peak_r > 0) ? peak_r[11:0] : 12'd0;
    assign dbg_d    = sig_r;
    assign dbg_hit  = hit_r;
endmodule
