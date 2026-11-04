# Tang 60K 手机 WiFi 工作台（ESP32，LINK v2，固件 3.0.0）

**一句话**：手机连 ESP32 的热点，用一个网页改音色/音量/定弦/混响、把整首曲谱下发进 FPGA
让它自己演奏、录一段自己拉的琴回传试听。

- 协议：LINK v2，230400 8N1，`A5 5A` 帧头 + CRC16-CCITT
- 唯一真源：FPGA 侧 `src/link_pkg.vh` + `src/cmd_dispatch.v`
- FPGA 侧对应版本：**R25**

---

## 一、接线（只要 3 根线）

| ESP32 | 方向 | 中间件 | FPGA |
|---|---|---|---|
| `GPIO17`（UART2 TX） | → | R6 **33 Ω** 串联 | **E14**（`uart_rx_i`） |
| `GPIO16`（UART2 RX） | ← | R5 **33 Ω** 串联 | **E13**（`uart_tx_o`） |
| `GND` | — | 必须共地 | `GND` |

- 两侧都是 3.3 V LVCMOS33，**不需要电平转换**。
- 33 Ω 是源端串联电阻，抑制 230400 下的过冲；没有也能跑，但长线（>15 cm）建议加。
- 依据：`LINK_ESP32_链路模块_20261031/04_DOCS/协议规格_v1.md` 第一节 +
  `R5_四弦独立_20261028/constraints/tang_mega_60k.cst:78`。
- **不要接 ESP32 的 GPIO1/GPIO3**（那是它自己的 USB 调试口，见下）。

### ESP32 供电与调试口

用 Type-C 供电即可，FT232 那一路（GPIO1/GPIO3）留给 `pio device monitor` 看日志，
**不参与 FPGA 通信**。这样"看日志"和"控制 FPGA"互不干扰——这是选 UART2 的唯一原因。

---

## 二、编译与烧录

```bash
cd esp32_wifi_console

pio run                      # 编译
pio run -t upload            # 烧录（USB 接 Type-C，upload_speed 921600）
pio device monitor           # 看日志（115200）

pio run -t mergebin          # 生成 firmware_merged.bin（从 0x0 烧，适合量产/救砖）
```

**首次上电应该看到**（115200 日志）：

```
=== Tang60K Music Console (LINK v2) ===
[ok] CRC16-CCITT self-test passed
[rec] buffer 48828 samples (2.0 s @ 24414 Hz)
[wifi] AP "Tang60K-Music"  ->  http://192.168.4.1/
[uart] 230400 bps  RX=GPIO16  TX=GPIO17
[fw] 3.0.0  slots=4  max events=1365
```

`[FATAL] CRC16 self-test failed` 说明协议实现有问题，**不要继续用**。

### 手机操作

1. 连 WiFi `Tang60K-Music`，密码 `tang60k2026`
2. 浏览器打开 `http://192.168.4.1/`
3. 顶栏出现绿色的 `FW 3.0.0` = 已连上

---

## 三、功能怎么用（固件 3.1.0）

| 卡片 | 作用 | 底层命令 | FPGA 侧落点 | 状态 |
|---|---|---|---|---|
| 音量与音色 | 音量 0..255（128=0 dB）+ 静音；音色单旋钮倾斜 | `CMD_SET_VOLUME` / `CMD_SET_TONE` | `pt8211_tx.i_volume` / `timbre_shaper` | ✅ |
| 弦与定弦 | 改空弦音高（MIDI） | `CMD_SET_TUNING` | `performer_pitch_map` | ✅ |
| 混响/阻尼/尾音 | wet/damp/tail/bypass | `CMD_SET_FX` | `instrument_bank_core` 的 FX 输入 | ✅ |
| 曲谱指引 | MIDI/文本谱 → 解析 → 整表下发 → **屏幕指示该按哪根弦哪个品，不发声** | `SCORE_BEGIN/DATA/CTRL` | `score_store` + `score_player` + 显示域目标框 | ✅ |
| 录音试听 | 录 2 秒 → 解码 → WAV | `REC_CTRL` + `REC_AUDIO` | `rec_ladpcm` + `rec_stream` | ⛔ 需 `LINK_PCM_TAP=1` 的位流 |

> **完整控制路线**（每个控件 → 寄存器 → 消费模块 → 默认值 → 状态）见
> `00_首页_最新版本/R37_控制路线_固件3.1.0_20261102/控制路线.md`，那份是唯一真源。

### 3.1.0 修掉的四个真问题

1. **曲谱 lane 映射**：旧版按"换乐器"状态把事件发到 lane 4..7，而 GUIDE 页只画
   `lane<4`，一旦点过"尤克里里"**目标框就消失**。现在固定发 0..3。
2. **定弦写入 lane**：同一个映射问题，旧版会把音高写进另一组 lane，表现为"改了没用"。
3. **静音无效**：旧版写 `REG_MUTE(0x16)`，那个寄存器只接录音抽头，DAC 直连后完全不生效。
   现在走音量（保存 → 0 → 恢复），并且**拖动音量会自动解除静音**。
