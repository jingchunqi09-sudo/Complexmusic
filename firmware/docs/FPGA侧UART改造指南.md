# FPGA 侧 UART 改造指南

> 适用基线：`00_首页_最新版本/R5_四弦独立_20261028/`
> 目标：让 FPAG 通过 E13/E14 与 ESP32 交换数据，使手机端看到真实数据、能下发控制。
>
> **本文所有步骤我未在实机综合验证**（本轮按你的要求不动 FPGA 代码），代码依据来自 `archive/physical_20261025/legacy_uart_src/` 的既有实现与 R5 顶层结构。请按第 7 节逐项验收。

---

## 1. 先明确一件事：R5 现在没有 UART

证据（三条，互相独立）：

1. `R5_四弦独立_20261028/src/tang_mega_60k_top.v:3`
   `// CN2/H4/H6 are the only performer inputs. No UART test path is synthesized.`
2. 同文件 10–18 行的端口列表没有 `uart_rx` / `uart_tx`。
3. `constraints/tang_mega_60k.cst:6`
   `// Core 50 MHz crystal; no UART test/control ports in this physical build.`

所以以下不是"改参数"，而是"接回一个被移除的子系统"。R5 的最小 hold 裕量只有 **+0.052 ns**（来源：`R5_四弦独立_20261028/TECHNICAL_REPORT.md`），任何新增逻辑都必须重跑 STA。

---

## 2. 改动清单

| 序号 | 文件 | 动作 | 风险 |
|---|---|---|---|
| 1 | `src/uart_rx_receiver.v` | 从 archive 复制 | 无 |
| 2 | `src/uart_event_bridge.v` | 从 archive 复制 | 无 |
| 3 | `src/uart_status_tx.v` | 从 archive 复制 | 无 |
| 4 | `src/instrument_protocol.vh` | 从 archive 复制 | 无（若无同名文件冲突） |
| 5 | `src/uart_perf_telemetry.v` | **新建**（第 5 节给出完整代码） | 低 |
| 6 | `src/tang_mega_60k_top.v` | 加 2 个端口 + 例化 | 中（改顶层） |
| 7 | `constraints/tang_mega_60k.cst` | 加 E13/E14 约束 | 低 |
| 8 | `tang_mega_60k.gprj` | 新文件加入工程 | 低 |

**分两步走更稳**：先做第 3 节（仅遥测上行，不改演奏逻辑），验证手机能看到真实数据；确认时序通过后再做第 4 节（命令注入）。

---

## 3. 第一步：只做上行遥测（推荐先做）

### 3.1 复制既有模块

> **编者注**：本文写于 2026-10-28，记录当时把 UART 链路接入项目的改造过程。
> 文中路径（`archive/.../legacy_uart_src/`、`00_首页_最新版本/R5_...`）属于当时的
> 工程结构，**本仓库不提供这些目录**。R54 起相关模块已在 `fpga/src/`
> （`uart_rx.v`、`uart_tx.v`、`link_frame_rx.v`、`link_regs.v` 等），
> 下列命令仅作历史参考。

```bash
cd <项目根>
cp archive/physical_20261025/legacy_uart_src/uart_rx_receiver.v \
   archive/physical_20261025/legacy_uart_src/uart_event_bridge.v \
   archive/physical_20261025/legacy_uart_src/uart_status_tx.v \
   archive/physical_20261025/legacy_uart_src/instrument_protocol.vh \
   "00_首页_最新版本/R5_四弦独立_20261028/src/"
```

### 3.2 必须改的一处默认参数

`uart_rx_receiver.v` 第 4 行的默认值是 **217**，那是 230400 波特率对应的分频。115200 时必须显式覆盖：

```verilog
uart_rx_receiver #(.CLKS_PER_BIT(CLKS_PER_BIT_115200)) u_rx(...)
```

其中 `CLKS_PER_BIT_115200 = 50_000_000 / 115200 = 434`（实际 434.03，误差 0.008%，可用）。

**如果不改，收到的每一个字节都是错的**，表现为 ESP32 侧 `ERR` 计数持续增长、手机端永远没有数据。

`uart_status_tx.v` 和 `uart_event_bridge.v` 内部是按 `CLOCK_HZ / BAUD_RATE` 计算的，只要参数传 50 MHz / 115200 就正确，无需改。

### 3.3 顶层加端口

`src/tang_mega_60k_top.v`，在现有端口列表末尾（`hdmi_clock_p,hdmi_clock_n,hdmi_tx_enable` 之后）加两行：

