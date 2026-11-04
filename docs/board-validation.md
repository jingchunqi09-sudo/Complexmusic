# Tang Mega 60K 板级验证记录

## 1. 本版硬件对象

主工程针对用户提供的 **Tang Mega 60K 核心板**，不是 138K FPGA。核心原理图 `tang_mega_60k_30354_schematics..pdf` 共 7 页，第 5 页 FPGA 符号为 `GW5AT-60K-PG484A`。Gowin 工程因此选用：

- 器件：`GW5AT-60B`
- 封装：`PBGA484A`
- 完整型号：`GW5AT-LV60PG484AC1/I0`
- Gowin 设备编号：`gw5at60b-002`

`Tang_Mega_NEO_Dock-138K_31005_Schematics.pdf` 是底板原理图。这里使用它确认 Dock 的 PT8211、按键、UART 和外接连接器网络，再按 **BTB 插座脚号** 对照 60K 核心板第 1 页，得到 60K 的实际球位。不能把底板页面上的 138K BANK 名直接复制到 60K 约束。

旧本地工程 `Tang mega 60k_96` 使用 `GW5AT-EV60UG324SC2/I1`，与用户提供的 PG484A 核心板原理图不同，本版不采用那个封装。

## 2. 板载时钟、串口、音频和复位

| RTL 端口 | 60K 球位 / BANK | 物理路径 | 电平 |
|---|---|---|---|
| clk_50m | V22 / 7 | 核心板第 2 页 Y1100 50 MHz 晶振，BANK7_V22_EMCLK_50M | 3.3 V |
| uart_rx | V14 / 8 | 核心 JTAG 8-pin UART RX；Dock FPGA_UART.RX；BTB C2400 pin 54 | 3.3 V |
| uart_tx | U15 / 6 | 核心 JTAG 8-pin UART TX；Dock FPGA_UART.TX；BTB C2400 pin 50 | 3.3 V |
| hp_bck | Y17 / 7 | Dock U16 PT8211 BCK；I2S_BCLK；BTB C2400 pin 26 | 3.3 V |
| hp_ws | AB17 / 7 | Dock U16 PT8211 WS；I2S_LRCK；BTB C2400 pin 28 | 3.3 V |
| hp_din | AA16 / 7 | Dock U16 PT8211 DIN；I2S_DIN；BTB C2400 pin 30 | 3.3 V |
| pa_en | AB16 / 7 | Dock PA_EN，低电平开启功放；BTB C2400 pin 36 | 3.3 V |
| reset_n | AA13 / 9 | Dock EX_KEY.0 用户按键，按下接地；BTB C2400 pin 60 | **1.5 V** |

证据页：

- 核心板第 1 页：C2400 BTB 连接器。
- 核心板第 2 页：晶振、JTAG/UART 连接器。
- 核心板第 5 页：BANK 6/7/8 实际 FPGA 球位。
- 核心板第 3 页：BANK 9/10/11 的 1.5 V DDR3 电压域。
- Dock 第 7 页：音频、UART、EX_KEY.0 至 BTB 的脚号。
- Dock 第 9 页：用户按键接地结构，需要 FPGA 内部上拉。
- Dock 第 10 页：PT8211 和功放网络；PA_EN=1 关，PA_EN=0 开。

RESET_N 使用用户按键，不能映射到核心板 N12 RECONFIG。RECONFIG 触发 FPGA 重新装载，不是普通逻辑复位。复核时也明确排除了 AA14：AA14 在 Dock 是摄像头 I2C 时钟 CAM_TWI.SCL，不能作为本版复位键。

PT8211 输出是三线、16-bit、右对齐格式。底板网络名含 I2S 不代表器件采用标准 I2S 的一位延迟格式。本版 PT8211 驱动必须按器件实际协议验证。

## 3. 三片独立 SPI ADC 与延迟测量 GPIO

ADC 型号与用户未来主控板尚未冻结，本版选择 Dock **J13 SDRAM0 扩展排针的裸 GPIO** 作为临时引脚方案。三个 SPI 控制器保持独立；每片 ADC 各有 SCK、MOSI、MISO、CS_N。

| RTL 端口 | J13 脚号 / 网络 | BTB C2399 脚号 | 60K 球位 / BANK |
|---|---|---|---|
| adc0_sck | 1 / SDRAM0_D0 | 65 | E14 / 1 |
| adc0_mosi | 2 / SDRAM0_D1 | 67 | E13 / 1 |
| adc0_miso | 3 / SDRAM0_D2 | 59 | C15 / 1 |
| adc0_cs_n | 4 / SDRAM0_D3 | 61 | C14 / 1 |
| adc1_sck | 5 / SDRAM0_D4 | 53 | B13 / 1 |
| adc1_mosi | 6 / SDRAM0_D5 | 55 | C13 / 1 |
| adc1_miso | 7 / SDRAM0_D6 | 47 | A14 / 1 |
| adc1_cs_n | 8 / SDRAM0_D7 | 49 | A13 / 1 |
| adc2_sck | 18 / SDRAM0_D8 | 7 | B21 / 2 |
| adc2_mosi | 17 / SDRAM0_D9 | 5 | A21 / 2 |
| adc2_miso | 16 / SDRAM0_D10 | 13 | B20 / 2 |
| adc2_cs_n | 15 / SDRAM0_D11 | 11 | A20 / 2 |
| latency_event_gpio | 14 / SDRAM0_D12 | 37 | A15 / 1 |
| latency_audio_gpio | 13 / SDRAM0_D13 | 35 | A16 / 1 |

