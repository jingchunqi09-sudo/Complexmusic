// ============================================================
// main.cpp —— Tang Mega 60K 手机 WiFi 工作台（LINK v2，固件 3.5.8）
//
// 3.4.0：音色量程 +-9 dB -> +-12 dB（必须配 R48/R49 位流）
// 3.5.11：配合 R55 位流 —— 屏幕指引只剩尤克里里（左手品框 + 右手弦线），
//         小提琴不再显示指引。只改网页文案/选项文字，控制逻辑与协议零改动。
// 3.5.8：引脚映射真值表（U11 与 H9 网络整组反序 + U1 座位 → GPIO），
//        旧表 18/19/34 实际是"旋钮4 且 A/SW 互换"，所以转最右旋钮会静音。
// 3.5.5：修"音量旋钮没反应"—— 静音后 gVolTarget 被置 0，转音量从 0 起步（0→2 听不见）；
//        改成静音态下从 gVolBeforeMute 起步。另加 state.sw（4 路按键电平）做接线诊断，
//        驱动加 swArmed 防止 SW 常闭时上电自动触发参数复位。
// 3.5.4：state 新增 `tn`（8 条 lane 的定弦值）。3.5.3 只推了 tsel（当前弦号），
//        网页上的音高数字不会跟着旋钮动 —— 这是"转了没反应"的真正原因。
// 3.5.3：4 个编码器长按**都**触发参数复位（3.5.2 只有 ENC4）。
// 3.5.2：物理面板补完（**纯 ESP32，FPGA 不用重烧**）。
//        ENC3：旋 = 当前弦音高 ±1 半音，按 = 换下一根弦（琴1..琴4..尤1..尤4 轮转）。
//        ENC4：长按 1.5 s = 参数复位（音量/音色/定弦/混响回默认，不重启、不断 WiFi）。
//        驱动 encoder_panel 新增长按：短按回调改到**松手沿**，否则长按会先误触发短按。
// 3.5.1：R53 配套（= R51 行为）。保留 3.5.0 的**纯网页**改进：定弦扩到 8 弦并显示 Hz、
//        ±半音 / 标准音 / 8 弦一览、tune 的 MIDI 钳到 24..96。
//        **删掉 3.5.0 的选弦卡片与 sel/selstat 命令** —— 那套在 FPGA 侧把 force mux
//        插进了 selected_strings->next_gates 的发声门控路径，实板 S1 乱响，已回退。
//        只烧 3.5.1 + R53 位流；烧旧位流也安全（网页只是少一块）。
// 3.4.1：网页在「混响启用」时显示红色警示。原因：旁路状态由 ESP32 自己保持，
//        点过一次「启用混响」后重烧 FPGA 也不会清，很容易被误判成"音色坏了"。
//   改了两处：link_v2.h 的 kToneStepDb（2048/9）与 tiltToTone 的系数 0.09。
//   原因：R43 及以前 FPGA 侧 v=0.5*s，满量程只有 +-6 dB，而峰值归一化会把
//   "抬高架"的净增益全额补偿掉，所以"变亮"只剩低频被压 —— 听感不明显。
//   R44 把 s 的系数改成 0.75（+-9 dB），倾斜量 12 -> 18 dB。
//
// 3.3.7：接入 4 路 EC11 旋转编码器（无源操作面板）
//   面板来自 ProPrj_无源操作面板_2026-11-02.epro2：4 × EC11E15244G1，
//   12 根信号（ENC1_A/B/SW … ENC4_A/B/SW）全部另一端接地，面板本身无上拉、无电源，
//   所以上拉由 ESP32 内部提供，引脚也必须避开"无上拉的 GPIO34~39"。
//   驱动见 encoder_panel.h / .cpp，接线与功能见《旋转编码器接入说明.md》。
//   设计要点：旋钮和手机**共用同一套内部变量**，不另开一份状态；
//   pushState 增加 tilt/wet/damp/tail/bp 字段，网页滑块因此会跟着旋钮动。
//
// 3.3.6：修一个会误导判断的显示 bug，并加两个决定性指标（仍然只读）
//   1. 原来 sniff[] 初始化为 0 且无条件显示 → **一个字节都没收到时网页也显示
//      "00 00 00 00 00 00 00 00"**，看起来就像"收到全 0"。现在区分开：
//      没收到就显示"（一个字节都没收到）"，收到才显示字节并给出已采字节数。
//   2. 新增「RX 空闲电平」：直接 gpio_get_level(16)。UART 空闲必须是高，
//      恒为 0 就是被拉到了地（接错到 GND / 短地）。
//   3. 新增「收字节/秒」：线被恒定拉低时 UART 每个 10 位时隙判一次帧错并塞一个
//      0x00，速率≈230400/10≈23000/s；波特率不匹配时通常是几百~几千/s。
//      这个数字能一眼分开两种完全不同的故障。
//
// 3.3.5：网页直接显示收到的前 8 个原始字节（不接 USB 也能看到）。格式类似
//   "A5 5A 90 01 0C 00 00 00" = FPGA 真的在回合法帧头；
//   随机值/全 FF/全 00 = 噪声或线没接。这一行能一眼定性。
//
// 3.3.4：RX 引脚开内部上拉 + setRxTimeout(1)。上拉让线断了表现为 rxBytes 完全不涨
//   （而不是浮空拾取噪声），这样能一眼区分「线断」和「有噪声」。
//
// 3.3.3：给 poll() 的 while 加预算（防饿死主循环），并加 loop 心跳
//   症状：上电收到几十字节，然后彻底没数据。原因：线上有持续噪声时
//   available() 永远 > 0，poll() 的 while 永不返回，loop() 卡死，不再发 QUERY_STATUS。
//   现在每轮最多处理 128 字节。网页「loop 心跳」数字停止 = 主循环卡死。
//
// 3.3.2 相对 3.3.1：把「收不到有效帧」拆成三段诊断，仍然只加显示，不改控制逻辑
//   新增 sofCount（命中 A5 5A 的次数）、lenBadCount（LEN>120 的次数），
//   并把上电后前 96 个原始字节一次性打到 USB 串口。
//
// 3.3.1 相对 3.3.0：只加诊断显示，不改任何控制逻辑
//   「链路状态」卡新增「收字节」与「CRC错」两个计数（gLink.rxBytes 本次上电累计），
//   用来区分「ESP32 一个字节都没收到」（接线/引脚/波特率）与「收到了但解析失败」。
//
// 3.3.0 相对 3.2.0（配合 R40 位流）
// --------------------------------------------------------
//   1. 录音解码改成 8 位偏移二进制。R38/R39 的 LADPCM 版在实板上会让 S1/S2/S3 自鸣
//      （布局余量为零，250+ LUT 挤动了音频核）。R40 把 FPGA 侧抽头换成 12 FF 的
//      抽取+截断，代价是录音变成 12.2 kHz / 8 bit。
//   2. 抽取固定 4x（gRecDecim=2）。
//
// 3.2.0 相对 3.1.0 的改动（仍然只有固件，配合 R38 位流）
// --------------------------------------------------------
//   1. 录音真正可用：R38 位流开了 LINK_PCM_TAP=1，并修了 rec_stream 的读指针
//      预取 bug（原来每 56 字节帧的首字节重复、末字节丢失，会让 LADPCM 解码器
//      整体偏移 2 个样本）。网页提示从"当前位流没开通"改成按实测状态说话。
//   2. 录音期间调参提示：dispatch 与录音流共用一个发送缓冲，录音中拖动控件
//      有极小概率打断一帧。丢帧会让 LADPCM predictor 失步，所以录音时界面
//      直接把参数卡片置灰，避免用户自己撞上去（不改 RTL，零风险）。
//
// 3.1.0 相对 3.0.0 的改动（全部是固件侧，**不改位流**）
// --------------------------------------------------------
//   1. 曲谱 lane 直接用弦号 0..3，删掉按 timbre 映射到 4..7 的逻辑。
//      那个映射会让 GUIDE 页的目标框消失（i_guide_lane<4 不成立）。
//   2. 定弦写入的 lane 同样改为 0..3（同上，旧版会写进尤克里里那一组）。
//   3. 静音改走**音量**（vol=0 + 恢复），不再写 REG_MUTE —— 那个寄存器
//      在 R36 的 DAC 直连之后没有任何模块消费。
//   4. 音量加软斜坡（每 5 ms 一小步）：R36 的 DAC 音量是逐帧直算的，
//      一次跳几十级会有 click；斜坡放在 ESP32 侧，零风险。
//   5. 音色倾斜拖动时实时下发（60 ms 节流），旧版要松手才生效。
//   6. 录音看门狗：下发使能后 800 ms 无音频 → 提示"位流未开通录音"。
//   7. "换乐器"明确回报不支持（8 条物理弦综合时已固定 4 弓 + 4 拨）。
//
// 与 2.x 的根本区别
// ------------------
//   2.x：ESP32 当序列器，按时间轴逐音下发单音命令，节奏精度 = WiFi 抖动（数十 ms）。
//   3.x：整张曲谱一次性下发进 FPGA 的 8 KB score_store，由 50 MHz 计数器推进，
//        量化误差 20 ns。**曲谱只驱动屏幕指法框，不参与发声**（R33 起）。
//
// 控制路线（详见 docs/implementation/r38_20261102/控制路线.md）
// ------------------------------------------------------------
//   1 音量     CMD_SET_VOLUME        -> pt8211_tx 的 i_volume（R36 起）
//   2 音色     CMD_SET_TONE          -> timbre_shaper（低架 600 / 高架 1200 Hz）
//   3 定弦     CMD_SET_TUNING        -> performer_pitch_map
//   4 FX       CMD_SET_FX            -> instrument_bank_core 混响
//   5 表现     CMD_SET_EXPR          -> vib_depth / vib_rate / glide_ms
//   6 曲谱     SCORE_BEGIN/DATA/CTRL -> score_store + score_player -> **GUIDE 页**
//   7 录音     REC_CTRL + REC_AUDIO  -> rec_ladpcm + rec_stream（R38 起已接通）
// ============================================================
#include <WiFi.h>
#include <WebServer.h>
#include <WebSocketsServer.h>
#include <ArduinoJson.h>
#include <LittleFS.h>