```verilog
    output [2:0] hdmi_data_p,hdmi_data_n,
    output hdmi_clock_p,hdmi_clock_n,hdmi_tx_enable,
    input  esp_uart_rx,     // E14 <- ESP32 TX2（经 R6 33Ω）
    output esp_uart_tx      // E13 -> ESP32 RX2（经 R5 33Ω）
);
```

方向和原理图对应关系（依据 `官方资料/主控板.pdf` 与 `tang_mega_60k.cst:78` 注释）：

```
ESP32 GPIO17 (TX2) --ESP_TX--[R6]--> E14 : FPGA 输入
ESP32 GPIO16 (RX2) <--ESP_RX--[R5]-- E13 : FPGA 输出
```

### 3.4 实例化命令解析器（只解析，不注入演奏总线）

在顶层 `u_physical` 例化之后插入：

```verilog
    // ------------------------------------------------------------------
    // ESP32 命令通道。第一步只解析不注入：ENABLE_LEGACY_PERFORMANCE=0，
    // 弹奏类命令会被判为 frame_error，但调弦/查询/诊断通道可用。
    // ------------------------------------------------------------------
    wire        uart_frame_error;
    wire        uart_tuning_commit;
    wire        uart_tuning_write;
    wire [2:0]  uart_tuning_addr;
    wire [7:0]  uart_tuning_note;
    wire        uart_status_req;

    uart_event_bridge #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(115200),
        .ENABLE_LEGACY_PERFORMANCE(0)
    ) u_uart_cmd (
        .i_clk(clk_50m),
        .i_reset(reset),
        .i_uart_rx(esp_uart_rx),
        .i_open_notes(`INST_DEFAULT_OPEN_NOTES),
        .o_rx_byte_valid(), .o_rx_byte_data(),
        .o_legacy_type(), .o_legacy_index(),
        .o_note_bus(), .o_gate_bus(), .o_pluck_pulse_bus(), .o_stop_pulse_bus(),
        .o_velocity_bus(), .o_bow_speed_bus(), .o_bow_position_bus(),
        .o_direction_bus(), .o_instrument_select_bus(),
        .o_event_pulse(), .o_frame_error(uart_frame_error),
        .o_tuning_write(uart_tuning_write),
        .o_tuning_address(uart_tuning_addr),
        .o_tuning_note(uart_tuning_note),
        .o_tuning_commit(uart_tuning_commit),
        .o_spi_profile_write(), .o_spi_adapter(), .o_spi_field(), .o_spi_value(),
        .o_status_request(uart_status_req),
        .o_diag_request(), .o_diag_index(),
        .o_sensor_snapshot_request(), .o_scope_request(), .o_scope_capture(),
        .o_scope_index(), .o_sensor_snapshot_adapter()
    );
```

> 注意 `u_uart_cmd` 的 `o_status_request` 目前**没有接到 `uart_status_tx`**。如果你只想跑通遥测，可以把 `uart_status_tx` 的 `i_publish` 直接用第 5 节的周期遥测替代，更简单——第 5 节的模块不依赖 `uart_status_tx`。

### 3.5 遥测上行：接第 5 节的模块

R5 顶层已有现成的"四弦视图"总线（`tang_mega_60k_top.v` 约 126–133 行的 `DISPLAY_VIEW` generate 块）：

```verilog
    wire [27:0] view_notes;        // 4 弦 × 7bit
    wire [3:0]  view_gates;
    wire [3:0]  view_directions;
    wire [31:0] view_velocities;   // 4 弦 × 8bit
    wire [95:0] view_positions;
```

这正好是手机端要的四个物理弦，且已经按当前乐器做了选择，**直接复用，不要另起一套采样**。

例化（放在 `DISPLAY_VIEW` generate 块之后）：

```verilog
    uart_perf_telemetry #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(115200),
        .PERIOD_MS(20)
    ) u_uart_telemetry (
        .i_clk(clk_50m),
        .i_reset(reset),
        .i_notes(view_notes),
        .i_velocities(view_velocities),
        .i_gates(view_gates),
        .i_directions(view_directions),
        .i_view_mode(view),
        .o_uart_tx(esp_uart_tx)
    );
