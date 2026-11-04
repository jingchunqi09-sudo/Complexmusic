`timescale 1ns/1ps
//=============================================================================
// timbre_shaper.v — 连续可调总音色（低架 1200 Hz / 高架 300 Hz，各 +-12 dB）
//
// R48：**拐点交叉重排 + 量程 +-12 dB + 亮方向响度回补**。
//      这版是为了解决用户实测"通过 WiFi 调音色听不出来"。
//
// ---- R48 之前为什么听不出来（实测数据，不是猜） ---------------------------
// R44/R46/R47 是低架 600 / 高架 1200 / 量程 +-9 dB，`tb_timbre_r20` 实测：
//   bright+6: 273 -5.76 / 567 -5.09 / 1800 -2.41 / 8k -0.64
//   warm  +6: 273 -0.57 / 567 -1.82 / 1800 -4.63 / 8k -5.62
// 用琴体实测模态（273/305/489/567/860~931）乘弦谐波列做听感模型，结论：
//   * **"暖"方向是死的**：峰值归一化把低频钉在 0 dB，暖只能去切高频；
//     而 3 kHz 以上只有 1.5% 能量 —— 切了也没东西可切。
//     实测暖满 A 计权只掉 1.1 dB，谱重心只动 -36 音分（≈ 2%），必然听不出。
//   * **"亮"方向只是变小声**：低频被压 13~15 dB，谱重心 +297 音分，
//     听感是"音量旋钮"而不是"音色旋钮"。
// 根因不是量程不够，是**两个搁架的作用频段都落在没能量的地方**。
//
// ---- R48 的两条改法 -------------------------------------------------------
// 1) **把两个拐架交叉**：低架抬到 1200 Hz（管"亮"——直接把基频/琴体主模态
//    压下去，听感"变薄/变透"）、高架压到 300 Hz（管"暖"——直接从 300 Hz
//    往上切，落进 99% 能量所在的 300~1200 Hz 带内）。
//    两者在 300~1200 Hz 叠加成一条更陡的倾斜，同量程下对比度翻倍。
//    量程同时从 +-9 提到 +-12 dB（s2 系数 3/4 -> 1，仍在 18 位 K 的
//    可表示范围 G<=4 之内，见下）。
// 2) **"亮"方向补回 6 dB 响度**（LIFT_Q）。峰值归一化在亮方向会多压掉
//    12 dB 低频，而波形峰值本来就由低频决定 —— 补 6 dB 后低频净增益仍是
//    -6 dB，输出峰值反而更低。于是"亮"从"变小声"变成"同音量下变亮"。
//    补偿仍然**永远 <= 1**（见 w_s2_c 的钳位），结构上不可能抬过输入峰值。
//
// 位置：small_room_reverb 之后、PT8211 之前（"总音色"）
//       依据 instrument_bank_core.v:166-172（混响）与 :305-321（输出合流）
//
// ---- 为什么这个结构"调不坏" ----------------------------------------------
// 1) 状态只有一阶低通（系数 a 恒在 (0,1)），增益是前馈乘在信号上、
//    不进状态递推 -> 任意参数、任意变化速率严格稳定
//    (Valimaki & Reiss, Appl. Sci. 6(5):129, 2016，一阶搁架；
//     phosphor-dsp 实测：direct-form 换系数有 15~26 dB click 能量，
//     且"逐点稳定"推不出"时变稳定"；Kalinichenko DAFx-2006 同结论)；
// 2) 量程 +-12 dB = 增益指数 v 落在 [-2,+2)，正好是 2 位 v_int 的
//    四档（x1/4,x1/2,x1,x2）覆盖范围；K=G-1 最大 3.0 -> Q15 98304，
//    18 位有符号（±131071）装得下，不会截断；
// 3) 响度补偿 Gc 恒 <= 1。亮方向最多补到 +6 dB（仅限于低频正在被压的
//    情形），暖方向不补 —— 所以绝对不会有"越调越响"而削顶；
// 4) 出口还有 32000 以上 1/4 斜率软限幅，作最后保险。
//
// ---- 连续性的三个来源 -----------------------------------------------------
//   (1) 参数 12 bit（4096 级）；
//   (2) 增益 G = 2^(s/16384)，65 点表 + 8 bit 插值 -> 每倍频程 16384 级；
//   (3) 参数一阶平滑 tau = 2^SLEW_SHIFT/Fs = 10.5 ms。
//
// ---- 资源 ---------------------------------------------------------------
//   单 18x18 乘法器分时，每样本 7 次乘（4 音频 + 1 补偿 + 2 查表插值），
//   36 拍/样本。固定延迟：i_sample_valid -> o_sample_valid = 15 拍。
//=============================================================================
module timbre_shaper #(
    // a = 1 - exp(-2*pi*fc/Fs)，Fs = 48828.125 Hz
    // R48：低架 600 -> 1200 Hz。低架只负责"亮"方向（压基频/琴体主模态），
    //      拐点抬高后 273 Hz 的压制量从 -5.5 dB 变成 -11 dB 量级，同一倾斜
    //      量下听感差异大得多；同时 300~1200 Hz 变成连续斜坡，不再是两级台阶。
    //      A = 1-exp(-2*pi*1200/48828.125) = 0.143084, x65536 = 9377
    parameter integer A_LOW_Q16  = 9377,    // fc = 1200 Hz
    // 高架 1200 -> 300 Hz。高架只负责"暖"方向（切谐波）。原来 1200 Hz 时
    // 暖满在 400~1600 Hz 只动 -3.3/-6.1 dB（该段能量占 99%），听不出；
    // 压到 300 Hz 后变成 -6.4/-9.5 dB，且 1600~3200 Hz 从 -12.3 到 -14.7。
    //      A = 1-exp(-2*pi*300/48828.125) = 0.037868, x65536 = 2482
    parameter integer A_HIGH_Q16 = 2482,    // fc = 300 Hz
    parameter integer PARAM_WIDTH = 12,     // 0..4095，2048 = 中性
    parameter integer SLEW_SHIFT  = 9,      // tau = 512/Fs = 10.5 ms
    // 软限幅拐点。原版 30000，但 R14 起 r_dry 的 8 声部峰值就到 31999，
    // 30000 会在"旁路档"也压掉 1.5 dB（实测 31998 -> 30500，不是 1:1 直通）。
    // 改成 32000：本信号链的任何合法输入都不触发，旁路档严格直通。
    parameter integer SOFT_KNEE   = 32000,
    // 峰值归一化响度补偿的上限抬升量（Q 单位：16384 = 1 倍频程 = 6.02 dB）
    // R48：改成"亮方向专用的回补上限"，只在低频正在被压（v_warm<0）时生效。
    //   8192 = +3.01 dB。
    //
    //   最初取 16384(+6 dB)，三份独立评审一致否掉：拨弦起音的前 5 ms 和弓毛
    //   噪声是宽带的，那一瞬间波形峰值可能由高频决定，"低频被压 12 dB 所以
    //   峰值空出来了"这个前提在瞬态上不成立。取 +3 dB 后传递函数峰值从
    //   +5.4 dB 降到 +2.4 dB（实测 tb_timbre_r48 T2），倾斜量完全不变
    //   （100 Hz -16.8 / 8 kHz +2.3，仍是 19.1 dB），只是整体降 3 dB。
    //   即：**这个参数只改绝对电平，不改音色对比**，所以往下取没有听感代价。
    parameter integer COMP_LIFT   = 8192
)(
    input  wire                   i_clk,
    input  wire                   i_reset,
    input  wire                   i_sample_valid,  // 单拍脉冲，每样本一次
    input  wire signed [15:0]     i_sample,
    input  wire [PARAM_WIDTH-1:0] i_bright,        // 高频 0..4095，2048 = 0 dB
    input  wire [PARAM_WIDTH-1:0] i_warm,          // 低频 0..4095，2048 = 0 dB
    input  wire                   i_enable,        // 0 = 平滑回到精确直通
    output reg  signed [15:0]     o_sample,
    output reg                    o_sample_valid,
    output reg  [15:0]            o_clip_count,    // 软限幅动作次数
    output reg  signed [17:0]     o_gain_low,      // K_lo = Glo-1（诊断）
    output reg  signed [17:0]     o_gain_high
);
    //------------------------------------------------------------------
    // 窄化 / 饱和工具
    //------------------------------------------------------------------
    function signed [17:0] clamp18;          // 24 bit -> 18 bit 饱和
        input signed [23:0] v;
        begin
            if (v > 24'sd131071)       clamp18 = 18'sd131071;
            else if (v < -24'sd131072) clamp18 = -18'sd131072;
            else                       clamp18 = v[17:0];
        end
    endfunction

    //------------------------------------------------------------------
    // 参数平滑：目标 = param<<4（中性 32768），一阶低通，逐样本更新
    //
    // R48：加"接近即吸附"。原式的 (diff >>> 9) 在 |diff| < 512 时恒为 0，
    //   一阶低通就停住了 —— 实测把音色拧到底再拧回中点，r_p 会停在
    //   32768-511，对应 v=-0.031，高频端仍有 -0.19 dB 衰减，
    //   "回到中性 = 逐位直通"这个承诺就不成立了（tb_timbre_r48 的 T2
    //   中性列原本读 -0.18 dB）。加吸附后 |diff|<512 直接写目标值，
    //   中性档从此严格等于复位态。
    //   diff 用 17 位就够：w_tgt 最大 4095<<4 = 65520，|diff| <= 65520，
    //   17 位有符号上限 65535，不会溢出。
    //------------------------------------------------------------------
    reg signed [16:0] r_p_b, r_p_w;
    wire signed [16:0] w_tgt_b = i_enable ? {5'd0, i_bright, 4'd0} : 17'sd32768;
    wire signed [16:0] w_tgt_w = i_enable ? {5'd0, i_warm,   4'd0} : 17'sd32768;
    wire signed [16:0] w_dif_b = w_tgt_b - r_p_b;
    wire signed [16:0] w_dif_w = w_tgt_w - r_p_w;
    wire               w_snap_b = (w_dif_b > -17'sd512) && (w_dif_b < 17'sd512);
    wire               w_snap_w = (w_dif_w > -17'sd512) && (w_dif_w < 17'sd512);

    always @(posedge i_clk) begin
        if (i_reset) begin
            r_p_b <= 17'sd32768;
            r_p_w <= 17'sd32768;
        end else if (i_sample_valid) begin
            r_p_b <= w_snap_b ? w_tgt_b : (r_p_b + (w_dif_b >>> SLEW_SHIFT));
            r_p_w <= w_snap_w ? w_tgt_w : (r_p_w + (w_dif_w >>> SLEW_SHIFT));
        end
    end

    //------------------------------------------------------------------
    // 参数 -> 增益指数
    //   s   = p - 32768   in [-32768, 32752]
    //   s2  = s           in [-32768, 32752]  -> v = s2/16384 in [-2, 2)
    //
    // R48：量程从 +-9 dB 扩到 +-12 dB（s2 的系数 3/4 -> 1）。
    //   上限是结构决定的，不是随便定的：v_int 只有 2 位，四档
    //   （x1/4, x1/2, x1, x2）刚好覆盖 v in [-2, +2)；再大就表达不了。
    //   同时 K = G-1 最大 3.0 -> Q15 98304，在 18 位有符号（+-131071）内，
    //   乘法器操作数不会被 clamp18 截断。
    //
    //   为什么必须扩量程：峰值归一化把被抬的那一端钉死在 0 dB，
    //   旋钮的"倾斜量"就等于量程本身。+-9 时亮满只把 273 Hz 压 8.6 dB，
    //   实测听不出；+-12 后同一档位的带内变化普遍再涨 30~90%。
    wire signed [16:0] w_s_b  = r_p_b - 17'sd32768;
    wire signed [16:0] w_s_w  = r_p_w - 17'sd32768;
    wire signed [16:0] w_s2_b = w_s_b;
    wire signed [16:0] w_s2_w = w_s_w;
    // ---- 响度补偿（R48：峰值归一化 + 亮方向回补） ------------------------
    // 峰值归一化：先取两个正增益里较大的那个（负增益不参与，否则单边衰减
    // 会反过来抬电平），补偿 -max(v_b,v_w,0)。于是整条幅频响应的最大值
    // 恒为 0 dB：任何档位下输出峰值都不会超过输入峰值，
    // 8 声部 31999 也只是 31999，不需要靠限幅兜底，也不会硬削。
    // （把 COMP_LIFT 调大就能换回"真的抬一点"，代价是 8 声部时会进限幅。）
    // 中性档 2048/2048 时 maxp=0、Gc=1，模块严格直通，听感与 R19 完全一致。
    //
    // R48 的改动只加了一条：当**低频正在被压**（v_warm<0）时，把补偿
    // 往上抬最多 COMP_LIFT，抬完仍然钳在 <= 0（即 Gc <= 1）。
    //   w_neg_w = max(-v_warm, 0)   低频被压掉多少
    //   w_lift  = min(w_neg_w, COMP_LIFT)
    // 三种边界都验过：
    //   亮满 (v_b=+2, v_w=-2): possum=2, lift=1 -> s2c=-1  -> Gc=0.5
    //   暖满 (v_b=-2, v_w=+2): possum=2, lift=0 -> s2c=-2  -> Gc=0.25
    //   中性 / 两个都衰减:     possum=0, lift>=possum -> s2c=0 -> Gc=1（不抬）
    wire signed [16:0] w_pos_b = w_s2_b[16] ? 17'sd0 : w_s2_b;
    wire signed [16:0] w_pos_w = w_s2_w[16] ? 17'sd0 : w_s2_w;
    wire signed [16:0] w_neg_w = w_s2_w[16] ? -w_s2_w : 17'sd0;
    wire signed [16:0] w_lift  = (w_neg_w > COMP_LIFT) ? COMP_LIFT : w_neg_w;

    // ---- 两个"正向增益"之和的钳位（只在非倾斜时有意义） ------------------
    // Gc = 2^-max(v_b,v_w,0) 对**倾斜**是精确的：两个架的极值一个 <1、一个 >1，
    // 乘积恰好 1，峰值 0 dB。
    // 但 tone_console 的两根独立滑杆可以同时往"提升"拉 —— 此时中频段是两个架
    // **相加**（各 +12 时实测 273 Hz 得 +18 dB），Gc 只补 -12，峰值 +6 dB
    // 会撞软限幅；内部 y2 还会撞 clamp18 的 4 倍上限，波形直接被削。
    // 网页和编码器只发倾斜，走不到这条路；为了不留一条会削顶的通路，
    // 这里把两个正向增益之和钳到 <= 32752（+12 dB），多出来的从较大的那个
    // 扣掉。倾斜时 w_possum 恰好等于 |v|，钳位不触发，行为与钳位前逐位相同。
    wire signed [17:0] w_possum    = {{1{w_pos_b[16]}}, w_pos_b}
                                   + {{1{w_pos_w[16]}}, w_pos_w};
    wire signed [17:0] w_ovf       = (w_possum > 18'sd32752) ? (w_possum - 18'sd32752)
                                                             : 18'sd0;
    wire signed [17:0] w_b_lim     = (w_pos_b >= w_pos_w) ? ({{1{w_pos_b[16]}}, w_pos_b} - w_ovf)
                                                          : {{1{w_pos_b[16]}}, w_pos_b};
    wire signed [17:0] w_w_lim     = (w_pos_b >= w_pos_w) ? {{1{w_pos_w[16]}}, w_pos_w}
                                                          : ({{1{w_pos_w[16]}}, w_pos_w} - w_ovf);
    wire signed [16:0] w_s2_b_lim  = w_s2_b[16] ? w_s2_b : w_b_lim[16:0];
    wire signed [16:0] w_s2_w_lim  = w_s2_w[16] ? w_s2_w : w_w_lim[16:0];
    wire signed [17:0] w_possum_l  = (w_possum > 18'sd32752) ? 18'sd32752 : w_possum;
    // Gc 指数 = lift - (两个正向增益之和)。倾斜时 sum == maxp，与旧式等价。
    wire signed [17:0] w_s2_c18    = {w_lift[16], w_lift} - w_possum_l;
    wire signed [16:0] w_s2_c      = (w_s2_c18 >= 18'sd0) ? 17'sd0 : w_s2_c18[16:0];

    wire [1:0] w_vint_b = w_s2_b_lim[15:14];
    wire [1:0] w_vint_w = w_s2_w_lim[15:14];
    wire [1:0] w_vint_c = w_s2_c[15:14];
    wire [5:0] w_idx_b  = w_s2_b_lim[13:8];
    wire [5:0] w_idx_w  = w_s2_w_lim[13:8];
    wire [5:0] w_idx_c  = w_s2_c[13:8];
    wire [7:0] w_frac_b = w_s2_b_lim[7:0];
    wire [7:0] w_frac_w = w_s2_w_lim[7:0];
    wire [7:0] w_frac_c = w_s2_c[7:0];

    //------------------------------------------------------------------
    // 单口查表：地址寄存一拍，三条曲线顺序读取
    //------------------------------------------------------------------
`include "timbre_pow2_table.vh"

    reg  [6:0]  r_addr;
    wire [17:0] w_rom = timbre_pow2_q15(r_addr);
    reg  [17:0] r_t0;
    reg  [18:0] r_poly_b, r_poly_w, r_poly_c;
    wire [17:0] w_dt = w_rom - r_t0;         // 表单调递增，恒为正

    // 2^(v) 的整倍频程部分：v_int in {-2,-1,0,+1}
    function signed [19:0] shift_oct;
        input [18:0] poly;
        input [1:0]  vint;
        reg   signed [19:0] v;
        begin
            v = $signed({1'b0, poly});
            case (vint)
                2'b10:   shift_oct = v >>> 2;
                2'b11:   shift_oct = v >>> 1;
                2'b00:   shift_oct = v;
                default: shift_oct = v <<< 1;
            endcase
        end
    endfunction

    wire signed [19:0] w_g_b = shift_oct(r_poly_b, w_vint_b);
    wire signed [19:0] w_g_w = shift_oct(r_poly_w, w_vint_w);
    wire signed [19:0] w_g_c = shift_oct(r_poly_c, w_vint_c);

    // K = G - 1（Q2.15），限幅到 18 bit 供乘法器使用
    wire signed [19:0] w_k_b   = w_g_b - 20'sd32768;
    wire signed [19:0] w_k_w   = w_g_w - 20'sd32768;
    wire signed [17:0] w_k_b18 = clamp18({{4{w_k_b[19]}}, w_k_b});
    wire signed [17:0] w_k_w18 = clamp18({{4{w_k_w[19]}}, w_k_w});
    wire signed [17:0] w_gc18  = clamp18({{4{w_g_c[19]}}, w_g_c});

    //------------------------------------------------------------------
    // 音频状态
    //------------------------------------------------------------------
    reg signed [23:0] r_x;
    reg signed [23:0] r_lp1, r_lp2, r_y1, r_y2;
    reg signed [17:0] r_k_lo, r_k_hi, r_gc;
    reg signed [23:0] r_inc;
    reg signed [17:0] r_mula, r_mulb;
    reg signed [35:0] r_prod;

    always @(posedge i_clk) r_prod <= r_mula * r_mulb;

    wire signed [23:0] w_lp1_n = clamp18(r_lp1 + r_inc);
    wire signed [23:0] w_lp2_n = clamp18(r_lp2 + r_inc);
    wire signed [23:0] w_y1_n  = clamp18(r_x   + r_inc);
    wire signed [23:0] w_y2_n  = clamp18(r_y1  + r_inc);

    wire signed [23:0] w_d2n   = (w_y1_n - r_lp2) >>> 1;  // 用更新后的 y1
    wire signed [23:0] w_d2n2  = (r_y1 - w_lp2_n) >>> 1;  // 用更新后的 lp2

    // 出口软限幅：|v| <= KNEE 直通，超出按 1/4 斜率压缩（渐近 30000+8192）
    localparam signed [23:0] KNEE24 = SOFT_KNEE;
    wire signed [23:0] w_y3 = r_prod >>> 15;
    reg  signed [23:0] w_soft;
    always @(*) begin
        if (w_y3 > KNEE24)
            w_soft = KNEE24 + ((w_y3 - KNEE24) >>> 2);
        else if (w_y3 < -KNEE24)
            w_soft = -KNEE24 + ((w_y3 + KNEE24) >>> 2);
        else
            w_soft = w_y3;
    end
    wire signed [15:0] w_out16 = (w_soft > 24'sd32767)  ? 16'sd32767 :
                                 (w_soft < -24'sd32768) ? -16'sd32768 : w_soft[15:0];

    //------------------------------------------------------------------
    // 主相位机（36 拍/样本）
    //   乘法器带输出寄存器：操作数在相位 P 装入，结果在 P+2 可用，
    //   所以每个 issue 后必须插一个 hold 相位。
    //------------------------------------------------------------------
    reg [5:0] r_ph;

    always @(posedge i_clk) begin
        if (i_reset) begin
            r_ph   <= 6'd0;
            r_x    <= 24'sd0;
            r_lp1  <= 24'sd0; r_lp2 <= 24'sd0;
            r_y1   <= 24'sd0; r_y2  <= 24'sd0;
            r_inc  <= 24'sd0;
            r_mula <= 18'sd0; r_mulb <= 18'sd0;
            r_k_lo <= 18'sd0; r_k_hi <= 18'sd0; r_gc <= 18'sd32768;
            r_addr <= 7'd0; r_t0 <= 18'd0;
            r_poly_b <= 19'd0; r_poly_w <= 19'd0; r_poly_c <= 19'd32768;
            o_sample <= 16'sd0; o_sample_valid <= 1'b0; o_clip_count <= 16'd0;
            o_gain_low <= 18'sd0; o_gain_high <= 18'sd0;
        end else begin
            o_sample_valid <= 1'b0;
            case (r_ph)
            //---------- 音频：低架 ----------
            6'd1: begin
                r_x    <= {{8{i_sample[15]}}, i_sample};
                r_mula <= A_LOW_Q16;
                r_mulb <= clamp18({{8{i_sample[15]}}, i_sample} - r_lp1);
                r_ph   <= 6'd2;
            end
            6'd2: r_ph <= 6'd3;                       // hold
            6'd3: begin
                r_inc  <= r_prod >>> 16;
                r_ph   <= 6'd4;
            end
            6'd4: begin
                r_lp1  <= w_lp1_n;
                r_mula <= r_k_lo;
                r_mulb <= clamp18(w_lp1_n);
                r_ph   <= 6'd5;
            end
            6'd5: r_ph <= 6'd6;                       // hold
            6'd6: begin
                r_inc  <= r_prod >>> 15;
                r_ph   <= 6'd7;
            end
            6'd7: begin
                r_y1   <= w_y1_n;
                r_mula <= A_HIGH_Q16;
                r_mulb <= clamp18(w_d2n);
                r_ph   <= 6'd8;
            end
            //---------- 音频：高架 ----------
            6'd8: r_ph <= 6'd9;                       // hold
            6'd9: begin
                r_inc  <= r_prod >>> 15;
                r_ph   <= 6'd10;
            end
            6'd10: begin
                r_lp2  <= w_lp2_n;
                r_mula <= r_k_hi;
                r_mulb <= clamp18(w_d2n2);
                r_ph   <= 6'd11;
            end
            6'd11: r_ph <= 6'd12;                     // hold
            6'd12: begin
                r_inc  <= r_prod >>> 14;
                r_ph   <= 6'd13;
            end
            6'd13: begin
                r_y2   <= w_y2_n;
                r_mula <= r_gc;                       // 响度补偿
                r_mulb <= clamp18(w_y2_n);
                r_ph   <= 6'd14;
            end
            6'd14: r_ph <= 6'd15;                     // hold
            6'd15: begin
                o_sample       <= w_out16;
                o_sample_valid <= 1'b1;
                if (w_y3 > SOFT_KNEE || w_y3 < -SOFT_KNEE)
                    o_clip_count <= o_clip_count + 16'd1;
                r_ph <= 6'd16;
            end
            //---------- 增益查表：warm（低架）----------
            6'd16: begin r_addr <= {1'b0, w_idx_w};                      r_ph <= 6'd17; end
            6'd17: begin r_t0 <= w_rom; r_addr <= {1'b0, w_idx_w} + 7'd1; r_ph <= 6'd18; end
            6'd18: begin r_mula <= {1'b0, w_dt[16:0]};
                          r_mulb <= {10'd0, w_frac_w};                   r_ph <= 6'd19; end
            6'd19: r_ph <= 6'd20;                     // hold
            6'd20: begin r_poly_w <= r_t0 + {9'd0, r_prod[17:8]};        r_ph <= 6'd21; end
            6'd21: begin r_k_lo <= i_enable ? w_k_w18 : 18'sd0;
                          o_gain_low <= w_k_w18;                         r_ph <= 6'd22; end
            //---------- 增益查表：bright（高架）----------
            6'd22: begin r_addr <= {1'b0, w_idx_b};                      r_ph <= 6'd23; end
            6'd23: begin r_t0 <= w_rom; r_addr <= {1'b0, w_idx_b} + 7'd1; r_ph <= 6'd24; end
            6'd24: begin r_mula <= {1'b0, w_dt[16:0]};
                          r_mulb <= {10'd0, w_frac_b};                   r_ph <= 6'd25; end
            6'd25: r_ph <= 6'd26;                     // hold
            6'd26: begin r_poly_b <= r_t0 + {9'd0, r_prod[17:8]};        r_ph <= 6'd27; end
            6'd27: begin r_k_hi <= i_enable ? w_k_b18 : 18'sd0;
                          o_gain_high <= w_k_b18;                        r_ph <= 6'd28; end
            //---------- 增益查表：补偿 ----------
            6'd28: begin r_addr <= {1'b0, w_idx_c};                      r_ph <= 6'd29; end
            6'd29: begin r_t0 <= w_rom; r_addr <= {1'b0, w_idx_c} + 7'd1; r_ph <= 6'd30; end
            6'd30: begin r_mula <= {1'b0, w_dt[16:0]};
                          r_mulb <= {10'd0, w_frac_c};                   r_ph <= 6'd31; end
            6'd31: r_ph <= 6'd32;                     // hold
            6'd32: begin r_poly_c <= r_t0 + {9'd0, r_prod[17:8]};        r_ph <= 6'd33; end
            6'd33: begin r_gc <= i_enable ? w_gc18 : 18'sd32768;         r_ph <= 6'd34; end
            //---------- 等下一次样本 ----------
            default: begin
                r_ph <= i_sample_valid ? 6'd1 : 6'd0;
            end
            endcase
        end
    end
endmodule
