//=============================================================================
// disp_v3_funcs.vh —— v3 显示层的纯函数库
//
// **必须在每个使用它的 module 内部 include**：Verilog-2001 不允许在 module
// 之外做 function 声明（vlog-2155）。宏定义在 disp_v3_defs.vh 里，文件头
// include 一次即可。
//=============================================================================

//-----------------------------------------------------------------------------
// 弦色 / 弦名
//-----------------------------------------------------------------------------
function [23:0] str_color;
    input [1:0] s;
    begin
        case (s)
            2'd0: str_color = `C_S1;
            2'd1: str_color = `C_S2;
            2'd2: str_color = `C_S3;
            default: str_color = `C_S4;
        endcase
    end
endfunction

// 品位 x 坐标：L=380 mm 等比（与 HTML 的 FRETS[] 同源，由脚本生成的常量表）
//   0=琴枕，16=第 16 品边界
function [10:0] fret_x;
    input [4:0] f;
    begin
        case (f)
            5'd0:  fret_x = 11'd112;  5'd1:  fret_x = 11'd154;
            5'd2:  fret_x = 11'd193;  5'd3:  fret_x = 11'd230;
            5'd4:  fret_x = 11'd265;  5'd5:  fret_x = 11'd298;
            5'd6:  fret_x = 11'd330;  5'd7:  fret_x = 11'd359;
            5'd8:  fret_x = 11'd387;  5'd9:  fret_x = 11'd413;
            5'd10: fret_x = 11'd438;  5'd11: fret_x = 11'd461;
            5'd12: fret_x = 11'd483;  5'd13: fret_x = 11'd504;
            5'd14: fret_x = 11'd524;  5'd15: fret_x = 11'd542;
            default: fret_x = 11'd560;
        endcase
    end
endfunction

//-----------------------------------------------------------------------------
// 亮度混合：把 c 按权重 w (0..15) 向白色方向提亮
//   c + (255-c)*w/16 ≈ c + ((255-c)*w)>>4
// 只用一次 8x4 乘加，Gowin 会推成 LUT+加法，不占 DSP
//-----------------------------------------------------------------------------
function [7:0] lighten;
    input [7:0] c;
    input [3:0] w;
    reg [11:0] d;
    begin
        d = ((12'd255 - {4'd0, c}) * {8'd0, w}) >> 4;
        lighten = c + d[7:0];
    end
endfunction

// 线性混合两个通道：t=0 → a，t=16 → b
function [7:0] mix8;
    input [7:0] a;
    input [7:0] b;
    input [4:0] t;
    reg signed [12:0] d;
    begin
        d = ($signed({5'd0, b}) - $signed({5'd0, a})) * $signed({1'b0, t}) >>> 4;
        mix8 = a + d[7:0];
    end
endfunction

//-----------------------------------------------------------------------------
// 音符头 9x7 位图（斜椭圆），与 HTML 的 HEAD9[] 逐行一致
//-----------------------------------------------------------------------------
function [7:0] note_head_row;
    input [2:0] r;
    begin
        case (r)
            3'd0: note_head_row = 8'b0001_1110;
            3'd1: note_head_row = 8'b0011_1111;
            3'd2: note_head_row = 8'b0111_1111;
            3'd3: note_head_row = 8'b1111_1111;
            3'd4: note_head_row = 8'b1111_1111;
            3'd5: note_head_row = 8'b1111_1110;
            default: note_head_row = 8'b0111_1100;
        endcase
    end
endfunction

//-----------------------------------------------------------------------------
// MIDI 音名：字母 / 是否带升号 / 八度
//   pc→letter: C D E F G A B 的序号 0..6
//   pc→sharp : C# D# F# G# A# 为 1
//-----------------------------------------------------------------------------
function [2:0] pc_letter;
    input [3:0] pc;
    begin
        case (pc)
            4'd0, 4'd1:  pc_letter = 3'd0;   // C, C#
            4'd2, 4'd3:  pc_letter = 3'd1;   // D, D#
            4'd4:        pc_letter = 3'd2;   // E
            4'd5, 4'd6:  pc_letter = 3'd3;   // F, F#
            4'd7, 4'd8:  pc_letter = 3'd4;   // G, G#
            4'd9, 4'd10: pc_letter = 3'd5;   // A, A#
            default:     pc_letter = 3'd6;   // B
        endcase
    end
endfunction

function pc_sharp;
    input [3:0] pc;
    begin
        case (pc)
            4'd1, 4'd3, 4'd6, 4'd8, 4'd10: pc_sharp = 1'b1;
            default: pc_sharp = 1'b0;
        endcase
    end
endfunction

function [7:0] letter_ascii;
    input [2:0] l;
    begin
        case (l)
            3'd0: letter_ascii = 8'd67;   // C
            3'd1: letter_ascii = 8'd68;   // D
            3'd2: letter_ascii = 8'd69;   // E
            3'd3: letter_ascii = 8'd70;   // F
            3'd4: letter_ascii = 8'd71;   // G
            3'd5: letter_ascii = 8'd65;   // A
            default: letter_ascii = 8'd66; // B
        endcase
    end
endfunction

// MIDI → 五线谱 y（diatonic 基准：E4 在 `ST_YE4，每 diatonic 走 `ST_HALF px）
//   d  = (note/12)*7 + step(pc)
//   y  = ST_YE4 - (d - 37) * ST_HALF
// 全部用移位加实现，无乘法器。**系数由 `ST_HALF 推出，改半间距不必改这里。**
function [9:0] staff_y_of;
    input [6:0] note;
    reg [15:0] prod;  // 必须显式加宽：Verilog 乘法结果宽度 = max(操作数)，7x7 会丢高位
    reg [3:0] q;      // note/12
    reg [2:0] st;     // pc → diatonic step
    reg [3:0] pc;
    reg [12:0] dq;    // 7*ST_HALF*q
    reg [9:0] ds;     // ST_HALF*st
    begin
        prod = note * 16'd43;          // 0..5461
        q    = prod[12:9];             // /12，对 0..127 全域精确
        pc   = note - (q << 3) - (q << 2);
        case (pc)
            4'd0, 4'd1:  st = 3'd0;
            4'd2, 4'd3:  st = 3'd1;
            4'd4:        st = 3'd2;
            4'd5, 4'd6:  st = 3'd3;
            4'd7, 4'd8:  st = 3'd4;
            4'd9, 4'd10: st = 3'd5;
            default:     st = 3'd6;
        endcase
        // 7*ST_HALF*q = 49q（ST_HALF=7 时）；写法 q*(64-16+1)
        dq = (q << 6) - (q << 4) + q;
        // ST_HALF*st = 7*st
        ds = (st << 3) - {7'd0, st};
        staff_y_of = (`ST_YE4 + 37 * `ST_HALF) - dq - {4'd0, ds};
    end
endfunction
