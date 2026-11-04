// ============================================================
// link_v2.h —— FPGA <-> ESP32 链路协议 v2（与 src/link_pkg.vh 逐条对应）
//
// 唯一真源：FPGA 侧 src/link_pkg.vh + src/cmd_dispatch.v。
// 任何一侧改常量，两侧必须同步。
//
// 与 v1（fpga_protocol.h）不兼容：
//   v1 = 115200 / 固定 7 字节 / XOR 校验 / ESP32 逐音下发
//   v2 = 230400 / A5 5A + 变长 LEN / CRC16-CCITT / 整张曲谱下发 + FPGA 自己播放
//
// ---- 本轮从 RTL 逐行核对出来的三处事实（文档里写错或没写的）----
//   1. ACK 的 payload 是 **1 字节**（只有状态码），不是 link_pkg 注释里的 2 字节。
//      依据 cmd_dispatch.v:310  `tx_send_len <= ... 8'd1`。
//   2. STATUS 是 12 字节，布局见 cmd_dispatch.v:151-170 的 stat_byte()。
//   3. CMD_SCORE_END 在 cmd_dispatch 里没有分支（走 default 回 ACK），
//      也就是说 FPGA 不校验事件流 CRC，校验由 ESP32 自己做完再决定发不发。
// ============================================================
#pragma once

#include <Arduino.h>
#include <stdint.h>
#include <stddef.h>