#include "link_v2.h"
#include "score_v2.h"
#include "rec_player.h"
#include "encoder_panel.h"
#include "web_ui.h"

// ---------------- 可改配置 ----------------
static const char* kApSsid = "Tang60K-Music";
static const char* kApPass = "tang60k2026";   // WPA2 至少 8 位
static const char* kFwVer  = "3.5.13";

// ---- 旋转编码器灵敏度：每转一格（1 detent）改动多少 ----
// 3.5.13：用户要求"除音调外全部拉高 10 倍"。
//   音量  2 -> 20   （0..255，一格约 8%）
//   音色  2 -> 20   （-100..+100，一格 10%）
//   湿声  4 -> 40   （0..255，一格约 16%）
//   音调（ENC3 定弦/音高）保持 ±1 半音 —— 半音是最小音乐单位，×10 会没法用。
// 要单独调某一颗旋钮，只改这一张表，不用动 onEncTurn 里的算式。
static constexpr int kStepVolume = 20;
static constexpr int kStepTilt   = 20;
static constexpr int kStepTune   = 1;
static constexpr int kStepWet    = 40;


// ---------------- 全局对象 ----------------
static linkv2::Link       gLink;
static scorev2::Score     gScore;
static recplayer::Player  gRec;
static WebServer          gHttp(80);
static WebSocketsServer   gWs(81);

// ---------------- 参数镜像（供界面回显；真值在 FPGA 里） ----------------
static uint8_t  gVolume   = 128;              // 128 = 0 dB
static int      gTilt     = 0;                // -100..+100
static uint8_t  gTune[8]  = {55, 62, 69, 76, 67, 60, 64, 69};
// R60：固定曲谱指引的控制入口（实现见 loop() 之前那段）。
// 这里只放原型与状态 —— WebSocket 分发和 pushState 都在本文件靠前处，
// 早于实现，所以状态必须在这里声明。
static void guideCommand(const char* a, int v);

struct GuideStep { uint8_t str; uint8_t fret; };   // str = 1..4（人话：第一弦 = 1）

// 用户给定的固定乐谱（17 步）
static const GuideStep kGuideSeq[17] = {
    {2,0},{4,0},{1,5},{4,0},{3,0},{3,2},{2,0},{1,5},{4,0},
    {4,0},{3,2},{1,5},{4,0},{4,0},{1,5},{2,2},{1,5}
};
static const uint8_t kGuideSteps = 17;

static bool     gGuideOn     = false;   // 是否在指引模式
static bool     gGuideAuto   = true;    // true = 弹完目标弦自动推进
static uint8_t  gGuideIdx    = 0;       // 当前步（0 基）
static uint8_t  gGuideCnt    = 0;       // 上次看到的起音计数
static bool     gGuideCntOk  = false;
static uint8_t  gGuidePoll   = 0;       // 0 空闲 / 1 等 CNT / 2 等 MASK
static uint32_t gGuideNextMs = 0;
// R53：R52 的选弦控制（gSelManual/gSelForce/gSelThr/gSelStat）已全部删除。
//   那套东西在 FPGA 侧把 force mux 插进了发声门控路径，实板 S1 乱响，已回退。

// 3.5.2：物理旋钮 ENC3 用来调"当前这根弦"的音高，这里是它的游标。
//   0..3 = 小提琴 1~4 弦，4..7 = 尤克里里 1~4 弦。
//   和网页的 st.sel 是同一个概念；网页会通过 state 里的 tsel 跟随它。
//   **只改 ESP32 侧数值 + 走已有的 SET_TUNE 命令**，不动任何 FPGA 逻辑。
static uint8_t  gTuneSel = 0;
static uint8_t  gWet = 64, gDamp = 128, gTail = 1, gBypass = 1;
static uint8_t  gSens = 0;
static uint16_t gDead = 0;
static uint8_t  gRecDecim = 2;                // 0=1x 1=2x 2=4x 3=8x；R40 起固定 4x（12.2 kSPS/8bit）
static bool     gRecOn = false;

