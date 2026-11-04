//=============================================================================
// disp_v3_tokens.vh —— 动态 token 定义与字符解析（由 gen_v3_maps.py 生成）
//
// **请勿手改**：改文案或改 token 编号请改 05_生成脚本/gen_v3_maps.py。
// 本文件必须在 module 内部 include，且在下列寄存器声明之后：
//   wire [15:0] t_cur;      // {字母, 八度}
//   wire [95:0] t_sname;    // 4 x {字母, 升号, 八度}
//   reg  [3:0] t_vel  [0:11];   // 4 弦 x 3 位小数
//   reg  [3:0] t_freq [0:3];    // 当前频率 4 位
//   reg  [3:0] t_sfq  [0:15];   // 4 弦 x 4 位频率
//   reg  [3:0] t_fret [0:1];    // 品号 2 位
//   reg  [3:0] t_ct   [0:3];    // 音分 {符号,十位,个位,十分位}
//   reg  [3:0] t_gn   [0:1];    // 量程 整数,十分位
//   wire [1:0] t_sel;  wire [2:0] t_gate_cnt; wire [2:0] t_pz_cnt;
//   wire signed [7:0] t_bow;  wire [7:0] t_spd;
//=============================================================================

`define TOK_CUR    200
`define TOK_SNAME  204
`define TOK_VEL    220
`define TOK_FREQ   236
`define TOK_STR    240
`define TOK_FRET   241
`define TOK_SFREQ  244
`define TOK_CENTS  264
`define TOK_GAIN   268
`define TOK_BOW    272
`define TOK_SPD    276
`define TOK_CONT   280
`define TOK_PZ     284
`define TOK_PK     288
`define TOK_RMS    292
`define TOK_CR     296

// 数值 -> 字符；t_sel/计数等按 4 位十进制输出，前导 0 用空格
function [7:0] token_char;
    input [11:0] tk;
    reg [3:0] dgt;
    begin
        dgt = 4'd0;
        token_char = 8'd32;                 // 默认空白
        case (tk)
            12'd200: token_char = t_cur[15:8];
            12'd201: token_char = t_cur[7:0];
            12'd204: token_char = t_sname[23:16];
            12'd205: token_char = t_sname[15:8];
            12'd206: token_char = t_sname[7:0];
            12'd207: token_char = t_sname[47:40];
            12'd208: token_char = t_sname[39:32];
            12'd209: token_char = t_sname[31:24];
            12'd210: token_char = t_sname[71:64];
            12'd211: token_char = t_sname[63:56];
            12'd212: token_char = t_sname[55:48];
            12'd213: token_char = t_sname[95:88];
            12'd214: token_char = t_sname[87:80];
            12'd215: token_char = t_sname[79:72];
            12'd220: token_char = 8'd48 + {4'd0, t_vel[0]};
            12'd221: token_char = 8'd48 + {4'd0, t_vel[1]};
            12'd222: token_char = 8'd48 + {4'd0, t_vel[2]};
            12'd223: token_char = 8'd48 + {4'd0, t_vel[3]};
            12'd224: token_char = 8'd48 + {4'd0, t_vel[4]};
            12'd225: token_char = 8'd48 + {4'd0, t_vel[5]};
            12'd226: token_char = 8'd48 + {4'd0, t_vel[6]};
            12'd227: token_char = 8'd48 + {4'd0, t_vel[7]};
            12'd228: token_char = 8'd48 + {4'd0, t_vel[8]};
            12'd229: token_char = 8'd48 + {4'd0, t_vel[9]};
            12'd230: token_char = 8'd48 + {4'd0, t_vel[10]};
            12'd231: token_char = 8'd48 + {4'd0, t_vel[11]};
            12'd236: token_char = (t_freq[0] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_freq[0]});
            12'd237: token_char = 8'd48 + {4'd0, t_freq[1]};
            12'd238: token_char = 8'd48 + {4'd0, t_freq[2]};
            12'd239: token_char = 8'd48 + {4'd0, t_freq[3]};
            12'd240: token_char = 8'd49 + {6'd0, t_sel};
            12'd241: token_char = 8'd48 + {4'd0, t_fret[0]};
            12'd242: token_char = 8'd48 + {4'd0, t_fret[1]};
            12'd244: token_char = (t_sfq[0] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_sfq[0]});
            12'd245: token_char = 8'd48 + {4'd0, t_sfq[1]};
            12'd246: token_char = 8'd48 + {4'd0, t_sfq[2]};
            12'd247: token_char = 8'd48 + {4'd0, t_sfq[3]};
            12'd248: token_char = (t_sfq[4] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_sfq[4]});
            12'd249: token_char = 8'd48 + {4'd0, t_sfq[5]};
            12'd250: token_char = 8'd48 + {4'd0, t_sfq[6]};
            12'd251: token_char = 8'd48 + {4'd0, t_sfq[7]};
            12'd252: token_char = (t_sfq[8] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_sfq[8]});
            12'd253: token_char = 8'd48 + {4'd0, t_sfq[9]};
            12'd254: token_char = 8'd48 + {4'd0, t_sfq[10]};
            12'd255: token_char = 8'd48 + {4'd0, t_sfq[11]};
            12'd256: token_char = (t_sfq[12] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_sfq[12]});
            12'd257: token_char = 8'd48 + {4'd0, t_sfq[13]};
            12'd258: token_char = 8'd48 + {4'd0, t_sfq[14]};
            12'd259: token_char = 8'd48 + {4'd0, t_sfq[15]};
            12'd264: token_char = (t_ct[0] == 4'd2) ? 8'd45 : 8'd43;   // '-' / '+'
            12'd265: token_char = 8'd48 + {4'd0, t_ct[1]};
            12'd266: token_char = 8'd46;                            // '.'
            12'd267: token_char = 8'd48 + {4'd0, t_ct[2]};
            12'd268: token_char = (t_gn[0] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_gn[0]});
            12'd269: token_char = 8'd48 + {4'd0, t_gn[1]};
            12'd272: token_char = (t_bow_sgn == 4'd2) ? 8'd45 : 8'd43;   // '-' / '+'
            12'd273: token_char = (t_bow_d2 == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_bow_d2});
            12'd274: token_char = 8'd48 + {4'd0, t_bow_d1};
            12'd276: token_char = (t_spd_d2 == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_spd_d2});
            12'd277: token_char = 8'd48 + {4'd0, t_spd_d1};
            12'd278: token_char = 8'd48 + {4'd0, t_spd_d0};
            12'd280: token_char = t_cont_on ? 8'd79 : 8'd45;   // 'O' / '-'
            12'd281: token_char = t_cont_on ? 8'd78 : 8'd45;   // 'N' / '-'
            12'd284: token_char = 8'd48 + {4'd0, t_pz_cnt};
            12'd285: token_char = 8'd47;                        // '/'
            12'd286: token_char = 8'd52;                        // '4'
            12'd288: token_char = (t_pk[1] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_pk[1]});
            12'd289: token_char = 8'd48 + {4'd0, t_pk[0]};
            12'd292: token_char = (t_rms[1] == 4'd0) ? 8'd32 : (8'd48 + {4'd0, t_rms[1]});
            12'd293: token_char = 8'd48 + {4'd0, t_rms[0]};
            12'd296: token_char = 8'd48 + {4'd0, t_cr[0]};
            12'd297: token_char = 8'd46;
            12'd298: token_char = 8'd48 + {4'd0, t_cr[1]};
            default: token_char = (tk < 12'd128) ? tk[7:0] : 8'd32;
        endcase
    end
endfunction