4. **音量跳变有 click**：FPGA 侧音量是逐帧直算、无斜坡，现在 ESP32 侧做 2 ms/±2 的软斜坡。

### 关于"音色"的一个概念澄清

旧版这里有两个"音色"，其中一个**是假的**：

- ❌ "换乐器（小提琴 ⇄ 尤克里里）" —— 8 条物理弦在综合时就固定成 4 弓弦 + 4 拨弦，
  `lane_enable` 没有任何模块消费。**3.1.0 已把它从界面移除**，固件也改成明确回报
  `not supported`，不再静默成功。
- ✅ "音色倾斜" —— 同一个乐器的明暗，走 `timbre_shaper` 的双架（低架 600 Hz / 高架 1200 Hz），
  带峰值归一化，所以转到头只变音色、不变响。

### 曲谱格式

> **R33 起曲谱只做"演奏指引"**：事件不会让琴自己发声，只在屏幕 GUIDE 页点亮目标框
> （黄=该按这里，绿=按对了）。声音永远由你的动作产生。
> `score_v2` 因此只发 PLUCK 类型（表示"这里有一个音要演奏"），不再补 BOW/STOP。

**MIDI**：直接选 `.mid`。浏览器解析，按页面「乐器」下拉分弦：

- **小提琴** → lane `0..3`，空弦 G3/D4/A4/E5 = 55/62/69/76
- **尤克里里** → lane `4..7`，空弦 G4/C4/E4/A4 = 67/60/64/69

分弦规则是"不超过该音高的最高空弦"（`pickString`），所以定弦改了会自动跟着变。
同弦同一时刻只保留最高音（FPGA 每个 lane 只有一个音高寄存器）。
速度用页面上的 BPM 覆盖（不读 MIDI 的 tempo 事件，简化实现）。

**文本谱**：每行 `时间ms,弦0-7,音高0-127,力度0-127`，`#` 开头是注释。

```
# 时间(ms), 弦(0-7), 音高(0-127), 力度(0-127)
0,0,55,100      # 琴弦1 空弦 G3
250,0,57,100
500,5,60,90     # 尤弦2 空弦 C4
```

弦号 `0-3` = 小提琴 1-4 弦，`4-7` = 尤克里里 1-4 弦，**文本谱直接写弦号，不受「乐器」下拉影响**。

**容量**：FPGA `score_store` 是 8 KB = **1365 个事件**。超了页面会直接提示，不静默截断。

**tick 精度**：ESP32 按曲长自动选 `tick_us`，保证 `max(tick) ≤ 65000`。
3 分钟的曲子 `tick_us ≈ 2800`（2.8 ms 分辨率），对 16 分音符足够。

### 录音

> ⛔ **当前交付位流 R36 是 `LINK_PCM_TAP=0`，录音通路没有接音频。**
> 点"录 2 秒"会在 800 ms 后收到 `recwarn`，界面提示"位流未开通录音"。
> 这是固件的**看门狗**在如实报告，不是故障。要用录音必须重新生成一个
> `LINK_PCM_TAP=1` 的位流（见 R37 控制路线 §7 待办第 3 项）。

点"录 2 秒" → ESP32 发 `REC_CTRL=0x03`（使能 + 2x 抽取）→ FPGA 每 2.73 ms 回一帧
56 字节 LADPCM → ESP32 解码进缓冲 → 2 秒后自动停 → 点"试听"从 `/rec.wav` 下载。

- 采样率 24.4 kHz（48.828 k ÷ 2），16 bit 单声道
- 缓冲 2 秒 = 97.7 KB，从堆分配；内存不足时自动降到 1 秒，再失败就禁用录音（其它功能不受影响）
- **录的是 FPGA 音量之前的信号**：回传后在手机侧调音量不会把录音也调小

---

## 四、代码结构

| 文件 | 行数 | 职责 | 改动时要注意 |
|---|---|---|---|
| `src/link_v2.h/.cpp` | ~330 | 传输层：组帧、CRC16、解析、六个功能的命令封装 | **协议唯一真源**；改常量必须同步 FPGA 的 `link_pkg.vh` |
| `src/score_v2.h/.cpp` | ~240 | 曲谱模型 + LittleFS 存储 + 整表下发 | 事件结构 `__attribute__((packed))` 必须与 FPGA 的 6 字节格式逐字节对齐 |
| `src/rec_player.h/.cpp` | ~150 | LADPCM 解码 + WAV 打包 | 解码器必须与 `src/rec_ladpcm.v` 的自研格式一致，**不是标准 IMA ADPCM** |
| `src/web_ui.h` | ~430 | 单页界面（PROGMEM） + 浏览器侧 MIDI 解析 | 改的是纯前端，不影响链路 |
| `src/main.cpp` | ~430 | WiFi AP / HTTP / WebSocket / 命令路由 / 状态推送 | 新命令在这里加分支 |

`legacy_v1/` 是 2.x 的 v1 固件（115200 + 逐音下发），**不参与编译**，只作对照。

### 三条容易踩的坑（都已在代码里注释）