// ---- 音量软斜坡（R37） ----
// 为什么要做：FPGA 侧的音量是「逐帧直算、无斜坡」（见 R36 README §7.3），
// 目标值一次跳很多级会有一声 click。这里在 ESP32 侧按小步逼近，
// 纯固件改动、不碰位流，也不影响演奏。
static uint8_t  gVolTarget = 128;             // 目标（用户拖到的位置）
static uint8_t  gVolCur    = 128;             // 已下发到 FPGA 的值
static uint32_t gVolStepMs = 0;
static uint8_t  gVolBeforeMute = 128;
static bool     gMuted = false;

// ---- 音色倾斜节流（拖动时实时发，但限制频率） ----
static int      gTonePending = 0;
static bool     gToneDirty   = false;
static uint32_t gToneLastMs  = 0;

// ---- 音色寄存器回读（3.4.0 新增） ----
// 用户反馈"调音色听不出来"时，要先分清是"参数没到 FPGA"还是"到了但差别太小"。
// 这里定期用 CMD_REG_READ 读回 0x2A(warm)/0x2C(bright)，网页上和滑杆并排显示。
// 回读值与滑杆一致 -> 链路没问题，问题在听感；不一致 -> 帧没到，去查串口。
static uint8_t  gToneRb[4]  = {0xFF, 0xFF, 0xFF, 0xFF};  // 0x2A..0x2D，0xFF = 未读到
static uint8_t  gToneRbIdx  = 0;      // 轮询下标 0..3
static uint32_t gToneRbMs   = 0;

// ---- 录音看门狗：下发 recCtrl(1) 后若一直没有音频回来，说明位流没开通录音 ----
static uint32_t gRecStartMs = 0;
static uint32_t gRecBytesAtStart = 0;

static uint32_t gLastStatusMs = 0;
// R40.3 诊断：loop() 心跳。如果这个数在网页上停住，说明主循环卡死了
// （而不是"线路没数据"）。这是区分两种故障最直接的一个指标。
static uint32_t gLoopCount = 0;
// R40.4 诊断：收字节速率 + RX 空闲电平。
//   gRxBps —— 每秒收到多少字节。
//     线被恒定拉低时，UART 每个 10 位时隙都判一次帧错并塞一个 0x00，
//     所以速率会接近 230400/10 ≈ 23040 /s。这个数字能一眼把
//     「线被拉低（≈23000/s）」和「波特率不匹配（几百~几千/s）」分开。
//   gRxLevel —— 直接读 GPIO16 的电平（gpio_get_level 走输入寄存器，
//     即使引脚被路由给 UART 外设也能读到真实电平）。
//     UART 空闲必须为高；恒为 0 就是被拉到地了。
static uint32_t gRxBps    = 0;
static uint32_t gRxPrev   = 0;
static uint32_t gRxPrevMs = 0;
static uint8_t  gRxLevel  = 1;
static uint32_t gLastPushMs   = 0;
static uint32_t gStatusPeriod = 200;          // 5 Hz 轮询 FPGA

// ---------------- 工具 ----------------
static void sendJson(uint8_t client, const char* s) { gWs.sendTXT(client, s); }

static void ackTo(uint8_t client, const char* cmd, bool ok, const char* msg = "") {
    char b[160];
    snprintf(b, sizeof(b), "{\"t\":\"ack\",\"c\":\"%s\",\"ok\":%s,\"m\":\"%s\"}",
             cmd, ok ? "true" : "false", msg);
    sendJson(client, b);
}

// 录音帧回调：FPGA -> LADPCM 解码 -> 环形缓冲
static void onRecAudio(const uint8_t* p, uint8_t n) { gRec.feed(p, n); }

// ---------------- 命令处理 ----------------
static void applyTone(int tilt) {
    gTilt = tilt < -100 ? -100 : (tilt > 100 ? 100 : tilt);
    uint16_t warm, bright;
    linkv2::tiltToTone(gTilt, warm, bright);
    gLink.setTone(warm, bright, true);
}

// 把音量目标值写进斜坡；实际下发由 loop() 逐步推进
static void setVolumeTarget(uint8_t v) {
    gVolTarget = v;
    gVolume    = v;
}

// ---------------- 物理旋钮（4 × EC11 无源面板） ----------------
// 设计原则：旋钮和手机**共用同一套内部变量**，不另开一份状态。
// 这样无论从哪边改，另一边下一次读取/推送看到的都是同一个值，
// 不会出现"旋钮转过了、手机还显示旧值"的分叉。
//
// 功能分配（3.5.3 起；可按需要改这里，不用碰驱动）：
//   ENC1 旋 = 音量            按 = 静音 / 取消静音        长按 = 参数复位
//   ENC2 旋 = 音色倾斜         按 = 倾斜回中（0 dB）        长按 = 参数复位
//   ENC3 旋 = **当前弦音高** ±1 半音   按 = **换下一根弦**   长按 = 参数复位
//   ENC4 旋 = 混响湿声         按 = 混响旁路开关           长按 = 参数复位
//
// **4 个编码器长按都是参数复位**（3.5.3：用户要求 ENC1/2/3 也要能复位）。
// 只改参数、不重启 ESP32，所以 WiFi 和网页连接都不会断。
// 阈值 1.5 s 在 encoder_panel.h 的 kHoldMs；想只留某一个复位，
// 把 onEncHold 里的 idx 判断加回去即可。
// ---------------- 参数复位（长按 ENC4 触发） ----------------
// 只把"演奏参数"恢复成上电默认值，并立即重发给 FPGA。
// **不重启 ESP32**：WiFi、网页连接、曲谱进度都不受影响。
// 默认值与 link_regs.v 的复位值逐条一致（0x37/0x3E/0x45/0x4C/0x43/0x3C/0x40/0x45）。
static void doParamReset() {
    static const uint8_t kDefTune[8] = {55, 62, 69, 76, 67, 60, 64, 69};

    gMuted = false;
    setVolumeTarget(128);                       // 0 dB

    gTilt = 0;                                  // 音色回中
    gTonePending = 0;
    gToneDirty   = true;                        // 由 loop() 节流下发

    for (uint8_t i = 0; i < 8; ++i) {           // 定弦回标准音
        gTune[i] = kDefTune[i];
        gLink.setTuning(i, gTune[i]);
    }
    gTuneSel = 0;

    gWet = 64; gDamp = 128; gTail = 1; gBypass = 1;   // 混响回旁路（干声）
    gLink.setFx(gWet, gDamp, gTail, true);

    Serial.println("[enc] PARAM RESET -> vol=128 tilt=0 tune=std fx=bypass");
}

