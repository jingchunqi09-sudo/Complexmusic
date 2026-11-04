> 历史研究/方案。2026-10-02第二轮已实现部分声音改进、原模拟器A5直连和HDMI；当前状态以 [第二轮报告](implementation_revision2_20261002_cn.md) 和 [README](../README.md) 为准。本页未实现状态属于当时版本。

# 屏幕接口与 60K 引脚核对记录

日期：2026-10-02。状态：**研究与设计记录，显示功能尚未接入当前 RTL；未修改约束、时钟、位流，也未连接屏幕测试。**

## 1. 接口结论

建议第一版走 **NEO Dock 的 HDMI Type-A 口 → 屏幕 HDMI 输入**。若屏幕实际接口是 mini-HDMI，应使用 HDMI Type-A 至 mini-HDMI 线；屏幕另用其规定的 USB-C 电源供电。完整屏幕型号及支持的输入模式仍须以铭牌、说明书或 EDID 核实，不能仅凭订单截图保证兼容。

用户提供的 Dock 原理图第 15 页表明：J29 的三组 TMDS 数据差分对与一组时钟差分对，通过保护和耦合电路直接连接 FPGA；**该路径没有 SiI9022A 等 RGB 至 HDMI 桥接芯片**。因此需要在 FPGA 内生成视频时序、RGB、TMDS 编码和串行输出。

Dock 的 Type-C 有不同职责：

| 接口 | 原理图证据 | 实际职责 | 对本屏幕的用途判断 |
|---|---|---|---|
| J7 调试 Type-C | Dock 第 8 页 | BL616 的 USB-JTAG、UART 和电源输入 | 电脑下载、串口调试；不提供视频输出 |
| P1 USB3 Type-C | Dock 第 20、21 页 | USB 信号经 VL162 切换到 CH569，再通过 HSPI 与 FPGA 通信；电源方向标注为输入 | 没有画出 DisplayPort Alt Mode 视频发送路径，不能当 USB-C 显示输出 |
| J29 HDMI Type-A | Dock 第 15 页 | FPGA 直接 TMDS；可由方向控制电路选择 TX/RX | 本轮推荐用于屏幕视频输入，设计为 TX |

两处 Type-C 的原理图都标注电源输入方向。不能依连接器形状把它们当屏幕电源输出；HDMI 第 18 脚的 +5V 也不是便携显示器的主电源。