1. **ACK 是 1 字节**，不是 `link_pkg.vh` 注释里写的 2 字节。
   依据 `cmd_dispatch.v:310` 的 `tx_send_len <= 8'd1`。
2. **`CMD_SCORE_END` 在 FPGA 侧没有分支**（走 default 回 ACK），也就是 FPGA 不校验事件流 CRC。
   校验由 ESP32 自己算完写进文件头，加载时比对。
3. **曲谱的 BOW/PLUCK 必须有非零弓速**：小提琴波导的 `i_bow_speed` 同时控制
   `w_bow_target_velocity`（0 就不发声）。`lane_arbiter.v` 里给曲谱 lane 的弓速是
   `vel + 32`（0/64/127 → 32/96/159 → 弓压 224/240/255）。
4. **小提琴弦（lanes 0..3）只能发 BOW，不能发 PLUCK**。
   `violin_waveguide_voice` 的注能要过 `w_contact_allowed = i_gate && (... || i_trigger)`，
   PLUCK 只给 trigger 不给 gate，实测 34 ms 内 `pcm` 全 0。
   所以 `score_v2` 现在按弦号自动选事件类型（0..3 → BOW，4..7 → PLUCK），
   并在曲谱末尾给每根被拉的弦**补一个 STOP**——BOW 是电平 gate，不停止会一直响。

---

## 五、故障排查

| 现象 | 先查什么 |
|---|---|
| 界面一直"断开" | 手机是否连的是 `Tang60K-Music` 而不是家里的 WiFi；`http://192.168.4.1/` 能否打开 |
| 顶栏"已连接"但 FPGA 显示"离线" | `statusValid` 需要收到 STATUS 帧。查 E14/E13 是否接反（ESP32 TX 必须接 FPGA RX=E14）、是否共地 |
| 好帧一直 0、坏帧猛涨 | 波特率不对（FPGA 侧 `DIV_DEFAULT` 应为 217）、或者 ESP32 的 GPIO16/17 被别的库占用 |
| 参数改了没反应 | 先确认"好帧"在涨；FPGA 侧参数**上电默认值等于 R24 硬编码**，如果 ESP32 没发就保持默认 |
| 下发曲谱返回 `ok:false` | 事件数超 1365；或者 `splay` 之前没 `scommit`（`loaded()` 为假） |
| 播放没声音但进度在动 | `lane_enable` 把该 lane 屏蔽了（换过乐器），或者该 lane 的定弦被改成了 0 |
| 录音下载 404 | `rec` 为 0（内存不足）；或 `REC_CTRL` 没使能（看 FPGA 侧 `r_rec_ctrl[0]`） |
| 录音是静音 | FPGA 的 `i_pcm` 没接真实音频——R24 及以前是硬接 0，**必须用 R25 及以后的位流** |

### 离线调试（不接 FPGA）

固件在没接 FPGA 时照常启动：所有命令都只是往 UART2 写，界面正常、状态里"FPGA"显示"离线"、
好帧恒 0。可以先把界面和曲谱上传流程走通再接线。

---

## 六、带宽预算（为什么是 230400 而不是 921600）

| 项 | 数值 |
|---|---|
| 230400 有效吞吐 | 23040 B/s（8N1 10 bit/字节） |
| 录音码率 | 12207 B/s（48828 ÷ 2 抽取 ÷ 2 打包） |
| 录音占用 | **53%** |
| 一帧录音 | 63 字节 / 2.73 ms |
| 曲谱下发 1365 事件 | 8.3 KB ≈ 0.36 s（一次性） |
| 状态轮询 5 Hz | 60 B/s |

录音占 53% 之后还剩 10.8 KB/s，足够曲谱下发和状态轮询。
**只有需要 48.8 kHz 全带宽录音时**才需要切 921600（`REG_LINK_CTRL` bit1），
但那时 `rec_stream` 的 512 B 环形缓冲要重新核算。

---

## 七、接力给下一个 AI 的话

如果你要扩展这个固件，按这个顺序最省事：

1. **加参数** → 先在 FPGA 侧 `link_regs.v` 找空地址，再在 `link_v2.h` 的 `Reg` 枚举加一行，
   然后 `main.cpp` 的 `handleCommand` 加一个 `else if`，最后 `web_ui.h` 加控件。
2. **加下行帧** → `link_v2.cpp` 的 `handleFrame` 加 case，参考 `CMD_REC_AUDIO` 的回调写法。
3. **改曲谱格式** → 同时改 `score_v2.h` 的 `Event` 和 FPGA 侧 `score_store.v` / `score_player.v`，
   两边字节序必须一致（FPGA 是小端：`{kind, lane, note, vel, tick_lo, tick_hi}`）。
4. **不要**在 `loop()` 里加阻塞超过 20 ms 的调用——20 Hz 状态推送会断，界面会以为掉线。
5. **不要**把 `Serial2` 的 RX 缓冲调回默认 256 字节：录音 56 B/2.73 ms，再加上曲谱突发，
   256 字节会在 11 ms 内溢出。
