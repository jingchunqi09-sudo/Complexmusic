# 硬件

本目录包含自研板卡的 EDA 工程、机械结构、引脚与接线定义，以及硬件验证记录。

---

## 一、目录

| 路径 | 内容 |
|---|---|
| `boards/` | 5 块自研板的嘉立创 EDA 工程（`.epro2`）+ 3 份原理图 PDF |
| `bow-module-3d/` | 琴弓传感器模块的 3D 结构（OpenSCAD 参数化模型 + 四视图 + 尺寸表） |
| `pinout.md` | **引脚表**，含 EC11 排线方向的实测反推过程 |
| `wiring.md` | 外设清单、接线表、上电检查清单 |
| `bow-pcb-guide.md` | PMW3360 画板设计建议（光学结构、LDO、封装） |
| `left-panel-validation.md` | 左手灯板（SK9822）与 ADC 原码监视的调试方法 |
| `display-hardware-review.md` | 显示硬件选型与走线评审 |

---

## 二、自研板卡

5 个 `.epro2` 工程 + 3 份原理图：

| 工程 | 对应硬件 | 大小 |
|---|---|---|
| `ProPrj_琴身左手采样加指引模块_2026-11-04.epro2` | 左手电极板 + 灯带指引（最大的一块） | 3.4 MB |
| `ProPrj_四弦压电采集板_2026-11-04.epro2` | 4 路压电前端 | 488 KB |
| `ProPrj_琴弓模块_2026-11-04.epro2` | PAW3395 光学传感器模块 | 405 KB |
| `ProPrj_电源端子转接板‘_copy_2026-11-04.epro2` | 电源 / 端子转接 | 652 KB |
| `ProPrj_无源操作面板_2026-11-04.epro2` | 4×EC11 操作面板 | 163 KB |
| `主控板.pdf` | 主控板原理图 | 263 KB |
| `右手压电陶瓷片采集.pdf` | 压电采集原理图 | 256 KB |
| `左手adc采集.pdf` | 左手 ADC 采集原理图 | 1.3 MB |

> 板卡与功能的对应关系按工程名整理。若与实际不符，以工程内部命名为准。

### 怎么打开 `.epro2`

`.epro2` 是**嘉立创 EDA 专业版（LCEDA Pro）**的工程包，本质是 zip 容器：

```
project2.json     工程元数据
<名称>.epru       设计数据（原理图 + PCB + 封装）
IMAGE/*.webp      预览图
```

打开方式：LCEDA Pro →「文件 → 打开工程」→ 选择 `.epro2`。

打开后可导出 Gerber、BOM、坐标文件（Pick&Place），直接下单打样。

> 三个 PDF 是原理图的**只读导出**，适合快速查阅，不能编辑。

---

## 三、引脚定义的权威来源

**`../fpga/constraints/tang_mega_60k.cst` 是唯一权威**，`pinout.md` 与 `wiring.md` 是导读。

原因：`.cst` 直接参与综合，改错会报错；文档可能滞后。

关键约定：

- `reset_n` / `mode_n` 落在 **Bank9（1.5 V）**，不能接 3.3 V 信号；
- `uart_tx_o` / `uart_rx_i` 均设 `PULL_MODE=UP`，避免 ESP32 复位期间 TX 悬空被误判为起始位；
- HDMI 差分对 `DRIVE=3.5`、`PULL_MODE=NONE`，不要手改；
- `.cst` 的 `IO_PORT` 行分隔符是**空格**且必须带 `BANK_VCCIO=3.3`（逗号会报 `CT2000`）。

---

## 四、机械结构

`bow-module-3d/` 提供琴弓传感器模块的**首版结构草稿**：

| 文件 | 用途 |
|---|---|
| `bow_sensor_module_draft.scad` | 参数化 OpenSCAD 模型，改参数后可直接导出 STL/3MF |
| `bow_sensor_module_4views.svg` | 可缩放四视图（等轴测、俯视、侧视、爆炸图），含尺寸线 |
| `bow_sensor_module_dimensions.csv` | 尺寸、单位、状态与来源 |
| `bow_sensor_module_geometry.json` | 供 CAD/脚本读取的坐标约定、零件包络、接口定义 |

> 这是**结构草稿，不是可直接加工的生产图**。加工前需按实际传感器、透镜与弓杆尺寸复核。

---

## 五、硬件验证记录

| 文档 | 内容 |
|---|---|
| `left-panel-validation.md` | 左手板 SK9822 灯带逐灯测试、ADC 原码监视、LH3 串口协议 |
| `display-hardware-review.md` | 显示链路选型与走线评审 |
| `../docs/board-validation.md` | 板级验证记录（器件、封装、原理图页对照） |
| `../docs/left-hand-latency.md` | 左手采集链的延迟预算与信噪比定量分析 |

实拍照片见 [`../docs/images/photos/`](../docs/images/photos/)。