static void onEncTurn(uint8_t idx, int8_t d) {
    switch (idx) {
    case 0: {                                   // 音量，每格 kStepVolume（3.5.13：20）
        // **3.5.5 修的真 bug**：静音时 setVolumeTarget(0) 会把 gVolTarget 也置 0，
        // 于是静音之后再转音量，是从 0 开始涨（0→2→4…），这个量级根本听不见，
        // 表现就是"音量旋钮转了没反应"。
        // 正确做法：静音态下从"静音前的值"起步，一转就回到原来那个响度附近。
        int base = gMuted ? (int)gVolBeforeMute : (int)gVolTarget;
        int v = base + (int)d * kStepVolume;
        if (v < 0) v = 0; else if (v > 255) v = 255;
        // 只在"从静音恢复"的那一次打印。正常转动不打印 ——
        // 每格一行在 115200 下要 2.6 ms，转快了会拖慢主循环。
        if (gMuted) Serial.printf("[enc] vol resume from %d -> %d\n", base, v);
        gMuted = false;                         // 与网页滑块一致：一动音量就解除静音
        setVolumeTarget((uint8_t)v);
        break;
    }
    case 1: {                                   // 音色倾斜，每格 kStepTilt（3.5.13：20）
        int t = gTilt + (int)d * kStepTilt;
        if (t < -100) t = -100; else if (t > 100) t = 100;
        gTilt = t;
        gTonePending = t;                       // 交给 loop() 节流下发
        gToneDirty   = true;
        break;
    }
    case 2: {                                   // 当前弦音高，每格 kStepTune（音调：保持 1 半音）
        // 走已有的 SET_TUNE 命令（0x10..0x17 字节），FPGA 侧一个字都没改。
        int n = (int)gTune[gTuneSel] + (int)d * kStepTune;
        if (n < 24) n = 24; else if (n > 96) n = 96;   // G1..C7
        gTune[gTuneSel] = (uint8_t)n;
        gLink.setTuning(gTuneSel, (uint8_t)n);
        break;
    }
    default: {                                  // 混响湿声，每格 kStepWet（3.5.13：40）
        // 3.5.2：湿声从原 ENC3 搬到 ENC4（ENC3 让给了定弦）。
        // 阻尼（gDamp）保留网页可调，值为 128 时是中性。
        int w = (int)gWet + (int)d * kStepWet;
        if (w < 0) w = 0; else if (w > 255) w = 255;
        gWet = (uint8_t)w;
        gLink.setFx(gWet, gDamp, gTail, gBypass != 0);
        break;
    }
    }
}

static void onEncClick(uint8_t idx) {
    switch (idx) {
    case 0:                                     // 静音切换（走音量，理由见 handleCommand）
        if (gMuted) { gMuted = false; setVolumeTarget(gVolBeforeMute); }
        else        { gVolBeforeMute = gVolume; gMuted = true; setVolumeTarget(0); }
        break;
    case 1:                                     // 音色回中
        gTilt = 0; gTonePending = 0; gToneDirty = true;
        break;
    case 2:                                     // 换下一根弦（8 根轮转）
        gTuneSel = (uint8_t)((gTuneSel + 1) & 7);
        // 串口提示当前是哪根；网页那侧靠 state 的 tsel 跟随（见 pushState）
        Serial.printf("[enc] tune sel = %u  (%s%u)  MIDI %u\n",
                      gTuneSel,
                      gTuneSel < 4 ? "violin" : "uke",
                      (uint8_t)((gTuneSel & 3) + 1),
                      gTune[gTuneSel]);
        break;
    default:                                    // 混响旁路 开/关
        // 3.5.2：从原 ENC3 搬过来。切到"干声"时网页会显示红字提醒（3.4.1 起）。
        gBypass = gBypass ? 0 : 1;
        gLink.setFx(gWet, gDamp, gTail, gBypass != 0);
        Serial.printf("[enc] reverb %s\n", gBypass ? "BYPASS(dry)" : "ON");
        break;
    }
}

// 长按（3.5.3）：**4 个编码器都触发参数复位**。
//   用户原话："ENC1/ENC2/ENC3 这几个也需要复位键"。
//   误触风险由 1.5 s 阈值兜底 —— 正常拧旋钮不会按住不动 1.5 秒。
static void onEncHold(uint8_t idx) {
    Serial.printf("[enc] long-press ENC%u -> param reset\n", (unsigned)(idx + 1));
    doParamReset();
}

