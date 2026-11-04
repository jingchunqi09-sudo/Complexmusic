# R54 —— GUIDE 页尤克里里弦指引 + 演示曲谱

日期：2026-11-03
基线：R53（位流不变的部分逐字节相同）
固件：3.5.8

---

## 一、需求与核实结论

用户原话：

> 在不破坏现有功能的前提下加入演示指引的功能，通过 esp32 导入曲谱，然后通过控制屏幕，
> 指引某个品就亮哪里，尤克里里则是右手部分直接对应弦有反应即可，波形显示真实演奏波形。

**先把现状逐条读代码核实了一遍，四件事里有三件已经存在：**

| 需求 | 现状 | 位置 |
|---|---|---|
| ESP32 导入曲谱 | **已有**（LittleFS 4 槽 + 网页上传 + 整表下发） | `score_v2.cpp`、`web_ui.h` |
| 屏幕指引某品亮哪里 | **已有**（黄框闪烁 / 命中变绿 / 空弦画琴枕左侧） | `r9_stage_dashboard.v` R33 |
| 波形显示真实演奏波形 | **已有**（`i_pcm` → `r9_audio_monitor` → 512 bin → 560 列） | `r9_audio_monitor.v` |
| 尤克里里对应弦 | **只缺指引**：演奏时的弦反馈已有（`view_instrument` 拨弦=4'hf） | 本版补 |

也就是说本轮真正要加的是**一件事**：曲谱事件是 lane 4..7 时，屏幕上没有任何提示
（`r9_stage_dashboard` 里写死 `i_guide_lane<2'd4`）。

顺手修掉两处**既有缺陷**（都会让"演示"看起来不工作）：

1. **小提琴指引框的坐标是 latch**。`g_xl/g_xr/g_yc` 原来写成
   "在 `always @(*)` 里按条件赋值的 reg"，条件不满足时保持旧值 → 综合器只能推断成 latch，
   上电初值不确定。实板表现可能是"第一次进 GUIDE 页框画在随机位置"。改成组合 `wire`。
2. **MIDI 分弦只认小提琴**。网页 `noteToString()` 只在 `st.tune[0..3]` 里找，
   尤克里里的 MIDI 曲谱永远被分到 0..3，lane 4..7 一个事件都不会有。

---

## 二、改动清单

### RTL（3 个文件，顶层端口零新增）

| 文件 | 改动 |
|---|---|
| `fpga/src/r9_stage_dashboard.v` | 新增 `i_instruments[3:0]` 输入；uke 弦指引绘制；`g_*` 坐标 reg→wire |
| `fpga/src/r9_audio_monitor.v` | `i_instruments` 进像素域（2 级同步，+12 FF），输出 `o_instruments` |
| `fpga/src/hdmi_instrument_display.v` | 模块内多接一组线（`i_instruments` → monitor → dashboard） |

**没有动**：音频链、选品链、灯带、链路寄存器、`tang_mega_60k_top.v`、任何顶层端口。

### 绘制规则（GUIDE 页，`i_mode==0`）

| 事件 lane | 显示 |
|---|---|
| 0..3（小提琴） | 原样：品格框，黄=未按到，绿=按对（本次只修 latch，不改规则） |
| **4..7（尤克里里）** | **琴颈该行上下各 3 px 琥珀提示线** + **最左空弦块实心**；该弦真的在响（`view_instrument==4'hf` 且该行 gate 有效）→ 变绿 |

闪烁仍用 `guide_blink`（8 帧翻转，~0.13 s），与小提琴一致。

### 低风险写法（多模型评审 B1/B3 的要求）

- 行中心用 **4 选 1 常量表** `uke_row_y()`，不用 `174+40r` 的移位加法 ——
  不给 neck 那串比较器接新支路。
- 命中判据 `uke_hit_r` **在时序块里打一拍**，颜色级只读 1 bit 寄存器，
  不在组合路径上索引 `i_gates`/`i_instruments`（hold 只有 184 ps）。
