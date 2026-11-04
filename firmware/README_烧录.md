# ESP32 烧录

两个入口，按心情选：

| 入口 | 行为 |
|---|---|
| **`一键烧录.cmd`** | 自动认口 → 编译 → 烧四个必需文件，全程不问。**日常用这个** |
| `烧录.cmd` | 先列串口、再列可烧文件，你选完才动手 |

配套文档：
- **`ESP32功能与使用.md`** —— 烧完之后 ESP32 能干什么、六个卡片怎么用、哪些功能在哪个位流上有效
- 本文 —— 只讲烧录本身

- 串口不会替你猜：`0403:6010`（FT2232H = Tang 板载调试器）会被标成「别选」，蓝牙虚拟串口直接不显示。
- 文件不会替你猜：每个文件都写明地址、大小、是必需还是可选、什么时候需要。
- `烧录.cmd` 在烧之前会把要写的地址和文件逐条列出来，要你再确认一次 `y`；`一键烧录.cmd` 跳过确认，但仍然先打印它要烧什么。

---

## 一、烧录到底需要哪些文件

ESP32 的 Flash 不是一个 `firmware.bin` 就够。它启动要经过三段代码 + 一张分区表：

| # | 文件 | 烧录地址 | 大小（本机实测） | 必需 | 作用 |
|---|---|---|---|---|---|
| 1 | `bootloader.bin` | **0x1000** | 17,536 B | 是 | 二级引导。上电后芯片 ROM 先跑，再把控制权交给它 |
| 2 | `partitions.bin` | **0x8000** | 3,072 B | 是 | 分区表。规定 app0 / spiffs 各在哪、多大 |
| 3 | `boot_app0.bin` | **0xE000** | 8,192 B | 是 | OTA 选择标记。告诉引导"从 app0 启动"。**在 framework 包里，不在 build 目录** |
| 4 | `firmware.bin` | **0x10000** | 864,992 B（固件 3.5.11） | 是 | 应用本体 = 你写的代码，落在 app0 分区 |
| 5 | `littlefs.bin` | **0x290000** | 需生成 | 否 | 曲谱文件系统（spiffs 分区，LittleFS）。只有要预置曲谱才烧 |
| 6 | `firmware_merged.bin` | **0x0** | 需生成 | 否 | 上面 1~4 合成的一个整包。**与 1~4 互斥** |

文件实际位置：

```
1  .pio\build\esp32dev\bootloader.bin
2  .pio\build\esp32dev\partitions.bin
3  %USERPROFILE%\.platformio\packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin
4  .pio\build\esp32dev\firmware.bin
5  .pio\build\esp32dev\littlefs.bin        （pio run -t buildfs 生成）
6  .pio\build\esp32dev\firmware_merged.bin （pio run -t mergebin 生成）
```

> 注意第 3 个：`boot_app0.bin` 不在你的 build 目录里，在 PlatformIO 的 framework 包里。
> 这是唯一一个"不属于你工程"的必需文件，漏了它芯片会一直从 app1 找固件，表现是烧完不启动。

---

## 二、什么情况烧哪些

| 你做了什么 | 要烧的文件 |
|---|---|
| 只改了 C++ 代码（最常见） | **只烧 4**（`firmware.bin`，0x10000） |
| 改过 `platformio.ini` 的分区表 / 换过 board | 1 + 2 + 3 + 4 全烧 |
| 换了新芯片 / 第一次上板 / 别处烧坏了 | 1 + 2 + 3 + 4 全烧，建议先全片擦除 |
| 要预置曲谱进文件系统 | 4 + 5 |
| 存档、发给别人、救砖 | 只烧 6（`firmware_merged.bin`，0x0） |

工具里对应两个快捷指令（在选择文件的提示符下直接输）：

- `app` → 只勾第 4 项
- `full` → 勾第 1~4 项

---

## 三、怎么操作

### 3.1 双击 `烧录.cmd`

