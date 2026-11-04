# R54 烧录说明

> 位流与固件**必须成对烧**。R54 位流配 3.5.10 固件是经过实板验证的组合。

本目录内容：

| 文件 | 说明 |
|---|---|
| `R54-bitstream.fs` | 发布位流（20,778,247 B） |
| `firmware_3.5.10.bin` | **推荐固件**（引脚表正确） |
| `firmware_3.5.8.bin` | 原始配对固件，引脚表反序，四旋钮会错位 |
| `firmware_3.5.13.bin` | 最新固件，状态帧长度不同，配 R54 可能显示不完整 |
| `SHA256SUMS.txt` | 校验和与配对说明 |

---

## 〇、先校验（可选但建议）

```powershell
cd releases\R54
certutil -hashfile R54-bitstream.fs SHA256
```

期望：`E99C65950C8BD723AB60F8D0457FBD6872367CD066CD1B8DFBD5552E8A67EDC1`

---

## 一、烧位流（FPGA）

工具：**Gowin Programmer**（Gowin EDA 自带）

| 项 | 值 |
|---|---|
| 文件 | `R54-bitstream.fs` |
| 器件 | GW5AT-LV60PG484AC1/I0（Gowin Programmer 里显示 `GW5AT-60`） |
| 目标 | 外部 Flash（`External Flash Mode`），不是 SRAM |
| 时钟 | 50 MHz |

步骤：

1. 打开 Gowin Programmer，Scan Device 识别到 `GW5AT-60`；
2. 添加 `R54-bitstream.fs`，Operation 选 `External Flash Mode`；
3. 勾选 `Verify`，Program；
4. 断电重上电（不要只按复位，Flash 模式需要重新加载）。

> `firmware/tools/flash_tool.py` 是 **ESP32 烧录工具**，不能烧 `.fs`。

---

## 二、烧固件（ESP32）

工具：`firmware/tools/flash_tool.py`（随仓库提供）。

### 2.1 安装依赖

```powershell
pip install esptool pyserial
```

### 2.2 找串口

```powershell
cd firmware
python tools\flash_tool.py --list
```

判据（重要）：

- `1A86:7523` = 板载 CH340，**这是 ESP32 的烧录口**；
- `0403:6010` = FT2232H，是 FPGA 板载调试器，**必须排除**；
- ESP32 的 COM 口号每次插拔都可能变化，不要写死。

### 2.3 烧录

```powershell
cd firmware
python tools\flash_tool.py --bin "..\releases\R54\firmware_3.5.10.bin" --yes
```

或双击 `firmware\烧录_R54_3.5.10.cmd`（用 `--bin 3.5.10` 版本号；`flash_tool.py`
会在 `../releases/R*/` 下自动找对应的 `firmware_*.bin`，不用写全路径）。

> 验证过：`--bin 3.5.10` → `releases/R54/firmware_3.5.10.bin`。

### 2.4 验证

烧完工具会自动复位并抓启动日志里的 `[fw] 3.5.10` 做比对。
手动确认：串口 115200 应打印 `[fw] 3.5.10` 与 WiFi 热点名。

---

## 三、上电自检顺序

| 步骤 | 现象 | 判据 |
|---|---|---|
| 1 | HDMI 出图 | 720p 画面，底部参数面板有数值 |
| 2 | WiFi 热点出现 | 手机连上后打开工作台网页 |
| 3 | 拨弦 | 对应弦的波形通道跳动、发声 |
| 4 | 拉弓 | 弓位随弓移动，触弦点亮 |
| 5 | 按品 | 左手指示灯与屏幕品框响应 |
| 6 | 上传曲谱 | 播放时 GUIDE 页出现琥珀色弦线指引 |

> 第 6 步是 R54 的核心新增功能：尤克里里（lane 4..7）的弦指引。
> 实板截图见 [`../../docs/images/evidence/`](../../docs/images/evidence/)。

---

## 四、常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 一字节都收不到 | TX/RX 未交叉，或未共地 | ESP32 GPIO17→E14、GPIO16←E13，**必须共地** |
| 四颗旋钮位置全错 | 固件用了 3.5.8 的反序引脚表 | 换 3.5.10 |
| 某根弦一直自鸣 | R54 的 `paw3395_driver` 带 MOT=0 缺陷 | 见 [`../../docs/version-history.md`](../../docs/version-history.md)「R59」；R54 上偶发，松手后重拉一次可复位 |
| 混响关不掉 | 旁路状态由 ESP32 保持，重烧 FPGA 不会清 | 网页点一次「关闭混响」 |
| 屏幕指引不出现 | 曲谱 lane 全落在 0..3 | 检查网页 MIDI 分弦是否用了尤克里里定弦 |
| 屏幕画面偏移或撕裂 | 非 720p 显示器 | 本设计固定 1280×720@60Hz |

引脚与接线细节见 [`../../hardware/pinout.md`](../../hardware/pinout.md)。