namespace linkv2 {

// ---------------- 链路参数 ----------------
constexpr uint32_t kBaud      = 230400;   // 50 MHz / 217 = 230415，误差 -0.007%
constexpr int      kPinRx     = 16;       // ESP32 RX2 <- R5 33R <- FPGA E13
constexpr int      kPinTx     = 17;       // ESP32 TX2 -> R6 33R -> FPGA E14
constexpr uint8_t  kSof0      = 0xA5;
constexpr uint8_t  kSof1      = 0x5A;
constexpr uint8_t  kMaxPayload = 120;
constexpr size_t   kOverhead   = 7;       // SOF0 SOF1 CMD SEQ LEN CRCL CRCH
constexpr size_t   kMaxFrame   = kMaxPayload + kOverhead;

// ---------------- 上行命令（ESP32 -> FPGA） ----------------
enum Cmd : uint8_t {
    CMD_PING          = 0x01,
    CMD_SET_VOLUME    = 0x10,
    CMD_SET_TIMBRE    = 0x11,
    CMD_SET_TUNING    = 0x12,
    CMD_SET_SENS      = 0x13,
    CMD_SET_FX        = 0x14,
    CMD_SET_EXPR      = 0x15,
    CMD_SET_TONE      = 0x16,
    CMD_SCORE_BEGIN   = 0x20,
    CMD_SCORE_DATA    = 0x21,
    CMD_SCORE_END     = 0x22,
    CMD_SCORE_CTRL    = 0x23,
    CMD_SCORE_SEEK    = 0x24,
    CMD_REC_CTRL      = 0x30,
    CMD_REG_WRITE     = 0x3E,
    CMD_REG_READ      = 0x3F,
    CMD_QUERY_STATUS  = 0x40,
};

// ---------------- 下行命令（FPGA -> ESP32） ----------------
enum DownCmd : uint8_t {
    CMD_ACK        = 0x80,
    CMD_NAK        = 0x81,
    CMD_REG_VALUE  = 0x82,
    CMD_STATUS     = 0x90,
    CMD_REC_AUDIO  = 0xA0,
    CMD_SCORE_PROGRESS = 0xB0,
};

// ---------------- 寄存器地址（与 link_pkg.vh 一致） ----------------
enum Reg : uint8_t {
    REG_VOLUME      = 0x00,
    REG_FX_WET      = 0x01,
    REG_FX_DAMP     = 0x02,
    REG_FX_TAIL     = 0x03,
    REG_FX_BYPASS   = 0x04,
    REG_SENS_PLUCK  = 0x05,
    REG_BOW_DEADBAND= 0x06,
    REG_VIB_DEPTH   = 0x08,
    REG_VIB_RATE    = 0x0C,
    REG_GLIDE_MS    = 0x10,
    REG_AUTO_EXPR   = 0x14,
    REG_LANE_ENABLE = 0x15,
    REG_MUTE        = 0x16,
    REG_REC_CTRL    = 0x17,
    REG_TUNE_BASE   = 0x18,
    REG_SCORE_TICK_US = 0x20,
    REG_SCORE_COUNT = 0x22,
    REG_SCORE_CTRL  = 0x24,
    REG_SCORE_STATE = 0x25,
    REG_SCORE_POS   = 0x26,
    REG_LINK_CTRL   = 0x28,
    REG_LINK_STAT   = 0x29,
    REG_TONE_WARM   = 0x2A,   // +0x2B 高字节，12 位，2048 = 0 dB
    REG_TONE_BRIGHT = 0x2C,   // +0x2D 高字节
    REG_TONE_CTRL   = 0x2E,   // bit0 使能
    REG_TONE_CLIP   = 0x2F,   // 只读：软限幅动作计数低字节
    // R53：R52 的 REG_SEL_*(0x30..0x33) 已删除 —— 见 src/link_pkg.vh 的说明。
    // R60：复用同一段地址做"演奏指引直控 + 起音回传"（纯显示侧，不接发声链）
    REG_GUIDE_CTRL  = 0x30,   // bit0=1 直控使能（曲谱事件失效）  bit1=指引有效
    REG_GUIDE_LANE  = 0x31,   // 0..7（0-3 小提琴，4-7 尤克里里）
    REG_GUIDE_NOTE  = 0x32,   // MIDI，FPGA 用 note - 当前定弦 = 品格
    REG_PLUCK_CNT   = 0x33,   // 只读：起音计数，每检测到一次起音 +1
    REG_PLUCK_MASK  = 0x34,   // 只读：最近一次起音的弦 mask
};

// ---------------- 曲谱事件（6 字节） ----------------
enum EvKind : uint8_t { EV_PLUCK = 0, EV_BOW = 1, EV_STOP = 2, EV_END = 3 };
constexpr uint8_t kEvBytes     = 6;
constexpr uint8_t kEvPerFrame  = 20;      // 20*6 = 120 = kMaxPayload

// ---------------- STATUS（12 字节，字段顺序照抄 stat_byte()） ----------------
struct Status {
    uint32_t uptimeMs   = 0;
    uint8_t  scoreState = 0;    // 0 空闲 / 1 播放 / 2 暂停
    uint16_t scorePos   = 0;    // 当前 tick
    uint8_t  laneEnable = 0xFF;
    uint8_t  volume     = 128;
    uint8_t  framesOk   = 0;
    uint8_t  framesBad  = 0;
    uint8_t  flags      = 0;    // bit0 bypass bit1 mute bit2 recording bit3 baud_fast
};

// ---------------- 音色参数约定 ----------------
// 12 位，2048 = 0 dB，每 2048 步 = 6.02 dB（一个倍频程）。
// 模块内部对两个架做"峰值归一化补偿"：任何档位下输出峰值 <= 输入峰值，
// 所以**单旋钮转到底不会变响，只会变音色**（参考 tb_timbre_r20.txt）。
constexpr uint16_t kToneCenter = 2048;
constexpr uint16_t kToneMax    = 4095;
// R48：FPGA 侧量程从 +-9 dB 扩到 +-12 dB（timbre_shaper 里 s2 的系数 3/4 -> 1，
// 同时两个搁架拐架交叉：低架 1200 Hz 管"亮"、高架 300 Hz 管"暖"）。
// 两边必须同步，否则网页显示 9 dB、硬件实际给 12 dB。
// 2048/12 = 170.67，取 170（约 0.0059 dB/步）。满量程 100 -> 12 dB 落在 4088，
// 在 12 位 0..4095 之内，不会撞上限。
constexpr int      kToneStepDb = 2048 / 12;  // 170 步 / dB，满量程 +-12 dB

inline uint16_t dbToTone(float db) {
    float v = (float)kToneCenter + db * (float)kToneStepDb;
    if (v < 0) v = 0;
    if (v > kToneMax) v = kToneMax;
    return (uint16_t)(v + 0.5f);
}
inline float toneToDb(uint16_t p) {
    return ((float)p - (float)kToneCenter) / (float)kToneStepDb;
}
// 单旋钮"倾斜"映射：t = -100..+100（+ = 变亮）
inline void tiltToTone(int t, uint16_t& warm, uint16_t& bright) {
    if (t >  100) t =  100;
    if (t < -100) t = -100;
    float db = (float)t * 0.12f;            // 满量程 100 -> 12 dB（R48 从 9 提到 12）
    bright = dbToTone(+db);
    warm   = dbToTone(-db);
}

// ---------------- 传输层 ----------------
// 录音帧回调：收到一帧 REC_AUDIO（56 字节 LADPCM）时调用。
// 用裸函数指针而不是 std::function，省 RAM 也避免 <functional> 的模板膨胀。
typedef void (*RecCb)(const uint8_t* ladpcm, uint8_t n);

class Link {
public:
    void begin(HardwareSerial& port = Serial2);

