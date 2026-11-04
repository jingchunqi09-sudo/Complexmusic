# FPGA 源码（R54）

**本目录的 RTL 是 R54**，与 [`../releases/R54/R54-bitstream.fs`](../releases/R54/R54-bitstream.fs) 同版本。

---

## 一、版本对照

| 项 | 版本 | 位置 |
|---|---|---|
| 发布位流 | **R54** | [`../releases/R54/R54-bitstream.fs`](../releases/R54/R54-bitstream.fs) |
| 本目录 RTL | **R54** | `src/`（91 文件 + `src/rom/` 9 个 `.hex`） |
| 配套固件 | **3.5.8**（亦可用 3.5.10） | [`../releases/R54/`](../releases/R54/) |

---

## 二、这份 R54 源码的来源（必读）

本项目长期采用「单份 `src/` 持续演进 + 发布目录只存位流/固件」的管理方式，且早期
**没有版本控制**。R54 之后同一天内又迭代了 R55→R62b，`src/` 被持续覆盖，
R54 时刻的 RTL **没有整目录快照**。

因此本目录的 R54 源码是**按版本记录逐文件还原**得到的，不是原始目录的拷贝。
还原过程与依据如下，每一步都可复核：

| # | 文件 | 还原方式 | 依据 |
|---|---|---|---|
| 1 | `r9_audio_monitor.v`、`hdmi_instrument_display.v` | 取自 R55 源码快照 | 这两个文件的 SHA256 与 R62b **完全相同**，证明 R55 之后从未改动，故 R55 版即 R54 版 |
| 2 | `tang_mega_60k_top.v`、`link_pkg.vh`、`link_regs.v`、`physical_performer_frontend.v`、`piezo_string_vote.v`、`tang_link_top.v` | 取自 R53 备份 | R54 文档明确「没有动 `tang_mega_60k_top.v`」；其余 5 个文件 R54 也未触及 |
| 3 | `r9_stage_dashboard.v` | R55 快照 + 从 R36（R33 系列）恢复小提琴品格框分支 | R55 注释原文：「原来的 `g_yc`（174+lane*40）已删除 —— 小提琴不再画框」；R54 文档写明 lane 0..3 规则为「黄=未按到，绿=按对」，与 R36 实现一致 |
| 4 | `paw3395_driver.v` | 取自 R47 | R48~R58 的实现文档均未提及该文件；R59 才修 MOT=0 缺陷 |
| 5 | `bow_motion_tracker.v`、`ad7091r4_sensor_adapter.v`、`piezo_string_det.v` | 按 R61 文档记录的原值回退 | R61 文档逐项写明「新值 ← 原值」，见 `latency_profile.vh` 注释 |
| 6 | `instrument_bank_core.v` | 摘除 R62 的振荡器接线 | R62b 文档：该文件的 R62 改动只是接线 |
| 7 | `harmonic_osc_bank.v`、`latency_profile.vh` | **删除** | 前者 R62 新增、后者 R61 新增，R54 不存在 |
| 8 | `left_hand_vote_config.vh` | 时基回到 1.25 ms × 4 组 | R61 文档：「R60: 4×1.25 ms = 5.00 ms 一轮；R61: 4×0.32 ms = 1.28 ms」 |

R61 回退的具体数值（均可在代码注释中对照）：

| 参数 | R61（已撤销） | **R54（本目录）** |
|---|---|---|
| 左手槽长 / 分组 | 0.32 ms / 2 组 | **1.25 ms / 4 组** |
| 弓起音确认样本 | 2 | **3** |
| AD7091R-4 SPI 半周期 | 8 clk（3.125 MHz） | **25 clk（1 MHz）** |
| 压电单通道采样率 | 50 kSPS | **24.9 kSPS** |
| 压电判决窗 / 死区 | 4 ms / 16 ms | **8 ms / 60 ms** |
| 全局硬/软消抖 | 8 ms / 16 ms | **24 ms / 60 ms** |
| 上电消隐 | 120 ms | **250 ms** |
| 增长比回看窗 LAG | 150 | **148** |

---

## 三、已验证到什么程度