映射方法：Dock 第 19 页 J13 网络 → Dock 第 7 页 J1 插座脚号 → 60K 核心板第 1 页 C2399 相同脚号 → 核心板第 4 页实际球位。这样不会误用 138K BANK2 对应球位。

J13 pin 12 为 GND，pin 11 为 **5V_Peripheral**，不要把 pin 11 当成 ADC 的 3.3 V 电源。ADC 电源和 SPI 逻辑电压应按最终器件要求单独布置并共地。

本版 J13 GPIO 使用 3.3 V。核心板第 6 页 BANK1/2 的 VCCIO 来自 Dock；Dock 第 2 页电源树注明 1.8 V 分支电阻默认 NC，默认使用 3.3 V。若实物修改过 VCCIO 电阻选择，必须同时调整 CST 的 IO_TYPE 与 BANK_VCCIO。

这些引脚是 **SDRAM0 外接扩展接口**，不占用核心板已经焊接的两片 DDR3。后续若在 J13 插入 SDRAM 模组或其他扩展卡，必须先重新分配 SPI 和延迟 GPIO，不能同时驱动同一条线。当前也没有占用 SDRAM1/PMOD/摄像头、MicroSD 或配置 Flash 接口。

## 4. 电平与时序约束边界

核心板第 6 页给出 BANK6/7/8 的 VCCIO678 由 3V3 供电。因此本版时钟、UART、PT8211 全部约束为 LVCMOS33；旧 `930` 工程将这些线写为 LVCMOS15，与用户提供的本版核心原理图不符，不能直接沿用。

`constraints/tang_mega_60k.sdc` 的系统时钟为 50 MHz / 20 ns。UART 和用户复位为异步输入，设计中同步后使用；没有把 UART、SPI SCK 或 PT8211 BCK 当成内部逻辑时钟。

MISO 各经过两级寄存器同步，控制器将 SCK 半周期分频夹限到至少 4 个系统周期。外部芯片的返回时钟没有当作 50 MHz 系统时钟处理；SDC 排除外部 MISO 到第一级同步寄存器的捕获路径，后续同步寄存器及移位采样路径仍参与 STA。SPI 输出预算为最大 5 ns、最小 0 ns。

在默认 50 MHz 下，外设 clock-to-output、走线及输入建立时间合计必须落在 `(半周期分频−2) × 20 ns` 的返回稳定预算内。最小分频 4 留出约 40 ns；默认分频 8 留出约 120 ns。这是接口的设计预算。**尚未选定 ADC，不能证明具体芯片满足预算或最大 SCK。** 确定型号后应核对实际收发时序并用逻辑分析仪验证。SPI 测试覆盖四模式、自动最小分频夹限和非零返回延迟，但不替代芯片数据手册。

系统 50 MHz 寄存器路径的 Gowin STA、外围 ADC 时序、实际控制至 DAC 延迟是三类不同证据。某一项通过不能代替另两项。

## 5. 直接运行测试的范围

本版顶层共有 22 个物理信号：时钟/UART/复位 4 个、PT8211/功放 4 个、三路 SPI 12 个、延迟 GPIO 2 个。所有物理端口在 CST 中都有明确球位。

UART 使用经过检查的控制包注入音符与琴弓/拨弦事件，支持延迟状态和原始 SPI 响应回读。由于 ADC 型号与扫描帧格式尚未冻结，原始 SPI 响应没有自动冒充已正确解码的 48 品或压电数据。把真实 ADC 接到本版时，需要补齐针对其协议的 adapter。

构建产物和 STA 结论由实际 Gowin 运行日志决定。本文记录引脚与电平依据，不宣称已经进行实板烧录、实际声音试听、外围芯片验证或示波器延迟测量。

## 6. 工程与工具

- 主工程：`tang_mega_60k.gprj`
- 引脚约束：`fpga/constraints/tang_mega_60k.cst`
- 时序约束：`fpga/constraints/tang_mega_60k.sdc`
- 构建脚本：`tools/build/gowin_build_60k.ps1` / `gowin_build_60k.tcl`
- 烧录步骤：见 `releases/R54/README.md`
- 工具链：Gowin EDA V1.9.12.03（安装路径因人而异）

脚本默认使用 GW5AT-60B，并优先 SRAM Program and Verify 进行可恢复的现场测试。持久化 Flash 烧录须使用同一块 60K 核心的构建产物。