```

`PERIOD_MS(20)` 表示每 20 ms 发一帧，三帧一组（音符/力度/状态），即每弦每 60 ms 刷新一次，手机端 20 Hz 推送能追上。

---

## 4. 第二步：让手机能控制演奏（可选，风险较高）

`uart_event_bridge` 的输出是**另一套演奏源**，与 R5 的 `physical_performer_frontend` 并列。两者不能简单相与，否则真实传感器数据和手机命令会互相覆盖。

推荐做法是加一个明确的"控制权"选择，而不是让两路同时驱动：

```verilog
    // 0 = 真实传感器（默认），1 = 手机/上位机命令
    reg uart_takeover = 1'b0;
    always @(posedge clk_50m)
        if (reset) uart_takeover <= 1'b0;
        else if (uart_event_pulse) uart_takeover <= 1'b1;
        else if (physical_activity_seen) uart_takeover <= 1'b0;   // 有人碰传感器就交还
```

然后把 `note_bus / gate_bus / velocity_bus / speed_bus / position_bus` 在送进 `instrument_bank_core` 之前做一次 mux：

```verilog
    wire [55:0] mux_notes      = uart_takeover ? uart_notes      : notes;
    wire [7:0]  mux_gates      = uart_takeover ? uart_gates      : gates;
    wire [63:0] mux_velocities = uart_takeover ? uart_velocities : velocities;
