// ============================================================
// rec_player.h —— 录音回传：LADPCM 解码 + 环形缓冲 + WAV 打包
//
// 码流：FPGA 每帧发 REC_AUDIO（56 字节 LADPCM），230400 下 2.73 ms 一帧。
//       56 字节 = 112 个 4 bit code = 112 个样本。
//       2x 抽取后 24.414 kHz -> 12.2 KB/s，占链路 53%。
//
// 为什么不边录边推 WebSocket：
//   WebSocket 二进制帧 + WiFi 协议栈的开销会把 12.2 KB/s 放大到 30+ KB/s，
//   与 UART 抢占同一个 loop，录音期间界面会卡。所以"按需录一小段、HTTP 一次性下载"。
//
// 内存：默认 2 秒 @ 24.414 kHz × 16 bit = 97.7 KB，从堆分配。
//       分配失败时自动降到 1 秒（48.8 KB）；再失败就禁用录音但不影响其它功能。
// ============================================================
#pragma once

#include <Arduino.h>

namespace recplayer {

constexpr uint32_t kFullRate  = 48828;    // 48.828 kHz 源采样率
constexpr uint32_t kBaseRate  = 24414;    // 2x 抽取后的默认回传率
constexpr uint32_t kWantMs    = 2000;     // 目标录音时长
constexpr size_t   kWavHeader = 44;

class Player {
public:
    bool   begin();                       // 分配缓冲；返回 false = 录音不可用
    bool   available() const { return buf_ != nullptr; }

    void   start(uint8_t decim);          // decim: 0=1x 1=2x 2=4x 3=8x
    void   stop();
    bool   active() const { return active_; }

    // FPGA 回调入口：一帧 REC_AUDIO
    void   feed(const uint8_t* ladpcm, uint8_t n);

    // WAV（44 字节头 + PCM LE16 单声道）
    uint32_t sampleRate() const { return rate_; }
    uint32_t samples()    const { return count_; }
    uint32_t wavBytes()   const { return count_ ? count_ * 2 + kWavHeader : 0; }
    // 按偏移读取 WAV 数据（供 HTTP chunk 发送，避免一次性拷 100 KB）
    size_t   readWav(uint8_t* out, size_t maxLen, size_t offset) const;

private:
    int16_t* buf_   = nullptr;
    uint32_t cap_   = 0;        // 采样点容量
    uint32_t count_ = 0;        // 已写采样点
    uint32_t rate_  = kBaseRate;
    bool     active_ = false;
    bool     full_   = false;

    // 解码器状态（与 FPGA 侧 rec_ladpcm 严格自洽）
    int      idx_  = 0;
    int      pred_ = 0;
    uint8_t  half_ = 0;         // 0 = 上一个字节的低半字节还没用
    uint8_t  pend_ = 0;
};

}  // namespace recplayer