static void handleCommand(const char* payload, size_t len, uint8_t client) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, payload, len);
    if (err) { ackTo(client, "json", false, err.c_str()); return; }

    const char* c = doc["c"] | "";
    if (!strcmp(c, "ping")) {
        gLink.ping();
        ackTo(client, c, true);
    } else if (!strcmp(c, "vol")) {
        uint8_t v = (uint8_t)(doc["v"] | 128);
        // 拖动音量 = 明确想要声音，自动解除静音（UI 侧同步把按钮改回"静音"）。
        // 这样就不存在"静音时拖了滑块、取消静音又跳回旧值"的歧义。
        gMuted = false;
        setVolumeTarget(v);
        ackTo(client, c, true);
    } else if (!strcmp(c, "guide")) {
        // R60：固定曲谱指引（开始/停止/上一步/下一步/自动开关/回到第一步）
        guideCommand(doc["a"] | "", doc["v"] | 1);
        ackTo(client, c, true);
    } else if (!strcmp(c, "tone")) {
        // 只记目标，真正下发由 loop() 节流执行（拖动时每 60 ms 一帧）
        int t = doc["t"] | 0;
        gTilt = t < -100 ? -100 : (t > 100 ? 100 : t);
        gTonePending = gTilt;
        gToneDirty   = true;
        ackTo(client, c, true);
    } else if (!strcmp(c, "mute")) {
        // R37：静音改走**音量**，不再写 REG_MUTE。
        // 原因：REG_MUTE(0x16) 在 FPGA 里只影响录音抽头，
        // R36 的 DAC 直连 pcm 之后它完全不生效（见控制路线表）。
        bool on = (doc["v"] | 0) != 0;
        if (on && !gMuted)      { gVolBeforeMute = gVolume; gMuted = true;  setVolumeTarget(0); }
        else if (!on && gMuted) { gMuted = false; setVolumeTarget(gVolBeforeMute); }
        ackTo(client, c, true, gMuted ? "muted" : "unmuted");
    } else if (!strcmp(c, "timbre")) {
        // R33 起曲谱只做"演奏指引"，FPGA 侧也没有"换乐器"通路：
        // instrument_bank_core 的 8 条物理弦在综合时就固定成 4 弓弦 + 4 拨弦，
        // lane_enable(0x15) 没有任何模块消费。这里如实回报，不再静默成功。
        ackTo(client, c, false, "not supported: 8 strings are fixed 4 bowed + 4 plucked");
    } else if (!strcmp(c, "tune")) {
        uint8_t l = (uint8_t)(doc["l"] | 0);
        uint8_t n = (uint8_t)(doc["n"] | 60);
        if (l > 7) { ackTo(client, c, false, "lane 0..7"); return; }
        // R52：限幅到 24..96（G1~C7）。不拒绝而是钳位 —— 旧固件/旧网页发 0 时
        // 也不会把某根弦变成 8 Hz（performer_pitch_map 只在"全 0"时才回退默认）。
        if (n < 24) n = 24;
        if (n > 96) n = 96;
        gTune[l] = n;
        gLink.setTuning(l, n);
        ackTo(client, c, true);
    } else if (!strcmp(c, "fx")) {
        if (doc["wet"].is<int>())  gWet    = (uint8_t)(doc["wet"]  | 64);
        if (doc["damp"].is<int>()) gDamp   = (uint8_t)(doc["damp"] | 128);
        if (doc["tail"].is<int>()) gTail   = (uint8_t)(doc["tail"] | 1);
        if (doc["bp"].is<int>())   gBypass = (uint8_t)(doc["bp"]   | 1);
        gLink.setFx(gWet, gDamp, gTail, gBypass != 0);
        ackTo(client, c, true);
    } else if (!strcmp(c, "sens")) {
        if (doc["pluck"].is<int>()) gSens = (uint8_t)(doc["pluck"] | 0);
        if (doc["db"].is<int>())    gDead = (uint16_t)(doc["db"]   | 0);
        gLink.setSens(gSens, gDead);
        // 寄存器存在但当前没有检测链消费它，如实说明
        ackTo(client, c, true, "reserved: stored but not yet used by detectors");
    } else if (!strcmp(c, "expr")) {
        uint32_t d = doc["depth"] | 0;
        uint32_t r = doc["rate"]  | 0x30303030;
        uint32_t g = doc["glide"] | 0;
        gLink.setExpr(d, r, g);
        ackTo(client, c, true);
    }
    // ---------------- 曲谱上传 ----------------
    else if (!strcmp(c, "sbegin")) {
        const char* name = doc["name"] | "untitled";
        uint32_t dur = doc["dur"] | 0;
        gScore.uploadBegin(name, dur);
        ackTo(client, c, true);
    } else if (!strcmp(c, "sbatch")) {
        // {"c":"sbatch","e":[[t_ms,string,note,vel],...]}
        JsonArray arr = doc["e"].as<JsonArray>();
        uint16_t n = 0;
        for (JsonVariant v : arr) {
            uint32_t t  = v[0] | 0;
            uint8_t  s  = (uint8_t)(v[1] | 0);
            uint8_t  nn = (uint8_t)(v[2] | 60);
            uint8_t  vv = (uint8_t)(v[3] | 100);
            // R37：曲谱只做"演奏指引"，lane 直接用弦号 0..3。
            // 以前这里按 gTimbre[] 映射到 lane 4..7（换乐器时代留下的），
            // 一旦界面点过"尤克里里"，GUIDE 页的 i_guide_lane<4 判断不成立，
            // 目标框会直接消失 —— 这是个真 bug，已删。
            if (gScore.uploadAdd(t, s, nn, vv)) n++;
            else break;
        }
        char b[96];
        snprintf(b, sizeof(b), "{\"t\":\"sbatch\",\"n\":%u,\"total\":%u,\"full\":%s}",
                 (unsigned)n, (unsigned)gScore.uploadCount(),
                 gScore.uploadFull() ? "true" : "false");
        sendJson(client, b);
    } else if (!strcmp(c, "scommit")) {
        uint8_t slot = (uint8_t)(doc["slot"] | 0);
        bool ok = gScore.uploadCommit(slot);
        ackTo(client, c, ok, ok ? "" : "empty or fs error");
    } else if (!strcmp(c, "splay")) {
        if (!gScore.loaded()) { ackTo(client, c, false, "no score loaded"); return; }
        uint16_t sent = 0;
        bool ok = gScore.sendToFpga(gLink, sent);
        char b[128];
        snprintf(b, sizeof(b),
                 "{\"t\":\"ack\",\"c\":\"splay\",\"ok\":%s,\"n\":%u,\"tick_us\":%u,\"m\":\"\"}",
                 ok ? "true" : "false", (unsigned)sent, (unsigned)gScore.tickUs());
        sendJson(client, b);
    } else if (!strcmp(c, "sctrl")) {
        gLink.scoreCtrl((uint8_t)(doc["v"] | 0));
        ackTo(client, c, true);
    } else if (!strcmp(c, "sseek")) {
        gLink.scoreSeek((uint32_t)(doc["tick"] | 0));
        ackTo(client, c, true);
    } else if (!strcmp(c, "slot")) {
        uint8_t op = (uint8_t)(doc["op"] | 0);   // 0 加载 1 删除
        uint8_t s  = (uint8_t)(doc["s"] | 0);
        bool ok = (op == 0) ? gScore.loadSlot(s) : gScore.removeSlot(s);
        ackTo(client, c, ok);
    }
    // ---------------- 录音 ----------------
    else if (!strcmp(c, "rec")) {
        uint8_t s = (uint8_t)(doc["s"] | 0);
        if (s) {
            if (!gRec.available()) { ackTo(client, c, false, "no buffer"); return; }
            if (doc["decim"].is<int>()) gRecDecim = (uint8_t)(doc["decim"] | 1) & 3;
            gRec.start(gRecDecim);
            gLink.recCtrl((uint8_t)(0x01 | ((gRecDecim & 7) << 1)));
            gRecOn = true;
            gRecStartMs = millis();
            gRecBytesAtStart = gRec.samples();   // 看门狗基线
        } else {
            gLink.recCtrl(0);
            gRec.stop();
            gRecOn = false;
        }
        ackTo(client, c, true);
    }
    // ---------------- 查询 ----------------
    else if (!strcmp(c, "stat")) {
        gLink.queryStatus();
    } else {
        ackTo(client, "unknown", false, c);
    }
}

// ---------------- WebSocket ----------------
static void onWsEvent(uint8_t client, WStype_t type, uint8_t* payload, size_t len) {
    switch (type) {
    case WStype_CONNECTED: {
        // 连上就推一次完整配置，手机界面不用等状态轮询
        char b[384];
        snprintf(b, sizeof(b),
            "{\"t\":\"hello\",\"fw\":\"%s\",\"vol\":%u,\"tilt\":%d,\"mute\":%u,"
            "\"tune\":[%u,%u,%u,%u,%u,%u,%u,%u],"
            "\"wet\":%u,\"damp\":%u,\"tail\":%u,\"bp\":%u,\"rec\":%u}",
            kFwVer, gVolume, gTilt, gMuted ? 1u : 0u,
            gTune[0], gTune[1], gTune[2], gTune[3],
            gTune[4], gTune[5], gTune[6], gTune[7],
            gWet, gDamp, gTail, gBypass, gRec.available() ? 1 : 0);
        gWs.sendTXT(client, b);
        break;
    }
    case WStype_TEXT:
        handleCommand((const char*)payload, len, client);
        break;
    default:
        break;
    }
}