```
=== ESP32 烧录工具 ===

[1/3] 选择串口
  当前 USB 串口：
    [1] COM16   USB Serial Port (COM16)   0403:6010  <- FT2232H = Tang 板载调试器，不是 ESP32【别选】
    [2] COM7    USB Serial Port (COM7)    10C4:EA60  <- CP210x
  输入编号选择串口（q 退出）: 2

[2/3] 选择要烧录的文件
     [x] 1. bootloader.bin   0x001000   17,536 B   必需   二级引导（开机第一段代码）
     [x] 2. partitions.bin   0x008000    3,072 B   必需   分区表（决定 app0 / spiffs 落在哪）
     [x] 3. boot_app0.bin    0x00E000    8,192 B   必需   OTA 选择标记
     [x] 4. firmware.bin     0x010000  864,992 B   必需   应用本体 = 你的代码
     [ ] 5. littlefs.bin     0x290000   未生成     可选   曲谱文件系统
     [ ] 6. firmware_merged.bin 0x000000 未生成    可选   1~4 合成整包
  命令：输入编号切换勾选（如 1,4） | a=全选 | n=清空 | app=只烧应用 | full=烧四个必需 | 回车=开烧
  > app

[3/3] 烧录
  [1/2] 先编译一遍（保证烧的是当前代码）...
  [2/2] 即将执行：
        0x010000  firmware.bin
  确认烧录到 COM7？(y/N) y
  ...esptool 输出...
  [成功] 已写入 COM7，共 1 个文件。
```

- 如果只有一个能识别的 ESP32 串口，工具会**直接用它**并打印出来，不问你。
- 如果识别不出来（桥型号不在白名单），会列出全部 USB 串口，你手选编号即可。
- 编译只在你选了 1/2/4/5 时做；只烧合并包（第 6 项）不编译。

### 3.2 命令行（等价，脚本在 `tools/flash_tool.py`）

```powershell
python tools\flash_tool.py --list                 # 只看串口和文件，不动手
python tools\flash_tool.py                        # 交互式
python tools\flash_tool.py --port COM7            # 跳过选串口
python tools\flash_tool.py --port COM7 --baud 460800
python tools\flash_tool.py --log                  # 只看日志
python tools\flash_tool.py --diag                 # 链路诊断：复位抓日志 + 判读为什么收不到字节
python tools\flash_tool.py --check                 # 不烧，只回读板上版本并与 build 对比
python tools\flash_tool.py --watch-enc             # 面板联调：实时打印 [enc] 日志，逐路按一遍
python tools\flash_tool.py --encprobe              # 接线自检：只转最左旋钮，判排线 1-1 还是 1<->14（走 WiFi）
python tools\flash_tool.py --bin 3.3.1            # 只烧指定版本到 0x10000（切版本 / 回退）
python tools\flash_tool.py --all                  # 四个必需文件全烧
```

### 3.3 VS Code 里

`Ctrl+Shift+P` → `Tasks: Run Task`：

| 任务 | 作用 |
|---|---|
| `1. 烧录（自选串口 + 自选文件）` | 同双击 `烧录.cmd` |
| `2. 查看串口与可烧录文件（只列不烧）` | 同 `--list` |
| `3. 看串口日志（115200）` | 同 `--log` |
| `4. 快速全烧（四个必需文件）` | 同 `一键烧录.cmd` |

### 3.4 想完全手工（不用脚本）

```powershell
py -3 "$env:USERPROFILE\.platformio\packages\tool-esptoolpy\esptool.py" `
  --chip esp32 --port COM7 --baud 921600 write_flash `
  --flash_mode dio --flash_freq 40m --flash_size 4MB --compress --verify `
  0x1000  .pio\build\esp32dev\bootloader.bin `
  0x8000  .pio\build\esp32dev\partitions.bin `
  0xe000  "$env:USERPROFILE\.platformio\packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin" `
  0x10000 .pio\build\esp32dev\firmware.bin
```