Sipeed 官方资料确认 60K 与 138K 使用同一 NEO 底板，但核心板球位必须分别核对：[60K 官方说明](https://wiki.sipeed.com/hardware/zh/tang/tang-mega-60k/mega-60k.html)。本记录没有直接继承 Dock 图中 138K 的球位标注。

## 2. 60K PG484A 映射

核对方式：视觉阅读 Dock 第 7、8、15、20 页，60K 核心板第 1、4、5 页，并与官方 60K `cam_dvi` 的 [NEO_DOCK.cst](https://github.com/sipeed/TangMega-60K-example/blob/main/cam_dvi/src/NEO_DOCK.cst) 对照。连接器脚号对应的是物理 BTB 接触位置。

| 信号 | Dock BTB → 核心板 BTB | 60K 球位 | 60K Bank | 备注 |
|---|---|---|---|---|
| TMDS D2 正 / 负 | J1 52 / 50 → C2399 52 / 50 | K17 / J17 | 5 | 红色分量；与 138K Bank 编号不同 |
| TMDS D1 正 / 负 | J1 56 / 54 → C2399 56 / 54 | J15 / H15 | 4 | 绿色分量 |
| TMDS D0 正 / 负 | J1 60 / 58 → C2399 60 / 58 | J14 / H14 | 4 | 蓝色分量及消隐期同步控制 |
| TMDS CK 正 / 负 | J1 64 / 62 → C2399 64 / 62 | G15 / G16 | 4 | 视频时钟差分输出 |
| DVI_ALT / DIR_SEL | J2 63 → C2400 63 | K14 | 4 | 原理图定义 1=TX、0=RX，管理方向与电源开关 |
| DVI_A_HPD | J2 65 → C2400 65 | K13 | 4 | HDMI HPD 经 5.1kΩ / 10kΩ 网络连接 FPGA |
| DDC SCL | J2 32 → C2400 32 | M13 | 5 | 经电平转换连接 HDMI SCL |
| DDC SDA | J2 34 → C2400 34 | L13 | 5 | 经电平转换连接 HDMI SDA |
| 已配置 MS5351 USR_CLK_IN | J2 90 → C2400 90 | V13 | 7 | 用户已设置 1.536MHz，保留用于未来音频时钟方案 |

官方 60K 示例对 TMDS 相关 I/O 指定 Bank VCCIO=3.3V，差分 I/O 类型由 DVI TX IP / 输出原语管理。实际集成前仍需确认实物电压开关、焊接配置与 Bank4/5 供电一致，不能把 TMDS 输出替换成普通单端 `LVCMOS33` 高速翻转。

DDC 应使用开漏读写并遵循屏幕应答；不应向 SDA/SCL 推挽输出高电平。HPD 在发送器设计中用于判断显示器是否存在。官方示例将 K13 命名 `hpd_en` 并恒置高，这个做法不能直接作为本项目的插拔检测逻辑；应先按原理图区分 **K14 的 TX 方向控制**与 **K13 的 HPD 状态**。

上述 HDMI 球位与当前工程 UART、PT8211、三路 SPI 和延迟 GPIO 的 CST 球位没有重叠；V13 也不与它们重叠。引脚不冲突不等于时钟网络、输出电气条件和综合时序已经验证。

## 3. 视频时钟与实现入口

推荐候选 profile 为 **1280×720，60Hz**，屏幕接受该模式后由屏幕自身缩放。其标准时序需要 74.25MHz 像素时钟、5 倍的 371.25MHz 串行器时钟，TMDS 每个数据通道为 742.5Mbit/s。这组频率是设计需求，**本轮尚未通过当前机器的 IP Generator、VCO 检查和 PNR/STA 验证**。

不要用音频的 1.536MHz 时钟充当视频像素时钟，也不要为了显示直接改动用户已设好的 MS5351 输出。官方 60K `cam_dvi` 的 [top.v](https://github.com/sipeed/TangMega-60K-example/blob/main/cam_dvi/src/top.v) 将 V22 上的 50MHz 输入送入 `TMDS_PLL`，由其提供像素时钟与五倍串行时钟；该顶层和 CST 没有依赖 V13。优先沿这个独立视频时钟结构设计。

可参考的实现入口及限制：

| 入口 | 已核对内容 | 可借鉴内容 / 限制 |
|---|---|---|
| [Sipeed 60K cam_dvi](https://github.com/sipeed/TangMega-60K-example/tree/main/cam_dvi) | README 写明 720p60/30、直接 TMDS、DDR3 图像缓冲；已阅读顶层、CST 与 DVI TX IPC | 60K 器件适配、连接和视频输出入口；本项目初期不需要搬入摄像头和整帧 DDR3 链 |
| [DVI TX IP 配置](https://github.com/sipeed/TangMega-60K-example/blob/main/cam_dvi/src/dvi_tx/DVI_TX_Top.ipc) | 指定 gw5at60b、外部时钟和 TLVDS；源目录有加密 `.vo` | 可以封装成器件适配层；不能称全部底层为开放 RTL |
| [Sipeed dvi_colorbar](https://github.com/sipeed/TangMega-60K-example/tree/main/dvi_colorbar) | 本轮查看时 README 仅 `TBD` | 不作为现成可运行工程的交付证据 |
| [Project F display_controller](https://github.com/projf/display_controller) | Verilog、MIT；包括时序、TMDS 编码及测试模型 | 可学习可移植编码器 / 验证方法；其 Xilinx 串行器与 PLL 不能直接复制到 Gowin |

官方 `cam_dvi` 目录包含 60Hz/30Hz 的 PLL 参数文件，但本轮这些文件的具体内容未成功取回，不能断言它恰好生成 74.25MHz 而非邻近值。集成阶段需在当前 Gowin、GW5AT-60B、PG484A 下重新生成 / 核准 PLL 与输出原语。

[Gowin IPUG938-2.5.2E](https://www.gowinsemi.com/upload/database_doc/2720/document/69cab0e35c660.pdf) 给出单链路 DVI TX、10–80MHz 像素时钟范围、串行时钟为像素时钟的五倍，源代码交付形式含加密 Verilog。该范围与官方 60K 720p 示例支持选取 720p 作为候选，不能推导出本板能直接输出 2.5K 180Hz。文档列出的其他器件参考速率也不能替代 60K 的实测和时序报告。

官方示例仓库的普通代码采用 Apache-2.0；Gowin 生成 IP 的交付和许可仍须遵循其自己的 [IP 使用条款](https://www.gowinsemi.com/en/support/ip/?page=14)。本方案核心状态接口、捕获与绘制可以保持 Verilog-2001，Gowin PLL / 差分输出 / 串行器放在独立适配层。

## 4. 资源和验收边界

初期四弦、品位、弓位、文字和波形是规则图形，可以用坐标生成器、字模 ROM、状态快照及小型波形 RAM 绘制，不必先引入整帧 framebuffer。720p RGB565 单帧仅像素载荷就需 1,843,200 字节；双缓冲为 3,686,400 字节，应与未来摄像头一起规划 DDR3。

显示必须旁路观察音频：音频产生 PCM 和事件状态后写入有限缓冲；屏幕忙时允许丢显示更新、显示旧快照并报告年龄，不能反压声部计算或 PT8211 输出。屏幕上的 PCM 图形是数字输出波形，不是扬声器声压或 DAC 模拟电压。显示刷新延迟也不能混入 FPGA 事件至 DAC 字发送完成的延迟计数。

当前工程已有 PNR 的 50MHz setup 最小余量约 0.033ns，存在 V22 相关 PR1014 警告。资源报告的 PRIMARY/LW 计数各为 8/8，其中还含使能、地址或复位等全局网络；这不能解释为八个独立时钟或所有 PLL 已耗尽，但说明加显示前必须审计全局网络分配与时钟路由。当前音频工程的时序结论不能直接继承给显示集成工程。

进入实现前 / 后的必要证据：

1. 型号、视频接口和供电要求，EDID 支持的 720p60 或备选模式；480p 仅作候选排错 profile，不保证本屏幕一定接收。
2. 实物 Bank 电压、HDMI TX 控制、DDC / HPD 与适配后完整 CST。
3. 视频 PLL、OSER10 / 输出原语合法性；相关时钟约束和跨域接口检查。
4. 加显示后的资源、setup/hold、全局网络分配与 DAC 连续样本检查。
5. 色条、文字、四弦状态、波形和延迟数值的实屏逐步测试，再验证满负荷显示不会丢音或改变音频延迟。

本轮完成硬件和官方入口核对；上述显示功能、时钟生成、EDID / HPD 管理和资源结果均尚未实现或验收。