// ---------------- 状态推送（20 Hz） ----------------
static void pushState() {
    const linkv2::Status& s = gLink.status;
    // 640 -> 800（3.5.3 的 tn）-> 950（3.5.12 的指引状态 gs/gi/gl/gf/ga）。
    // snprintf 一截断就是半截 JSON，网页会整条丢弃，所以宁可给大。
    char b[950];
    snprintf(b, sizeof(b),
        "{\"t\":\"st\",\"up\":%u,\"ss\":%u,\"sp\":%u,\"le\":%u,\"vol\":%u,"
        "\"mut\":%u,\"vt\":%u,\"tilt\":%d,\"wet\":%u,\"damp\":%u,\"tail\":%u,\"bp\":%u,"
        "\"tw\":%u,\"tb\":%u,\"tsel\":%u,"
        "\"tn\":\"%u,%u,%u,%u,%u,%u,%u,%u\","
        "\"enc\":\"%u,%u,%u,%u\",\"sw\":%u,"
        "\"ok\":%u,\"bad\":%u,\"fl\":%u,\"link\":%u,\"crc\":%u,\"rxb\":%u,"
        "\"rxs\":%u,\"rxl\":%u,\"snn\":%u,"
        "\"sof\":%u,\"lenb\":%u,\"lpc\":%u,"
        "\"sn\":\"%02X %02X %02X %02X %02X %02X %02X %02X\","
        "\"rec\":%u,\"recn\":%u,\"recsr\":%u,"
        "\"sc\":%u,\"schit\":%u,\"scsz\":%u,"
        // R60：固定曲谱指引的状态（网页用来显示"第 n/17 步 · 第 X 弦 第 Y 品"）
        //   gs = 是否在指引模式  gi = 当前步（1 基）  gl = 弦（1..4）  gf = 品（0=空弦）
        "\"gs\":%u,\"gi\":%u,\"gl\":%u,\"gf\":%u,\"ga\":%u}",
        (unsigned)s.uptimeMs, (unsigned)s.scoreState, (unsigned)s.scorePos,
        (unsigned)s.laneEnable, (unsigned)s.volume,
        gMuted ? 1u : 0u, (unsigned)gVolTarget,
        gTilt, (unsigned)gWet, (unsigned)gDamp, (unsigned)gTail, (unsigned)gBypass,
        (unsigned)(gToneRb[0] | ((gToneRb[1] & 0x0F) << 8)),
        (unsigned)(gToneRb[2] | ((gToneRb[3] & 0x0F) << 8)),
        (unsigned)gTuneSel,
        // 3.5.3：把 8 条 lane 的定弦值推给网页。
        // 不推的话，转 ENC3 改完音高，FPGA 收到了、网页数字却不动 —— 看起来像"没控制成功"。
        (unsigned)gTune[0], (unsigned)gTune[1], (unsigned)gTune[2], (unsigned)gTune[3],
        (unsigned)gTune[4], (unsigned)gTune[5], (unsigned)gTune[6], (unsigned)gTune[7],
        // 3.5.4：4 路编码器的累计格数。**这是判断"面板到底有没有工作"的唯一直接证据**：
        //   转一下 ENC1，第一个数字必须涨；四个都不动 = 面板没接好或引脚不对。
        (unsigned)encpanel::turnCount(0), (unsigned)encpanel::turnCount(1),
        (unsigned)encpanel::turnCount(2), (unsigned)encpanel::turnCount(3),
        // 3.5.5：4 路按键的当前电平（bit0=ENC1 … bit3=ENC4，1 = 未按，0 = 按下）。
        // 静置时必须是 0b1111=15；哪一位是 0，就说明那一路 SW 接到了 GND 或接错。
        (unsigned)((encpanel::swLevel(0) ? 1u : 0u) |
                   (encpanel::swLevel(1) ? 2u : 0u) |
                   (encpanel::swLevel(2) ? 4u : 0u) |
                   (encpanel::swLevel(3) ? 8u : 0u)),
        (unsigned)s.framesOk, (unsigned)s.framesBad, (unsigned)s.flags,
        (unsigned)gLink.statusValid, (unsigned)gLink.crcCount,
        (unsigned)gLink.rxBytes,
        (unsigned)gRxBps, (unsigned)gRxLevel, (unsigned)gLink.sniffLen,
        (unsigned)gLink.sofCount, (unsigned)gLink.lenBadCount,
        (unsigned)gLoopCount,
        gLink.sniff[0], gLink.sniff[1], gLink.sniff[2], gLink.sniff[3],
        gLink.sniff[4], gLink.sniff[5], gLink.sniff[6], gLink.sniff[7],
        gRecOn ? 1u : 0u, (unsigned)gRec.samples(), (unsigned)gRec.sampleRate(),
        (unsigned)gScore.count(), (unsigned)gScore.activeSlot(),
        (unsigned)gScore.durMs(),
        // R60：指引状态
        gGuideOn ? 1u : 0u,
        (unsigned)(gGuideIdx + 1),
        (unsigned)kGuideSeq[gGuideIdx].str,
        (unsigned)kGuideSeq[gGuideIdx].fret,
        gGuideAuto ? 1u : 0u);
    gWs.broadcastTXT(b);
}

// ---------------- HTTP ----------------
// 首页必须禁缓存：网页 HTML 是编译进固件的，改代码重新烧之后如果浏览器还拿缓存，
// 表现就是"烧了新固件但页面没变"。手机浏览器尤其激进，加这几个头一次解决。
static void handleRoot() {
    gHttp.sendHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
    gHttp.sendHeader("Pragma", "no-cache");
    gHttp.sendHeader("Expires", "0");
    gHttp.send_P(200, "text/html; charset=utf-8", kIndexHtml);
}

static void handleWav() {
    size_t total = gRec.wavBytes();
    if (!total) { gHttp.send(404, "text/plain", "no recording"); return; }
    gHttp.sendHeader("Content-Type", "audio/wav");
    gHttp.sendHeader("Content-Length", String(total));
    gHttp.sendHeader("Cache-Control", "no-store");
    gHttp.setContentLength(total);
    WiFiClient cli = gHttp.client();
    uint8_t buf[512];
    size_t off = 0;
    while (off < total) {
        size_t n = gRec.readWav(buf, sizeof(buf), off);
        if (!n) break;
        cli.write(buf, n);
        off += n;
    }
}

static void handleStateHttp() {
    char b[256];
    snprintf(b, sizeof(b),
        "{\"fw\":\"%s\",\"vol\":%u,\"tilt\":%d,\"score\":%u,\"slot\":%u,"
        "\"rec\":%u,\"recn\":%u,\"uptime\":%u}",
        kFwVer, gVolume, gTilt, (unsigned)gScore.count(),
        (unsigned)gScore.activeSlot(), gRecOn ? 1u : 0u,
        (unsigned)gRec.samples(), (unsigned)gLink.status.uptimeMs);
    gHttp.send(200, "application/json", b);
}

// ---------------- 3.5.10 接线自检 ----------------
// 返回 12 个编码器 GPIO 的当前电平和累计边沿数。转一个旋钮，看哪两个脚在涨，
// 就能定死排线是 1-1 还是 1<->14（两种接法下四个旋钮都能动，只有物理位置不同）。
// 访问 /encprobe 读取；/encprobe?clr=1 先清零再读。
static void handleEncProbe() {
    if (gHttp.hasArg("clr")) encpanel::probeReset();
    char b[420];
    int n = 0;
    n += snprintf(b + n, sizeof(b) - n, "{\"fw\":\"%s\",\"pins\":[", kFwVer);
    for (uint8_t i = 0; i < encpanel::kProbeCount; ++i)
        n += snprintf(b + n, sizeof(b) - n, "%s%u", i ? "," : "",
                      (unsigned)encpanel::kProbePins[i]);
    n += snprintf(b + n, sizeof(b) - n, "],\"edges\":[");
    for (uint8_t i = 0; i < encpanel::kProbeCount; ++i)
        n += snprintf(b + n, sizeof(b) - n, "%s%u", i ? "," : "",
                      (unsigned)encpanel::probeEdges(i));
    snprintf(b + n, sizeof(b) - n, "]}");
    gHttp.sendHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
    gHttp.send(200, "application/json", b);
}

static void handleNotFound() { gHttp.send(404, "text/plain", "not found"); }

