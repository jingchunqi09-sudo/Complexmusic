//=============================================================================
// link_pkg.vh — Tang Mega 60K <-> ESP32 链路协议常量 (LINK v1)
//
// 本文件是协议唯一真源。ESP32 侧 esp32_link_protocol.h 必须与逐条对应。
// 依据：现有旧协议 archive/physical_20261025/legacy_uart_src/instrument_protocol.vh
//       采用 A5 帧头与 XOR 校验；本版因曲谱/录音数据量增大，升级为
//       A5 5A 双字节同步 + 长度 + CRC16，避免误同步。
//
// 时钟与波特率（50 MHz 主时钟，全部由整数分频得到）:
//   230400 bps : DIV = 217 -> 实际 230415 bps, 误差 -0.007%
//   921600 bps : DIV = 54  -> 实际 925926 bps, 误差 -0.47% (UART 容差内)
//=============================================================================
`ifndef LINK_PKG_VH
`define LINK_PKG_VH

`define LINK_CLK_HZ              50000000
`define LINK_UART_DIV_DEFAULT    217        // 230400 bps
`define LINK_UART_DIV_FAST       54         // ~921600 bps

// ---- 帧结构 ---------------------------------------------------------------
//  [0]      SOF0 = A5
//  [1]      SOF1 = 5A
//  [2]      CMD
//  [3]      SEQ   0..255 循环，用于丢帧检测（只做统计，不重传）
//  [4]      LEN   载荷字节数 0..120
//  [5..]    PAYLOAD
//  [5+LEN]  CRC16 low   (CRC16-CCITT-FALSE: poly 0x1021, init 0xFFFF)
//  [6+LEN]  CRC16 high  覆盖 CMD..PAYLOAD 最后一个字节
//  固定开销 7 字节
//
// LEN 上限从 252 降到 120 的原因（R17 基线重算，2026-11-01）：
//   主工程 BSRAM 已用 98/118，只剩 20 块。帧暂存按 256 字节要占 1 块，
//   降到 128 字节仍是 1 块但为将来合并两缓冲留出余地；
//   同时 SCORE_DATA 一帧可放 20 个事件（120/6），比原来的 7 个更省帧开销。
`define LINK_SOF0                8'hA5
`define LINK_SOF1                8'h5A
`define LINK_MAX_PAYLOAD         120
`define LINK_OVERHEAD            7

// ---- 上行命令 (ESP32 -> FPGA) ---------------------------------------------
`define CMD_PING                 8'h01
`define CMD_SET_VOLUME           8'h10   // p[0]=0..255, 128 = 0 dB
`define CMD_SET_TIMBRE           8'h11   // p[0]=lane 0..7, p[1]=0 violin / 1 uke
`define CMD_SET_TUNING           8'h12   // p[0]=lane, p[1]=MIDI
`define CMD_SET_SENS             8'h13   // p[0]=拨弦门限, p[1..2]=弓死区 LE16
`define CMD_SET_FX               8'h14   // p[0]=wet p[1]=damping p[2]=tail p[3]=bypass
`define CMD_SET_EXPR             8'h15   // p[0..3]=depth p[4..7]=rate p[8..11]=glide_ms
`define CMD_SET_TONE             8'h16   // p[0..1]=warm LE16 p[2..3]=bright LE16 p[4]=enable
`define CMD_SCORE_BEGIN          8'h20   // p[0..1]=事件数 LE16, p[2..3]=tick_us LE16
`define CMD_SCORE_DATA           8'h21   // p[]=N 个 6 字节事件 (N<=42)
`define CMD_SCORE_END            8'h22   // p[0..1]=事件流 CRC16 LE16
`define CMD_SCORE_CTRL           8'h23   // p[0]=0 停止 / 1 播放 / 2 暂停 / 3 回到起点
`define CMD_SCORE_SEEK           8'h24   // p[0..3]=目标 tick LE32
`define CMD_REC_CTRL             8'h30   // p[0]=bit0 使能 | bit1..2 抽取 | bit3 编码
`define CMD_REG_WRITE            8'h3E   // p[0]=addr, p[1]=value
`define CMD_REG_READ             8'h3F   // p[0]=addr -> 回 REG_VALUE
`define CMD_QUERY_STATUS         8'h40

// ---- 下行命令 (FPGA -> ESP32) ---------------------------------------------
`define CMD_ACK                  8'h80   // p[0]=原 CMD, p[1]=状态码
`define CMD_NAK                  8'h81   // p[0]=原 CMD, p[1]=错误码
`define CMD_REG_VALUE            8'h82   // p[0]=addr, p[1]=value
`define CMD_STATUS               8'h90   // 见 status_report.v
`define CMD_REC_AUDIO            8'hA0   // p[]=LADPCM 码流
`define CMD_SCORE_PROGRESS       8'hB0   // p[0..3]=当前 tick LE32

