//-----------------------------------------------------------------------------
// ms_core_ch.v —— 单通道压电前端（算法 v3，2026-10-30 移植进生产）
//
// 来源：main_piezo_hspi_20261028/src/ms_core_ch.v（deepseek 版本，行为仿真与
// Python algo_v3 逐点一致）。本文件在其基础上新增一条**独立的发声 fire 路径**，
// cand_valid 识别路径的逻辑、参数与计时完全不变，因此原有的"与 Python 参考
// 算法一致"的证据继续有效。
//
// 滤波/包络（全部一阶 + 移位，无除法器）：
//   x    = code - DC                          去直流（每通道常数，CH3=1882）
//   hp   = (235 * (x - x1 + hp1)) >>> 8       一阶高通，fc ≈ 82 Hz
//   lp   = (hp + 3*lp1) >>> 2                 一阶低通，a=0.75
//   e3  += (|lp| - e3) >>> 3                  快包络 τ ≈ 1.3 ms
//   e9  += ((|lp|<<8) - e9) >>> 9             慢包络 τ ≈ 83 ms（Q8）
//   辅助：lo1/lo2（a=0.80）与 hi1（a=0.30），用于高频能量比
//
// 起振判据（与 algo_v3.py 相同）：
//   cond = (e3 > GATE) && ((e3 - e3[n-8]) << 8 > e9) && n >= WARM
//   —— 上升速度判据，拍频/衰减内小峰的 rise 只有 0.4~1.6，真实击弦 2.2~16，
//      静止时 e3/e9 同处噪声底，rise≈0，因此"不碰不响"。
//
// 发声 fire 路径（新增，与 cand 路径的 refr 完全独立）：
//   段首（cond && !seg 且 fire_refr==0）后第 LAG 个样本发单周期 fire，
//   力度取当时的 e3 按 INV 归一化（≈e3*256/REF，钳位 [24,255]）。
//   延迟 = 起振检测(数样本) + LAG(8)样本 ≈ 2~3 ms @6.2kHz，满足实时演奏；
//   此时 e3 已过快包络上升段，力度接近真实峰值。
//   fire_refr = REFR(250 ms) 保证一次动作只发一次声。
//
// 注意：Verilog 表达式位宽由上下文决定。所有乘积/左移都先落到 32 位中间量。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module ms_core_ch #(
    parameter integer DC   = 2051,
    parameter integer GATE = 13,
    parameter integer WARM = 1860,
    parameter integer REFR = 1550,
    parameter integer INV  = 172          // ≈65536/REF，用于发声力度归一化
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire [11:0] sample_code,
    output reg         cand_valid,
    output reg  [31:0] cand_pos,
    output reg  [16:0] cand_peak,
    output reg  [15:0] cand_amp,
    output wire [15:0] ay,
    output wire [15:0] lov,
    output wire [15:0] hiv,
    output wire        warm_done,
    // 发声路径（快速，独立于识别 cand 路径）
    output reg         fire,
    output reg  [7:0]  fire_vel
);

    localparam integer LAG = 8;

    reg signed [31:0] x1, hp1, lp1, lo1, lo2, hi1;
    reg        [15:0] e3;
    reg        [23:0] e9;
    reg        [15:0] e3d [0:LAG-1];
    reg        [31:0] n;
    reg        [15:0] refr;
    reg               seg;
    reg        [16:0] seg_peak;
    reg        [15:0] seg_amp;   // 段内 |y| 峰值（供顶层做归属）
    reg        [31:0] seg_pos;
    reg        [5:0]  gap;

    // 发声路径状态
    reg               fire_pend;
    reg        [3:0]  fire_cnt;
    reg        [15:0] fire_refr;
    reg               seg_fired;   // 本段已发声，段结束时才重装不应期

    // ---------- 滤波（常数乘法全部展开为移位加，零 DSP；与乘法数学等价） ----------
    // R7 时序：hp/lp 在 sample_valid 拍计算并寄存 lp_r；lo/hi/e3/e9 与全部
    // 样本状态在 lp_valid 拍（晚一个 50MHz 时钟 = 20ns）更新。样本间隔 162us，
    // 20ns 的流水延迟对算法在样本时间尺度上无任何影响（cand_pos/n 统一晚一拍）。
    wire signed [31:0] x    = $signed({20'd0, sample_code}) - DC;
    wire signed [31:0] hpd  = (x - x1) + hp1;
    // 235 = 256-16-4-1
    wire signed [31:0] hp   = ((hpd<<<8) - (hpd<<<4) - (hpd<<<2) - hpd) >>> 8;
    // 3*lp1 = (lp1<<1)+lp1
    wire signed [31:0] lpd  = hp + (lp1<<<1) + lp1;
    wire signed [31:0] lp   = lpd >>> 2;
    reg  signed [31:0] lp_r;      // lp 流水寄存
    reg                lp_valid;
    wire signed [31:0] lpv  = lp_r;
    // 51 = 32+16+2+1；205 = 256-51
    wire signed [31:0] lp51  = (lpv<<<5) + (lpv<<<4) + (lpv<<<1) + lpv;
    wire signed [31:0] lo1d = (lp51 + ((lo1<<<8) - ((lo1<<<5)+(lo1<<<4)+(lo1<<<1)+lo1))) >>> 8;
    wire signed [31:0] lo151 = (lo1<<<5) + (lo1<<<4) + (lo1<<<1) + lo1;
    wire signed [31:0] lo2d = (lo151 + ((lo2<<<8) - ((lo2<<<5)+(lo2<<<4)+(lo2<<<1)+lo2))) >>> 8;
    // 179 = 256-77；77 = 64+8+4+1
    wire signed [31:0] hi77 = (hi1<<<6) + (hi1<<<3) + (hi1<<<2) + hi1;
    wire signed [31:0] hi1d = (((lpv<<<8) - ((lpv<<<6)+(lpv<<<3)+(lpv<<<2)+lpv)) + hi77) >>> 8;

    wire [15:0] ay_w  = lpv[31] ? (16'd0 - lpv[15:0]) : lpv[15:0];
    wire [15:0] lov_w = lo2[31] ? (16'd0 - lo2[15:0]) : lo2[15:0];
    wire signed [31:0] hid = hi1 - lo2;
    wire [15:0] hiv_w = hid[31] ? (16'd0 - hid[15:0]) : hid[15:0];

    assign ay  = ay_w;
    assign lov = lov_w;
    assign hiv = hiv_w;
    assign warm_done = (n >= WARM);

    // ---------- 包络（signed 上下文算完再截位）----------
    wire signed [16:0] d3 = $signed({1'b0, ay_w}) - $signed({1'b0, e3});
    wire signed [16:0] e3_next = $signed({1'b0, e3}) + (d3 >>> 3);
    wire signed [24:0] d9 = $signed({9'd0, ay_w}) - $signed({1'b0, e9});
    wire signed [24:0] e9_next = $signed({1'b0, e9}) + (d9 >>> 9);

    // ---------- 起振 ----------
    wire [15:0] e3d8 = e3d[LAG-1];
    wire signed [16:0] rise  = $signed({1'b0, e3}) - $signed({1'b0, e3d8});
    wire signed [31:0] rise8 = rise <<< 8;
    wire signed [31:0] e9s   = $signed({8'd0, e9});
    wire cond = warm_done && (e3 > GATE) && (rise8 > e9s);

    // ---------- 发声力度归一化：vel ≈ e3*256/REF，钳位 [24,255] ----------
    wire [31:0] vel_scaled = (e3 * INV) >> 8;
    wire [7:0]  vel_w = (vel_scaled > 32'd255) ? 8'd255 :
                        (vel_scaled < 32'd24)  ? 8'd24  : vel_scaled[7:0];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            x1 <= 0; hp1 <= 0; lp1 <= 0; lo1 <= 0; lo2 <= 0; hi1 <= 0;
            e3 <= 0; e9 <= 0;
            for (i = 0; i < LAG; i = i + 1) e3d[i] <= 0;
            n <= 0; refr <= 0; seg <= 1'b0; seg_peak <= 0; seg_pos <= 0; gap <= 0;
            seg_amp <= 0; lp_r <= 0; lp_valid <= 1'b0;
            cand_valid <= 1'b0; cand_pos <= 0; cand_peak <= 0; cand_amp <= 0;
            fire <= 1'b0; fire_vel <= 8'd0; fire_pend <= 1'b0;
            fire_cnt <= 4'd0; fire_refr <= 16'd0; seg_fired <= 1'b0;
        end else begin
            cand_valid <= 1'b0;
            fire <= 1'b0;
            // 第一拍：hp/lp 计算并寄存（x1/hp1 递归在此拍）
            lp_valid <= sample_valid;
            if (sample_valid) begin
                x1  <= x;
                hp1 <= hp;
                lp_r <= lp;
            end
            // 第二拍：lo/hi/e3/e9 与全部样本状态（晚一拍，数学不变）
            if (lp_valid) begin
                lp1 <= lp_r;
                lo1 <= lo1d;
                lo2 <= lo2d;
                hi1 <= hi1d;

                e3 <= e3_next[15:0];
                e9 <= e9_next[23:0];

                for (i = LAG - 1; i > 0; i = i - 1) e3d[i] <= e3d[i-1];
                e3d[0] <= e3;

                n <= n + 1;
                if (refr != 0) refr <= refr - 1'b1;

                // ---- 发声路径：段首后第 LAG 个样本触发 ----
                // 不应期从"段结束"起算（与 cand 路径一致）：若从段首起算，
                // 衰减段的拍频残余在 250 ms 后会形成新段首导致重复发声
                // （14 s 真实数据实测多出 6 次 vel=24 的假 fire）。
                if (fire_refr != 0) fire_refr <= fire_refr - 1'b1;
                if (cond && !seg) begin
                    if (fire_refr == 0) begin
                        fire_pend <= 1'b1;
                        fire_cnt  <= 4'd0;
                    end
                end else if (fire_pend) begin
                    if (fire_cnt == LAG-1) begin
                        fire_pend <= 1'b0;
                        fire      <= 1'b1;
                        fire_vel  <= vel_w;
                        seg_fired <= 1'b1;
                    end else begin
                        fire_cnt <= fire_cnt + 1'b1;
                    end
                end

                // ---- 识别路径（与 deepseek 原版一致，不改动）----
                if (cond) begin
                    if (!seg) begin
                        seg <= 1'b1; seg_peak <= {1'b0, e3}; seg_pos <= n;
                        seg_amp <= ay_w;
                    end else begin
                        if (e3 > seg_peak[15:0]) begin
                            seg_peak <= {1'b0, e3}; seg_pos <= n;
                        end
                        if (ay_w > seg_amp) seg_amp <= ay_w;
                    end
                    gap <= 0;
                end else if (seg) begin
                    if (gap >= 6'd32) begin
                        seg <= 1'b0;
                        // 段结束：发声路径在此重装不应期（与 cand 同一起点）
                        if (seg_fired) fire_refr <= REFR[15:0];
                        seg_fired <= 1'b0;
                        if (refr == 0) begin
                            refr <= REFR;
                            cand_valid <= 1'b1;
                            cand_pos   <= seg_pos;
                            cand_peak  <= seg_peak;
                            cand_amp   <= seg_amp;
                        end
                    end else begin
                        gap <= gap + 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
