//=============================================================================
// disp_v3_text —— v3.1 文本层（tile map + 动态 token + 双字号字模）
//
// 架构沿用 R16 的 r9_text_layer（tile-map -> token -> 字模 ROM -> 位测试）：
//   小字：160 列 x 64 行 x 8x16 tile，字符码 12 bit + 颜色码 4 bit
//   大字： 80 列 x 32 行 x 16x32 tile（y>=464 的区块上移 16 行避开面板间隙）
//
// 动态 token 的编号与解析函数由 05_生成脚本/gen_v3_maps.py 统一生成到
// disp_v3_tokens.vh —— 本模块只负责把上游信号转成寄存器，不重复定义编号。
//=============================================================================
`include "disp_v3_defs.vh"

module disp_v3_text (
    input  wire        i_clk,
    input  wire        i_reset,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire        i_frame_start,
    input  wire [1:0]  i_mode,
    input  wire [23:0] i_name_cur,     // {字母, 升号, 八度}
    input  wire [95:0] i_name_s,       // 4 x 24 bit
    input  wire [31:0] i_vel,
    input  wire [27:0] i_notes,
    input  wire [4:0]  i_fret,
    input  wire [1:0]  i_sel,
    input  wire [15:0] i_freq,
    input  wire [1:0]  i_gain,
    input  wire signed [7:0] i_cents,  // 音分 x10（±500）
    input  wire signed [7:0] i_bow,    // 弓位 -62..+62
    input  wire [7:0]  i_bow_speed,
    input  wire [3:0]  i_bow_gates,
    input  wire [3:0]  i_piezo_warm,
    input  wire [15:0] i_peak,         // 峰值保持（Q15 无符号量级）
    input  wire [15:0] i_rms,          // 有效值
    input  wire [15:0] i_crest_tenths, // 峰均比 x10
    output reg         o_hit,
    output reg  [23:0] o_rgb
);
`include "r9_note_hz.vh"
`include "disp_v3_funcs.vh"

    //------------------------------------------------------------------
    // 令牌寄存器（disp_v3_tokens.vh 依赖这些名字，顺序不可调）
    //------------------------------------------------------------------
    wire [15:0] t_cur;          // {字母, 八度}
    wire [95:0] t_sname;        // 4 x {字母, 升号, 八度}
    reg  [3:0]  t_vel  [0:11];
    reg  [3:0]  t_freq [0:3];
    reg  [3:0]  t_sfq  [0:15];
    reg  [3:0]  t_fret [0:1];
    reg  [3:0]  t_ct   [0:3];
    reg  [3:0]  t_gn   [0:1];
    reg  [3:0]  t_pk   [0:1];
    reg  [3:0]  t_rms  [0:1];
    reg  [3:0]  t_cr   [0:1];
    wire [1:0]  t_sel;
    reg  [3:0]  t_bow_sgn;
    reg  [3:0]  t_bow_d2, t_bow_d1;
    reg  [3:0]  t_spd_d2, t_spd_d1, t_spd_d0;
    reg         t_cont_on;
    reg  [2:0]  t_pz_cnt;

    assign t_cur   = {i_name_cur[23:16], i_name_cur[7:0]};
    assign t_sname = i_name_s;
    assign t_sel   = i_sel;

    // 四弦频率查表预寄存：note_hz 是 128 项 case（约 7 级 MUX 树），
    // 原来直接串在 frame_start 那一拍里，和十进制拆分叠成 27.2 ns 的关键路径。
    // 输入只有 i_notes（变化极慢），每拍算一次、代价 4×16 bit，把查表移出关键路径。
    reg [63:0] nhz;
    always @(posedge i_clk) begin
        nhz[ 0 +: 16] <= note_hz(i_notes[ 0 +: 7]);
        nhz[16 +: 16] <= note_hz(i_notes[ 7 +: 7]);
        nhz[32 +: 16] <= note_hz(i_notes[14 +: 7]);
        nhz[48 +: 16] <= note_hz(i_notes[21 +: 7]);
    end

`include "disp_v3_tokens.vh"

    //------------------------------------------------------------------
    // 十进制拆分（只用移位加，避免除法器进关键路径）
    //   /10   : (x * 205) >> 11     对 0..199 精确
    //   /100  : (x * 41)  >> 12     对 0..999 精确
    //
    // R42：原来写成 `v * 20'd205` / `v * 20'd41`，被综合成 DSP。
    // 本工程 DSP 只有 118 块、已用 77.5，逐拍实测显示：
    //   关键路径 = DSP[37] → DSP[42] 串联，且每级 tNET 3~4 ns（CLS 86% 导致布线极长），
    //   单条路径 27.2 ns，预算 13.6 ns → worst slack −13.624 ns，271 个端点违例。
    // 改回纯移位加法后这些乘法落回寄存器旁边的 LUT，既释放 DSP 又砍掉长途布线。
    // 注意：移位必须在 20 位上下文里做，否则 v<<7 会按 v 的 10 位截断。
    //------------------------------------------------------------------
    function [3:0] div10;
        input [9:0] v;
        reg [19:0] p, x;
        begin
            x = {10'd0, v};
            p = (x<<7) + (x<<6) + (x<<3) + (x<<2) + x;   // v*205
            div10 = p[14:11];
        end
    endfunction

    function [3:0] div100;
        input [9:0] v;
        reg [19:0] p, x;
        begin
            x = {10'd0, v};
            p = (x<<5) + (x<<3) + x;                     // v*41
            div100 = p[15:12];
        end
    endfunction

    function [9:0] mul10;
        input [3:0] d;
        begin
            mul10 = (d << 3) + (d << 1);       // 10 位上下文里做 *10，不会被截断
        end
    endfunction

    function [9:0] mul100;
        input [3:0] d;
        begin
            mul100 = (d << 6) + (d << 5) + (d << 2);   // d*100
        end
    endfunction

    function [3:0] mod10;
        input [9:0] v;
        reg [9:0] t;
        begin
            t = mul10(div10(v));
            mod10 = v[3:0] - t[3:0];
        end
    endfunction
    integer n, m;
    reg [9:0]  vp, r2, r3, ac;
    reg [15:0] fqv;
    reg [23:0] mul;                 // 宽中间量：Verilog 乘法结果宽度取上下文宽度，
                                    // 直接写 (a*b)>>k 会按 LHS 位宽截断（v3.0 的 0.03 就是这里）

    always @(posedge i_clk) begin
        if (i_reset) begin
            for (n = 0; n < 12; n = n + 1) t_vel[n] <= 4'd0;
            for (n = 0; n < 16; n = n + 1) t_sfq[n] <= 4'd0;
            for (n = 0; n < 4;  n = n + 1) begin t_freq[n] <= 4'd0; t_ct[n] <= 4'd0; end
            t_fret[0] <= 4'd0; t_fret[1] <= 4'd0;
            t_gn[0]   <= 4'd2; t_gn[1]   <= 4'd0;
            t_pk[0]   <= 4'd0; t_pk[1]   <= 4'd0;
            t_rms[0]  <= 4'd0; t_rms[1]  <= 4'd0;
            t_cr[0]   <= 4'd0; t_cr[1]   <= 4'd0;
            t_bow_sgn <= 4'd1; t_bow_d2 <= 4'd0; t_bow_d1 <= 4'd0;
            t_spd_d2  <= 4'd0; t_spd_d1  <= 4'd0; t_spd_d0 <= 4'd0;
            t_cont_on <= 1'b0; t_pz_cnt  <= 3'd0;
        end else if (i_frame_start) begin
            // ---- 力度 0.00..1.00 ----
            for (n = 0; n < 4; n = n + 1) begin
                // *101 用移位加（原 `* 24'd101` 会被综合成 DSP）
                mul = ({12'd0,i_vel[n*8 +: 8]}<<6) + ({12'd0,i_vel[n*8 +: 8]}<<5)
                    + ({12'd0,i_vel[n*8 +: 8]}<<2) + {12'd0,i_vel[n*8 +: 8]};
                vp  = mul[17:8];                                // 0..100
                r2  = vp - mul100(div100(vp));
                t_vel[n*3]     <= div100(vp);
                t_vel[n*3 + 1] <= div10(r2);
                t_vel[n*3 + 2] <= mod10(r2);
            end

            // ---- 当前频率 4 位 ----
            fqv = (i_freq > 16'd1999) ? 16'd1999 : i_freq;
            t_freq[0] <= (fqv >= 16'd1000) ? 4'd1 : 4'd0;
            r2 = (fqv >= 16'd1000) ? (fqv[9:0] - 10'd1000) : fqv[9:0];
            r3 = r2 - mul100(div100(r2));
            t_freq[1] <= div100(r2);
            t_freq[2] <= div10(r3);
            t_freq[3] <= mod10(r3);

            // ---- 四弦频率 ----
            for (n = 0; n < 4; n = n + 1) begin
                fqv = nhz[n*16 +: 16];
                if (fqv > 16'd1999) fqv = 16'd1999;
                t_sfq[n*4]     <= (fqv >= 16'd1000) ? 4'd1 : 4'd0;
                r2 = (fqv >= 16'd1000) ? (fqv[9:0] - 10'd1000) : fqv[9:0];
                r3 = r2 - mul100(div100(r2));
                t_sfq[n*4 + 1] <= div100(r2);
                t_sfq[n*4 + 2] <= div10(r3);
                t_sfq[n*4 + 3] <= mod10(r3);
            end

            // ---- 品号 ----
            t_fret[0] <= div10({5'd0, i_fret});
            t_fret[1] <= mod10({5'd0, i_fret});

            // ---- 音分：显示 ±9.9（{符号, 个位, 十分位}）----
            t_ct[0] <= i_cents[7] ? 4'd2 : 4'd1;
            ac      = i_cents[7] ? (10'd0 - {2'd0, i_cents}) : {2'd0, i_cents};
            ac      = (ac > 10'd99) ? 10'd99 : ac;
            t_ct[1] <= div10(ac);
            t_ct[2] <= mod10(ac);

            // ---- 量程 x.x ----
            t_gn[0] <= {2'd0, i_gain} + 4'd1;
            t_gn[1] <= 4'd0;

            // ---- 峰值 / 有效值（%FS）与峰均比（dB x10）----
            mul = ({9'd0,i_peak[15:1]}<<6) + ({9'd0,i_peak[15:1]}<<5) + ({9'd0,i_peak[15:1]}<<2);
            vp  = mul[21:14];                                   // /128/256 -> %FS
            vp  = (vp > 10'd99) ? 10'd99 : vp;
            t_pk[1] <= div10(vp);
            t_pk[0] <= mod10(vp);

            mul = ({9'd0,i_rms[15:1]}<<6) + ({9'd0,i_rms[15:1]}<<5) + ({9'd0,i_rms[15:1]}<<2);
            vp  = mul[21:14];
            vp  = (vp > 10'd99) ? 10'd99 : vp;
            t_rms[1] <= div10(vp);
            t_rms[0] <= mod10(vp);

            ac = (i_crest_tenths > 16'd99) ? 10'd99 : i_crest_tenths[9:0];
            t_cr[0] <= div10(ac);
            t_cr[1] <= mod10(ac);

            // ---- 小提琴：弓位 ----
            ac = i_bow[7] ? (10'd0 - {2'd0, i_bow}) : {2'd0, i_bow};
            ac = (ac > 10'd99) ? 10'd99 : ac;
            t_bow_sgn <= i_bow[7] ? 4'd2 : 4'd1;               // 2 -> '-', 1 -> '+'
            t_bow_d2  <= div10(ac);                            // 十位（0 显示为空格）
            t_bow_d1  <= mod10(ac);                            // 个位

            // ---- 小提琴：弓速 ----
            ac = {2'd0, i_bow_speed};
            r2 = ac - mul10(div100(ac));
            t_spd_d2 <= div100(ac);
            t_spd_d1 <= div10(r2);
            t_spd_d0 <= mod10(r2);

            // ---- 接触 / 压电就绪计数 ----
            t_cont_on <= (i_bow_gates != 4'd0);
            t_pz_cnt  <= {1'b0, i_piezo_warm[3]} + {1'b0, i_piezo_warm[2]} +
                         {1'b0, i_piezo_warm[1]} + {1'b0, i_piezo_warm[0]};
        end
    end

    //------------------------------------------------------------------
    // 调色板（与 gen_v3_maps.py 的 C{} 一一对应）
    //------------------------------------------------------------------
    function [23:0] palette;
        input [3:0] c;
        begin
            case (c)
                4'd1:  palette = `C_TX;
                4'd2:  palette = `C_TEAL;
                4'd3:  palette = `C_AMBER;
                4'd4:  palette = `C_RED;
                4'd5:  palette = `C_TX2;
                4'd6:  palette = `C_TX3;
                4'd7:  palette = `C_TX4;
                4'd8:  palette = `C_S1;
                4'd9:  palette = `C_S2;
                4'd10: palette = `C_S3;
                4'd11: palette = `C_S4;
                4'd12: palette = `C_VIOLET;
                4'd13: palette = `C_BLUE;
                4'd14: palette = `C_EDGE_HI;
                default: palette = `C_TX3;
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // ROM
    //------------------------------------------------------------------
    reg [15:0] small_map [0:8191]  /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] large_map [0:2047]  /* synthesis syn_romstyle="block_rom" */;
    reg [7:0]  font_small[0:2047]  /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] font_large[0:4095]  /* synthesis syn_romstyle="block_rom" */;
    initial begin
        $readmemh("src/rom/disp_v3_small_map.hex",  small_map);
        $readmemh("src/rom/disp_v3_large_map.hex",  large_map);
        $readmemh("src/rom/r9_font8x16.hex",        font_small);
        $readmemh("src/rom/r9_font16x32.hex",       font_large);
    end

    wire [9:0] big_y = (i_y >= 10'd464) ? i_y - 10'd16 : i_y;

    wire [12:0] small_address = ({7'd0, i_y[9:4]} << 7) + ({7'd0, i_y[9:4]} << 5) + {5'd0, i_x[10:3]};
    wire [10:0] large_address = (i_y >= 10'd448 && i_y < 10'd464) ? 11'd2047 :
                                ({6'd0, big_y[9:5]} << 6) + ({6'd0, big_y[9:5]} << 4) + {4'd0, i_x[10:4]};

    reg [15:0] sm1, lg1;
    reg [2:0]  sx1, sx2, sx3;
    reg [3:0]  sy1, lx1, lx2, lx3;
    reg [4:0]  ly1, ly2;
    reg [7:0]  sc2, lc2;
    reg [3:0]  sy2, scol2, lcol2, scol3, lcol3;
    reg [7:0]  sbits3;
    reg [15:0] lbits3;

    // 字模 ROM 只存 32..126 共 95 个字形（1520 / 3040 行），
    // 所以索引必须是 (char-32)*字高 + row。直接用 char*字高 会整体偏移 32 个字形
    // （表现为大写变小写、数字变字母）——这是 v3.0 就存在的隐性错误。
    wire [6:0] si = (sc2 >= 8'd32) ? (sc2[6:0] - 7'd32) : 7'd0;
    wire [6:0] li = (lc2 >= 8'd32) ? (lc2[6:0] - 7'd32) : 7'd0;
    wire [10:0] s_faddr = {si, 4'b0000} + {7'd0, sy2};
    wire [11:0] l_faddr = {li, 5'b00000} + {8'd0, ly2};

    always @(posedge i_clk) begin
        sm1 <= small_map[small_address];
        lg1 <= large_map[large_address];
        sx1 <= i_x[2:0]; sy1 <= i_y[3:0];
        lx1 <= i_x[3:0]; ly1 <= big_y[4:0];
        sc2 <= token_char(sm1[11:0]);
        lc2 <= token_char(lg1[11:0]);
        sx2 <= sx1; sy2 <= sy1;
        lx2 <= lx1; ly2 <= ly1;
        scol2 <= sm1[15:12]; lcol2 <= lg1[15:12];
        sbits3 <= font_small[s_faddr];
        lbits3 <= font_large[l_faddr];
        sx3 <= sx2; lx3 <= lx2;
        scol3 <= scol2; lcol3 <= lcol2;
        if (i_reset) begin
            o_hit <= 1'b0; o_rgb <= 24'd0;
        end else if (lbits3[15 - lx3]) begin
            o_hit <= 1'b1; o_rgb <= palette(lcol3);
        end else if (sbits3[7 - sx3]) begin
            o_hit <= 1'b1; o_rgb <= palette(scol3);
        end else begin
            o_hit <= 1'b0; o_rgb <= 24'd0;
        end
    end

endmodule