    // 每 loop() 调一次：非阻塞收字节、推进解析
    void poll();

    // 组帧发送。返回 false 表示参数越界或串口忙。
    bool sendRaw(uint8_t cmd, const uint8_t* payload, uint8_t len);

    // ---------------- 参数 ----------------
    bool ping();
    bool setVolume(uint8_t vol);
    bool setTone(uint16_t warm, uint16_t bright, bool enable);
    bool setTuning(uint8_t lane, uint8_t midi);
    bool setSens(uint8_t pluck, uint16_t deadband);
    bool setFx(uint8_t wet, uint8_t damping, uint8_t tail, bool bypass);
    bool setExpr(uint32_t vibDepth, uint32_t vibRate, uint32_t glideMs);
    bool setTimbre(uint8_t string, uint8_t timbre);   // timbre: 0 小提琴 / 1 尤克里里
    bool writeReg(uint8_t addr, uint8_t value);
    bool readReg(uint8_t addr);
    bool queryStatus();

    // ---------------- 曲谱 ----------------
    bool scoreBegin(uint16_t count, uint16_t tickUs);
    bool scoreData(const uint8_t* events, uint8_t nEvents);
    bool scoreEnd(uint16_t crc);
    bool scoreCtrl(uint8_t ctrl);       // 0 停止 1 播放 2 暂停 3 回起点
    bool scoreSeek(uint32_t tick);

    // ---------------- 录音 ----------------
    bool recCtrl(uint8_t ctrl);         // bit0 使能 | bit3:1 抽取 | bit4 编码使能

    void setRecCallback(RecCb cb) { recCb_ = cb; }

    // ---------------- 结果 ----------------
    Status   status;
    bool     statusValid   = false;
    uint8_t  lastAckCmd    = 0;
    uint8_t  lastAckStat   = 0;
    uint32_t okCount = 0, nakCount = 0, crcCount = 0, timeoutCount = 0;
    // R40.2 诊断：把"收不到帧"拆成三段，用来区分是信号质量还是解析问题。
    //   rxBytes  —— 收到的原始字节数（不管对不对）
    //   sofCount —— 命中 A5 5A 帧头的次数（能命中说明字节基本对，只是会丢）
    //   lenBad   —— LEN 字段非法（>120）的次数（帧头对了但字节错位 → LEN 读出垃圾）
    uint32_t rxBytes = 0, sofCount = 0, lenBadCount = 0;
    // 上电后收到的前 96 个原始字节（用于 USB 串口抓包，判断是"错位"还是"噪声"）
    uint8_t  sniff[96] = {0};
    uint8_t  sniffLen  = 0;
    bool     sniffDone = false;
    bool     haveRegValue  = false;
    uint8_t  regValueAddr  = 0, regValueData = 0;

private:
    void feed(uint8_t b);
    void handleFrame(uint8_t cmd, const uint8_t* p, uint8_t n);
    void parseStatus(const uint8_t* p);

    HardwareSerial* port_ = nullptr;
    RecCb    recCb_ = nullptr;
    uint8_t  seq_ = 0;
    uint8_t  buf_[kMaxFrame];
    uint8_t  idx_ = 0;
    uint16_t want_ = 0;
    bool     inFrame_ = false;
};

// CRC16-CCITT-FALSE（poly 0x1021, init 0xFFFF），与 FPGA 侧 link_crc.v 一致
uint16_t crc16(const uint8_t* p, size_t n);

// 自检：向量 "123456789" 应得 0x29B1
bool selfTest();

}  // namespace linkv2
