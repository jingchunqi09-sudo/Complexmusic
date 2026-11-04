// ============================================================
// score_v2.cpp —— 曲谱整表下发实现
// ============================================================
#include "score_v2.h"
#include <LittleFS.h>

namespace scorev2 {

static const char* kDir = "/sc";
static const uint32_t kMagic = 0x53364B54;   // 'T','6','K','S'（小端写入）

uint16_t Score::chooseTickUs(uint32_t durMs) {
    uint32_t us = 1000;
    if (durMs > 0) {
        uint32_t need = (uint32_t)(((uint64_t)durMs * 1000ULL) / (uint64_t)kTickMax);
        if (need > us) us = need;
    }
    if (us > 65535) us = 65535;
    return (uint16_t)us;
}

void Score::begin() {
    if (!LittleFS.begin(true)) {
        Serial.println("[sc] LittleFS mount failed");
        return;
    }
    if (!LittleFS.exists(kDir)) LittleFS.mkdir(kDir);
    refreshSlots();
}

void Score::refreshSlots() {
    for (uint8_t i = 0; i < kSlots; ++i) {
        slots_[i] = SlotInfo();
        char path[32];
        snprintf(path, sizeof(path), "%s/s%u.bin", kDir, (unsigned)i);
        File f = LittleFS.open(path, "r");
        if (!f) continue;
        uint32_t magic = 0;
        uint16_t cnt = 0, tus = 0, crc = 0;
        char nm[kNameLen + 1] = {0};
        if (f.read((uint8_t*)&magic, 4) == 4 && magic == kMagic &&
            f.read((uint8_t*)&cnt, 2) == 2 &&
            f.read((uint8_t*)&tus, 2) == 2 &&
            f.read((uint8_t*)&crc, 2) == 2 &&
            f.read((uint8_t*)nm, kNameLen) == kNameLen) {
            nm[kNameLen] = 0;
            slots_[i].used = true;
            slots_[i].count = cnt;
            slots_[i].tickUs = tus;
            memcpy(slots_[i].name, nm, kNameLen + 1);
        }
        f.close();
    }
}

// ---------------- 上传 ----------------
void Score::uploadBegin(const char* name, uint32_t durMs) {
    upCount_ = 0;
    upDurMs_ = durMs;
    strncpy(upName_, name ? name : "untitled", kNameLen);
    upName_[kNameLen] = 0;
}

bool Score::uploadAdd(uint32_t tMs, uint8_t string, uint8_t note, uint8_t vel) {
    if (upCount_ >= kMaxEvents) return false;
    if (string > 7) return false;
    // 手机端给的是毫秒，这里先存 ms，commit 时按最终 tickUs 换算
    // （tickUs 依赖总时长，只有收完才知道）
    Event& e = events_[upCount_];
    // R33：曲谱只做"演奏指引"，FPGA 侧不再把它接到发声总线。
    // 事件类型统一用 PLUCK=0 表示"这里有一个音要演奏"，kind 只用于区分
    // 音与 STOP；不再补 BOW/STOP（那是自动播放时代的写法）。
    e.kind = linkv2::EV_PLUCK;
    e.lane = string;
    e.note = note & 0x7F;
    e.vel  = vel > 127 ? 127 : vel;
    // tick 字段暂时存 ms（<= 65535），commit 时整体换算
    e.tick = (uint16_t)(tMs > 65535 ? 65535 : tMs);
    upCount_++;
    if (tMs > upDurMs_) upDurMs_ = tMs;
    return true;
}

bool Score::uploadCommit(uint8_t slot) {
    if (upCount_ == 0 || slot >= kSlots) return false;

    uint16_t us = chooseTickUs(upDurMs_);
    // ms -> tick 换算。事件按时间非递减排列（手机端保证，这里不再排序）
    for (uint16_t i = 0; i < upCount_; ++i) {
        uint32_t ms = events_[i].tick;           // 暂存的是 ms
        uint32_t tk = (ms * 1000UL) / (uint32_t)us;
        events_[i].tick = (uint16_t)(tk > kTickMax ? kTickMax : tk);
    }

    count_  = upCount_;
    tickUs_ = us;
    durMs_  = upDurMs_;
    strncpy(name_, upName_, kNameLen);
    name_[kNameLen] = 0;

    // R33：不再补 STOP。曲谱只做指引，FPGA 侧不发声，也就不需要"停止发声"。
    // 目标框的清除由 FPGA 侧 score_state 回 0 完成（见 tang_mega_60k_top.v）。

    activeSlot_ = slot;
    return writeSlot(slot);
}

bool Score::writeSlot(uint8_t slot) {
    char path[32];
    snprintf(path, sizeof(path), "%s/s%u.bin", kDir, (unsigned)slot);
    File f = LittleFS.open(path, "w");
    if (!f) return false;
    uint32_t magic = kMagic;
    uint16_t crc = linkv2::crc16((const uint8_t*)events_, (size_t)count_ * sizeof(Event));
    f.write((const uint8_t*)&magic, 4);
    f.write((const uint8_t*)&count_, 2);
    f.write((const uint8_t*)&tickUs_, 2);
    f.write((const uint8_t*)&crc, 2);
    f.write((const uint8_t*)name_, kNameLen);
    f.write((const uint8_t*)events_, (size_t)count_ * sizeof(Event));
    f.close();
    refreshSlots();
    return true;
}

bool Score::readSlot(uint8_t slot) {
    char path[32];
    snprintf(path, sizeof(path), "%s/s%u.bin", kDir, (unsigned)slot);
    File f = LittleFS.open(path, "r");
    if (!f) return false;
    uint32_t magic = 0;
    uint16_t cnt = 0, tus = 0, crc = 0;
    char nm[kNameLen + 1] = {0};
    bool ok = f.read((uint8_t*)&magic, 4) == 4 && magic == kMagic &&
              f.read((uint8_t*)&cnt, 2) == 2 &&
              f.read((uint8_t*)&tus, 2) == 2 &&
              f.read((uint8_t*)&crc, 2) == 2 &&
              f.read((uint8_t*)nm, kNameLen) == kNameLen &&
              cnt <= kMaxEvents;
    if (ok) {
        nm[kNameLen] = 0;
        size_t want = (size_t)cnt * sizeof(Event);
        size_t got = f.read((uint8_t*)events_, want);
        ok = (got == want) &&
             linkv2::crc16((const uint8_t*)events_, want) == crc;
        if (ok) {
            count_  = cnt;
            tickUs_ = tus;
            memcpy(name_, nm, kNameLen + 1);
            durMs_  = (uint32_t)((uint64_t)cnt * 0);   // 由最后事件推
            if (cnt) durMs_ = (uint32_t)((uint32_t)events_[cnt - 1].tick * tus / 1000);
            activeSlot_ = slot;
        }
    }
    f.close();
    return ok;
}

bool Score::loadSlot(uint8_t slot) {
    if (slot >= kSlots) return false;
    return readSlot(slot);
}

bool Score::removeSlot(uint8_t slot) {
    if (slot >= kSlots) return false;
    char path[32];
    snprintf(path, sizeof(path), "%s/s%u.bin", kDir, (unsigned)slot);
    LittleFS.remove(path);
    if (activeSlot_ == slot) { count_ = 0; activeSlot_ = 0xFF; }
    refreshSlots();
    return true;
}

// ---------------- 下发 ----------------
bool Score::sendToFpga(linkv2::Link& link, uint16_t& sentEvents) {
    sentEvents = 0;
    if (count_ == 0 || count_ > kMaxEvents) return false;

    // 先停，避免旧曲目还在跑
    link.scoreCtrl(0);
    delay(3);

    if (!link.scoreBegin(count_, tickUs_)) return false;
    delay(2);

    const uint8_t* raw = (const uint8_t*)events_;
    uint16_t sent = 0;
    while (sent < count_) {
        uint16_t left = count_ - sent;
        uint8_t n = (left > linkv2::kEvPerFrame) ? linkv2::kEvPerFrame : (uint8_t)left;
        if (!link.scoreData(raw + (size_t)sent * sizeof(Event), n)) return false;
        sent += n;
        // 每 8 帧让 FPGA 追一次。230400 下 20 事件 = 130 字节 = 5.6 ms 传输，
        // 而 cmd_dispatch 逐帧处理要几个 µs，这里留 2 ms 是给 RX 缓冲兜底。
        if ((sent / linkv2::kEvPerFrame) % 8 == 7) delay(2);
    }

    uint16_t crc = linkv2::crc16(raw, (size_t)count_ * sizeof(Event));
    link.scoreEnd(crc);
    delay(2);
    link.scoreCtrl(1);          // 开始播放
    sentEvents = count_;
    return true;
}

}  // namespace scorev2