- `i_guide_lane` 是 3 位，天然只可能 0..7，`uke_row` 不会折回。

### ESP32 网页（`web_ui.h`）

1. 曲谱卡片加**乐器选择**（小提琴 / 尤克里里）。
2. `noteToString` 拆成 `pickString(n, base, count)`，支持 0..3 与 4..7；
   **不再假设定弦升序** —— 尤克里里默认 G4/C4/E4/A4 = 67/60/64/69 本身不是升序。
3. 上传流程抽成 `uploadList()`，手动导入与演示共用。
4. 新增**「生成演示曲谱」**按钮：8 根空弦依次点亮（琴 1-4 → 尤 1-4），每根 0.9 s，两轮。
   不需要任何文件即可验证整条链路。
5. 提示文字：文本谱弦号 0-7；日志会显示"（琴 N / 尤 M）"的事件数。

---

## 三、仿真

`sim/tb_r54_uke_guide.v` —— 直接驱动 dashboard 扫描坐标，等流水后回读 RGB。

```
ok   uke row0 top edge     (x=300,y=166) = e9b353
ok   uke row0 bottom edge  (x=300,y=195) = e9b353
ok   uke row0 left block   (x=10, y=180) = e9b353
ok   uke row2 top edge     (x=300,y=246) = e9b353
ok   uke row2 bottom edge  (x=300,y=275) = e9b353
ok   uke hit -> green                    28e070
ok   violin view stays amber             e9b353
ok   violin fret box still drawn         e9b353
ok   uke guide cleared                   (底色)
==== PASS: all uke-guide checks ====
```

第 8 条是小提琴框的回归 —— **它在改之前是失败的**（读到琴颈底色，因为坐标 reg 是 X），
改成 wire 后才通过，反过来证实了上面那条第 1 个既有缺陷。

运行方式：

```powershell
cd build\_sim_r54
vlog -work work ..\..\src\stage_bcd.v ..\..\src\r9_text_layer.v ..\..\src\r9_stage_dashboard.v ..\..\sim\tb_r54_uke_guide.v
vsim -c -do "run -all; quit -f" work.tb_r54_uke_guide
```

（`r9_stage_dashboard` 里 `$readmemh("src/rom/r9_violin_mask.hex")` 是相对路径，
仿真目录下要有 `src/rom/` 的副本。）

---

## 四、多模型评审

脚本 `scripts/review_r54_uke_guide.py`，千问 / Kimi / DeepSeek 各两轮，
全文见 `多模型评审_uke指引.md`。采纳情况：

| 建议 | 来自 | 采纳 |
|---|---|---|
| `uke_yc` 不要留加法在比较链里 | 三家一致 | ✅ 改常量表 |
| `uke_hit` 必须打一拍 | 三家一致 | ✅ `uke_hit_r` |
| 整行 + 左侧实心块最易读 | 千问 / Kimi | ✅ 已按此实现 |
| uke 指引时压暗其余 3 行 | 三家一致 | ❌ 不改 —— 会动小提琴页的绘制逻辑，风险大于收益 |
| 命中后锁存 300 ms 窗 | DeepSeek | ❌ 不改 —— 要加约 8 FF + 比较器，`i_gates` 本身在发声期间就有效，够用 |
| 命中绿色留到下一版 | 千问 | ❌ 已用寄存版做出来了，验证通过 |

---

## 五、构建

`python scripts/build_batch.py --place 1 --jobs R54`，综合 0 error，`Bitstream generation completed`。

| 项 | R54 (place 1) | R53 对照 |
|---|---|---|
| CLS | **25104 / 29952（84%）** | 24895（84%） |
| Logic | 34956 / 59904（59%） | —— |
| Register | 21519 / 60780（36%） | —— |
| **Logic Register as Latch** | **0** | （R33 那三个坐标 reg 本应是 latch） |
| BSRAM | 104 / 118（89%，余 14） | 104 |
| DSP | 77.5 / 118（66%） | 77.5 |
| Fmax | 56.577 MHz | 58.814 |
| **setup** | **+2.316 ns** | +1.912 |
| **hold** | **+0.168 ns** | +0.184 |