参数名已核对 `esptool.py write_flash --help`（esptool 4.5.1）：
`--flash_mode {keep,qio,qout,dio,dout}`、`--flash_freq {...40m...}`、`--flash_size {...,4MB}`、`--compress/-z`、`--verify`。

---

## 四、这些地址是怎么来的

不是抄的，是解析你工程的 `partitions.bin` 得出的（3,072 B = 96 × 32 字节，7 条有效）：

| 分区 | 类型 | 起始地址 | 大小 |
|---|---|---|---|
| `nvs` | data/nvs | 0x009000 | 20 KB |
| `otadata` | data/ota | 0x00E000 | 8 KB |
| `app0` | app/ota_0 | **0x010000** | 1280 KB |
| `app1` | app/ota_1 | 0x150000 | 1280 KB |
| `spiffs` | data/spiffs | **0x290000** | 1408 KB |
| `coredump` | data | 0x3F0000 | 64 KB |

由此可得：

- `firmware.bin` → app0 = **0x10000**（和 Arduino-ESP32 默认布局一致）
- `littlefs.bin` → spiffs 分区 = **0x290000**
- 分区表本身放在 `0x8000`，bootloader 在 `0x1000`，`boot_app0.bin` 写 `otadata` 起始 `0xE000`

> 结论：**别用 0x0 烧 `firmware.bin`**。0x0 只属于合并包。
> 如果你改了分区表，上面 1/4/5 的地址要重新按新 `partitions.bin` 算，工具里的地址表在
> `tools/flash_tool.py` 的 `FILES` 常量，改一行即可。

---

### 三个入口怎么选

| 脚本 | 烧的是什么 | 什么时候用 |
|---|---|---|
| **`烧录_R54_3.5.13_编码器x10.cmd`** | **交付目录里已编译好的 `firmware_3.5.13.bin`**（不编译） | **当前推荐**：冲 R54 位流 + 编码器灵敏度 ×10 |
| `烧录_R54_3.5.10.cmd` | `firmware_3.5.10.bin` | 想要 R54 原始灵敏度（每格 ±2/±2/±4） |
| `烧录_R55_3.5.11.cmd` | `firmware_3.5.11.bin` | **已弃用**（R55 位流实板乱响，不再发） |
| `一键烧录.cmd` | `.pio` 里现编译出来的固件 | 刚改完代码，要"编译+烧录"一条龙（当前源码 = 3.5.13） |
| `烧录.cmd` | 自选文件 / 自选串口 | 回退旧版本、只烧 app 分区 |

> 这几个"锁版本"的脚本走 `--bin <版本号>`，由脚本自己在
> `00_首页_最新版本/R*/` 里找 `firmware_<版本>.bin`，所以**路径含中文也不会出错**。
> 文件本身保持纯 ASCII —— `.cmd` 里写中文会被控制台代码页搞乱，中文提示全部由 Python 打印。

## 五、烧完之后：配哪个 FPGA 位流

ESP32 只负责**控制**，声音全部由 FPGA 出。两者版本必须对上。

### 当前推荐：R54 + 固件 3.5.13

| 项 | 值 |
|---|---|
| 位流 | `../releases/R54/R54-bitstream.fs`，sha `E99C6595…` |
| 固件 | **3.5.13**（868,528 B，sha `795AA12C…`）；3.5.13 只改编码器步长，**位流不用重烧** |
| 状态 | 可烧（R54：place 1，hold +0.168 ns / setup +2.316 / CLS 25,104） |

> 下面这段 R55 / R53 的记录保留作为历史。**R55 已弃用**（实板乱响），不要再照着烧；
> 需要回顾时看它的 `README.md` 与 `manifest.json` 即可。


