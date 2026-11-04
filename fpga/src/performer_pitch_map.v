`timescale 1ns/1ps
// Four independent fingerboards. Uke is chromatic 0..16 frets. Violin uses
// three 5-key gesture groups and fret16 as the +36-semitone anchor.
// Group changes preserve pitch class; changing speed never resets pitch.
module performer_pitch_map #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer FAST_MS=40,
    parameter integer SLOW_MS=160
)(
    input wire clk,reset,
    input wire [19:0] fret_bus,
    input wire [3:0] valid_mask,
    // R25：8 lane 定弦音高（每 lane 7 bit，低 4 lane = 小提琴、高 4 = 尤克里里）。
    // 由 ESP32 的 CMD_SET_TUNING/REG_TUNE_BASE 驱动。上电默认值见 link_regs.v，
    // 逐条等于原来这里的 localparam（55/62/69/76 + 67/60/64/69），
    // 所以 ESP32 不接线时音高与 R24 完全一致。
    input wire [55:0] open_notes,
    output wire [55:0] note_bus,
    output wire [3:0] bowed_strings
);
    localparam integer TICK_CLKS=CLOCK_HZ/1000;
    function integer width;
        input integer n;
        begin width=1;while(n>1)begin n=n>>1;width=width+1;end end
    endfunction
    reg [width(TICK_CLKS)-1:0] tick_count;
    wire tick_ms=(tick_count==TICK_CLKS-1);
    always @(posedge clk) begin
        if(reset || tick_ms)tick_count<=0;else tick_count<=tick_count+1'b1;
    end
    genvar s;
    // R25：定弦回退。open_notes 全 0（端口悬空 / ESP32 从未连接 / 老测试台
    // 没接这个新端口）时退回 R24 的硬编码定弦，保证音高与以前完全一致。
    // 8 根弦同时被设成 MIDI 0 在物理上不成立，所以这条回退不会误触发。
    // 用拼接常量而不是 hex 字面量：56 bit 不是 4 的整数倍，手写 hex 极易错。
    wire [55:0] open_eff = (open_notes == 56'd0) ?
        {7'd69, 7'd64, 7'd60, 7'd67, 7'd76, 7'd69, 7'd62, 7'd55} : open_notes;
    generate for(s=0;s<4;s=s+1) begin: STRING
        // R26：**逐 lane** 回退，不能只在"8 个全 0"时回退。
        // 只要有一根弦写成 0（ESP32 只发了部分 lane、写地址错一位、上电时序……），
        // open_notes!=0 就不会触发整体回退，而那根弦的开放音高是 MIDI 0 ≈ 8 Hz ——
        // 波导延迟会超过延迟线深度并环绕成噪声（听感是"乱响"）。
        // 判据：MIDI < 12（≈16 Hz）在本乐器上不可能出现，一律当"没设"处理。
        localparam [6:0] V_OPEN_DEF=(s==0)?7'd55:(s==1)?7'd62:(s==2)?7'd69:7'd76;
        localparam [6:0] U_OPEN_DEF=(s==0)?7'd67:(s==1)?7'd60:(s==2)?7'd64:7'd69;
        wire [6:0] V_RAW = open_eff[s*7 +: 7];
        wire [6:0] U_RAW = open_eff[(s+4)*7 +: 7];
        wire [6:0] V_OPEN = (V_RAW < 7'd12) ? V_OPEN_DEF : V_RAW;
        wire [6:0] U_OPEN = (U_RAW < 7'd12) ? U_OPEN_DEF : U_RAW;
        wire [4:0] fret=valid_mask[s] ? fret_bus[s*5 +:5] : 5'd0;
        reg [4:0] previous_fret;
        // Octave is decoded directly from the coherent current fret.  Holding
        // an old group for one cycle can create a false note at 16->group0.
        reg [2:0] gesture;
        reg [3:0] pitch_class;
        reg [width(SLOW_MS)-1:0] dwell_ms;
        wire [4:0] key=(fret==0)?5'd0:fret-1'b1;
        // Explicit range decode avoids variable divide/modulo hardware.
        wire [1:0] next_group=(fret<=5)?0:(fret<=10)?1:2;
        // Keep the subtractors in the five-bit fret domain.  Unsized integer
        // literals made Gowin infer a 32-bit expression and then truncate it;
        // the explicit constants preserve the same values without a width
        // warning or an unnecessarily wide compare/subtract cone.
        wire [4:0] group_key=(fret<=5)?key:(fret<=10)?key-5'd5:key-5'd10;
        wire fast=(gesture==0 || gesture==4);
        wire move_left=(gesture==0 || gesture==1);
        wire moving=(gesture!=2 && fret!=0 && fret!=16);
        wire [5:0] offset=(fret==16)?6'd36:
            (fret==0)?6'd0:((next_group==0)?6'd0:(next_group==1)?6'd12:6'd24)+pitch_class;
        assign note_bus[s*7 +:7]=V_OPEN+offset;
        assign note_bus[(s+4)*7 +:7]=U_OPEN+fret;
        assign bowed_strings[s]=(fret!=0);
        always @(posedge clk) begin
            if(reset)begin previous_fret<=0;gesture<=2;pitch_class<=0;dwell_ms<=0;end
            else if(fret!=previous_fret)begin
                previous_fret<=fret;dwell_ms<=0;
                if(fret!=0 && fret!=16)begin gesture<=group_key[2:0];end
                else gesture<=2;
            end else if(tick_ms)begin
                if(!moving) dwell_ms<=0;
                else if(dwell_ms>=(fast?FAST_MS:SLOW_MS)-1)begin
                    dwell_ms<=0;
                    if(move_left && pitch_class!=0)pitch_class<=pitch_class-1'b1;
                    else if(!move_left && pitch_class!=11)pitch_class<=pitch_class+1'b1;
                end else dwell_ms<=dwell_ms+1'b1;
            end
        end
    end endgenerate
endmodule