hold 门禁：<0.10 禁止上板，≥0.15 达标。三种 place 实测：

| place | hold | setup | 结论 |
|---|---|---|---|
| **1** | **0.168** | 2.316 | **采用** |
| 2 | 0.128 | 1.394 | 更差 |
| 3 | 0.052 | 1.966 | 更差 |

（历史上同一网表不同 place 的 hold 差 43~184 ps 且方向随机，所以每次都要实测。）

### 交付

| 文件 | 大小 | sha256 |
|---|---|---|
| `烧录_R54_尤克里里指引_20261103.fs` | 20,778,247 B | `E99C65950C8BD723AB60F8D0457FBD6872367CD066CD1B8DFBD5552E8A67EDC1` |
| `firmware_3.5.8.bin` | 862,144 B | `EA188AC92D6EA744AD8373FE887CD76AEC8E2DBE8D4682DD98405B03A8413A3D` |

**位流与固件必须成对烧**：R54 位流 + 3.5.8 固件（旧位流没有 uke 指引，旧固件不会发 lane 4..7）。

### 后续固件对 R54 的兼容（2026-11-03 补）

R54 位流 + **3.5.9 / 3.5.10 / 3.5.11** 都能用，因为 3.5.9 之后只动了 ESP32：
3.5.9/3.5.10 修的是编码器引脚表（`kPins` → 18/19/34、23/25/35、26/27/36、33/32/39）
和 `/encprobe` 接线自检，3.5.11 只改了网页曲谱卡片的提示文字。
**但 3.5.8 的引脚表是反序那一套，四颗旋钮在实板上会全部错位 —— 回退时优先用 3.5.10。**

| 文件 | 大小 | sha256 |
|---|---|---|
| `firmware_3.5.10.bin`（推荐） | 864,384 B | `FBF9B098FD312AB7CED5847C88ECA871F942972B4F496A711AFD2E9C48F2B459` |
| `firmware_3.5.9.bin` | 862,096 B | `B5306E641BC16C8190A303106A8A8A70C43241CEB178169F09FB2E4F80F99114` |

烧法：`esp32_wifi_console\烧录_R54_3.5.10.cmd`（= `--bin 3.5.10`，只写 app 分区 0x10000，
bootloader / partitions / boot_app0 不用重烧）。

### 3.5.13：编码器灵敏度 ×10（2026-11-03 16:42，ESP32-only）

用户要求"除音调外全部拉高十倍"。改的是 `main.cpp` 顶部四个常量（`onEncTurn` 只读它们）：

| 旋钮 | 功能 | 3.5.12 | 3.5.13 |
|---|---|---|---|
| ENC1 | 音量 0..255 | 每格 ±2 | **±20** |
| ENC2 | 音色倾斜 −100..+100 | 每格 ±2 | **±20** |
| ENC3 | 定弦/音高（**音调**） | 每格 ±1 半音 | **±1 不变** |
| ENC4 | 混响湿声 0..255 | 每格 ±4 | **±40** |

驱动侧的"一格"定义没变：`encoder_panel.cpp:134` `acc[i]/4` → 一次回调 ±1，所以乘数 ×10
就是实打实的灵敏度 ×10。**位流不需要重烧**（这条改动不碰 FPGA，R54 的 `.fs` 照旧）。

| 文件 | 大小 | sha256 |
|---|---|---|
| `firmware_3.5.13.bin`（当前推荐） | 868,528 B | `795AA12CDF5CD1BB906E0663C782E6CFD4043AEEFDC6DEFF70C5A8F522771C88` |

烧法：双击 `esp32_wifi_console\烧录_R54_3.5.13_编码器x10.cmd`。