**这一版的核心是"回退"，不是新增。** R52 / R52b 把 force mux 插到了 `selected_strings` 上——那不是接口，是发声门控本身（`selected_strings → next_gates → gate_bus`）——实板上 S1 乱响，R53 把这些全部删掉、回到 R51 行为。`manifest.json` 的 `proof_no_audio_change` 给了三条可查的证据：端口与 R41 逐行相同（33 行）、`selected_strings` 表达式逐字相同、`u_vote` 资源 32 FF / 45 ALU / 86 LUT 与 R51 完全一致。

时序：**必须用 place 3**（place 1 只有 45 ps、place 2 是 140 ps，只有 place 3 到 184 ps）；hold **0.184 ns**、setup 1.912、Fmax 58.814、0 违例；CLS 24,895（84%）、BSRAM 104/118。

**3.5.1 → 3.5.10 全是纯 ESP32 改动，位流一个字节都没变；3.5.11 + R55 是新的成对组合：**

| 固件 | 新增 |
|---|---|
| 3.5.1 | 网页定弦扩到 8 弦并显示 Hz、±半音 / 标准音 / 8 弦一览、MIDI 钳 24..96 |
| 3.5.2 | 物理面板补完：ENC3 定弦 + 换弦、ENC4 长按复位；短按改到**松手沿** |
| 3.5.3 | **4 个编码器长按都触发参数复位** |
| 3.5.4 | state 新增 `tn`（8 条 lane 的定弦值）—— 3.5.3 只推了 `tsel`，转 ENC3 时网页音高数字不动 |
| 3.5.5 | 修"静音后转音量没反应"（从 0 起步 → 改为从 `gVolBeforeMute` 起步）；state 新增 `sw`（4 路按键电平）；驱动加 `swArmed`，防 SW 常闭时上电自动触发参数复位 |
| 3.5.6 | 「U11↔H9 网络整组反序」这个**方向判断是对的**（已由两份工程的 PAD_NET 证实），但它给的引脚补偿表算错了（4/5/13 根本不在 ENC 网络上） |
| 3.5.7 | ~~引脚真值表 18/19/34…~~ —— **只在排线反序时成立，同向排线整组错位** |
| 3.5.8 | 引脚表改为按两个工程 PCB 的 `PAD_NET` 反推，并加了 `ENCODER_CABLE_REVERSED` 两套表；**该宏在 3.5.10 已删除**（实板证明不需要二选一） |
| 3.5.9 | 引脚表以**用户按两个工程网络标签逐根核对**的结果为准：`ENC1 18/19/34`、`ENC2 23/25/35`、`ENC3 26/27/36`、`ENC4 33/32/39`（ENC4 的 A/B 与符号读出相反，只影响方向） |
| 3.5.10 | 新增**接线自检**：12 个编码器 GPIO 各自累计边沿数，网页「面板接线自检」卡片 + `/encprobe` 端点（`?clr=1` 清零）。转最左旋钮看哪两个数涨，就能定死排线是 1-1 还是 1↔14；脚本对应 `--encprobe` |
| 3.5.11 | 配合 **R55**：曲谱卡文案改为「只有尤克里里显示指引」；乐器下拉改成「小提琴（屏幕不显示指引）」；演示曲谱改为尤 1-4 每根「空弦 → 第 3 品」两轮，能同时验证品格框与弦线。**控制逻辑与协议零改动** |

音色量程在 3.4.0 已改为 **±12 dB**（配 R48/R49），R53 沿用。

### 不要烧的版本

| 版本 | 问题 |
|---|---|
| **R38** | 实板 **S1/S2 随机自鸣** |
| **R39** | 实板 **S2/S3 随机自鸣** |
| R36 | 正常但录音空（`PCM_TAP=0`），**最稳回退点** |
| R33 | 最可靠但无音量控制 |

### R40 做了什么

R38、R39 都自鸣，所以 R40 换了根因假设：**不是"某个信号被引出"，而是新增逻辑的体量挤动了音频核布局**。
佐证：R30 只改 place 策略就出过第二弦异常；R38→R39 大改结构后只是换了哪根弦响。

