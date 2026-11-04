// ============================================================
// link_v2.cpp —— LINK v2 传输层实现（ESP32 侧）
//
// 解析器设计要点（照抄 LINK 模块 04_DOCS 的安全要求）：
//   1. 不完全信任 LEN：>120 直接丢，避免缓冲区越界；
//   2. CRC 错只丢当前帧，不影响后续帧；
//   3. 失步时逐字节滑动找 A5 5A，不整体清空（否则一个坏字节会吃掉整包）；
//   4. 所有发送都是"一次写满整帧"，不做分片，避免与录音回传抢串口。
//
// 与 FPGA 侧逐项对齐的常量见 link_v2.h 顶部注释。
// ============================================================
#include "link_v2.h"
#include "driver/gpio.h"     // gpio_pullup_en()：只改上拉寄存器，不动 UART 引脚功能

namespace linkv2 {

uint16_t crc16(const uint8_t* p, size_t n) {
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; ++i) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; ++b)
            c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

bool selfTest() {
    static const uint8_t kVec[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    return crc16(kVec, sizeof(kVec)) == 0x29B1;
}

void Link::begin(HardwareSerial& port) {
    port_ = &port;
    // setRxBufferSize() 必须在 begin() 之前调用：
    // Arduino-ESP32 是在 begin() 里创建 UART driver 并分配环形缓冲的，
    // begin() 之后再调会直接返回 false（静默失败），缓冲仍是默认 256 B。
    // 录音 56 B / 2.7 ms 时 256 B 只够 12 ms，一次 loop 卡顿就会丢字节。
    port_->setRxBufferSize(2048);
    port_->begin(kBaud, SERIAL_8N1, kPinRx, kPinTx);
    // RX 内部上拉：目的不是"电平正确"（FPGA 是推挽输出，拉不拉都能收到），
    // 而是让**线断了以后引脚保持稳定高电平**、不浮空拾取噪声 ——
    // 这样"rxBytes 完全不涨"才能确定是线断了，而不是分不清"没数据"和"全是噪声"。
    //
    // 位置很关键，两种写法都是错的：
    //   1) 写在 begin() 之前（pinMode）—— begin() 内部的 uart_set_pin() 会调
    //      gpio_set_direction(GPIO_MODE_INPUT)，把上拉清掉，等于没设；
    //   2) 写在 begin() 之后用 pinMode() —— gpio_config() 会把引脚切回 GPIO 功能，
    //      断开 UART 的 RX 路由，直接收不到数据。
    // 只有 gpio_pullup_en() 只动上拉寄存器、不动功能选择矩阵。
    gpio_pullup_en((gpio_num_t)kPinRx);
    port_->setRxTimeout(1);        // read() 最多等 1 个符号，别拖住主循环
    idx_ = 0;
    want_ = 0;
    inFrame_ = false;
}

bool Link::sendRaw(uint8_t cmd, const uint8_t* payload, uint8_t len) {
    if (port_ == nullptr) return false;
    if (len > kMaxPayload) return false;

    uint8_t f[kMaxFrame];
    f[0] = kSof0;
    f[1] = kSof1;
    f[2] = cmd;
    f[3] = seq_++;
    f[4] = len;
    for (uint8_t i = 0; i < len; ++i) f[5 + i] = payload[i];
    // CRC 覆盖 CMD..PAYLOAD 最后一个字节（不含两个 SOF）
    uint16_t c = crc16(&f[2], (size_t)len + 3);
    f[5 + len] = (uint8_t)(c & 0xFF);
    f[6 + len] = (uint8_t)(c >> 8);

    port_->write(f, (size_t)len + kOverhead);
    return true;
}

// ---------------- 参数 ----------------
bool Link::ping() { return sendRaw(CMD_PING, nullptr, 0); }

bool Link::setVolume(uint8_t vol) {
    uint8_t p[1] = {vol};
    return sendRaw(CMD_SET_VOLUME, p, 1);
}

bool Link::setTone(uint16_t warm, uint16_t bright, bool enable) {
    if (warm > kToneMax) warm = kToneMax;
    if (bright > kToneMax) bright = kToneMax;
    uint8_t p[5];
    p[0] = (uint8_t)(warm & 0xFF);
    p[1] = (uint8_t)((warm >> 8) & 0x0F);
    p[2] = (uint8_t)(bright & 0xFF);
    p[3] = (uint8_t)((bright >> 8) & 0x0F);
    p[4] = enable ? 0x01 : 0x00;
    return sendRaw(CMD_SET_TONE, p, 5);
}

bool Link::setTuning(uint8_t lane, uint8_t midi) {
    if (lane > 7) return false;
    uint8_t p[2] = {lane, (uint8_t)(midi & 0x7F)};
    return sendRaw(CMD_SET_TUNING, p, 2);
}

bool Link::setSens(uint8_t pluck, uint16_t deadband) {
    uint8_t p[3] = {pluck, (uint8_t)(deadband & 0xFF), (uint8_t)(deadband >> 8)};
    return sendRaw(CMD_SET_SENS, p, 3);
}

bool Link::setFx(uint8_t wet, uint8_t damping, uint8_t tail, bool bypass) {
    uint8_t p[4] = {wet, damping, tail, (uint8_t)(bypass ? 1 : 0)};
    return sendRaw(CMD_SET_FX, p, 4);
}

bool Link::setExpr(uint32_t vibDepth, uint32_t vibRate, uint32_t glideMs) {
    uint8_t p[12];
    for (int i = 0; i < 4; ++i) {
        p[i]      = (uint8_t)(vibDepth >> (8 * i));
        p[4 + i]  = (uint8_t)(vibRate  >> (8 * i));
        p[8 + i]  = (uint8_t)(glideMs  >> (8 * i));
    }
    return sendRaw(CMD_SET_EXPR, p, 12);
}

// SET_TIMBRE: p[0]=物理弦 0..3, p[1]=0 小提琴 / 1 尤克里里
// FPGA 侧据此把 lane_enable 的另一侧关掉：
//   timbre=0 -> 关 lane+4，timbre=1 -> 关 lane
bool Link::setTimbre(uint8_t string, uint8_t timbre) {
    if (string > 3) return false;
    uint8_t p[2] = {string, (uint8_t)(timbre ? 1 : 0)};
    return sendRaw(CMD_SET_TIMBRE, p, 2);
}

bool Link::writeReg(uint8_t addr, uint8_t value) {
    uint8_t p[2] = {addr, value};
    return sendRaw(CMD_REG_WRITE, p, 2);
}

bool Link::readReg(uint8_t addr) {
    uint8_t p[1] = {addr};
    return sendRaw(CMD_REG_READ, p, 1);
}

bool Link::queryStatus() { return sendRaw(CMD_QUERY_STATUS, nullptr, 0); }

// ---------------- 曲谱 ----------------
bool Link::scoreBegin(uint16_t count, uint16_t tickUs) {
    uint8_t p[4] = {(uint8_t)(count & 0xFF), (uint8_t)(count >> 8),
                    (uint8_t)(tickUs & 0xFF), (uint8_t)(tickUs >> 8)};
    return sendRaw(CMD_SCORE_BEGIN, p, 4);
}

bool Link::scoreData(const uint8_t* events, uint8_t nEvents) {
    if (nEvents == 0 || nEvents > kEvPerFrame) return false;
    return sendRaw(CMD_SCORE_DATA, events, (uint8_t)(nEvents * kEvBytes));
}

bool Link::scoreEnd(uint16_t crc) {
    uint8_t p[2] = {(uint8_t)(crc & 0xFF), (uint8_t)(crc >> 8)};
    return sendRaw(CMD_SCORE_END, p, 2);
}

bool Link::scoreCtrl(uint8_t ctrl) {
    uint8_t p[1] = {(uint8_t)(ctrl & 0x03)};
    return sendRaw(CMD_SCORE_CTRL, p, 1);
}

bool Link::scoreSeek(uint32_t tick) {
    uint8_t p[4] = {(uint8_t)(tick & 0xFF), (uint8_t)((tick >> 8) & 0xFF),
                    (uint8_t)((tick >> 16) & 0xFF), (uint8_t)((tick >> 24) & 0xFF)};
    return sendRaw(CMD_SCORE_SEEK, p, 4);
}

// ---------------- 录音 ----------------
bool Link::recCtrl(uint8_t ctrl) {
    uint8_t p[1] = {ctrl};
    return sendRaw(CMD_REC_CTRL, p, 1);
}

// ---------------- 解析 ----------------
void Link::parseStatus(const uint8_t* p) {
    status.uptimeMs   = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    status.scoreState = p[4];
    status.scorePos   = (uint16_t)p[5] | ((uint16_t)p[6] << 8);
    status.laneEnable = p[7];
    status.volume     = p[8];
    status.framesOk   = p[9];
    status.framesBad  = p[10];
    status.flags      = p[11];
    statusValid = true;
}

void Link::handleFrame(uint8_t cmd, const uint8_t* p, uint8_t n) {
    switch (cmd) {
    case CMD_ACK:
        // ★ ACK 只有 1 字节（状态码）。link_pkg.vh 的注释写成 2 字节是错的，
        //   以 cmd_dispatch.v:310 的 tx_send_len<=1 为准。
        if (n >= 1) { lastAckStat = p[0]; okCount++; }
        break;
    case CMD_NAK:
        if (n >= 1) { lastAckStat = p[0]; }
        nakCount++;
        break;
    case CMD_REG_VALUE:
        if (n >= 2) { regValueAddr = p[0]; regValueData = p[1]; haveRegValue = true; }
        break;
    case CMD_STATUS:
        if (n >= 12) parseStatus(p);
        break;
    case CMD_REC_AUDIO:
        if (recCb_ && n > 0) recCb_(p, n);
        break;
    case CMD_SCORE_PROGRESS:
        // 预留，当前 RTL 不发
        break;
    default:
        break;
    }
}

void Link::feed(uint8_t b) {
    rxBytes++;                       // 诊断用：先计数，再解析
    if (sniffLen < sizeof(sniff)) sniff[sniffLen++] = b;   // 抓包（前 96 字节）
    if (!inFrame_) {
        if (b == kSof0) { buf_[0] = b; idx_ = 1; inFrame_ = true; }
        return;
    }
    if (idx_ == 1) {
        if (b == kSof1) { buf_[idx_++] = b; sofCount++; }
        else if (b == kSof0) { /* 仍是候选帧头，留在 idx=1 */ }
        else inFrame_ = false;
        return;
    }

    if (idx_ < 5) {
        buf_[idx_++] = b;
        if (idx_ == 5) {
            uint8_t len = buf_[4];
            if (len > kMaxPayload) {          // 不可信的 LEN：整帧丢弃并重新同步
                lenBadCount++;
                inFrame_ = false; idx_ = 0;
                return;
            }
            want_ = (uint16_t)(len + kOverhead);
        }
        return;
    }

    buf_[idx_++] = b;
    if (want_ != 0 && idx_ >= want_) {
        uint8_t len = buf_[4];
        uint16_t got = (uint16_t)buf_[5 + len] | ((uint16_t)buf_[6 + len] << 8);
        uint16_t cal = crc16(&buf_[2], (size_t)len + 3);
        if (got == cal) handleFrame(buf_[2], &buf_[5], len);
        else            crcCount++;
        inFrame_ = false;
        idx_ = 0;
        want_ = 0;
    }
}

void Link::poll() {
    if (port_ == nullptr) return;
    // R40.3 修（真 bug，这是"上电收到几十字节、然后就彻底没数据"的原因）：
    // 原来是无上限的 while。只要线上有**持续**噪声（母头松/地线虚接/引脚悬空），
    // 每个毛刺都会被 UART 当成一个起始位，available() 就永远 > 0，
    // 这个 while 永远不返回 —— loop() 卡死在这里，连 QUERY_STATUS 都不再发，
    // 于是 FPGA 不再回话，看起来就是"开头有一点点数据，后面全没了"。
    // 限成每轮最多 128 字节：正常 5 Hz × 19 字节连 1 都不到，噪声也淹不死主循环。
    int budget = 128;
    while (budget-- > 0 && port_->available() > 0) feed((uint8_t)port_->read());
}

}  // namespace linkv2
