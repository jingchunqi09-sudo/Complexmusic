//-----------------------------------------------------------------------------
// rh5_core_ch.v —— 右手多弦识别 v5 的单通道前端
//
// 与 v4（rh4_core_ch）的差别只在包络：
//   v4: 一级包络 τ=2.6 ms，靠"包络峰 + 固定死区"判事件 -> 衰减音里的 40 Hz 拍频
//       每 25 ms 造一个峰，一次弹奏被报成 3~9 次
//   v5: 两级包络 ef(τ=1.32 ms) -> es(τ=10.55 ms)，判决用 **es 的 6 ms 增长比**
//
// 频带与包络（v5 定标时 fs = 12136 Hz/通道）：
//   一阶高通 fc=55 Hz,  a = 1/(1+2π·55/fs) = 0.9723 -> 249/256，两级
//   一阶低通 fc=900 Hz, b = w/(1+w) = 0.3179     -> 81/256，一级
// 包络：
//   ef += (|y| - ef) >> EF_S    2^4  = 16 样本  = 1.32 ms
//   es += (ef - es) >> ES_S     2^7  = 128 样本 = 10.55 ms
//
// 2026-10-31 v11（采样率翻倍/三倍）后这些常数全部变成参数，由 rh5_string_det
// 从顶层传进来，物理响应保持不变。判据用的是"6 ms 内涨 2.25 倍"，它只依赖
// 6 ms 这个物理时长（LAG = 6 ms × fs），与 fs 本身无关。
//
// 判决量：es(t) 与 LAG 个样本前的 es 比较。
// 一次拨弦在 3~6 ms 内把 es 抬高 2.25 倍以上；拍频 6 ms 内最多 1.13 倍。
//
// 所有乘加都在 32 位 signed 中间量里算完再截位 —— Verilog 的表达式宽度由
// 上下文决定，直接写 16 位会静默回绕（v3 踩过这个坑）。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module piezo_band_ch #(
    parameter integer DC   = 2047,
    parameter integer HP_K = 249,      // 高通 a = HP_K/256
    parameter integer LP_K = 81,       // 低通 a = LP_K/256
    parameter integer EF_S = 4,        // 快包络 τ = 2^EF_S 样本
    parameter integer ES_S = 7,        // 慢包络 τ = 2^ES_S 样本
    parameter integer LAG  = 73,       // 6.0 ms @12.136 kHz
    parameter integer LAG2 = 1,        // rh6 的重拨回看窗（24 ms）；rh5 用不到，置 1
    parameter integer ES_FRAC = 0,     // es/ef 输出保留的小数位数（0=整数，rh6 用 4）
    parameter integer GATE = 8         // 触发门限（es 码值）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire [11:0] sample_code,
    output reg  [15:0] es,             // 慢包络（判决量）
    output reg  [15:0] es_lag,         // LAG 个样本之前的慢包络
    output reg  [15:0] es_lag2,        // LAG2 个样本之前的慢包络（rh6 重拨判据用）
    output reg  [15:0] ef,             // 快包络（rh6 的瞬态门用）
    output reg  [15:0] absy,           // 带通后瞬时 |y|（调试）
    output reg         ysign,          // 带通后 y 的符号（1=负）。rh6 用它算通道对同相率
    output reg         trig            // 单周期触发脉冲
);

    reg signed [31:0] x1, hp1;
    reg signed [31:0] x2, hp2;
    reg signed [31:0] lp1;
    reg signed [31:0] ef_s, es_s;      // Q8 定点：低 8 位是小数

    // 整条链必须带小数位（Q8），原因有两条，都是实测踩出来的：
    //  1) 包络若用整数做 `env += (x-env)>>4`，|x-env|<16 时增量为 0，
    //     包络会永远停在输入下方十余个码值处；
    //  2) 滤波器若用整数做 `y = 249*(...)/256`，任何 -1 都会被 249/256 截成 -1，
    //     负向直流永远衰减不到 0 —— 实测 CH1 留下 3 个码值的假底噪，
    //     轻拨（8~15 码）就被这层假底噪淹掉。
    localparam integer EQ = 8;
    // 输出定点的小数位数：rh5（整数）用 0，rh6 用 4。
    // 为什么必须有小数位：rh6 的重拨判据是「24 ms 涨 1.35 倍」，只留整数时
    // es=10 附近的量化误差就有 10%，判据的余量被吃掉，实测 RTL 在扫弦上比
    // float 模型多报 50%（36→54）。留 4 位小数后两边一致（见 g16_parity.py）。
    localparam integer ESH = EQ - ES_FRAC;

    wire signed [31:0] x  = ($signed({20'd0, sample_code}) - DC) <<< EQ;
    wire signed [31:0] h1 = (HP_K * ((x - x1) + hp1)) >>> 8;
    wire signed [31:0] h2 = (HP_K * ((h1 - x2) + hp2)) >>> 8;
    wire signed [31:0] l1 = (LP_K * h2 + (256 - LP_K) * lp1) >>> 8;
    wire        [23:0] ayq = l1[31] ? (24'd0 - l1[23:0]) : l1[23:0];   // |y| in Q8
    wire        [15:0] ay  = ayq[15 + EQ:EQ];

    // ---- 两级包络（Q8）----
    wire signed [31:0] d1   = $signed({12'd0, ayq}) - ef_s;
    wire signed [31:0] ef_n = ef_s + (d1 >>> EF_S);
    wire signed [31:0] d2   = ef_n - es_s;
    wire signed [31:0] es_n = es_s + (d2 >>> ES_S);

    wire [15:0] es_i = es_n[31] ? 16'd0 : es_n[15 + ESH : ESH];   // 整数部分（或 Q(ES_FRAC)）

    // ---- 6 ms 延迟线（每个通道自己的样本节拍）----
    reg [15:0] dl [0:LAG-1];
    integer i;
    reg [15:0] es_lag_n;

    // ---- 24 ms 延迟线（rh6 重拨判据用；LAG2=1 时退化成一级寄存器）----
    reg [15:0] dl2 [0:LAG2-1];
    integer j;
    reg [15:0] es_lag2_n;

    // ---- 倍增判据：4*es > 9*es_lag 且 es >= GATE ----
    // 这一级必须打一拍：es_n 是 4 级串行加法（d1→ef_n→d2→es_n）的结果，
    // 若再把 18 位比较器和门限判断串在同一条组合路径上，50 MHz 就差了 0.1 ns
    // （v10 首版：Fmax 49.71 MHz、4 个 setup 违例全在这条路上）。
    reg        vld_d;
    reg [15:0] es_d, lag_d;
    always @(posedge clk) begin
        if (!rst_n) begin
            vld_d <= 1'b0; es_d <= 16'd0; lag_d <= 16'd0;
        end else begin
            vld_d <= sample_valid;
            if (sample_valid) begin
                es_d  <= es_i;
                lag_d <= es_lag_n;
            end
        end
    end

    localparam [15:0] GATE16 = GATE << ES_FRAC;
    wire [19:0] es4  = {4'd0, es_d, 2'b00};                       // 4×es
    wire [19:0] lag9 = {4'd0, lag_d} + {1'b0, lag_d, 3'b000};     // 9×es_lag
    wire        hit  = vld_d && (es_d >= GATE16) && (es4 > lag9);

    always @(posedge clk) begin
        if (!rst_n) begin
            x1 <= 0; hp1 <= 0; x2 <= 0; hp2 <= 0; lp1 <= 0;
            ef_s <= 0; es_s <= 0;
            ef <= 0; es <= 0; es_lag <= 0; es_lag2 <= 0; absy <= 0;
            ysign <= 1'b0; trig <= 1'b0;
            es_lag_n = 16'd0;
            es_lag2_n = 16'd0;
            for (i = 0; i < LAG; i = i + 1) dl[i] <= 16'd0;
            for (j = 0; j < LAG2; j = j + 1) dl2[j] <= 16'd0;
        end else begin
            trig <= hit;
            if (sample_valid) begin
                x1  <= x;
                hp1 <= h1;
                x2  <= h1;
                hp2 <= h2;
                lp1 <= l1;
                absy <= ay;
                ysign <= l1[31];       // 只多一个触发器，不进任何组合路径

                ef_s <= ef_n;
                es_s <= es_n;
                ef   <= ef_n[15 + ESH:ESH];
                es   <= es_i;

                es_lag_n = dl[LAG-1];
                es_lag   <= dl[LAG-1];
                for (i = LAG - 1; i > 0; i = i - 1) dl[i] <= dl[i-1];
                dl[0] <= es_i;

                es_lag2_n = dl2[LAG2-1];
                es_lag2   <= dl2[LAG2-1];
                for (j = LAG2 - 1; j > 0; j = j - 1) dl2[j] <= dl2[j-1];
                dl2[0] <= es_i;
            end
        end
    end

endmodule

`default_nettype wire