// ---------------- 生命周期 ----------------
void setup() {
    Serial.begin(115200);
    Serial.println();
    Serial.println("=== Tang60K Music Console (LINK v2) ===");

    if (!linkv2::selfTest()) {
        Serial.println("[FATAL] CRC16 self-test failed");
    } else {
        Serial.println("[ok] CRC16-CCITT self-test passed");
    }

    if (!LittleFS.begin(true)) Serial.println("[warn] LittleFS mount failed");

    gLink.begin(Serial2);
    gLink.setRecCallback(onRecAudio);
    gScore.begin();
    if (!gRec.begin()) Serial.println("[warn] recording disabled (no memory)");

    // 上电把界面镜像值同步进 FPGA。这些值本身等于 FPGA 上电默认值，
    // 发一遍只是保证"ESP32 显示的和 FPGA 里的一致"。
    gVolCur = gVolTarget = gVolume;      // 斜坡从当前值起步，避免上电就跑一遍
    gLink.setVolume(gVolume);
    applyTone(0);
    for (uint8_t i = 0; i < 8; ++i) gLink.setTuning(i, gTune[i]);
    gLink.setFx(gWet, gDamp, gTail, gBypass != 0);
    gLink.ping();

    // 物理旋钮：4 路 EC11（无源操作面板）。全靠内部上拉，无中断、1 ms 轮询。
    encpanel::begin(onEncTurn, onEncClick, onEncHold);
    Serial.print("[enc] 4x EC11  A/B/SW = ");
    for (uint8_t i = 0; i < encpanel::kEncCount; ++i) {
        Serial.printf("%u/%u/%u ", encpanel::kPins[i][0],
                                  encpanel::kPins[i][1],
                                  encpanel::kPins[i][2]);
    }
    Serial.println("\n[enc] 引脚表 3.5.9：ENC1 18/19/34  ENC2 23/25/35  ENC3 26/27/36  ENC4 33/32/39");

    WiFi.mode(WIFI_AP);
    WiFi.softAP(kApSsid, kApPass);
    Serial.printf("[wifi] AP \"%s\"  ->  http://%s/\n", kApSsid,
                  WiFi.softAPIP().toString().c_str());

    gHttp.on("/", handleRoot);
    gHttp.on("/rec.wav", handleWav);
    gHttp.on("/state", handleStateHttp);
    gHttp.on("/encprobe", handleEncProbe);
    gHttp.onNotFound(handleNotFound);
    gHttp.begin();

    gWs.begin();
    gWs.onEvent(onWsEvent);

    Serial.printf("[uart] %u bps  RX=GPIO%d  TX=GPIO%d\n",
                  (unsigned)linkv2::kBaud, linkv2::kPinRx, linkv2::kPinTx);
    Serial.printf("[fw] %s  slots=%u  max events=%u\n",
                  kFwVer, (unsigned)scorev2::kSlots, (unsigned)scorev2::kMaxEvents);
}

// ============================================================================
// R60：固定曲谱指引（ESP32 触发，HDMI 只显示"该弹哪根弦第几品"）
//
// 用户要求：
//   · ESP32 上触发按钮，触发后屏幕显示第一个目标；
//   · **弹完对应弦就自动指到下一个**；
//   · 乐谱固定 17 步；
//   · 进入指引模式后**左手只显示指引，不显示实时按压**（FPGA 侧不读左手总线）；
//   · 声音仍以真实演奏为主，**指引与发声隔离**；要求可控。
//
// FPGA 接口（纯显示侧，见 src/link_pkg.vh / link_regs.v）：
//   REG_GUIDE_CTRL(0x30)  bit0=1 才进直控（此时曲谱事件与 g_expire 全部失效）
//                         bit1=指引有效
//   REG_GUIDE_LANE(0x31)  0..7
//   REG_GUIDE_NOTE(0x32)  MIDI，FPGA 内部用 note - 当前定弦 得品格
//   REG_PLUCK_CNT(0x33)   只读，起音计数
//   REG_PLUCK_MASK(0x34)  只读，**最近一次起音是哪几根弦**
//
// 推进判据：CNT 变化（有人弹了）→ 读 MASK → 若包含目标弦才推进。
// 这样拨错弦不会跳步（多模型评审指出的关键点）。
//
// 为什么不用录音做起音检测：本文件顶部第 71 行记录过 —— R38/R39 的 LADPCM
// 录音版在实板上会让 S1/S2/S3 自鸣，那条路会破坏发声链，本版不走。
// ============================================================================

// （状态变量与 kGuideSeq 已前移到 gTune 旁边声明 —— pushState 与 WebSocket 分发要用）

static inline uint8_t guideLane() { return (uint8_t)(kGuideSeq[gGuideIdx].str - 1); }
static inline uint8_t guideFret() { return kGuideSeq[gGuideIdx].fret; }
static inline uint8_t guideNote() {
    uint16_t n = (uint16_t)gTune[guideLane()] + guideFret();
    return (uint8_t)(n > 127 ? 127 : n);
}

// 把当前步写到 FPGA
static void guidePush() {
    if (!gGuideOn) return;
    gLink.writeReg(linkv2::REG_GUIDE_LANE, guideLane());
    gLink.writeReg(linkv2::REG_GUIDE_NOTE, guideNote());
    gLink.writeReg(linkv2::REG_GUIDE_CTRL, 0x03);   // 直控 + 有效
    gGuidePoll   = 1;
    gGuideNextMs = millis() + 150;                  // 让刚写的三步先发完
}

static void guideStop() {
    gGuideOn = false;
    gGuidePoll = 0;
    gLink.writeReg(linkv2::REG_GUIDE_CTRL, 0x00);   // 退出直控，立即回到曲谱模式
}

static void guideStepBy(int8_t d) {
    int n = (int)gGuideIdx + (int)d;
    if (n < 0) n = 0;
    if (n > (int)kGuideSteps - 1) n = (int)kGuideSteps - 1;
    gGuideIdx = (uint8_t)n;
    gGuideCntOk = false;                            // 重新对表，避免旧计数误触发
    guidePush();
}

// WebSocket 命令入口（"guide"）。a = start/stop/next/prev/auto/reset，v = auto 的开关值
static void guideCommand(const char* a, int v) {
    if (!strcmp(a, "start")) {
        gGuideOn    = true;
        gGuideAuto  = true;
        gGuideIdx   = 0;
        gGuideCntOk = false;
        guidePush();
    } else if (!strcmp(a, "stop")) {
        guideStop();
    } else if (!strcmp(a, "next")) {
        if (gGuideOn) guideStepBy(1);
    } else if (!strcmp(a, "prev")) {
        if (gGuideOn) guideStepBy(-1);
    } else if (!strcmp(a, "auto")) {
        gGuideAuto = (v != 0);
        gGuideCntOk = false;
    } else if (!strcmp(a, "reset")) {
        gGuideIdx   = 0;
        gGuideCntOk = false;
        if (gGuideOn) guidePush();
    }
}

// loop() 里每圈调用：节流发起音计数轮询
static void guideLoop() {
    if (!gGuideOn || !gGuideAuto) return;
    uint32_t now = millis();
    if (now < gGuideNextMs) return;
    // 回包是"单槽"的（haveRegValue + 一组 addr/data），音色回读也在用同一个槽。
    // 已经有未消费的回包时不要插队，否则两个 CMD_REG_READ 会互相覆盖。
    if (gLink.haveRegValue) return;
    if (gGuidePoll == 1 || gGuidePoll == 2) {
        // 上一轮没收到回包：放弃这一轮，过一会儿重来（不阻塞主循环）
        gGuidePoll   = 0;
        gGuideNextMs = now + 100;
        return;
    }
    gLink.readReg(linkv2::REG_PLUCK_CNT);
    gGuidePoll   = 1;
    gGuideNextMs = now + 60;
}

