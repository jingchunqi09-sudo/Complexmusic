//-----------------------------------------------------------------------------
// ms_string_top.v —— 多弦识别顶层（核外置版）
//
// 来源：main_piezo_hspi_20261028/src/ms_string_det.v 的顶层部分，逻辑逐行一致；
// 区别仅在于 4 个 ms_core_ch 不再内部实例化，核信号改为端口输入，以便与发声
// 路径共享同一组核（避免资源翻倍）。cand 路径的判定、窗口、阈值与计时不变。
//
// 功能：4 通道候选 → 聚类窗（进行中不接受新候选，等价 60 ms 合并）→
//   窗内累积各通道 |y| 峰值、80~250/250~1200 能量和、头 30 ms 与 300~450 ms 能量和
//   → spread>1.9 且 (sustain<0.09 或 hf<0.65) 判敲击剔除
//   → 归一化幅度 ≥0.20×最大 的通道为被弹响的弦（可多根）。
// 事件延迟 0.45 s（等尾部窗），只用于识别/显示，不参与实时发声。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module ms_string_top #(
    parameter integer INV0 = 172, parameter integer INV1 = 94,
    parameter integer INV2 = 106, parameter integer INV3 = 152
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire [1:0]  sample_ch,
    // 4 核的候选与包络（核外置）
    input  wire        cv0, cv1, cv2, cv3,
    input  wire [31:0] cp0, cp1, cp2, cp3,
    input  wire [16:0] ck0, ck1, ck2, ck3,
    input  wire [15:0] ca0, ca1, ca2, ca3,
    input  wire [15:0] ay0, ay1, ay2, ay3,
    input  wire [15:0] lo0, lo1, lo2, lo3,
    input  wire [15:0] hi0, hi1, hi2, hi3,
    output reg         ev_valid,
    output reg  [3:0]  ev_strings,
    output reg  [14:0] ev_peak,
    output reg  [31:0] ev_pos,
    output reg  [15:0] ev_total
);

    localparam integer W_AMP  = 930;    // 0~150 ms   幅度窗
    localparam integer W_HF   = 744;    // 0~120 ms   高频比窗
    localparam integer W_HEAD = 186;    // 0~30 ms    头部
    localparam integer T_TAIL = 1860;   // 300 ms
    localparam integer W_TAIL = 930;    // 300~450 ms 尾部
    localparam integer T_END  = T_TAIL + W_TAIL;

    // ---- 聚类与窗口寄存器 ----
    reg        busy;
    reg [31:0] age;
    reg [31:0] pos_r;
    reg [14:0] peak_r;
    reg [15:0] amp    [0:3];
    reg [23:0] sum_hd [0:3];
    reg [23:0] sum_tl [0:3];
    reg [23:0] sum_lf [0:3];
    reg [23:0] sum_hf [0:3];

    wire any_cand = cv0 | cv1 | cv2 | cv3;
    wire [31:0] cand_pos_f = cv0 ? cp0 : cv1 ? cp1 : cv2 ? cp2 : cp3;
    wire [16:0] cand_pk_f  = cv0 ? ck0 : cv1 ? ck1 : cv2 ? ck2 : ck3;
    wire [15:0] cand_amp_f = cv0 ? ca0 : cv1 ? ca1 : cv2 ? ca2 : ca3;
    wire [1:0]  cand_ch_f  = cv0 ? 2'd0 : cv1 ? 2'd1 : cv2 ? 2'd2 : 2'd3;
    wire tick_ch0 = sample_valid && (sample_ch == 2'd0);

    // ---- 归一化幅度（段 1：amp 移位加，寄存 pr_r；切断 amp→emit 的长组合链） ----
    wire [31:0] a0 = {16'd0, amp[0]}, a1 = {16'd0, amp[1]};
    wire [31:0] a2 = {16'd0, amp[2]}, a3 = {16'd0, amp[3]};
    // INV0=172=128+32+8+4；INV1=94=64+16+8+4+2；INV2=106=64+32+8+2；INV3=152=128+16+8
    reg [31:0] pr0, pr1, pr2, pr3;
    always @(posedge clk) begin
        pr0 <= (a0<<7)+(a0<<5)+(a0<<3)+(a0<<2);
        pr1 <= (a1<<6)+(a1<<4)+(a1<<3)+(a1<<2)+(a1<<1);
        pr2 <= (a2<<6)+(a2<<5)+(a2<<3)+(a2<<1);
        pr3 <= (a3<<7)+(a3<<4)+(a3<<3);
    end

    // ---- 判定（段 2：pr_r → max/spread/sustain/hf → emit，寄存 emit_r） ----
    // 段 1（amp→pr_r）与段 2（pr_r→emit_r）各约 12 ns，50 MHz 可收敛。
    // 定案延迟 2 拍（age==T_END+2），此时 emit_r 已是完整尾部窗的判定，
    // 算法数学与 deepseek 原版完全一致，仅事件时刻多 40 ns。
    wire [31:0] max01 = (pr0 >= pr1) ? pr0 : pr1;
    wire [31:0] max23 = (pr2 >= pr3) ? pr2 : pr3;
    wire [31:0] maxv  = (max01 >= max23) ? max01 : max23;
    wire [31:0] tot   = pr0 + pr1 + pr2 + pr3;

    wire [31:0] tot_x10  = (tot<<3)+(tot<<1);        // tot*10
    wire [31:0] max_x19  = (maxv<<4)+(maxv<<1)+maxv; // maxv*19
    wire spread_hi = tot_x10 > max_x19;

    reg [1:0] k;
    always @(*) begin
        if ((pr0 >= pr1) && (pr0 >= pr2) && (pr0 >= pr3)) k = 2'd0;
        else if ((pr1 >= pr2) && (pr1 >= pr3))            k = 2'd1;
        else if (pr2 >= pr3)                              k = 2'd2;
        else                                              k = 2'd3;
    end

    wire [23:0] s_hd = sum_hd[k];
    wire [23:0] s_tl = sum_tl[k];
    wire [23:0] s_lf = sum_lf[k];
    wire [23:0] s_hf = sum_hf[k];

    wire [31:0] sus_l = (s_tl<<4)+(s_tl<<2);         // s_tl*20
    wire [31:0] sus_r = (s_hd<<3)+s_hd;              // s_hd*9
    wire sus_ok = sus_l >= sus_r;
    wire [31:0] hf_l = (s_hf<<4)+(s_hf<<2);          // s_hf*20
    wire [31:0] hf_r = (s_lf<<3)+(s_lf<<2)+s_lf;     // s_lf*13
    wire hf_ok = hf_l >= hf_r;

    wire emit_ok = (maxv != 0) && (!spread_hi || (sus_ok || hf_ok));
    wire [31:0] p0x5 = (pr0<<2)+pr0, p1x5 = (pr1<<2)+pr1,
                p2x5 = (pr2<<2)+pr2, p3x5 = (pr3<<2)+pr3;
    wire [3:0] emit_strings = {
        (p3x5 >= maxv), (p2x5 >= maxv), (p1x5 >= maxv), (p0x5 >= maxv)
    };
    // 段 2 结果寄存
    reg       emit_ok_r;
    reg [3:0] emit_strings_r;
    always @(posedge clk) begin
        emit_ok_r <= emit_ok;
        emit_strings_r <= emit_strings;
    end

    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; age <= 0; pos_r <= 0; peak_r <= 0;
            ev_valid <= 1'b0; ev_strings <= 4'd0; ev_peak <= 15'd0;
            ev_pos <= 0; ev_total <= 16'd0;
            for (j = 0; j < 4; j = j + 1) begin
                amp[j] <= 0; sum_hd[j] <= 0; sum_tl[j] <= 0;
                sum_lf[j] <= 0; sum_hf[j] <= 0;
            end
        end else begin
            ev_valid <= 1'b0;

            if (busy) begin
                if (sample_valid && (sample_ch == 2'd0)) begin
                    if (age < W_AMP  && ay0 > amp[0]) amp[0] <= ay0;
                    if (age < W_HF) begin
                        sum_lf[0] <= sum_lf[0] + lo0;
                        sum_hf[0] <= sum_hf[0] + hi0;
                    end
                    if (age < W_HEAD) sum_hd[0] <= sum_hd[0] + ay0;
                    if (age >= T_TAIL && age < T_END) sum_tl[0] <= sum_tl[0] + ay0;
                end
                if (sample_valid && (sample_ch == 2'd1)) begin
                    if (age < W_AMP  && ay1 > amp[1]) amp[1] <= ay1;
                    if (age < W_HF) begin
                        sum_lf[1] <= sum_lf[1] + lo1;
                        sum_hf[1] <= sum_hf[1] + hi1;
                    end
                    if (age < W_HEAD) sum_hd[1] <= sum_hd[1] + ay1;
                    if (age >= T_TAIL && age < T_END) sum_tl[1] <= sum_tl[1] + ay1;
                end
                if (sample_valid && (sample_ch == 2'd2)) begin
                    if (age < W_AMP  && ay2 > amp[2]) amp[2] <= ay2;
                    if (age < W_HF) begin
                        sum_lf[2] <= sum_lf[2] + lo2;
                        sum_hf[2] <= sum_hf[2] + hi2;
                    end
                    if (age < W_HEAD) sum_hd[2] <= sum_hd[2] + ay2;
                    if (age >= T_TAIL && age < T_END) sum_tl[2] <= sum_tl[2] + ay2;
                end
                if (sample_valid && (sample_ch == 2'd3)) begin
                    if (age < W_AMP  && ay3 > amp[3]) amp[3] <= ay3;
                    if (age < W_HF) begin
                        sum_lf[3] <= sum_lf[3] + lo3;
                        sum_hf[3] <= sum_hf[3] + hi3;
                    end
                    if (age < W_HEAD) sum_hd[3] <= sum_hd[3] + ay3;
                    if (age >= T_TAIL && age < T_END) sum_tl[3] <= sum_tl[3] + ay3;
                end
            end

            if (any_cand && !busy) begin
                busy  <= 1'b1;
                age   <= 0;
                pos_r <= cand_pos_f;
                peak_r <= cand_pk_f;
                for (j = 0; j < 4; j = j + 1) begin
                    amp[j] <= 0; sum_hd[j] <= 0; sum_tl[j] <= 0;
                    sum_lf[j] <= 0; sum_hf[j] <= 0;
                end
                amp[cand_ch_f] <= cand_amp_f;
            end

            if (busy && tick_ch0) begin
                age <= age + 1'b1;
                // 定案延迟 2 拍：emit_ok_r/emit_strings_r 经段 1/段 2 流水后，
                // 在 T_END+2 时恰好是完整窗口的判定（与原版同数学结果）。
                if (age == T_END + 2) begin
                    busy <= 1'b0;
                    if (emit_ok_r) begin
                        ev_valid   <= 1'b1;
                        ev_strings <= emit_strings_r;
                        ev_peak    <= peak_r;
                        ev_pos     <= pos_r;
                        ev_total   <= ev_total + 16'd1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
