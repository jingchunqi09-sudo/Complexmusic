// ============================================================
// score_v2.h —— 曲谱模型 + 整表下发（LINK v2）
//
// 与 v1（score.h）的根本区别：
//   v1 = ESP32 当序列器，按时间轴逐音下发 PLUCK/BOW，节奏精度等于 WiFi 抖动（数十 ms）
//   v2 = 整张表下发进 FPGA 的 8 KB score_store，由 50 MHz 计数器推进，
//        量化误差 20 ns。副作用是播放期间 UART 空闲，正好给录音回传。
//
// 容量：FPGA score_store 默认 4096 × 16 bit = 8 KB = 1365 个 6 字节事件
//       （src/tang_link_top.v 的 SCORE_WORD_DEPTH 参数）。
//       超过时要分段：SCORE_CTRL=0 停 → 重新 BEGIN/DATA → 再播放。
//       本轮实现单段；超过 1365 时直接拒绝并在手机上提示，不做隐式截断。
//
// tick 单位：tick_us 由 ESP32 按曲长自动选，保证 max(tick) <= 65000。
//   3 分钟的曲子 tick_us ≈ 2800（2.8 ms 分辨率），对 16 分音符足够。
// ============================================================
#pragma once

#include <Arduino.h>
#include "link_v2.h"

namespace scorev2 {

constexpr uint16_t kMaxEvents = 1365;
// R33 起不再需要预留 STOP 名额（曲谱只做指引、不发声），保留常量仅为兼容旧调用。
constexpr uint8_t  kSlots     = 4;
constexpr uint8_t  kNameLen   = 23;      // 不含结尾 0
constexpr uint16_t kTickMax   = 65000;   // LE16 留 535 的余量

// 与 FPGA score_store 逐字节对齐：kind, lane, note, vel, tick_le16
struct __attribute__((packed)) Event {
    uint8_t  kind;      // 0 PLUCK / 1 BOW / 2 STOP / 3 END
    uint8_t  lane;      // 0..7
    uint8_t  note;      // MIDI 0..127
    uint8_t  vel;       // 0..127
    uint16_t tick;      // LE16，单位 = tick_us
};

struct SlotInfo {
    bool     used = false;
    char     name[kNameLen + 1] = {0};
    uint16_t count = 0;
    uint16_t tickUs = 0;
};

class Score {
public:
    void begin();                       // 扫 LittleFS 重建槽位表

    // ---------------- 上传（手机 -> ESP32） ----------------
    // 手机端按 [t_ms, string, note, vel] 逐条发，这里转成 tick 并排队
    void     uploadBegin(const char* name, uint32_t durMs);
    bool     uploadAdd(uint32_t tMs, uint8_t string, uint8_t note, uint8_t vel);
    bool     uploadCommit(uint8_t slot);
    uint16_t uploadCount() const { return upCount_; }
    bool     uploadFull()  const { return upCount_ >= kMaxEvents; }

    // ---------------- 槽位 ----------------
    bool     loadSlot(uint8_t slot);
    bool     removeSlot(uint8_t slot);
    void     refreshSlots();
    const SlotInfo& slot(uint8_t i) const { return slots_[i]; }

    // ---------------- 下发到 FPGA ----------------
    // 返回 false 表示：未加载 / 事件数超容量 / 串口写失败。
    // sentEvents 回传实际下发的条数（供手机提示）。
    bool sendToFpga(linkv2::Link& link, uint16_t& sentEvents);

    // ---------------- 状态 ----------------
    bool     loaded()     const { return count_ > 0; }
    uint16_t count()      const { return count_; }
    uint16_t tickUs()     const { return tickUs_; }
    uint32_t durMs()      const { return durMs_; }
    const char* name()    const { return name_; }
    uint8_t  activeSlot() const { return activeSlot_; }

    static uint16_t chooseTickUs(uint32_t durMs);

private:
    bool readSlot(uint8_t slot);
    bool writeSlot(uint8_t slot);

    Event    events_[kMaxEvents];
    uint16_t count_    = 0;
    uint16_t tickUs_   = 1000;
    uint32_t durMs_    = 0;
    char     name_[kNameLen + 1] = {0};
    uint8_t  activeSlot_ = 0xFF;

    SlotInfo slots_[kSlots];

    // 上传暂存直接写进 events_，commit 时才落盘
    uint16_t upCount_ = 0;
    uint32_t upDurMs_ = 0;
    char     upName_[kNameLen + 1] = {0};
};

}  // namespace scorev2
