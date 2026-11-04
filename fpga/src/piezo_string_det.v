`timescale 1ns/1ps
`default_nettype none
//-----------------------------------------------------------------------------
// piezo_string_det.v —— 右手压电识别（R17，2026-11-01）
//
// 移植自 pc/数据采集 那批 790 个事件定标的 rh6 判据（压电采集固件已验证：
// Fmax 51.187 MHz / 0 违例 / RTL-Python 逐事件对拍一致），裁掉本工程用不到的
// 重拨判据（需要 24 ms 的 es 延迟线），保留三项真正解决现场问题的结构：
//
//  1) **前端换成 rh5_core_ch 的 55~900 Hz 带通 + 双包络**。
//     旧 piezo_transient_core 用三阶差分 (1-z^-1)^3 做判据量，实测（g20_sigvar.py）
//     它的带符号输出在真实数据上对「琴体传导 vs 局部激励」**零判别力**（0/41），
//     而 55~900 Hz 带通是 90.2%、主工程已有的 310~1k 带通是 87.8%。
//     选带通不是为了精度，是因为空间判据要的是「同一波前」的相位关系。
//
//  2) **时间常数按真实采样率重标**。主工程的 ADC 实际是 24.9 kSPS/通道
//     （GAP 1060 + SPI 800 + 转换 133 ≈ 2000 clk @50 MHz），而不是旧注释里的
//     6.1 kHz。R8 的 GUARD=60 在 24.9 kSPS 下只有 2.4 ms、包络 τ 短了 4 倍，
//     这才是「偶尔误识别、误响」的根因（拍频周期 84 ms 完全不在死区覆盖内）。
//     本模块所有时间量都按 ms × fs 推导，见参数表。
//
//  3) **8 ms 空间判据**：拍琴身/碰琴/脚踩是「四路平摊 + 两路同相」的结构传导，
//     拨弦是「一路独大 + 其余不相干」。两个条件同时成立才判为琴体事件：
//        sp_range  = (pk_max - pk_min)/pk_max <= 0.80  <=>  5*pk_min >= pk_max
//        sp_wagree = P/(P+N)                   >= 0.80  <=>  P >= 4*N
//
//     **这两个门限不是照抄报告，是按主工程 RTL 真实前端重新扫出来的**
//     （`pc/数据采集/g21_sweep_lp310.py` / `g21_out.txt`）。报告 §2 的
//     W2=0.85/0.80 是在 rh6 的「12 ms 波形峰」上标的；本模块用的是
//     「8 ms 四路 es 峰」，判决量口径不同，阈值必须重标。
//     12 个真实文件、100 个拍琴身簇、1034 个音乐簇的扫描结果：
//         R/W       拍琴身拒           音乐误杀
//         0.78/0.80  83/100 = 83%     0/1034
//         0.80/0.80  90/100 = 90%     0/1034   <- 采用（零误杀前沿）
//         0.80/0.85  88/100 = 88%     0/1034
//         0.82/0.85  90/100 = 90%     1/1034
//         0.85/0.85  91/100 = 91%     3/1034
//         0.90/0.85  94/100 = 94%    14/1034
//     报告 §2 说「收 sp_range 不涨拒绝率」在这里同样成立：0.80 再往下收
//     （0.78）拒绝率掉到 83%；而 0.80/0.80 已是零误杀下的最高点，抬 sp_wagree
//     只会丢拒绝率。判决点 t0+8 ms。
//
//  4) **拍琴身 → 颤音**（用户要求）：被空间判据拒绝的簇不再当作音符，
//     而是给正在发声的声部加颤音深度；停止拍击后按 16 ms/级衰减回 0。
//
// 与 piezo_onset_bank 的接口保持一致，另加 vibrato_depth / rej_total。
//
// ---- R61（延迟优先档，见 src/latency_profile.vh）----------------------------
// 本模块的判据结构**一行未改**，只把三个时基常量换了：
//     fs     24.9 kSPS -> 50.0 kSPS   （AD7091R-4 的 SCLK 1 MHz -> 3.125 MHz）
//     判决窗 8 ms       -> 4 ms        （WIN 199 -> 200 样本，帧数 50 不变）
//     死区   60 ms      -> 16 ms
// 所有判据（5*pk_min>=pk_max、P>=4*N、增长比、双包络比值）都是无量纲比值，
// 只依赖"同一时间窗内的相对关系"，所以时基减半不需要重标任何门限。
// 唯一需要跟着改的是 LAG：它是**绝对样本数**（一条 16 位延迟线），
// 从 6 ms 收到 3 ms，使 LAG/τ_es 的比值保持 0.59 不变 —— 语义等价，
// 而延迟线深度维持在 150（R60 是 148），FF 成本基本持平。
// 代价：判决窗只剩 4 ms，四路"平摊"与"同相"的统计样本少一半，
// 拍琴身（误当音符）的拒绝率会略降 —— 见 latency_profile.vh 第二节。
// ---------------------------------------------------------------------------
//-----------------------------------------------------------------------------
module piezo_string_det #(
    // ---- 前端（与 fs 绑定）----
    parameter integer HP_K = 249,       // 55 Hz 高通 a = 249/256（两级）
    parameter integer LP_K = 81,        // 900 Hz 低通 b = 81/256
    parameter integer EF_S = 5, // 快包络 τ = 32 样本 = 0.64 ms @50 kHz
    parameter integer ES_S = 8,         // 慢包络 τ = 256 样本 ≈ 5.1 ms @50 kHz
    parameter integer LAG  = 148,  // 增长比回看窗 3 ms（0.59τ，与 R60 同比例）
    // ---- 时间量，单位 = 通道样本数（fs = 50 kHz，单通道口径）----
    // R61：全部改为宏，真源在 src/latency_profile.vh 第三节。
    parameter integer WIN_MS   = 8,    // 合并/判决窗
    parameter integer DEAD_MS  = 60,   // 逐通道死区
    parameter integer REFR_H_MS= 24, // 全局硬消抖（无条件吸收）
    parameter integer REFR_S_MS= 60, // 全局软消抖（只吸收弱跟随者）
    parameter integer WARM_MS  = 250,   // 启动消隐，等滤波器收敛
    parameter integer FS_HZ    = 24900,
    parameter integer REVERSE_CHANNELS = 1,
    // ---- 每通道直流与门限（与采集固件同源；生产板增益不同需重标）----
    parameter integer DC0 = 2051, DC1 = 2050, DC2 = 2050, DC3 = 1882,
    parameter integer GATE0 = 8, GATE1 = 8, GATE2 = 8, GATE3 = 8
)(
    input  wire        clk, reset, sample_valid, healthy,
    input  wire [1:0]  channel,
    input  wire [11:0] value,
    output reg  [3:0]  trigger,
    output reg  [31:0] velocity,
    output reg         ev_valid,
    output reg  [3:0]  ev_strings,
    output reg  [14:0] ev_peak,
    output reg  [15:0] ev_total,
    output wire [63:0] dbg_ay,
    output wire [3:0]  dbg_warm,
    output reg  [7:0]  vibrato_depth,
    output reg  [15:0] rej_total
);
    wire rst = reset | ~healthy;

    // ---------------- 四路带通前端 ----------------
    wire [15:0] es[0:3], el[0:3], e2[0:3], ef[0:3], ab[0:3];
    wire [3:0]  sg, tg;

    piezo_band_ch #(.DC(DC0),.GATE(GATE0),.LAG2(1),.ES_FRAC(4),
                    .HP_K(HP_K),.LP_K(LP_K),.EF_S(EF_S),.ES_S(ES_S),.LAG(LAG)) u_ch0(
        .clk(clk),.rst_n(~rst),
        .sample_valid(sample_valid && channel==2'd0),.sample_code(value),
        .es(es[0]),.es_lag(el[0]),.es_lag2(e2[0]),.ef(ef[0]),
        .absy(ab[0]),.ysign(sg[0]),.trig(tg[0]));
    piezo_band_ch #(.DC(DC1),.GATE(GATE1),.LAG2(1),.ES_FRAC(4),
                    .HP_K(HP_K),.LP_K(LP_K),.EF_S(EF_S),.ES_S(ES_S),.LAG(LAG)) u_ch1(
        .clk(clk),.rst_n(~rst),
        .sample_valid(sample_valid && channel==2'd1),.sample_code(value),
        .es(es[1]),.es_lag(el[1]),.es_lag2(e2[1]),.ef(ef[1]),
        .absy(ab[1]),.ysign(sg[1]),.trig(tg[1]));
    piezo_band_ch #(.DC(DC2),.GATE(GATE2),.LAG2(1),.ES_FRAC(4),
                    .HP_K(HP_K),.LP_K(LP_K),.EF_S(EF_S),.ES_S(ES_S),.LAG(LAG)) u_ch2(
        .clk(clk),.rst_n(~rst),
        .sample_valid(sample_valid && channel==2'd2),.sample_code(value),
        .es(es[2]),.es_lag(el[2]),.es_lag2(e2[2]),.ef(ef[2]),
        .absy(ab[2]),.ysign(sg[2]),.trig(tg[2]));
    piezo_band_ch #(.DC(DC3),.GATE(GATE3),.LAG2(1),.ES_FRAC(4),
                    .HP_K(HP_K),.LP_K(LP_K),.EF_S(EF_S),.ES_S(ES_S),.LAG(LAG)) u_ch3(
        .clk(clk),.rst_n(~rst),
        .sample_valid(sample_valid && channel==2'd3),.sample_code(value),
        .es(es[3]),.es_lag(el[3]),.es_lag2(e2[3]),.ef(ef[3]),
        .absy(ab[3]),.ysign(sg[3]),.trig(tg[3]));

    // dbg_ay 的字节 i 表示「弦 i」。不反转时弦 i = 通道 i；反转时弦 0 = 通道 3。
    //
    // **必须是包络（es），不能是瞬时有符号幅度 ab。**
    // R17 首版这里错写成 {ab[0],ab[1],ab[2],ab[3]}，代价是实板小提琴直接不出声：
    // 下游 physical_performer_frontend 拿它做「哪根弦真的在振动」的选弦依据
    // （PIEZO_SELECT_MIN=32，每 1.31 ms 评估、连续 8 窗确认）。ab 是带通后的
    // **瞬时** |y|，每样本剧烈跳变，选弦会跟着瞬时值疯狂切换，selected_strings
    // 抖动 → bow gate 开合抖动 → 小提琴四根波导都注不进能量。
    // 旧的 piezo_onset_bank 输出的是 abs_lp[23:8]（包络），语义就是"稳定包络"。
    // es 是 Q4 定点（ES_FRAC=4，即真实包络 ×16），静止噪声 3~6、拨弦峰 >100，
    // SELECT_MIN=32 落在两者之间的空档里。
    assign dbg_ay = REVERSE_CHANNELS ? {es[0],es[1],es[2],es[3]}
                                     : {es[3],es[2],es[1],es[0]};
    assign dbg_warm = 4'hf;   // 带通无独立暖机；用 WARM 样本计数统一消隐

    // ---------------- 时间量（样本数） ----------------
    localparam integer WIN    = FS_HZ*WIN_MS  /1000;
    localparam integer DEAD   = FS_HZ*DEAD_MS /1000;
    localparam integer REFR_H = FS_HZ*REFR_H_MS/1000;
    localparam integer REFR_S = FS_HZ*REFR_S_MS/1000;
    localparam integer WARM   = FS_HZ*WARM_MS /1000;
    localparam integer WIN_FR = (WIN+3)/4;          // 判决窗按 4 通道帧计

    // ---------------- 帧边界与时间基准 ----------------
    wire frame = sample_valid && (channel==2'd3);
    reg [15:0] smp_cnt;        // 通道样本计数（模 65536，60 ms 窗口不受回绕影响）
    reg [15:0] warm_cnt;
    wire warm_done = (warm_cnt >= WARM);

    always @(posedge clk) begin
        if (rst) begin smp_cnt<=16'd0; warm_cnt<=16'd0; end
        else if (sample_valid) begin
            smp_cnt <= smp_cnt + 1'b1;
            if (!warm_done) warm_cnt <= warm_cnt + 1'b1;
        end
    end

    // ---------------- 窗内统计 ----------------
    reg        busy;
    reg        decide;      // 窗末置 1，下一拍用寄存的 pk/pacc/nacc 判决
    reg [15:0] win_fr;
    reg [15:0] pk[0:3];
    reg [23:0] pacc, nacc;
    reg [3:0]  hit_mask;

    // 帧内四路 es 的新峰值
    wire [15:0] pk0 = (es[0] > pk[0]) ? es[0] : pk[0];
    wire [15:0] pk1 = (es[1] > pk[1]) ? es[1] : pk[1];
    wire [15:0] pk2 = (es[2] > pk[2]) ? es[2] : pk[2];
    wire [15:0] pk3 = (es[3] > pk[3]) ? es[3] : pk[3];

    // 四路瞬态幅值里最大的两路（与 rh6 的 best/best_key 同义，逐帧更新）
    wire [15:0] a0=ab[0],a1=ab[1],a2=ab[2],a3=ab[3];
    wire [15:0] mx01 = a0>=a1?a0:a1, mn01 = a0>=a1?a1:a0;
    wire [15:0] mx23 = a2>=a3?a2:a3, mn23 = a2>=a3?a3:a2;
    wire [1:0]  ix01 = a0>=a1?2'd0:2'd1;
    wire [1:0]  ix23 = a2>=a3?2'd2:2'd3;
    wire        hi_left = mx01>=mx23;
    wire [1:0]  hi_ix = hi_left ? ix01 : ix23;
    wire [1:0]  lo_ix = hi_left ? ((mx23>=mn01)?ix23:ix01) : ((mx01>=mn23)?ix01:ix23);
    // ---- 选择索引打一拍（R17 时序修复之二）----
    // r17h 的 PnR 关键路径：absy → n737(15 级) → hi_ix → lo_ix(16 级) → ylo → pacc，
    // 30 多级级联 LUT，setup -2.128 / 410 条违例。
    // 索引滞后 1 个样本（40 ns）再选幅度，8 ms 窗共 198 帧，物理上无影响
    // （相邻样本的通道强弱排序不会突变），却把这条链切成两段。
    reg [1:0] hi_ix_r, lo_ix_r;
    always @(posedge clk) begin
        if (rst) begin hi_ix_r<=2'd0; lo_ix_r<=2'd1; end
        else if (sample_valid) begin hi_ix_r<=hi_ix; lo_ix_r<=lo_ix; end
    end
    wire [15:0] yhi = ab[hi_ix_r];
    wire [15:0] ylo = ab[lo_ix_r];
    wire        shi = sg[hi_ix_r], slo = sg[lo_ix_r];
    wire [15:0] ymin = yhi<ylo ? yhi : ylo;
    wire        same_sign = (shi == slo);
    wire [23:0] pacc_n = pacc + (same_sign ? {8'd0,ymin} : 24'd0);
    wire [23:0] nacc_n = nacc + (same_sign ? 24'd0 : {8'd0,ymin});

    // ---------------- 判决与输出 ----------------
    reg [15:0] last_out[0:3];   // 该通道上一次输出事件的样本时刻
    reg [15:0] last_t;          // 全局上一次输出事件的样本时刻
    reg [15:0] last_pk;         // 全局上一次输出事件的峰值
    reg [1:0]  pick;
    integer k;
    reg [19:0] sel_pk;

    // 窗末判决用组合量。输入一律取**寄存的窗峰** pk[0..3]，不取组合的
    // pk0..pk3：后者把「es → 取最大 → wmin 树 → 5*wmin → 比较」串成一整条
    // 路径（r17l 实测 24.9 ns / setup -1.075）。判决延后一拍由 decide 标志完成。
    wire [15:0] wmin_a = pk[0]<pk[1]?pk[0]:pk[1], wmin_b = pk[2]<pk[3]?pk[2]:pk[3];
    wire [15:0] wmax_a = pk[0]>pk[1]?pk[0]:pk[1], wmax_b = pk[2]>pk[3]?pk[2]:pk[3];
    wire [15:0] wmin = wmin_a<wmin_b?wmin_a:wmin_b;
    wire [15:0] wmax = wmax_a>wmax_b?wmax_a:wmax_b;
    wire [19:0] wmin5 = {4'd0,wmin} + {2'd0,wmin,2'b00};       // 5*min
    // sp_wagree >= 0.80  <=>  P/(P+N) >= 0.80  <=>  P >= 4*N。
    // 这一行保持「一行一根 + 显式 assign」：本文件曾试过 3*P >= 17*N 的写法
    // （p_q/n_q 右移 4 位再放大），Gowin 连续两次综合都报
    //   ERROR (SP00018) "error bus name set"
    // 拆成单根声明也没用；改回 4*N 后消失。以后要改这个门限，先跑一次
    // `--stage syn` 确认日志里 SP00018 count = 0，再进 PnR。
    wire [23:0] nacc4;
    assign nacc4 = {2'd0,nacc,2'b00};                         // 4*N
    // sp_range<=0.80 且 sp_wagree>=0.80 且窗内确有触发 -> 判为琴体传导
    wire spatial_reject = warm_done && (hit_mask!=4'd0) && (wmax!=16'd0) &&
                          (wmin5 >= {4'd0,wmax}) && (pacc >= nacc4);

    // 通过时在 hit_mask 内选 es 峰值最大的通道（琴体事件不发声）
    wire [15:0] c0 = hit_mask[0]?pk[0]:16'd0;
    wire [15:0] c1 = hit_mask[1]?pk[1]:16'd0;
    wire [15:0] c2 = hit_mask[2]?pk[2]:16'd0;
    wire [15:0] c3 = hit_mask[3]?pk[3]:16'd0;
    wire [15:0] s01 = c0>=c1?c0:c1, s23 = c2>=c3?c2:c3;
    wire [1:0]  i01 = c0>=c1?2'd0:2'd1, i23 = c2>=c3?2'd2:2'd3;
    wire [15:0] smx = s01>=s23?s01:s23;
    wire [1:0]  six = s01>=s23?i01:i23;

    // 力度曲线：gamma=0.8（用户："整体略微偏大，小声音再小一点"）。
    // 相对 R16 的 gamma=0.65：x=16 42->28、x=32 66->48、x=128 163->147、x=255 不变。
    function [7:0] vel_table;
        input [4:0] i;
        begin
            case(i)
            5'd0:vel_table=8'd0;    5'd1:vel_table=8'd28;
            5'd2:vel_table=8'd48;   5'd3:vel_table=8'd67;
            5'd4:vel_table=8'd84;   5'd5:vel_table=8'd101;
            5'd6:vel_table=8'd117;  5'd7:vel_table=8'd132;
            5'd8:vel_table=8'd147;  5'd9:vel_table=8'd161;
            5'd10:vel_table=8'd176; 5'd11:vel_table=8'd190;
            5'd12:vel_table=8'd203; 5'd13:vel_table=8'd217;
            5'd14:vel_table=8'd230; 5'd15:vel_table=8'd243;
            5'd16:vel_table=8'd255;
            default:vel_table=8'd255;
            endcase
        end
    endfunction
    function [7:0] vel_curve;
        input [7:0] v;
        reg [7:0] lo,hi;reg [8:0] d;reg [11:0] w;
        begin
            lo=vel_table(v[7:4]);
            hi=vel_table(v[7:4]+4'd1);
            d=hi-lo;
            w=12'd0;
            if(v[3]) w=w+({4'd0,d}<<3);
            if(v[2]) w=w+({5'd0,d}<<2);
            if(v[1]) w=w+({6'd0,d}<<1);
            if(v[0]) w=w+{7'd0,d};
            vel_curve=lo+w[11:4];
        end
    endfunction
    // 输入是 es 的 Q4 峰值，>>4 得整数码值；<96 视为极轻，兜底 16。
    function [7:0] velocity_of;
        input [15:0] p;
        reg [15:0] q;
        begin
            q = p[15:4];
            if (q >= 16'd255) velocity_of = 8'd255;
            else if (q < 16'd6) velocity_of = 8'd16;
            else velocity_of = vel_curve(q[7:0]);
        end
    endfunction

    // 颤音：深度增量按拍击强度分档（轻 4 / 中 8 / 重 12 / 很重 16），上限 32，
    // 每 100 帧（≈16 ms）衰减 1 —— 从满深度回到 0 约 0.5 s，接近一次真实揉弦动作。
    // 依据：多模型评审（docs/implementation/r17_20261101/多模型评审.md）指出
    // 固定 +8 会让「轻拍」和「重拍」一样深、上限 48 + 50 ms/级 的尾巴长达 2.4 s，
    // 听感是「拖尾的电子颤音」而不是揉弦。速率调制（3.5~7 Hz 跟随拍击间隔）需要
    // 改下游 i_vibrato_rate 接口，留到下一版。
    localparam integer VIB_MAX  = 32;
    localparam integer VIB_DEC_FRAMES = 100;
    wire [7:0] vib_step = (smx >= 16'd96) ? 8'd16 :
                          (smx >= 16'd64) ? 8'd12 :
                          (smx >= 16'd32) ? 8'd8  : 8'd4;
    reg [9:0] vib_div;

    // ---- 输出流水级（R17 时序修复）----
    // r17f 的 PnR 关键路径实测：es → wmin 比较树 → smx/six 约 9.5 ns，
    // 而 velocity_of() 查表+插值+变量移位约 14.6 ns，串在同一拍里 24.1 ns
    // 超过 20 ns 周期（setup -4.797，492 条违例）。
    // 把 velocity 的输入寄存在这里，两段各自 < 10 ns / < 15 ns，都能过周期。
    // 代价：发声晚 1 个样本（20 ns），相对 8 ms 判决点可忽略。
    reg        fire_pend;
    // R33：判决二级流水（见窗末判决注释）
    reg        decide2;
    reg [15:0] smx2;
    reg [1:0]  lane2, six2;
    reg        rej2;
    reg [3:0]  fire_mask;
    reg [15:0] fire_smx;
    reg [1:0]  fire_lane;
    wire [1:0] lane = REVERSE_CHANNELS ? (2'd3 - six) : six;

    always @(posedge clk) begin
        if (rst) begin
            trigger<=4'd0; velocity<=32'd0; ev_valid<=1'b0; ev_strings<=4'd0;
            ev_peak<=15'd0; ev_total<=16'd0; rej_total<=16'd0; vibrato_depth<=8'd0;
            busy<=1'b0; decide<=1'b0; win_fr<=16'd0; pacc<=24'd0; nacc<=24'd0; hit_mask<=4'd0;
            pick<=2'd0; sel_pk<=20'd0; last_t<=16'd0; last_pk<=16'd0; vib_div<=10'd0;
            fire_pend<=1'b0; fire_mask<=4'd0; fire_smx<=16'd0; fire_lane<=2'd0;
            decide2<=1'b0; smx2<=16'd0; lane2<=2'd0; six2<=2'd0; rej2<=1'b0;
            for (k=0;k<4;k=k+1) begin pk[k]<=16'd0; last_out[k]<=16'd0; end
        end else begin
            // ---- 输出流水级的第二拍：上一拍决定的事件在这里发声 ----
            // 这里只依赖 fire_* 寄存器，所以 velocity_of() + 变量移位自成一段，
            // 不再和 wmin 比较树串成一整条 24 ns 的链。
            fire_pend <= 1'b0;
            trigger   <= 4'd0;
            velocity  <= 32'd0;
            ev_valid  <= 1'b0;
            if (fire_pend) begin
                trigger   <= fire_mask;
                velocity  <= {24'd0, velocity_of(fire_smx)} << {fire_lane, 3'b000};
                ev_valid  <= 1'b1;
                ev_strings<= fire_mask;
                ev_peak   <= (fire_smx > 16'd32767) ? 15'd32767 : fire_smx[14:0];
            end

            // ---- 簇起点：任一通道触发 ----
            // 加 !decide：判决那一拍不能开新簇，否则 pk/hit_mask 会被重置掉。
            if ((tg != 4'd0) && !busy && !decide && warm_done) begin
                busy<=1'b1; win_fr<=16'd0; hit_mask<=tg; pacc<=24'd0; nacc<=24'd0;
                pk[0]<=es[0]; pk[1]<=es[1]; pk[2]<=es[2]; pk[3]<=es[3];
            end else begin
                // tg 是单周期脉冲，可能在非帧边界出现，必须逐拍累积；
                // 只在 frame 分支里合并会漏掉一半触发通道。
                if (busy && (tg != 4'd0)) hit_mask <= hit_mask | tg;
                // ---- 窗内逐帧累加 ----
                if (busy && frame) begin
                    hit_mask <= hit_mask | tg;
                    pk[0]<=pk0; pk[1]<=pk1; pk[2]<=pk2; pk[3]<=pk3;
                    pacc<=pacc_n; nacc<=nacc_n;
                    if (win_fr >= WIN_FR-1) begin
                        busy<=1'b0;
                        decide<=1'b1;       // 判决延后一拍，见下面的 decide 分支
                    end else win_fr <= win_fr + 1'b1;
                end
            end

            // ---- 窗末判决 ----
            // R33：判决拆成两级。原来 "decide 那一拍" 要一口气算完
            //   smx(=4 路包络的最大值树) → 与 last_out[six](RAM 读) 相减 → 三次比较
            //   → last_pk 的写使能，实测 19.5~19.7 ns，几乎占满 20 ns 周期。
            // 现在 decide 那一拍只把 smx/lane/six/spatial_reject 打进寄存器，
            // 真正的比较放到下一拍。发声晚 1 拍（20 ns），对 ms 级的起音检测无影响。
            if (decide) begin
                decide  <= 1'b0;
                decide2 <= 1'b1;
                smx2    <= smx;
                lane2   <= lane;
                six2    <= six;
                rej2    <= spatial_reject;
            end else begin
                decide2 <= 1'b0;
            end
            if (decide2) begin
                if (rej2) begin
                    // 拍琴身 / 碰琴：不发声，转成颤音
                    rej_total <= rej_total + 1'b1;
                    vibrato_depth <= (vibrato_depth + vib_step > VIB_MAX) ?
                                     VIB_MAX[7:0] : (vibrato_depth + vib_step);
                end else if (smx2 != 16'd0) begin
                    // 消抖：逐通道死区 + 全局硬/软窗
                    if (!((smp_cnt - last_out[six2]) < DEAD) &&
                        !((smp_cnt - last_t) < REFR_H) &&
                        !(((smp_cnt - last_t) < REFR_S) &&
                          (({1'b0,smx2} <<< 3) < {1'b0,last_pk}))) begin
                        // 只做「决定」，发声交给下一拍
                        fire_pend <= 1'b1;
                        fire_mask <= 4'b0001 << lane2;
                        fire_smx  <= smx2;
                        fire_lane <= lane2;
                        ev_total  <= ev_total + 1'b1;
                        last_out[six2] <= smp_cnt;
                        last_t <= smp_cnt;
                        last_pk <= smx2;
                    end
                end
            end

            // ---- 颤音衰减 ----
            if (frame) begin
                if (vib_div >= VIB_DEC_FRAMES-1) begin
                    vib_div <= 10'd0;
                    if (vibrato_depth != 8'd0) vibrato_depth <= vibrato_depth - 1'b1;
                end else vib_div <= vib_div + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