```

**这里必须改 `ENABLE_LEGACY_PERFORMANCE(1)`**，否则弹奏类命令全部被判 `frame_error`。

风险提示：

- 会改变演奏主通路，必须重新跑全部回归（memory 记录 R5 有 5 组数字回归）；
- `uart_notes` 是 4 弦 7bit 布局，R5 的 `notes` 是 8 弦（小提琴 4 + 尤克里里 4），合并时要注意高 4 弦不能被清零；
- 建议加一个物理开关或命令来关闭接管，避免手机断连后卡在接管态。

如果你暂时不需要手机弹奏（只调参 + 看数据），**跳过本节**，第 3 节就够了。

---

## 5. 新模块 `uart_perf_telemetry.v` 完整代码

放在 `src/uart_perf_telemetry.v`。这是本工程新增的演奏状态遥测，帧格式与 ESP32 侧 `fpga_protocol.h` 的 `STA_PERF` 严格对应。

```verilog
`include "instrument_protocol.vh"

// 演奏状态遥测：每 PERIOD_MS 发一帧，三帧一组。
//   sub=0 音符    first[7:0]/[15:8]/[23:16]/[31:24] = 弦 0..3 的 MIDI
//   sub=1 力度    同上，每字节一条弦
//   sub=2 状态    每字节 = {1'b0, direction, gate, fret[4:0]}
//   second = 组计数器（手机端据此检测丢帧）
// 帧结构：D5 kind flags first_LE32 second_LE32 XOR
module uart_perf_telemetry #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer PERIOD_MS = 20
) (
    input             i_clk,
    input             i_reset,
    input [27:0]      i_notes,        // 4 弦 × 7bit
    input [31:0]      i_velocities,   // 4 弦 × 8bit
    input [3:0]       i_gates,
    input [3:0]       i_directions,
    input [3:0]       i_view_mode,    // 0=小提琴 1=尤克里里
    output reg        o_uart_tx
);
    localparam integer CLK_PER_BIT = CLOCK_HZ / BAUD_RATE;
    localparam integer TICK_MAX    = (CLOCK_HZ / 1000) * PERIOD_MS;
    localparam [7:0]   STATUS_HEADER = `INST_UART_STATUS_HEADER;  // 0xD5
    localparam [7:0]   KIND_PERF     = 8'h10;

    // 开弦音：弦 0..3
    localparam [6:0] VIO_OPEN0 = 7'd55, VIO_OPEN1 = 7'd62,
                     VIO_OPEN2 = 7'd69, VIO_OPEN3 = 7'd76;
    localparam [6:0] UKE_OPEN0 = 7'd67, UKE_OPEN1 = 7'd60,
                     UKE_OPEN2 = 7'd64, UKE_OPEN3 = 7'd69;

    // 每弦按各自乐器取开弦音
    function [6:0] open_of;
        input [1:0] idx;
        input       uke;
        begin
            if (!uke) begin
                case (idx) 2'd0: open_of = VIO_OPEN0;
                           2'd1: open_of = VIO_OPEN1;
                           2'd2: open_of = VIO_OPEN2;
                           default: open_of = VIO_OPEN3; endcase
            end else begin
                case (idx) 2'd0: open_of = UKE_OPEN0;
                           2'd1: open_of = UKE_OPEN1;
                           2'd2: open_of = UKE_OPEN2;
                           default: open_of = UKE_OPEN3; endcase
            end
        end
    endfunction

    function [7:0] fret_byte;
        input [6:0] note;
        input       gate;
        input       dir;
        input [1:0] idx;
        input       uke;
        integer     diff;
        begin
            diff = note - open_of(idx, uke);
            if (diff < 0)  diff = 0;
            if (diff > 16) diff = 16;
            fret_byte = {1'b0, dir, gate, diff[4:0]};
        end
    endfunction

    function [7:0] checksum_of;
        input [7:0]  kind;
        input [7:0]  flags;
        input [31:0] first;
        input [31:0] second;
        begin
            checksum_of = kind ^ flags ^
                first[7:0]  ^ first[15:8]  ^ first[23:16] ^ first[31:24] ^
                second[7:0] ^ second[15:8] ^ second[23:16] ^ second[31:24];
        end
    endfunction

    reg [31:0] tick_cnt;
    reg [1:0]  sub;
    reg [31:0] group;
    reg [95:0] packet;
    reg [3:0]  byte_idx;
    reg [3:0]  bit_idx;
    reg [9:0]  shift_reg;
    reg [31:0] baud_cnt;
    reg        sending;
    reg        byte_busy;

    // 注意拼接顺序：Verilog 拼接左端是高位，所以弦 0 必须写在最右，
    // 才能落到 first[7:0]，与 ESP32 侧 (first >> (8*i)) 的取法一致。
    wire [31:0] w_first = (sub == 2'd0) ? i_notes :
                          (sub == 2'd1) ? i_velocities :
                          { fret_byte(i_notes[27:21], i_gates[3], i_directions[3], 2'd3, i_view_mode[3]),
                            fret_byte(i_notes[20:14], i_gates[2], i_directions[2], 2'd2, i_view_mode[2]),
                            fret_byte(i_notes[13:7],  i_gates[1], i_directions[1], 2'd1, i_view_mode[1]),
                            fret_byte(i_notes[6:0],   i_gates[0], i_directions[0], 2'd0, i_view_mode[0]) };
    wire [7:0]  w_flags = {6'd0, sub};
    // 帧内字节顺序与 uart_status_tx.v 的 make_status_packet 一致：
    // packet[7:0]=header, [15:8]=kind, [23:16]=flags, [55:24]=first, [87:56]=second, [95:88]=XOR
    wire [95:0] w_packet = { checksum_of(KIND_PERF, w_flags, w_first, group),
                             group, w_first, w_flags, KIND_PERF, STATUS_HEADER };

    always @(posedge i_clk) begin
        if (i_reset) begin
            tick_cnt  <= 32'd0;
            sub       <= 2'd0;
            group     <= 32'd0;
            packet    <= 96'd0;
            byte_idx  <= 4'd0;
            bit_idx   <= 4'd0;
            shift_reg <= 10'h3FF;
            baud_cnt  <= 32'd0;
            sending   <= 1'b0;
            byte_busy <= 1'b0;
            o_uart_tx <= 1'b1;
        end else begin
            if (!sending) begin
                if (tick_cnt >= TICK_MAX - 1) begin
                    tick_cnt  <= 32'd0;
                    packet    <= w_packet;
                    sending   <= 1'b1;
                    byte_idx  <= 4'd0;
                    byte_busy <= 1'b0;
                    if (sub == 2'd2) begin sub <= 2'd0; group <= group + 32'd1; end
                    else              sub <= sub + 2'd1;
                end else begin
                    tick_cnt <= tick_cnt + 32'd1;
                end
            end else if (!byte_busy) begin
                shift_reg <= {1'b1, packet[byte_idx*8 +: 8], 1'b0};
                bit_idx   <= 4'd0;
                baud_cnt  <= 32'd0;
                byte_busy <= 1'b1;
                o_uart_tx <= 1'b0;
            end else begin
                if (baud_cnt == CLK_PER_BIT - 1) begin
                    baud_cnt <= 32'd0;
                    if (bit_idx == 4'd9) begin
                        byte_busy <= 1'b0;
                        o_uart_tx <= 1'b1;
                        if (byte_idx == 4'd11) sending <= 1'b0;
                        else                   byte_idx <= byte_idx + 4'd1;
                    end else begin
                        bit_idx   <= bit_idx + 4'd1;
                        shift_reg <= {1'b1, shift_reg[9:1]};
                        o_uart_tx <= shift_reg[1];
                    end
                end else begin
                    baud_cnt <= baud_cnt + 32'd1;
                end
            end
        end
    end
endmodule
```

> 字段顺序必须与 `uart_status_tx.v` 的 `make_status_packet` 完全一致：`{XOR, second, first, flags, kind, header}`。顺序反了时 XOR 覆盖的字节集合虽然相同、数值却不同，ESP32 侧表现为 `RX` 增长而 `ERR` 同步增长。

---

## 6. 引脚约束

`constraints/tang_mega_60k.cst` 里原来那两行注释保留，追加：

```tcl
// ESP32 UART2：E14 = ESP_TX (FPGA 输入)，E13 = ESP_RX (FPGA 输出)
// 两条网络经主控板 R6/R5 33Ω 串联，两侧均为 3.3V CMOS，无需电平转换。
IO_LOC "esp_uart_rx" E14;
IO_PORT "esp_uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=4 BANK_VCCIO=3.3;
IO_LOC "esp_uart_tx" E13;
IO_PORT "esp_uart_tx" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=4 BANK_VCCIO=3.3;
```

`PULL_MODE=UP` 的作用：ESP32 未上电或复位时，FPGA 的 RX 不会悬空收到噪声；TX 默认空闲高电平也符合 UART 协议。

---

## 7. 构建与验证

### 7.1 构建（中文路径必须绕开）

`工程` 这类中文目录会让 `.prj` 解析失败（历史踩坑记录）。用 ASCII 副本构建：

```bash
BUILD=/d/lh_uart_build_20261028
rm -rf $BUILD && mkdir -p $BUILD
# 以当时的 R5 版本目录为起点（本仓库不提供，改为从 fpga/ 复制）
cp -r <工程目录>/{src,constraints} $BUILD/
cp <工程目录>/tang_mega_60k.gprj $BUILD/
```

新文件要加入 `.gprj` 的源文件列表（Gowin IDE 里 `Project > Add Files`，或直接编辑 gprj 的 file 列表），否则综合时找不到 `uart_perf_telemetry`。

```bash
"/d/applicationstudy/Fpga/Gowin_vip/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe" \
    build_gowin.tcl
```

### 7.2 必须逐项确认

| 项目 | 合格标准 |
|---|---|
| 综合 | 无 inferred latch、无未连接端口告警 |
| 资源 | LUT/FF 增量不超过 1%，否则说明逻辑被意外复制 |
| Setup | WNS ≥ 0 |
| **Hold** | **WNS > 0**，且不低于原 +0.052 ns。R5 裕量极窄，这项必须单独看 |
| 时钟域 | `esp_uart_rx` 必须经 `uart_rx_receiver` 内部两级同步，不得直接进组合逻辑 |

### 7.3 板级联调顺序

1. FPGA 只烧遥测版本，ESP32 上电，手机页面关掉"模拟数据"；
2. 看页面顶部 `RX` 是否持续增长、`ERR` 是否接近 0；
3. 若 `RX` 涨但 `ERR` 也涨 → 波特率或 `CLKS_PER_BIT` 不对，回到 3.2；
4. 若 `RX` 完全不涨 → E13/E14 没绑上，或用错球号；用示波器量 E13 应有 115200 的脉冲；
5. 弹一根弦，看四弦卡片是否变化；
6. 最后再验证手机下发：先试"查延迟"，再试"调弦"。

### 7.4 回退

新增逻辑全部集中在 `u_uart_*` 前缀，删除例化 + 端口 + CST 三处即回到 R5 原状。改之前先把 `R5_四弦独立_20261028/` 整目录复制一份备份。

---

## 8. 关键风险汇总

1. **hold 裕量**：原设计仅 +0.052 ns，新增 UART 逻辑（尤其 434 分频计数器和 12 字节移位寄存器）可能压垮。若违例，把遥测模块整体放到独立时钟域不可行（只有一个 50 MHz），只能优化计数器位宽或降低 `PERIOD_MS` 的重载频率。
2. **`CLKS_PER_BIT` 默认值陷阱**：`uart_rx_receiver.v` 默认 217 是 230400 的；不改就全错。
3. **命令注入会改变演奏主通路**：第 4 节是可选步骤，未做充分回归前不要上比赛。
4. **E13/E14 曾被 latency_probe 规划为测量口**：`tang_mega_60k.cst:78-80` 的注释明确"不要在这些网络上驱动测量脉冲"。接 UART 后不要再把 `latency_probe` 的 `o_gpio_*` 接到这两个脚。