| 检查 | 方法 | 结果 |
|---|---|---|
| 语法与端口连接 | ModelSim `vlog` 编译全部 91 个文件 | **0 error** |
| 尤克里里指引 | R54 自带 `sim/tb_r54_uke_guide.v` | **6/6 `ok`**（行线、空弦块、命中变绿、清除） |
| 小提琴指引 | 同一 tb 的对照项 | 框恢复为 R54 行为（`28e070` 绿），tb 因已被 R58 改成「期望无框」而判 FAIL —— **恰说明行为回到了 R54** |
| 工程完整性 | 解析 `.gprj` 逐个校验路径 | **71/71 引用全部存在** |

**未验证**：综合后的资源数与布局（本机内存不足以重跑 PnR）。R54 的记录基线为
CLS **25,104**、BSRAM **104**、hold **+0.168 ns**、setup **+2.316 ns**、Fmax **56.577 MHz**。
若你重新综合，资源数应落在同一量级；**逐位相同不保证**——等价写法在不同综合版本下的映射可能不同。

---

## 四、目录内容

| 路径 | 内容 |
|---|---|
| `src/` | 91 个 RTL 文件 + `src/rom/` 下 9 个 `.hex` ROM |
| `constraints/tang_mega_60k.cst` | 引脚约束（**唯一权威**，见 [`../hardware/pinout.md`](../hardware/pinout.md)） |
| `constraints/tang_mega_60k.sdc` | 时序约束 |
| `config/left_hand_detection.json` | 左手检测参数真源，生成 `src/left_hand_vote_config.vh` |
| `tang_mega_60k.gprj` | Gowin 工程（相对路径引用上述目录，可直接打开） |

**注意**：`tang_mega_60k.gprj` 与 `$readmemh` 都使用 `src/...` 相对路径，
所以本目录必须作为工程根使用，不要把 `src/` 单独移走。

---

## 五、构建

环境：Gowin EDA V1.9.12.03（`gw_sh.exe`）、Python 3.11+。

```bash
cd fpga
python ../tools/build/build_batch.py --place 2 --jobs RX --early-copy ../out
```

分两段跑（综合 → PnR）更稳，物理内存 < 3 GB 时 `--stage all` 会在 routing 阶段崩溃。

**成功判据**：日志出现 `Bitstream generation completed`。
`gw_sh` 写完常以非零码退出（3221226505 / 127），只要产物齐全且 0 ERROR 即为成功
——**不要只看退出码**。

改 `config/left_hand_detection.json` 后必须重新生成：

```bash
python ../tools/build/generate_left_hand_config.py
```

`constraints/tang_mega_60k.cst` 的 `IO_PORT` 行分隔符是**空格**，且必须带 `BANK_VCCIO=3.3`
（写成逗号会报 `CT2000`）。

---

## 六、R54 指标基线

| 指标 | R54 实测（place 1） | 阈值 |
|---|---|---|
| CLS | 25,104 / 29,952（84%） | **< 88%（≈26,358）** |
| BSRAM | 104 / 118（余 14） | **余量 ≥ 10 块** |
| DSP | 77.5 / 118 | — |
| hold | +0.168 ns | **< 0.10 ns 禁止上板；目标 ≥ 0.15** |
| setup | +2.316 ns | ≥ 1.0（像素域） |
| Fmax | 56.577 MHz | — |
| Logic Register as Latch | **0** | 必须为 0 |

> **hold 不能只看"最差值"这一个数字**：同一设计在不同布局下，最差路径可能落在完全
> 不同的位置。R54 的三种 place 实测为 0.168 / 0.128 / 0.052，方向随机。
> 要比较的是**同一条路径**在各布局下的余量。选弦链是这个设计的固有临界路径。

---

## 七、三条不可违反的实现约束

这些是用三次同型事故换来的（R38 / R44 / R57），改代码前必读：

1. **不许给关键信号加负载**。关键信号 = `pcm` / `gate_bus` / `i_fret_bus` /
   `i_left_valid` / `selected_strings` / `note_bus`。它们的扇出与消费者数量
   必须与基线逐项相同。新增功能只能用本模块独立信号，或从**下游已寄存输出**取样。
2. **位宽写窄不报错，会静默变值**。`i_guide_lane < 2'd4` 里 `2'd4` 等于 0，
   导致 R33~R56 的指引框从来没显示过，综合器还把整块比较逻辑优化掉。
3. **端口上的 mux 永远折叠不掉**。`force_on ? force_hot : auto` 里 manual/force 是端口，
   "默认值是 0" 不是免检理由（R52 的错）。

更多见 [`../docs/version-history.md`](../docs/version-history.md) 末尾的"一句话总结"。