于是 R40 把录音抽头的逻辑量从 **250 LUT 砍到 98 LUT**：新增 `rec_tap_u8.v`（3 位抽取计数器 + 8 位寄存器，`byte = {~pcm[15], pcm[14:8]}`），顶层 `u_rec_tap` 从 `rec_ladpcm` 换成它。

代价写在 `known_limits` 里，要知道：
**8 位线性截断直接丢低 8 位，弱音会丢。** 仿真段 pcm 只有 ±30，取高字节后全是 0x80；实板能听见但粗糙。这是刻意的——本轮先验证"逻辑量"这个假设。

时序和资源反而全面优于 R36：setup **+2.740**（R36 +2.587）、hold **+0.179**（+0.130）、Fmax **58.847**（58.505）、CLS **25014**（比 R36 的 25113 还少 99）。

### 上板怎么判（`known_limits` 给的决策树）

1. **不自鸣了** → 假设成立，下一版加对数压缩（sign + 3 位指数 + 4 位尾数，约 +30 LUT）补回动态范围
2. **仍自鸣** → 这条路走不通，必须先做"降 CLS 给音频核留隔离区"，不再拿板子试

首查项：**上电不演奏，静听 30 秒**有没有自鸣/底噪。

### 一个必须说明的偏差

**没有偏差。** 本机 `firmware.bin` 与 `R54_.../firmware_3.5.10.bin` SHA256 完全一致（`FBF9B098…`，864,384 B），两边随便用哪个都行。之前我加的禁缓存响应头、3.3.1~3.3.6 的诊断、3.3.7 的编码器支持，都已进入官方包。

### 烧完会自动回读板上版本

`Hash of data verified` 只证明字节写进去了，**不证明它能跑起来**（分区表/启动链有问题时照样烧得进）。所以脚本在烧录成功后会自己复位板子、抓 6 秒启动日志里的 `[fw] X.Y.Z`，和刚烧的版本对照：

```
┌─ 板上实读确认（复位后 6 秒）──────────────
│ 期望版本：3.5.4
│ 实际版本：3.5.4   ✓ 一致
└────────────────────────────────────────────
```

不一致会明确写 `✗ 不一致`，没抓到 `[fw]` 行则提示"板子没启动/串口被占/启动链不完整"。
不想多等这 6 秒就加 `--no-verify`。

### 面板联调：一条命令看四个旋钮通不通

```powershell
python tools\flash_tool.py --watch-enc
```

复位后 25 秒内实时打印串口里的 `[enc]` 行，并提示你依次短按/长按哪个旋钮，最后汇总判读：

```
│ ENC3 短按换弦        ✓ 收到 1 次
│ ENC4 短按旁路        ✓ 收到 1 次
│ 长按复位             — 没收到
│ 静音态转 ENC1        — 没收到
```

注意：**转动本身不在串口打印**（走网页的 `state.enc`），所以这个命令验证的是短按、长按、换弦、旁路、静音态音量这些会打日志的动作。想验证"转"就看网页的「面板累计格数」。

### 接线自检：判定排线方向（3.5.10 新增）

```powershell
python tools\flash_tool.py --encprobe          # 默认采样 8 秒
python tools\flash_tool.py --encprobe --encwait 12
```

走的不是串口，而是 WiFi：读板上的 `/encprobe` 端点，拿 12 个编码器 GPIO 各自的**累计边沿数**。
**只转最左那颗旋钮约 5 格**，然后看哪两个数在涨：

| 在涨的脚 | 结论 |
|---|---|
| `18 / 19`（ENC1_A/B） | 排线是 **1↔14 反序**，当前 `kPins` 表正确，旋钮已对位 |
| `32 / 33`（当前表里是 ENC4） | 排线是 **1-1 同向**，整组倒转：要么重压一条反序线，要么把 `kPins` 改成 `{39,33,32} {36,27,26} {35,25,23} {34,19,18}` |
| `34`（ENC1_SW） | **A 与 SW 接反**：转被当成按压（会莫名换弦/切旁路） |
| 全是 0 | 面板没通：先查 GND、排线是否插到底 |