// ---- 应答状态码 -----------------------------------------------------------
`define LINK_OK                  8'h00
`define LINK_ERR_CRC             8'h01
`define LINK_ERR_LEN             8'h02
`define LINK_ERR_ARG             8'h03
`define LINK_ERR_STATE           8'h04
`define LINK_ERR_OVERFLOW        8'h05

// ---- 曲谱事件格式 (6 字节, 54 位) -----------------------------------------
//  b0    : kind  0=PLUCK 1=BOW 2=STOP 3=END
//  b1    : lane  0..7
//  b2    : note  0..127
//  b3    : vel   0..127
//  b4..b5: tick  LE16, 单位 = SCORE_BEGIN 的 tick_us
`define EV_PLUCK                 8'd0
`define EV_BOW                   8'd1
`define EV_STOP                  8'd2
`define EV_END                   8'd3
`define EV_BYTES                 6

// ---- 寄存器地址表 (与 CMD_REG_WRITE 通用) ---------------------------------
`define REG_VOLUME               8'h00
`define REG_FX_WET               8'h01
`define REG_FX_DAMP              8'h02
`define REG_FX_TAIL              8'h03
`define REG_FX_BYPASS            8'h04
`define REG_SENS_PLUCK           8'h05
`define REG_BOW_DEADBAND         8'h06   // +0x07 高字节
`define REG_VIB_DEPTH            8'h08   // +0x08..0x0B
`define REG_VIB_RATE             8'h0C
`define REG_GLIDE_MS             8'h10
`define REG_AUTO_EXPR            8'h14
`define REG_LANE_ENABLE          8'h15
`define REG_MUTE                 8'h16
`define REG_REC_CTRL             8'h17
`define REG_TUNE_BASE            8'h18   // 0x18..0x1F = lane0..7 的 MIDI
`define REG_SCORE_TICK_US        8'h20
`define REG_SCORE_COUNT          8'h22
`define REG_SCORE_CTRL           8'h24
`define REG_SCORE_STATE          8'h25   // 只读: 0 空闲 1 播放 2 暂停
`define REG_SCORE_POS            8'h26   // 只读 16 位当前 tick
`define REG_LINK_CTRL            8'h28
`define REG_LINK_STAT            8'h29   // 只读 错误计数低字节
`define REG_TONE_WARM            8'h2A   // +0x2B 高字节，12 位 0..4095，2048=0dB（低架 600Hz）
`define REG_TONE_BRIGHT          8'h2C   // +0x2D 高字节，12 位（高架 1800Hz）
`define REG_TONE_CTRL            8'h2E   // bit0 使能  bit1..3 预设号(0=手动)
`define REG_TONE_CLIP            8'h2F   // 只读 软限幅动作计数低字节
// R53：R52 的 REG_SEL_MODE/FORCE/THR/STAT(0x30..0x33) **已全部删除**。
//   原因见 docs/implementation/r53_20261103/README.md：
//   那套控制把 force mux 插进了 `selected_strings -> next_gates` 这条真正的
//   发声门控组合路径，并给 piezo_pick 加了扇出 —— 而本工程 hold 余量只有
//   43~45 ps，任何新增连线都会推动布局，实板表现为"S1 乱响不停"。
//   选弦手动控制要另立项（先争取时序余量）。
//
// R60：**复用 R53 删掉的同一段地址 0x30..0x33，做"演奏指引直控"。**
//   与 R52 的本质区别：R52 那套接的是 `selected_strings -> next_gates`（发声门控本身），
//   而这里接的是 `g_lane/g_note/g_valid` —— 它们只喂 `r9_stage_dashboard` 的
//   `i_guide_lane/i_guide_fret/i_guide_valid`，**没有任何发声侧消费者**。
//   所以这是"纯显示侧控制"，不改发声行为。
`define REG_GUIDE_CTRL           8'h30   // bit0 = ESP32 直控使能(1)/曲谱模式(0)  bit1 = 指引有效
`define REG_GUIDE_LANE           8'h31   // 0..7（0-3 小提琴，4-7 尤克里里）
`define REG_GUIDE_NOTE           8'h32   // MIDI 0..127，顶层用 note-tune 得品格
`define REG_PLUCK_CNT            8'h33   // **只读**：起音计数，每个 trigger_bus 非零拍 +1
`define REG_PLUCK_MASK           8'h34   // **只读**：最近一次起音的弦 mask（bit0=弦1 … bit7=尤4）
`define REG_MAX                  8'h35

`endif