void loop() {
    gLoopCount++;                    // 心跳：网页上看它有没有在涨
    gWs.loop();
    gHttp.handleClient();
    gLink.poll();
    encpanel::poll();          // 4 路旋钮，内部 1 ms 节流，不阻塞主循环
    guideLoop();               // R60：固定曲谱指引的起音轮询（非阻塞）

    // ---- 诊断：上电后收到的前 96 个原始字节，一次性打到 USB 串口 ----
    // 用途：判断"没有有效帧"到底是①字节完全乱（波特率/信号质量）
    //       ②能看到 A5 5A 但 CRC 总错（丢字节）③帧头都找不到（线路噪声）。
    // 只在攒够 96 字节时打印一次，不影响后续时序。
    if (!gLink.sniffDone && gLink.sniffLen >= (uint8_t)sizeof(gLink.sniff)) {
        gLink.sniffDone = true;
        Serial.printf("[sniff] first %u bytes from FPGA:\n", gLink.sniffLen);
        for (uint8_t i = 0; i < gLink.sniffLen; ++i) {
            if ((i & 15) == 0) Serial.printf("  %02X: ", i);
            Serial.printf("%02X ", gLink.sniff[i]);
            if ((i & 15) == 15) Serial.println();
        }
        Serial.println();
    }

    uint32_t now = millis();

    // ---- 诊断：RX 空闲电平 + 收字节速率（每秒刷新一次）----
    // gpio_get_level() 直接读 GPIO 输入寄存器，即使该脚已路由给 UART 外设，
    // 读到的仍是引脚真实电平。UART 空闲必须是高（3.3V）。
    gRxLevel = (uint8_t)gpio_get_level((gpio_num_t)linkv2::kPinRx);
    if (now - gRxPrevMs >= 1000) {
        gRxBps    = gLink.rxBytes - gRxPrev;
        gRxPrev   = gLink.rxBytes;
        gRxPrevMs = now;
    }

    // ---- 音量软斜坡：每 2 ms 逼近目标，单步 <= 2 LSB ----
    // 目的：避免手机一次拖动几十级时 DAC 那边出现 click。
    // FPGA 侧音量是逐帧直算的（R36 README §7.3），斜坡放在这里最省事、零风险。
    // 参数按专家评审调整：原先是 5 ms/±8，两家模型都指出单个台阶约 0.5 dB、
    // 仍有轻微 zipper 声；改成 2 ms/±2 后每步约 0.14 dB，
    // 0→255 全程约 256 ms，拖动时听不出延迟。
    if (gVolCur != gVolTarget && now - gVolStepMs >= 2) {
        gVolStepMs = now;
        int diff = (int)gVolTarget - (int)gVolCur;
        int step = diff / 16;
        if (step == 0) step = (diff > 0) ? 1 : -1;
        if (step >  2) step =  2;
        if (step < -2) step = -2;
        gVolCur = (uint8_t)((int)gVolCur + step);
        gLink.setVolume(gVolCur);
    }

    // ---- 音色倾斜节流：拖动时每 60 ms 下发一帧 ----
    if (gToneDirty && now - gToneLastMs >= 60) {
        gToneLastMs = now;
        gToneDirty  = false;
        applyTone(gTonePending);
    }

    // ---- 音色寄存器回读：250 ms 一轮，交替读 warm / bright ----
    if (gLink.haveRegValue) {
        uint8_t a = gLink.regValueAddr;
        if (a >= linkv2::REG_TONE_WARM && a <= linkv2::REG_TONE_BRIGHT + 1)
            gToneRb[a - linkv2::REG_TONE_WARM] = gLink.regValueData;

        // ---- R60：指引模式的起音回读（两段式：CNT 变化 -> 读 MASK -> 判目标弦） ----
        if (gGuideOn && gGuideAuto) {
            if (a == linkv2::REG_PLUCK_CNT) {
                if (!gGuideCntOk) {
                    gGuideCnt   = gLink.regValueData;      // 第一次只对表，不推进
                    gGuideCntOk = true;
                    gGuidePoll  = 0;
                    gGuideNextMs = millis() + 80;
                } else if (gLink.regValueData != gGuideCnt) {
                    gGuideCnt   = gLink.regValueData;      // 有新起音
                    gGuidePoll  = 2;
                    gLink.readReg(linkv2::REG_PLUCK_MASK);
                    gGuideNextMs = millis() + 60;
                } else {
                    gGuidePoll  = 0;                        // 没变化，过一会儿再问
                    gGuideNextMs = millis() + 100;
                }
            } else if (a == linkv2::REG_PLUCK_MASK) {
                uint8_t target = (uint8_t)(1u << guideLane());
                if (gLink.regValueData & target) {          // 弹的正是目标弦
                    if (gGuideIdx + 1 < kGuideSteps) {
                        gGuideIdx++;
                        guidePush();
                    } else {
                        // 最后一步：停在末音，不再前进（不自动退出，方便反复看）
                        gGuidePoll   = 0;
                        gGuideNextMs = millis() + 400;
                    }
                } else {
                    // 弹了别的弦：不推进（多模型评审指出的"拨错弦不该跳步"）
                    gGuidePoll   = 0;
                    gGuideNextMs = millis() + 150;
                }
            }
        }

        gLink.haveRegValue = false;
    }

    if (now - gToneRbMs >= 120) {          // 4 个寄存器一轮约 0.5 s
        gToneRbMs = now;
        gLink.readReg((uint8_t)(linkv2::REG_TONE_WARM + gToneRbIdx));
        gToneRbIdx = (uint8_t)((gToneRbIdx + 1) & 3);
    }

    // ---- 录音看门狗：下发使能后 800 ms 还没有任何音频字节，说明位流没开通录音 ----
    // R36 的位流是 LINK_PCM_TAP=0，rec_ladpcm 收不到数据，界面必须如实告诉用户，
    // 否则会表现为"点了录 2 秒，试听是空的"。
    if (gRecOn && (now - gRecStartMs) > 800 && gRec.samples() == gRecBytesAtStart) {
        gLink.recCtrl(0);
        gRec.stop();
        gRecOn = false;
        gWs.broadcastTXT("{\"t\":\"recwarn\",\"m\":\"no audio from FPGA (bitstream without PCM tap)\"}");
        Serial.println("[rec] no audio: this bitstream has no PCM tap");
    }

    // 录音写满后自动关 FPGA 侧使能（否则 LADPCM 还在空转、白占 53% 带宽）
    if (gRecOn && !gRec.active()) {
        gLink.recCtrl(0);
        gRecOn = false;
        Serial.printf("[rec] done: %u samples @ %u Hz\n",
                      (unsigned)gRec.samples(), (unsigned)gRec.sampleRate());
    }

    // 轮询 STATUS（5 Hz）。播放中它同时是播放进度来源。
    if (now - gLastStatusMs >= gStatusPeriod) {
        gLastStatusMs = now;
        gLink.queryStatus();
    }

    // 20 Hz 推送
    if (now - gLastPushMs >= 50) {
        gLastPushMs = now;
        pushState();
    }
}