前提只有一个：**电脑连在 ESP32 热点 `Tang60K-Music` 上**（密码 `tang60k2026`）。
连不上时脚本会直接说明，不会装死。手机上也可以直接开 `http://192.168.4.1/` 看「面板接线自检」卡片，效果相同。

### 脚本会自动告诉你该配哪个位流

`tools/flash_tool.py` 用"某个 R* 目录里同时有 `firmware_<版本>.bin` 和 `.fs`"来判定配对关系，所以不用维护版本表。而且 3.5.3 起它会**读 manifest 判断位流到底有没有重建**：

- 该版重建了位流 → 提示"必须成对"
- 该版只改 ESP32（manifest 里 `firmware_sha256` 与当前固件 SHA 不同）→ 提示**不用重烧**

当前 3.5.10 属于后者，`--list` 和烧录成功后都是这一句：

```
┌─ FPGA 位流这次不用重烧 ────────────────────────────
│ 位流目录：R53_回退R51_网页优化_20261103
│ 位流文件：烧录_R53_回退R51_网页优化_20261103.fs
│ 该版只改 ESP32（面板/网页/诊断），位流没重建。
│ 板上已是这一版 .fs 的话，直接开网页就行。
└────────────────────────────────────────────────────
```

要严格对齐官方包，用 `python tools\flash_tool.py --bin 3.3.0` 烧回去即可（但网页会重新被浏览器缓存）。

### 历史位流

R36（`EC7FA718…`）、R33（`DC27CACB…`）、R24（`540FF0DD…`）。能力差异见 `ESP32功能与使用.md` 第 3 节。

---

## 六、烧不进去查这几条

| 现象 | 原因 | 处理 |
|---|---|---|
| 串口列表里没有 ESP32 | 线是纯充电线 / 插在 Tang 板上 / 驱动没装 | 换线；确认插 ESP32 的 Type-C；装 CP210x 或 CH340 驱动 |
| `could not open port` / `Permission denied` | 串口被占用 | 关掉 `看日志.cmd` 窗口、串口助手、其它 IDE |
| `Failed to connect: Timed out waiting for packet header` | 没进下载模式 | 按住 **BOOT**，点一下 **EN/RST**，松开 BOOT，重跑 |
| `A fatal error occurred: Invalid head of packet` | 波特率太高 | `--baud 460800` 或 `115200` |
| 烧完不断重启 `RTCWDT_RTC_RESET` | 分区表与 Flash 不匹配 | 先全片擦除 `pio run -t erase --upload-port COM7`，再全烧 1~4 |
| 烧完不启动、串口无输出 | 漏了 `boot_app0.bin`（0xE000） | 全烧 1~4 |

全片擦除：

```powershell
pio run -t erase --upload-port COM7
```

---

## 七、验证边界

| 结论 | 状态 |
|---|---|
| 分区地址（0x1000/0x8000/0xE000/0x10000/0x290000） | **已验证**：解析 `.pio/build/esp32dev/partitions.bin` 得出，见第四节 |
| esptool 参数名 | **已验证**：`esptool.py write_flash --help`（4.5.1）实际输出 |
| esptool 在系统 Python 3.14.6 下可运行 | **已验证**：`python.exe esptool.py version` → `v4.5.1` |
| 文件清单、大小、存在性 | **已验证**：`flash_tool.py --list` 实跑输出 |
| 选串口 / 选文件 / 编译 / 确认 全流程 | **已验证**：实跑一次，走到「确认烧录到 COM16？(y/N)」并输入 n 中止，未真烧 |
| **真正写入 ESP32 Flash** | **未验证**：ESP32 至今未插入本机 |

最后一条是唯一的空白。插上板子后跑 `--list`，把输出发我，我确认它认对了口再烧。
