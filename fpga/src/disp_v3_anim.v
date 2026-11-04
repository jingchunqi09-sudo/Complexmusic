//=============================================================================
// disp_v3_anim —— 显示层 v3 的动画引擎
//
// 设计要点（对标 Project F / Tetris-VG 的做法：把「时间」做成一个帧节拍，
// 所有动画量都是帧计数的纯函数，像素路径只做查表比较）：
//
//   * frame_start 递增 16 位帧计数，60 Hz 下约 18 分钟回绕
//   * 起音闪光 flash[3:0]：i_fire 上升沿置 15，每帧减 1（约 0.25 s）
//   * 峰值保持 vpk[3:0]  ：跟随 i_vel 上升，每 4 帧减 1（约 1 s）
//   * 频谱峰值 band_pk   ：跟随 i_bands 上升，每 3 帧减 1
//   * 呼吸相位 breath     ：帧计数低 6 位的三角波，供按品格呼吸用
//   * 音名 / 五线谱 y      ：在帧节拍上算一次，像素域只读寄存器
//
// 全部在同一时钟域（pixel clock）内，不引入新的 CDC。
//=============================================================================
`include "disp_v3_defs.vh"

module disp_v3_anim (
    input  wire        i_clk,
    input  wire        i_reset,
    input  wire        i_frame_start,
    input  wire [3:0]  i_fire,        // 起音脉冲（pixel 域，来自 CDC 后的 fire_flash）
    input  wire [31:0] i_vel,         // 4 弦力度
    input  wire [27:0] i_notes,       // 4 弦 MIDI
    input  wire [63:0] i_bands,       // 8 段频谱
    output reg  [15:0] o_flash,       // 4 x 4 bit
    output reg  [31:0] o_vpk,         // 4 x 8 bit
    output reg  [63:0] o_band_pk,     // 8 x 8 bit
    output reg  [7:0]  o_breath,      // 0..15 呼吸幅度
    output reg  [23:0] o_name_cur,    // {char0, char1, char2} 当前音名
    output reg  [95:0] o_name_s,      // 4 x 24 bit 各弦音名
    output reg  [39:0] o_staff_y,     // 4 x 10 bit 五线谱纵坐标
    output reg  [29:0] o_hist_y,      // 3 x 10 bit 最近三次起音的五线谱纵坐标
    output reg  [2:0]  o_hist_v,      // 历史音有效位
    output reg  [1:0]  o_sel         // 当前发声弦（最近一次起音）
);
`include "disp_v3_funcs.vh"


    reg [15:0] frame_cnt;
    reg [3:0]  fire_d;                // 上一拍的 fire，用于上升沿
    reg [3:0]  tick2, tick3, tick4;

    wire [3:0] fire_rise = i_fire & ~fire_d;

    // 帧分频脉冲：tick3 每 3 帧，tick4 每 4 帧
    always @(posedge i_clk) begin
        if (i_reset) begin
            frame_cnt <= 16'd0;
            fire_d    <= 4'd0;
            tick2     <= 4'd0;
            tick3     <= 4'd0;
            tick4     <= 4'd0;
        end else begin
            fire_d <= i_fire;
            if (i_frame_start) begin
                frame_cnt <= frame_cnt + 16'd1;
                tick2     <= tick2 + 4'd1;
                tick3     <= (tick3 == 4'd2) ? 4'd0 : tick3 + 4'd1;
                tick4     <= (tick4 == 4'd3) ? 4'd0 : tick4 + 4'd1;
            end
        end
    end

    // 呼吸相位：帧计数低 6 位折成三角波 0..15
    always @(posedge i_clk) begin
        if (i_reset) o_breath <= 8'd0;
        else begin
            o_breath <= frame_cnt[5] ? (8'd31 - {2'd0, frame_cnt[4:0]})
                                     : {3'd0, frame_cnt[4:0]};
        end
    end

    // 闪光 / 峰值 / 频谱峰
    integer i;
    always @(posedge i_clk) begin
        if (i_reset) begin
            o_flash   <= 16'd0;
            o_vpk     <= 32'd0;
            o_band_pk <= 64'd0;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                // 起音闪光：置满后每帧衰减
                if (fire_rise[i])                    o_flash[i*4 +: 4] <= 4'd15;
                else if (i_frame_start && o_flash[i*4 +: 4] != 4'd0)
                                                     o_flash[i*4 +: 4] <= o_flash[i*4 +: 4] - 4'd1;

                // 峰值保持：上升立即，下降每 4 帧 1 级
                if (i_vel[i*8 +: 8] >= o_vpk[i*8 +: 8]) o_vpk[i*8 +: 8] <= i_vel[i*8 +: 8];
                else if (i_frame_start && tick4 == 4'd0) o_vpk[i*8 +: 8] <= o_vpk[i*8 +: 8] - 8'd1;
            end
            for (i = 0; i < 8; i = i + 1) begin
                if (i_bands[i*8 +: 8] >= o_band_pk[i*8 +: 8]) o_band_pk[i*8 +: 8] <= i_bands[i*8 +: 8];
                else if (i_frame_start && tick3 == 4'd0)      o_band_pk[i*8 +: 8] <= o_band_pk[i*8 +: 8] - 8'd1;
            end
        end
    end

    // 当前弦：最近一次起音，帧节拍上锁存
    // 同拍还要把「刚起音的那个音」推进历史表，供曲谱画左侧三个淡音
    wire [6:0] fired_note = fire_rise[0] ? i_notes[0*7 +: 7] :
                            fire_rise[1] ? i_notes[1*7 +: 7] :
                            fire_rise[2] ? i_notes[2*7 +: 7] :
                            fire_rise[3] ? i_notes[3*7 +: 7] :
                                           i_notes[0*7 +: 7];

    always @(posedge i_clk) begin
        if (i_reset) o_sel <= 2'd0;
        else begin
            // 起音沿立即切弦（不等帧节拍），否则一帧内最多慢 16 ms 才切
            if (fire_rise[0])      o_sel <= 2'd0;
            else if (fire_rise[1]) o_sel <= 2'd1;
            else if (fire_rise[2]) o_sel <= 2'd2;
            else if (fire_rise[3]) o_sel <= 2'd3;
        end
    end

    // 曲谱历史音：同样跟随起音沿，不能挂在 i_frame_start 上
    // （fire_flash 是单拍脉冲，等帧节拍时早就消失了）
    always @(posedge i_clk) begin
        if (i_reset) begin
            o_hist_y <= 30'd0;
            o_hist_v <= 3'd0;
        end else if (fire_rise != 4'd0) begin
            o_hist_y[19:10] <= o_hist_y[9:0];
            o_hist_y[29:20] <= o_hist_y[19:10];
            o_hist_y[9:0]   <= staff_y_of(fired_note);
            o_hist_v        <= {o_hist_v[1:0], 1'b1};
        end
    end

    // 音名与五线谱坐标：帧节拍算一次（含一次 7x7 乘，13.5 ns 预算内足够）
    // 注意 Verilog 函数必须「先定义后使用」，顺序不能调换。
    function [3:0] note_pc;
        input [6:0] note;
        reg [15:0] prod;
        reg [3:0] q;
        begin
            prod    = note * 16'd43;          // 0..5461
            q       = prod[12:9];             // note/12，对 0..127 精确
            note_pc = note - (q << 3) - (q << 2);
        end
    endfunction

    function [3:0] note_oct;
        input [6:0] note;
        reg [15:0] prod;
        begin
            prod     = note * 16'd43;
            note_oct = prod[12:9] - 4'd1;     // MIDI 60 = C4
        end
    endfunction

    function [7:0] name_letter;
        input [6:0] note;
        begin
            name_letter = letter_ascii(pc_letter(note_pc(note)));
        end
    endfunction

    function [7:0] name_acc;
        input [6:0] note;
        begin
            name_acc = pc_sharp(note_pc(note)) ? 8'd35 : 8'd32;   // '#'
        end
    endfunction

    function [7:0] name_digit;
        input [6:0] note;
        begin
            name_digit = 8'd48 + {4'd0, note_oct(note)};
        end
    endfunction

    integer k;
    always @(posedge i_clk) begin
        if (i_reset) begin
            o_name_cur <= 24'd0;
            o_name_s   <= 96'd0;
            o_staff_y  <= 40'd0;
        end else if (i_frame_start) begin
            for (k = 0; k < 4; k = k + 1) begin
                o_name_s[k*24      +: 8] <= name_letter(i_notes[k*7 +: 7]);
                o_name_s[k*24 + 8  +: 8] <= name_acc(i_notes[k*7 +: 7]);
                o_name_s[k*24 + 16 +: 8] <= name_digit(i_notes[k*7 +: 7]);
                o_staff_y[k*10 +: 10]    <= staff_y_of(i_notes[k*7 +: 7]);
            end
            o_name_cur <= {name_letter(i_notes[o_sel*7 +: 7]),
                           name_acc(i_notes[o_sel*7 +: 7]),
                           name_digit(i_notes[o_sel*7 +: 7])};
        end
    end

endmodule
