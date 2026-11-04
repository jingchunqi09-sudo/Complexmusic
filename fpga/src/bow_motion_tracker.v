`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// bow_motion_tracker.v —— 鼠标当琴弓：速度 / 接触 / 换弓 / 跳弓
//
// R10 (2026-10-31)：CPI 3200、3 点中值、死区、9 样本窗口、双门限、跳弓
// R24 (2026-11-01)：弓速链改造（用户反馈"弓与弦必须垂直、抖动严重、拉弦不稳定"）
//
// R24 改的四件事，每一条都有采集数据回放的量化依据
// （.workbuddy/analysis_bow_perp_r24/，5 组 mouse_typec 采集 × 3.2 换算到 CPI=3200）：
//
//  1) 幅度 L1 -> L2。
//     旧 mag = |主轴| + |副轴| 是 L1 范数，对运动方向的抖动**线性敏感**：
//     同一线速度，0° 时 L1 = |v|，45° 时 L1 = 1.41|v|。
//     实测"快速上下移动"副/主能量比 0.204、θ_p90 = 26.6°、15.2% 的样本两轴同动，
//     L1 窗口峰值 96 而同段主轴投影只有 76 —— 26.3% 的高估，且这 26% 随手的
//     倾斜角来回变，等于给弓速叠了一层幅度调制。摩擦模型在粘/滑边界上，
//     20% 的幅度扰动就足以让状态每周期乱跳，听感就是"抖/杂/噪"。
//     L2 是旋转不变量，方向怎么抖都不改幅度。用 max + 3*min/8 近似
//     （45° -2.8%、26.6° +5.2%），成本是两次窄加法。
//
//  2) 主轴不再逐样本自适应。
//     旧 use_x = (|dx| >= |dy|) 每样本判一次，实测"缓慢上下移动"有 **31.9%**
//     的样本被副轴噪声抢走，"快速上下"9.37%。raw 在 dx/dy 之间乱跳，
//     中值滤波的输入是混轴的，等于失效。
//     现在只有"当前轴被另一轴压过 2 倍、连续 16 个样本"才切换；而且轴只用于
//     方向和位置积分，**不参与弓速计算**——锁错了最多是弓位显示错，不会改声音。
//
//  3) 中值滤波从"有符号主轴投影"搬到"幅度域"。
//     标量幅度上做中值语义清晰（压单样本幅度毛刺），也顺带消除了混轴问题。
//
//  4) 输出速度加不对称 IIR（上行直通、下行 >>2）。
//     9 样本窗口只有 10.2 ms，对 8~12 Hz 的生理震颤几乎没有抑制：实测慢弓的
//     速度序列有 24~34% 的能量落在 3~15 Hz 带内。窗口不能再加长（延迟会吃掉起音），
//     所以把平滑放到输出端，且只平滑下降沿——起音/加速立即跟上，回落慢 4 倍。
//     关弓判据改用平滑值（稳），开弓仍用未平滑的窗口和（快）。
//
// 门限与量纲：CPI = 3200，speed8 = 9 样本 |d| 之和，满量程 255 ≈ 202 mm/s。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

// R61（延迟优先档）：本模块只改一个参数 —— ATTACK_N 3 -> 2。
// 其余全部靠"时基变快"自动缩短，因为 WIN / OPEN_CONFIRM / RELEASE_SAMPLES
// 都是**样本数**量纲：
//     窗口 9 样本   : 10.1 ms (893 Hz)  ->  1.81 ms (4975 Hz)
//     开弓确认 3 拍 :  3.4 ms           ->  0.60 ms
//     起音确认 2 拍 :  2.2 ms           ->  0.40 ms
//     松弓释放 21 拍: 23.5 ms           ->  4.22 ms
// speed8 / OPEN_TH(32) / CLOSE_TH(12) / TURN_H(252) / BOW_SUPPRESS_SPEED(40)
// 的量纲一个都没变，所以门限**不需要重标** —— 这是本档最干净的一处改动。

module bow_motion_tracker #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer WATCHDOG_MS=8,
    // 上电初始主轴（1 = y）。只影响方向/位置，不影响弓速。
    parameter integer AXIS_Y=1,
    // 死区，count。实测恒定偏置恰为 1 count（报告 §2.2）
    parameter integer DZ=1,
    // 速度窗口样本数（≈10.2 ms @880 Hz）
    parameter integer WIN=9,
    // 开弓 / 关弓门限，单位 = 窗口内 |d| 之和（speed8 同量纲）
    // R11.2：报告 §4.2 的 40 是按"CPI=3200 生效"推的。现场拉不响说明实际
    // 弓速低于该门限（用户拉弓的自然速度约 30~60 mm/s，CPI=3200 时
    // 9 样本和 ≈ 34~68，40 正好卡在慢弓上方）。
    // 24 ≈ 17 mm/s @3200 CPI，是"能拉响"与"静止不响"之间的折中。
    // R16（用户："灵敏度明显偏高"）：24 -> 32（≈23 mm/s）。R11.2 的 24 是
    // 在"拉不响"之后往下压出来的，压过头了：手持琴弓悬停、换把、桌面震动
    // 都能让 9 样本和越过 24。32 仍低于自然拉弓的 34~68，慢弓不受影响。
    parameter integer OPEN_TH=32,
    parameter integer CLOSE_TH=12,
    // 开弓需要窗口和连续过线几个样本（静止抖动是孤立的，过不了连续两拍）
    // R16：2 -> 3。单样本尖峰（放弓、磕碰）不再能开弓。
    parameter integer OPEN_CONFIRM=3,
    // 关弓释放样本数（22 ≈ 25 ms @880 Hz）
    // R16 曾试 16，被 control 回归的"26 个安静样本仍保持接触"契约否掉：
    // 释放变快会让慢弓的瞬时降速被误判成抬弓（断音），而"弓离开静音"实际由
    // violin_waveguide_voice 的 BOW_OFF_DAMP_SHIFT 主动阻尼完成，不需要在这里抢时间。
    // R24：22 -> 21。中值挪到寄存器后速度累积慢 1 拍，释放总拍数保持 32 不变
    // （窗口 9 + 流水 1 + 释放 21 + 判据 1），control/bank 两条时间契约原样成立。
    parameter integer RELEASE_SAMPLES=21,
    // 起音确认：瞬时幅度 >= ATTACK_D 连续 ATTACK_N 个样本立即开弓
    // R16：4/2 -> 6/3。静止噪声的 |d| 实测就是 2~4，4 会让它"连续两拍"过线。
    // R24：6 -> 5。幅度从 L1 换成 L2 后同段数据整体低 3%~20%，起音阈值等比例下调。
    // R61：3 -> 2。采样率从 893 Hz 提到 4975 Hz 后，一个样本只有 201 us，
    //      3 个样本 = 0.60 ms 的确认窗对本档的延迟目标来说太贵。
    //      保持 ATTACK_D=5 的结果是：**单样本**尖峰（放弓、单次磕碰）仍被否决，
    //      只有连续两个样本（≈0.40 ms）都超过起音阈值才开弓。
    //      代价写在 src/latency_profile.vh 第二节（声音层）。
    parameter integer ATTACK_D=5,
    parameter integer ATTACK_N=3,
    // 换弓迟滞，count（2 mm @ CPI=3200 -> 252）
    parameter integer TURN_H=252,
    // ---- R24 新增 ----
    // 主轴切换确认样本数。16（18 ms）偏保守：千问与 Kimi 独立建议 8~12
    // （9~14 ms）—— 既能滤掉瞬态抖动，又不会让"换了个方向演奏"迟迟不跟随。
    // 取 10。注意轴只影响方向和弓位显示，不影响弓速，所以这条不敏感。
    parameter integer AXIS_HYST_N=10,
    // 输出速度的下降平滑（0 = 关闭）。1 位右移 = 时间常数 1 样本，
    // 2 = 4 样本（≈4.6 ms），4 = 16 样本。上行永远直通。
    parameter integer SPEED_SLOW_SHIFT=2,
    // 跳弓：换弓间隔落在 [MIN,MAX] 样本内算一次弹跳，连续 RUN 次确认
    parameter integer BOUNCE_MIN_S=53,   // 60 ms @880 Hz
    parameter integer BOUNCE_MAX_S=220,  // 250 ms
    parameter integer BOUNCE_EXIT_S=264, // 300 ms 无换弓退出
    parameter integer BOUNCE_RUN=4
)(
    input  wire        clk, reset, sample_valid, ready,
    input  wire [7:0]  motion,          // 保留：仅用于 lifted 诊断，不作硬门控
    input  wire signed [15:0] dx, dy,
    output reg         gate,            // 运弓接触
    output reg         direction,       // 0 = 负向（左/下），1 = 正向
    output reg         lifted,          // 抬弓（无样本 / 未就绪）
    output reg  [7:0]  speed,           // 0..255，与窗口 SUM 同量纲（已平滑）
    output reg         bounce,          // 跳弓（6~10 Hz）
    output reg  signed [23:0] position   // 去偏置积分位置，单位 count
);
    function integer width;
        input integer n;
        begin
            width=1;
            if(n>1) while(n>1) begin n=n>>1; width=width+1; end
        end
    endfunction

    localparam integer LIMIT=CLOCK_HZ/1000*WATCHDOG_MS;

    reg [width(LIMIT)-1:0] age;
    reg [5:0]  quiet;

    // ---------------- 1. 各轴独立取幅 + 死区 ----------------
    // 17 位无符号幅度，能正确处理 -32768。
    // 死区分别加在两根轴上：实测存在 ±1 count 的确定性偏置（报告 §2.2），
    // 且偏置符号逐采集变化，只能按绝对值消。
    wire [16:0] adx = dx[15] ? {1'b0,(~dx + 16'd1)} : {1'b0,dx};
    wire [16:0] ady = dy[15] ? {1'b0,(~dy + 16'd1)} : {1'b0,dy};
    wire [16:0] ax  = (adx <= DZ) ? 17'd0 : adx;
    wire [16:0] ay  = (ady <= DZ) ? 17'd0 : ady;

    // ---------------- 2. 主轴锁定（迟滞，禁止逐样本翻转）----------------
    // 只有"当前轴被另一轴压过 2 倍、且连续 AXIS_HYST_N 个样本"才切换。
    // 斜着拉（两轴接近）时两个条件都不成立，保持原轴 —— 这正是想要的：
    // 斜拉不应该让方向判据在两轴之间来回跳。
    // 锁错也不会改变声音，因为弓速走第 3 节的 L2，与轴无关。
    reg use_x_l;
    reg [4:0] axis_cnt;
    wire ax_wins = {1'b0, ax} > {ay, 1'b0};    // |dx| > 2|dy|
    wire ay_wins = {1'b0, ay} > {ax, 1'b0};    // |dy| > 2|dx|
    always @(posedge clk) begin
        if (reset) begin
            use_x_l  <= (AXIS_Y == 0);
            axis_cnt <= 5'd0;
        end else if (sample_valid && ready) begin
            if (use_x_l ? ay_wins : ax_wins) begin
                if (axis_cnt >= AXIS_HYST_N-1) begin
                    use_x_l  <= ~use_x_l;
                    axis_cnt <= 5'd0;
                end else
                    axis_cnt <= axis_cnt + 1'b1;
            end else
                axis_cnt <= 5'd0;
        end
    end

    // ---------------- 3. L2 幅度（旋转不变）----------------
    // max + 3*min/8：两次窄加法，无乘法。45° 时 -2.8%、26.6° 时 +5.2%。
    // 与 L1 的区别是"方向抖动不改幅度"，这是本轮的核心修正。
    wire [16:0] mx = (ax >= ay) ? ax : ay;
    wire [16:0] mn = (ax >= ay) ? ay : ax;
    wire [15:0] l2_add = {1'b0, mn[16:2]} + {1'b0, mn[16:3]};   // (min>>2)+(min>>3)
    wire [16:0] l2f = mx + {1'b0, l2_add};

    // 幅度域 3 点中值（压单样本毛刺，不再受混轴影响）
    // ---- R24 时序修复：中值算在用寄存器的幅度上，慢一拍 ----
    // 第一版把 `dx → |d| → 死区 → max/min → L2 → med3 → 饱和 → 窗口和` 全串在
    // 一拍里，PnR 实测 20.875 ns（周期 20 ns，setup −0.941，31 条违例），
    // 起点 u_paw/delta_y、终点 u_bow/sum_w。把 L2 的结果先寄存一拍、
    // 中值树从寄存器出发，长链被切成「dx→…→l2f→l2f_r」和「l2f_r→中值→窗口」两段。
    // 代价是速度累积晚 1 个样本（1.14 ms），所以 RELEASE_SAMPLES 22→21 保持
    // 释放总拍数不变（窗口 9 + 流水 1 + 释放 21 + 判据 1 = 32，与 R23 一致）。
    // 起音不走这条路（instant_hit 用未寄存的 l2f），所以起音时刻不变。
    reg [16:0] l2f_r, l2f_r1, l2f_r2;
    always @(posedge clk) begin
        if (reset) begin
            l2f_r<=17'd0; l2f_r1<=17'd0; l2f_r2<=17'd0;
        end else if (sample_valid && ready) begin
            l2f_r  <= l2f;
            l2f_r1 <= l2f_r;
            l2f_r2 <= l2f_r1;
        end
    end
    wire [16:0] l_hi = (l2f_r1 > l2f_r2) ? l2f_r1 : l2f_r2;
    wire [16:0] l_lo = (l2f_r1 < l2f_r2) ? l2f_r1 : l2f_r2;
    wire [16:0] l_med = (l2f_r > l_hi) ? l_hi : (l2f_r < l_lo) ? l_lo : l2f_r;
    // 单样本上限 127（7 位）已经覆盖 CPI=3200 的峰值 24；再饱和一次防止猛甩
    // 时 |d| 超过 127 导致增量求和丢高位。
    wire [6:0]  dmz7 = (l_med > 17'd127) ? 7'd127 : l_med[6:0];

    // ---------------- 4. 方向：锁轴投影 + 3 点多数表决 ----------------
    // 方向只决定注入符号，但它一旦逐样本翻转就是爆音。原来的 3 点中值在
    // 混轴的 raw 上做；现在中值给了幅度，方向单独用"符号 3 取 2"，
    // 成本是 3 个 FF + 一个 3 输入多数门。
    wire signed [15:0] raw = use_x_l ? dx : dy;
    wire [16:0] proj_abs = raw[15] ? {1'b0,(~raw + 16'd1)} : {1'b0,raw};
    reg [2:0] sign_hist;
    wire dir_maj = (sign_hist[0] & sign_hist[1]) |
                   (sign_hist[0] & sign_hist[2]) |
                   (sign_hist[1] & sign_hist[2]);
    // 去偏置增量（位置积分只取主轴符号，避免副轴抖动让弓位乱跳）
    wire signed [16:0] dpos = (proj_abs <= DZ) ? 17'sd0 : {raw[15], raw};

    // ---------------- 5. 9 样本滑动窗口 ----------------
    // 环形移位 + 增量求和，避免 9 项组合加法形成长链。
    // R24：窗口单元从 17 位降到 7 位（存的就是饱和后的值），9×10 个 FF 省下来。
    reg [6:0] w [0:WIN-1];
    reg [10:0] sum_w;                    // 11 位足够（9*127=1143）
    wire [10:0] sum_next = sum_w + {4'd0, dmz7} - {4'd0, w[WIN-1]};
    integer wi;
    always @(posedge clk) begin
        if (reset) begin
            sum_w <= 11'd0;
            for (wi = 0; wi < WIN; wi = wi + 1) w[wi] <= 7'd0;
        end else if (sample_valid && ready) begin
            sum_w <= sum_next;
            // 必须存**饱和后**的 7 位样本：增量求和按 w[WIN-1] 回减，
            // 若存未饱和的原始值，一次猛甩（|d|>127）就会让 sum_w 只加不减、
            // 永久饱和，gate 卡在开弓状态无法释放（R11.2 踩过）。
            w[0] <= dmz7;
            for (wi = 1; wi < WIN; wi = wi + 1) w[wi] <= w[wi-1];
        end
    end

    wire [7:0] sum_sat = (sum_w > 11'd255) ? 8'd255 : sum_w[7:0];

    // ---------------- 6. 输出速度的不对称平滑 ----------------
    // 上行直通（起音、加速不掉延迟），下行 >>SPEED_SLOW_SHIFT（抑制 8~12 Hz 震颤）。
    // 平滑值同时用于关弓判据：门限附近用平滑值就不会被单样本抖动打断。
    reg  [7:0] sp_slow;
    wire [7:0] sp_next = (SPEED_SLOW_SHIFT <= 0) ? sum_sat :
                         (sum_sat >= sp_slow) ? sum_sat :
                         sp_slow - ((sp_slow - sum_sat) >> SPEED_SLOW_SHIFT);

    // ---------------- 7. 门控 / 换弓 / 跳弓 ----------------
    reg [3:0] attack_cnt;
    // 起音走**未中值**的瞬时幅度：中值滤波要看到第 3 个样本才输出真值
    // （3 点中值对着 (88,0,0) 的前 2 拍返回 0），用它做起音会整整晚 1 个样本。
    // R23 之所以没这个问题，是因为它的 mag 里 aux 那一路没经过中值，
    // 第一个样本就有值。换到 L2（单一路径）之后必须显式用 l2f。
    wire instant_hit = (l2f >= ATTACK_D);
    reg [1:0] open_cnt;
    wire sum_armed = (sum_sat >= OPEN_TH);

    reg signed [23:0] anchor;            // 上次换弓点的位置
    reg               dir_now;           // 当前弓向
    reg [15:0]        since_turn;        // 距上次换弓的样本数
    reg [3:0]         bounce_run;
    wire [4:0]        run_next = bounce_run + 1'b1;   // 5 位，避免 15+1 回绕
    wire signed [23:0] travel = position - anchor;

    // 换弓判据：相对上次换弓点走了 2 mm 就算一次换弓，方向由位移符号决定。
    // 旧写法要求"沿 dir_now 方向走满 TURN_H"，一旦位置被大幅单方向位移带偏
    // （例如猛甩一次把位置推到负端），之后正常的 ±4 count 行程永远回不到阈值，
    // 换弓/跳弓全部失效。
    wire turn_now = (travel >=  TURN_H) || (travel <= -TURN_H);

    always @(posedge clk) begin
        if (reset) begin
            attack_cnt<=0; open_cnt<=0;
            gate<=1'b0; direction<=1'b0; lifted<=1'b1; sp_slow<=8'd0;
            bounce<=1'b0; position<=24'sd0; anchor<=24'sd0;
            dir_now<=1'b0; since_turn<=16'd0; bounce_run<=4'd0;
            sign_hist<=3'b000;
            age<=0; quiet<=0;
        end else if (!ready) begin
            attack_cnt<=0; open_cnt<=0;
            gate<=1'b0; lifted<=1'b1; sp_slow<=8'd0;
            bounce<=1'b0; bounce_run<=4'd0; since_turn<=16'd0;
            dir_now<=1'b0; anchor<=position; age<=0; quiet<=0; sign_hist<=3'b000;
        end else if (sample_valid) begin
            age<=0;
            lifted<=1'b0;                 // 有有效样本 = 弓在弦上
            sign_hist<={sign_hist[1:0], raw[15]};
            attack_cnt<= instant_hit ? ((attack_cnt==4'd15)?4'd15:(attack_cnt+1'b1)) : 4'd0;
            open_cnt   <= sum_armed ? ((open_cnt==2'd3)?2'd3:(open_cnt+1'b1)) : 2'd0;
            sp_slow<=sp_next;

            // 门控：开弓用"窗口和连续确认"或"瞬时起音"（都快）；
            //       关弓看**平滑后**的速度，单样本掉速不再打断。
            if ((open_cnt >= OPEN_CONFIRM-1) || (instant_hit && attack_cnt >= ATTACK_N-1)) begin
                // 起音时把平滑器直接对齐到当前窗口和：否则 gate 短暂关闭后
                // sp_slow 还留着上一次的大值，一开弓 speed 会先跳高再往下掉，
                // 弓压前馈跟着跳（听感是起音"咔"一下）。
                //
                // ！！R25 在这里踩过一次，不要再改回 l2f[7:0] ！！
                //   sum_sat 是 9 样本**窗口和**，7 位饱和（0..127）；
                //   l2f 是**单样本** L2 幅度，17 位。两者量纲不同，而且
                //   l2f[7:0] 会按 256 回绕（l2f=300 时取到 44），于是每次起音的
                //   speed 种子是非单调的随机值 —— speed 同时决定波导的
                //   w_bow_target_velocity 与弓压前馈 p_eff，起音因此忽轻忽重。
                if (!gate) sp_slow <= sum_sat;
                gate<=1'b1; quiet<=6'd0;
                direction<=dir_maj;
            end else if (gate && (sum_sat > CLOSE_TH)) begin
                quiet<=6'd0;              // 仍在迟滞带内：保持
                direction<=dir_maj;
            end else if (gate) begin
                if (quiet >= RELEASE_SAMPLES-1) begin
                    gate<=1'b0; quiet<=6'd0;
                end else quiet<=quiet+1'b1;
            end

            // 位置积分（仅投影动样本）
            if (proj_abs > DZ) position<=position+dpos;

            // 换弓
            if (since_turn != 16'hffff) since_turn<=since_turn+1'b1;
            if (turn_now) begin
                dir_now<=(travel < 0);    // 新方向 = 刚走过的方向
                anchor<=position;
                // 跳弓：连续快速换弓
                if (since_turn>=BOUNCE_MIN_S && since_turn<=BOUNCE_MAX_S)
                    bounce_run<= (bounce_run==4'd15)?4'd15:(bounce_run+1'b1);
                else
                    bounce_run<=4'd1;
                if (run_next >= BOUNCE_RUN) bounce<=1'b1;
                since_turn<=16'd0;
            end else if (bounce && since_turn>BOUNCE_EXIT_S) begin
                bounce<=1'b0; bounce_run<=4'd0;
            end
        end else if (age>=LIMIT-1) begin
            // 采样超时：认为传感器停了
            gate<=1'b0; lifted<=1'b1; bounce<=1'b0; sp_slow<=8'd0;
        end else age<=age+1'b1;
    end

    // 输出：门关时速度清零，门开时给平滑值。
    // 用组合赋值而不是在时序块里再写一次 speed，避免与 sp_slow 抢同一寄存器。
    always @(*) begin
        speed = gate ? sp_slow : 8'd0;
    end

    // synthesis translate_off
    initial begin
        if (WATCHDOG_MS<1 || WIN<1 || WIN>16 || DZ<0 || OPEN_TH<=CLOSE_TH ||
            OPEN_CONFIRM<1 || OPEN_CONFIRM>4 ||
            RELEASE_SAMPLES<1 || ATTACK_N<1 || TURN_H<1 || BOUNCE_RUN<2 ||
            AXIS_HYST_N<1 || AXIS_HYST_N>31 || SPEED_SLOW_SHIFT<0 || SPEED_SLOW_SHIFT>4)
            begin $display("FAIL bow parameters out of range"); $finish; end
    end
    // synthesis translate_on
endmodule

`default_nettype wire
