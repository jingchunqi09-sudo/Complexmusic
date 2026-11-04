// ============================================================
// encoder_panel.cpp —— 4 路 EC11 增量编码器解码
//
// 为什么不用中断：4 路 × 2 相 = 8 个边沿源，机械编码器抖动会让中断风暴
// 拖慢 WiFi（本工程主循环还要 5 Hz 轮询 FPGA + 20 Hz 推状态）。
// 1 ms 采样足够：手拧最快约 100 格/秒，一格 4 个象限 ≈ 2.5 ms/象限。
// ============================================================
#include "encoder_panel.h"

namespace encpanel {

// 引脚分配 —— 见头文件顶部的完整依据。这里只留一张表，不再有"二选一宏"。
//
// 3.5.9：按用户核对结果（= 网络名直接对应旋钮号），ENC4 的 A/B 按用户表为 33/32。
// A/B 只决定旋转方向；若实板方向反了，改 DELTA_SIGN 或对调该路 A/B。
const uint8_t kPins[kEncCount][3] = {
    { 18, 19, 34},   // ENC1 = 面板最左（音量/静音）  A=18(D18) B=19(D19) SW=34(D34)
    { 23, 25, 35},   // ENC2 = 音色/回中              A=23(D23) B=25(D25) SW=35(D35)
    { 26, 27, 36},   // ENC3 = 定弦/换弦              A=26(D26) B=27(D27) SW=36(VP)
    { 33, 32, 39},   // ENC4 = 面板最右（混响/旁路）  A=33(D33) B=32(D32) SW=39(VN)
};

// 自检脚表：两种接法的并集（就是这 12 个，只是分组不同）
const uint8_t kProbePins[kProbeCount] = {
    18, 19, 34,   23, 25, 35,   26, 27, 36,   33, 32, 39
};

// 上拉来源：
//   SW 四路（34/35/36/39）是纯输入、无内部上拉，靠转接板 R1..R4 上拉到 ESP_3V3 -> 用 INPUT；
//   A/B 八根是普通脚 -> 用 INPUT_PULLUP。
static inline void configPin(uint8_t p) {
    if (p >= 34) pinMode(p, INPUT);
    else         pinMode(p, INPUT_PULLUP);
}

// 顺时针如果实际是减，把这里改成 -1（只翻符号，不影响计数与去抖）
#define DELTA_SIGN (+1)

namespace {

TurnCb  cbTurn  = nullptr;
ClickCb cbClick = nullptr;
HoldCb  cbHold  = nullptr;      // 3.5.2：长按

// 正交解码表：索引 = (上一状态 << 2) | 当前状态，状态 = (A << 1) | B
// 只有 4 个有效转移给 ±1，其余（含"原地不动""两相同时跳"）一律 0 —— 抖动被自然吸收。
const int8_t kQdec[16] = {
     0, -1,  1,  0,
     1,  0,  0, -1,
    -1,  0,  0,  1,
     0,  1, -1,  0,
};

uint8_t  lastQ[kEncCount];
int8_t   acc[kEncCount];          // 累积象限，±4 算一格
uint8_t  swStable[kEncCount];
uint8_t  swLast[kEncCount];
uint32_t swChangeMs[kEncCount];
uint32_t pressMs[kEncCount];      // 3.5.2：稳定按下的时刻（算按住多久）
bool     holdFired[kEncCount];    // 3.5.2：本次按压已算长按，松手时不再发短按
bool     swArmed[kEncCount];      // 3.5.5：必须先见过一次"松开"才允许长按
uint32_t lastPollMs = 0;
uint32_t turns[kEncCount];
uint32_t clicks[kEncCount];

// 3.5.10 自检：每个脚的上一次电平 + 边沿累计
uint8_t  probeLast[kProbeCount];
uint16_t probeCnt[kProbeCount];

}  // namespace

void begin(TurnCb onTurn, ClickCb onClick, HoldCb onHold) {
    cbTurn  = onTurn;
    cbClick = onClick;
    cbHold  = onHold;

    for (uint8_t i = 0; i < kEncCount; ++i) {
        configPin(kPins[i][0]);
        configPin(kPins[i][1]);
        configPin(kPins[i][2]);

        uint8_t a = (uint8_t)digitalRead(kPins[i][0]);
        uint8_t b = (uint8_t)digitalRead(kPins[i][1]);
        lastQ[i]     = (uint8_t)((a << 1) | b);
        swStable[i]  = (uint8_t)digitalRead(kPins[i][2]);
        swLast[i]    = swStable[i];
        swChangeMs[i] = 0;
        acc[i]       = 0;
        turns[i]     = 0;
        clicks[i]    = 0;
        pressMs[i]   = millis();
        holdFired[i] = false;
        // 3.5.5：上电时如果这一路已经是低电平（SW 接错/常闭），**不武装长按**。
        //   否则 begin 之后 1.5 s 就会自己发一次"参数复位"，把音量/音色/定弦全刷回默认，
        //   表现就是"转了半天，参数总被拉回去"。
        swArmed[i]   = (swStable[i] != 0);
    }
    // 自检脚初始化（独立于 kPins，两种接法都覆盖）
    for (uint8_t i = 0; i < kProbeCount; ++i) {
        configPin(kProbePins[i]);
        probeLast[i] = (uint8_t)digitalRead(kProbePins[i]);
        probeCnt[i]  = 0;
    }

    lastPollMs = millis();
}

void poll() {
    uint32_t now = millis();
    if (now - lastPollMs < 1) return;      // 1 ms 节流
    lastPollMs = now;

    // 自检：12 个脚各统计一次电平变化（只读、不参与解码）
    for (uint8_t i = 0; i < kProbeCount; ++i) {
        uint8_t lv = (uint8_t)digitalRead(kProbePins[i]);
        if (lv != probeLast[i]) {
            probeLast[i] = lv;
            if (probeCnt[i] != 0xFFFF) probeCnt[i]++;
        }
    }

    for (uint8_t i = 0; i < kEncCount; ++i) {
        // ---------- 旋转 ----------
        uint8_t a = (uint8_t)digitalRead(kPins[i][0]);
        uint8_t b = (uint8_t)digitalRead(kPins[i][1]);
        uint8_t q = (uint8_t)((a << 1) | b);

        if (q != lastQ[i]) {
            int8_t d = kQdec[(lastQ[i] << 2) | q];
            lastQ[i] = q;
            if (d) {
                acc[i] = (int8_t)(acc[i] + d);
                if (acc[i] >= 4 || acc[i] <= -4) {
                    int8_t step = (int8_t)(acc[i] / 4);
                    acc[i] = (int8_t)(acc[i] % 4);       // 余数留到下一格，不丢细分
                    turns[i] += (uint32_t)(step > 0 ? step : -step);
                    if (cbTurn) cbTurn(i, (int8_t)(step * DELTA_SIGN));
                }
            }
        }

        // ---------- 按键（低电平 = 按下）----------
        uint8_t sw = (uint8_t)digitalRead(kPins[i][2]);
        if (sw != swLast[i]) {
            swLast[i] = sw;
            swChangeMs[i] = now;
        }
        if ((now - swChangeMs[i]) >= 20 && sw != swStable[i]) {
            swStable[i] = sw;
            if (sw == 0) {
                // ---- 按下沿：只记时刻，不发动作 ----
                // 动作要等"松手且没超阈值"才算短按，否则长按会先误触发一次。
                pressMs[i]   = now;
                holdFired[i] = false;
                swArmed[i]   = true;      // 真正按下了，这次可以武装长按
            } else {
                // ---- 松手沿：没升级成长按才发短按 ----
                if (!holdFired[i]) {
                    clicks[i]++;
                    if (cbClick) cbClick(i);
                }
                holdFired[i] = false;
            }
        }

        // ---- 按住不放：到阈值就升级为长按，一次按压只发一次 ----
        if (swArmed[i] && swStable[i] == 0 && !holdFired[i] &&
            (uint32_t)(now - pressMs[i]) >= (uint32_t)kHoldMs) {
            holdFired[i] = true;
            if (cbHold) cbHold(i);
        }
    }
}

uint32_t turnCount(uint8_t idx)  { return idx < kEncCount ? turns[idx] : 0; }
uint32_t clickCount(uint8_t idx) { return idx < kEncCount ? clicks[idx] : 0; }
uint8_t  swLevel(uint8_t idx)     { return idx < kEncCount ? swStable[idx] : 1; }

uint16_t probeEdges(uint8_t i)    { return i < kProbeCount ? probeCnt[i] : 0; }
void     probeReset()             { for (uint8_t i = 0; i < kProbeCount; ++i) probeCnt[i] = 0; }

}  // namespace encpanel
