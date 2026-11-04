// ============================================================
// rec_player.cpp
// ============================================================
#include "rec_player.h"
#include <esp_heap_caps.h>

namespace recplayer {

static inline int clamp16(int v) {
    return v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
}

bool Player::begin() {
    // 先试 2 秒，失败退 1 秒，再失败禁用
    const uint32_t tries[2] = {kWantMs, kWantMs / 2};
    for (int i = 0; i < 2; ++i) {
        uint32_t n = (kBaseRate * tries[i]) / 1000;
        buf_ = (int16_t*)heap_caps_malloc(n * sizeof(int16_t), MALLOC_CAP_SPIRAM);
        if (!buf_) buf_ = (int16_t*)malloc(n * sizeof(int16_t));
        if (buf_) { cap_ = n; break; }
    }
    if (!buf_) {
        Serial.println("[rec] buffer alloc failed, recording disabled");
        return false;
    }
    Serial.printf("[rec] buffer %u samples (%.1f s @ %u Hz)\n",
                  (unsigned)cap_, (double)cap_ / (double)kBaseRate, (unsigned)kBaseRate);
    return true;
}

void Player::start(uint8_t decim) {
    if (!buf_) return;
    // decim 0=1x 1=2x 2=4x 3=8x
    static const uint32_t div[4] = {1, 2, 4, 8};
    rate_ = kFullRate / div[decim & 3];
    count_ = 0;
    full_ = false;
    active_ = true;
    idx_ = 0;
    pred_ = 0;
    half_ = 0;
    pend_ = 0;
}

void Player::stop() { active_ = false; }

void Player::feed(const uint8_t* p, uint8_t n) {
    if (!active_ || !buf_) return;
    // R40 起 FPGA 侧用极简抽头 rec_tap_u8：只做抽取 + 8 位截断，不做 LADPCM。
    // 字节是偏移二进制（0x80 = 静音），翻掉符号位就是补码的高字节，
    // 直接左移 8 位还原成 16 位 PCM。比原来简单得多，也不会再有 predictor 失步。
    for (uint8_t i = 0; i < n; ++i) {
        int16_t s = (int16_t)((int8_t)(p[i] ^ 0x80)) << 8;
        if (count_ < cap_) buf_[count_++] = s;
        else { full_ = true; active_ = false; return; }
    }
}

size_t Player::readWav(uint8_t* out, size_t maxLen, size_t offset) const {
    size_t total = wavBytes();
    if (offset >= total || !maxLen) return 0;
    size_t n = total - offset;
    if (n > maxLen) n = maxLen;

    size_t wrote = 0;
    while (wrote < n) {
        size_t pos = offset + wrote;
        if (pos < kWavHeader) {
            // 现算 WAV 头（不常驻 44 字节，省一点 RAM）
            uint32_t dataBytes = count_ * 2;
            uint32_t byteRate  = rate_ * 2;
            uint8_t hdr[kWavHeader];
            memcpy(hdr + 0,  "RIFF", 4);
            uint32_t riff = 36 + dataBytes;      memcpy(hdr + 4,  &riff, 4);
            memcpy(hdr + 8,  "WAVEfmt ", 8);
            uint32_t fmt = 16;                   memcpy(hdr + 16, &fmt, 4);
            uint16_t pcm = 1, ch = 1, align = 2, bps = 16;
            memcpy(hdr + 20, &pcm, 2);  memcpy(hdr + 22, &ch, 2);
            memcpy(hdr + 24, &rate_, 4);memcpy(hdr + 28, &byteRate, 4);
            memcpy(hdr + 32, &align, 2);memcpy(hdr + 34, &bps, 2);
            memcpy(hdr + 36, "data", 4);memcpy(hdr + 40, &dataBytes, 4);

            size_t take = kWavHeader - pos;
            if (take > n - wrote) take = n - wrote;
            memcpy(out + wrote, hdr + pos, take);
            wrote += take;
        } else {
            size_t sIdx = (pos - kWavHeader) / 2;
            if (sIdx >= count_) break;
            // 逐字节拷贝（奇偶偏移都要支持，HTTP 分块可能落在半个样本上）
            const uint8_t* src = (const uint8_t*)&buf_[sIdx];
            size_t byteInSamp = (pos - kWavHeader) % 2;
            size_t take = 2 - byteInSamp;
            if (take > n - wrote) take = n - wrote;
            memcpy(out + wrote, src + byteInSamp, take);
            wrote += take;
        }
    }
    return wrote;
}

}  // namespace recplayer
