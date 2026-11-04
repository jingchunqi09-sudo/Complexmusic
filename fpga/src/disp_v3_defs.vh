//=============================================================================
// disp_v3_defs.vh —— 显示层 v3.1 常量与色表
//
// 与 01_设计稿/design_v3_1280x720.html 的 P{}/L{} 逐项对应；改一处必须改另一处。
// 本文件无 include guard，由各 module 在自己的作用域内展开。
// function 声明在 disp_v3_funcs.vh（必须在 module 内部 include）。
//=============================================================================

// ---- 面板矩形（右下开区间），上半 A/B/C 与 R16 的 r9_stage_dashboard 一致 ----
`define A_X0   20
`define A_Y0   64
`define A_X1   576
`define A_Y1   452
`define B_X0   584
`define B_Y0   64
`define B_X1   840
`define B_Y1   452
`define C_X0   848
`define C_Y0   64
`define C_X1   1260
`define C_Y1   452
`define D_X0   20        // SCORE
`define D_Y0   464
`define D_X1   452
`define D_Y1   704
`define E_X0   460       // WAVEFORM
`define E_Y0   464
`define E_X1   880
`define E_Y1   704
`define F_X0   888       // PARAMETERS（尤克里里 / 小提琴 双栏）
`define F_Y0   464
`define F_X1   1260
`define F_Y1   704
`define HDR_H  44

// ---- 调色板（v3.1：次级文字整体提亮，tx4 对比度从 2.2 提到 4.9）----
`define C_BG0      24'h0C1218
`define C_BG1      24'h06080C
`define C_PANEL    24'h111820
`define C_PANEL_B  24'h0A0F15
`define C_HDR_A    24'h1E2833
`define C_HDR_B    24'h111A22
`define C_WELL     24'h04070A
`define C_EDGE     24'h26323E
`define C_EDGE_HI  24'h42525F
`define C_EDGE_DIM 24'h131B22
`define C_TX       24'hF2F6FA
`define C_TX2      24'hC6D2DE
`define C_TX3      24'hA2AEBA
`define C_TX4      24'h7C8896
`define C_TEAL     24'h45D9C0
`define C_AMBER    24'hF0B44E
`define C_RED      24'hE06256
`define C_VIOLET   24'h8B7FD4
`define C_BLUE     24'h5AA8DA
`define C_S1       24'h5FD2EA
`define C_S2       24'hE8B85C
`define C_S3       24'h7FD49C
`define C_S4       24'hC8789F

// ---- 尤克里里琴颈 ----
`define NUT_X      112
`define FRET16_X   560
`define NECK_TOP   152
`define NECK_BOT   296
`define STR_Y0     173
`define STR_DY     34
`define NECK_MID_Y 224

// ---- 五线谱：1 diatonic = ST_HALF px；E4 落在最低线 ----
`define ST_X0    52
`define ST_X1    408
`define ST_YE4   604
`define ST_HALF  7
`define NOTE_X0  344     // 当前音横坐标
`define NOTE_DX  56      // 历史音间距

// ---- 波形：0 FS 线 = SC_GY + SC_GH/2 ----
`define SC_GX  514
`define SC_GY  514
`define SC_GW  350
`define SC_GH  132
`define SC_MID 580

// ---- 频谱条（PARAMETERS 下半部）----
`define SP_X   904
`define SP_Y   608
`define SP_W   336
`define SP_H   40

// ---- 参数栏两列 ----
`define PAR_AX 904
`define PAR_BX 1080
`define PAR_W  160
`define PAR_Y0 528
`define PAR_DY 16

// ---- 小提琴掩模 ----
`define VIO_X  584
`define VIO_Y  108
`define VIO_W  256
`define VIO_H  340
`define BOW_CX   (`VIO_X + `VIO_W / 2)   // 584+128 = 712，与原硬编码值相同
`define BOW_CY   (`VIO_Y + 192)          // 108+192 = 300，与原硬编码值相同
`define BOW_HALF 104
