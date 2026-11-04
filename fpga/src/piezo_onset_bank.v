// R8 bounded causal onset collection; external R7 event/velocity contract.
// Display events now describe accepted AUDIO EVENTS, replacing the 450ms path.
// See docs/implementation/right_hand_r8_20261030 for evidence and limitations.
`timescale 1ns/1ps
`default_nettype none
module piezo_onset_bank #(
    // R10.1 延迟设计（替代 R8 的 24 帧）：
    //   收集窗只用于"取峰值算力度 + 选弦"，不是抗重复的手段。抗重复由
    //   piezo_transient_core 的 fast>3×base 瞬态判据承担（残余振荡达不到 3 倍基线）。
    //   拨弦瞬态的能量集中在前 1~2 ms，4 帧（≈2.6 ms）足够取到峰值。
    //   端到端：4 帧收集 + 4 拍发布 + 音频帧 ≈3 ms（R8 原 24 帧 ≈15.7 ms + 发布）。
    parameter integer COLLECT_FRAMES=4,
    // 每通道命中后的守卫样本。6139 Hz 下 60 ≈9.8 ms，允许约 100 次/秒连拨；
    // R8 原值 246 ≈40 ms，这正是"连续两次快速演奏识别不到"的主因。
    parameter integer GUARD=60,
    // 压电片 CH0 是否对应第一弦（s3）。现场实测为是，默认 1。
    parameter integer REVERSE_CHANNELS=1
)(
    input wire clk,reset,sample_valid,healthy,
    input wire [1:0] channel,input wire [11:0] value,
    output reg [3:0] trigger,output reg [31:0] velocity,
    output reg ev_valid,output reg [3:0] ev_strings,
    output reg [14:0] ev_peak,output reg [15:0] ev_total,
    output wire [63:0] dbg_ay,output wire [3:0] dbg_warm
);
    wire rst=reset|~healthy;
    // 弦序对齐（2026-10-31 现场确认）：压电片 CH0 物理贴在第一弦，而本工程的
    // s0 是第四弦（`INST_UKULELE_OPEN_NOTES=32'h45403C43` → s0=G4/s1=C4/s2=E4/s3=A4，
    // s3 才是第一弦 A4）。不反转时"拨第一弦发第四弦的音"，四弦顺序整体相反。
    //
    // **反转必须在输出端做，不能搬数据**：四个核的 GATE_Q8（1946/3584/3174/2202）
    // 与 INV（172/94/106/152）是按物理通道逐一实测标定的。若把 CH0 的样本喂给
    // core3，门限就与通道灵敏度错配 → 漏检（实测 14 s 真实数据：识别 9→7、
    // fire 12→7，全部挤在一个 lane）。现在核 i 始终处理通道 i，只把发布位序倒过来。
    wire [3:0] cand,mvalid;
    wire [19:0] hf[0:3];wire [19:0] ac[0:3];wire [15:0] ay[0:3];
    piezo_transient_core #(.GATE_Q8(1946),.INV(172),.GUARD(GUARD)) u_ch0(
        .clk(clk),.reset(rst),.sample_valid(sample_valid && channel==0),.sample_code(value),
        .candidate(cand[0]),.metric_valid(mvalid[0]),.transient_level(hf[0]),.acoustic_level(ac[0]),.ay(ay[0]),.warm_done(dbg_warm[0]));
    piezo_transient_core #(.GATE_Q8(3584),.INV(94),.GUARD(GUARD)) u_ch1(
        .clk(clk),.reset(rst),.sample_valid(sample_valid && channel==1),.sample_code(value),
        .candidate(cand[1]),.metric_valid(mvalid[1]),.transient_level(hf[1]),.acoustic_level(ac[1]),.ay(ay[1]),.warm_done(dbg_warm[1]));
    piezo_transient_core #(.GATE_Q8(3174),.INV(106),.GUARD(GUARD)) u_ch2(
        .clk(clk),.reset(rst),.sample_valid(sample_valid && channel==2),.sample_code(value),
        .candidate(cand[2]),.metric_valid(mvalid[2]),.transient_level(hf[2]),.acoustic_level(ac[2]),.ay(ay[2]),.warm_done(dbg_warm[2]));
    piezo_transient_core #(.GATE_Q8(2202),.INV(152),.GUARD(GUARD)) u_ch3(
        .clk(clk),.reset(rst),.sample_valid(sample_valid && channel==3),.sample_code(value),
        .candidate(cand[3]),.metric_valid(mvalid[3]),.transient_level(hf[3]),.acoustic_level(ac[3]),.ay(ay[3]),.warm_done(dbg_warm[3]));
    // dbg_ay 的字节 i 表示"弦 i"。不反转时弦 i = 通道 i；反转时弦 0 = 通道 3。
    assign dbg_ay = REVERSE_CHANNELS ? {ay[0],ay[1],ay[2],ay[3]}
                                     : {ay[3],ay[2],ay[1],ay[0]};
    reg [2:0] frame_pipe;
    reg collecting;reg [4:0] frames;reg [3:0] candidates;
    reg [19:0] peak_hf[0:3],peak_ac[0:3];
    reg [19:0] max01,max23,max_peak;reg [21:0] sum_peak;
    reg [2:0] publish;reg [3:0] selected;reg [31:0] next_velocity;
    // 输出位序反转（见文件头 REVERSE_CHANNELS 说明）：核 i = 通道 i，发布时倒序。
    wire [3:0] sel_out = REVERSE_CHANNELS ?
        {selected[0],selected[1],selected[2],selected[3]} : selected;
    wire [31:0] vel_out = REVERSE_CHANNELS ?
        {next_velocity[7:0],next_velocity[15:8],next_velocity[23:16],next_velocity[31:24]} :
        next_velocity;
    wire [24:0] sum_x10=({3'd0,sum_peak}<<3)+({3'd0,sum_peak}<<1);
    wire [24:0] max_x21=({5'd0,max_peak}<<4)+({5'd0,max_peak}<<2)+{5'd0,max_peak};
    integer i;
    // R16 力度曲线：原来是 rounded>>4 的线性映射，轻拨时 velocity 只有 20~50，
    // 波导激励幅度随之只有 8%~20%，听感"轻弹几乎没声"；重拨又早早饱和在 255，
    // 动态范围全挤在上半段。改成 gamma=0.65 的幂律：
    //   x=32 -> 66 (+6.3 dB)、x=64 -> 104 (+4.2 dB)、x=128 -> 163 (+2.1 dB)、
    //   x>=192 基本不变（重拨不受影响）。
    // 实现 = 33 段表（步长 8）+ 3 位线性插值，纯比较/移位/加法，无乘法器。
    // 只改"峰值→力度"的映射，触发判据（三阶差分 + 自适应基线）完全不动。
    function [7:0] velocity_curve_table;
        input [4:0] index;
        begin
            case(index)
            5'd0:velocity_curve_table=8'd0;     5'd1:velocity_curve_table=8'd42;
            5'd2:velocity_curve_table=8'd66;    5'd3:velocity_curve_table=8'd86;
            5'd4:velocity_curve_table=8'd104;   5'd5:velocity_curve_table=8'd120;
            5'd6:velocity_curve_table=8'd135;   5'd7:velocity_curve_table=8'd149;
            5'd8:velocity_curve_table=8'd163;   5'd9:velocity_curve_table=8'd176;
            5'd10:velocity_curve_table=8'd188;  5'd11:velocity_curve_table=8'd200;
            5'd12:velocity_curve_table=8'd212;  5'd13:velocity_curve_table=8'd223;
            5'd14:velocity_curve_table=8'd234;  5'd15:velocity_curve_table=8'd245;
            5'd16:velocity_curve_table=8'd255;
            default:velocity_curve_table=8'd255;
            endcase
        end
    endfunction
    // 16 段表 + 4 位线性插值（33 段 + 3 位会多一级 mux，R16 首版本正是它把
    // 系统 Fmax 从 53.3 拖到 50.1）。段内最大斜率 42/16，插值误差 <3 LSB。
    function [7:0] velocity_curve;
        input [7:0] value;
        reg [7:0] low,high;reg [8:0] delta;reg [11:0] weighted;
        begin
            low=velocity_curve_table(value[7:4]);
            high=velocity_curve_table(value[7:4]+4'd1);
            delta=high-low;
            weighted=12'd0;
            if(value[3]) weighted=weighted+({4'd0,delta}<<3);
            if(value[2]) weighted=weighted+({5'd0,delta}<<2);
            if(value[1]) weighted=weighted+({6'd0,delta}<<1);
            if(value[0]) weighted=weighted+{7'd0,delta};
            velocity_curve=low+weighted[11:4];
        end
    endfunction
    function [7:0] velocity_from_peak;
        input [19:0] p;input [19:0] t;reg [21:0] cap,bounded;reg [22:0] rounded;
        begin
            // Cap old-tail acoustic energy by the independent new transient.
            cap={t,2'b00};bounded={2'd0,p}<cap?{2'd0,p}:cap;
            rounded={1'b0,bounded}+23'd8;
            if(rounded>23'd4080) velocity_from_peak=8'd255;
            else if(rounded<23'd96) velocity_from_peak=8'd16;
            else velocity_from_peak=velocity_curve(rounded[11:4]);
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            trigger<=0;velocity<=0;ev_valid<=0;ev_strings<=0;ev_peak<=0;ev_total<=0;
            frame_pipe<=0;collecting<=0;frames<=0;candidates<=0;
            max01<=0;max23<=0;max_peak<=0;sum_peak<=0;publish<=0;selected<=0;next_velocity<=0;
            for(i=0;i<4;i=i+1) begin peak_hf[i]<=0;peak_ac[i]<=0;end
        end else begin
            trigger<=0;ev_valid<=0;
            // 帧边界必须与**反转后的通道编号**一致：四个核按 ch_of_string 采样，
            // 编号 3 的那个核才是本轮轮询的最后一个样本。写成物理 channel==3
            // 会让帧边界与采样窗错开 3 个样本，收集窗少收一个峰值
            // （R11.2 实测：14 s 真实数据识别 9->7、fire 12->7，全部挤在 ch0）。
            frame_pipe<={frame_pipe[1:0],sample_valid && channel==3};
            if(!collecting && publish==0 && |cand) begin
                collecting<=1;frames<=0;candidates<=cand;
                for(i=0;i<4;i=i+1) begin peak_hf[i]<=hf[i];peak_ac[i]<=ac[i];end
            end else if(collecting) begin
                candidates<=candidates|cand;
                for(i=0;i<4;i=i+1) if(mvalid[i]) begin
                    if(hf[i]>peak_hf[i]) peak_hf[i]<=hf[i];
                    if(ac[i]>peak_ac[i]) peak_ac[i]<=ac[i];
                end
                if(frame_pipe[2]) begin
                    if(frames==COLLECT_FRAMES-1) begin collecting<=0;publish<=1;end
                    else frames<=frames+1'b1;
                end
            end
            // Four 50MHz stages keep the arbitration and velocity paths bounded.
            if(publish==1) begin
                max01<=peak_hf[0]>peak_hf[1]?peak_hf[0]:peak_hf[1];
                max23<=peak_hf[2]>peak_hf[3]?peak_hf[2]:peak_hf[3];
                sum_peak<={2'd0,peak_hf[0]}+{2'd0,peak_hf[1]}+{2'd0,peak_hf[2]}+{2'd0,peak_hf[3]};publish<=2;
            end else if(publish==2) begin
                max_peak<=max01>max23?max01:max23;publish<=3;
            end else if(publish==3) begin
                for(i=0;i<4;i=i+1) begin
                    // Own-channel candidate is required: preserve its 40ms guard.
                    selected[i]<=candidates[i] && ((({5'd0,peak_hf[i]}<<4)+({5'd0,peak_hf[i]}<<2))>((({5'd0,max_peak}<<3)-{5'd0,max_peak})));
                    next_velocity[i*8+:8]<=velocity_from_peak(peak_ac[i],peak_hf[i]);
                end
                publish<=4;
            end else if(publish==4) begin
                publish<=0;
                // Do not mute a chord just because several strings start together.
                // Real knock replay remains zero without the spread veto.
                if(max_peak!=0 && |selected) begin
                    trigger<=sel_out;velocity<=vel_out;
                    ev_valid<=1;ev_strings<=sel_out;ev_peak<=max_peak>32767?15'd32767:max_peak[14:0];ev_total<=ev_total+1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
