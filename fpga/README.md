# FPGA 源码

**本目录的 RTL 是 R62b，不是 R54。** 这是本仓库最重要的一条说明。

---

## 一、版本对照

| 项 | 版本 | 位置 |
|---|---|---|
| 发布位流 | **R54** | [`../releases/R54/R54-bitstream.fs`](../releases/R54/R54-bitstream.fs) |
| 本目录 RTL | **R62b** | `src/`（93 文件） |
| 固件源码 | **3.5.13** | [`../firmware/src/`](../firmware/src/) |

**本目录源码不能编译出 R54 位流。**

---

## 二、为什么没有 R54 源码

本项目长期采用「单份 `src/` 持续演进 + 发布目录只存位流/固件」的管理方式，
且**没有版本控制**。R54 发布后，同一天内又迭代了 R55→R62b，`src/` 被持续覆盖，
R54 时刻的 RTL 没有独立快照。

核查依据：

1. `src/` 含 `harmonic_osc_bank.v`（18,616 B）——该文件由 R62 引入，R54 没有；
2. R54 的发布目录里只有 `README.md`、4 个 `firmware_*.bin` 与 `.fs`，无源码；
3. 构建临时目录（`build/_syntax_r54/`、`build/_sim_r54/`）里只有 ROM `.hex` 副本与
   ModelSim 库，没有 RTL。

这是事实陈述，不是推测。本仓库选择如实标注，而不是把 R62b 冒充成 R54。

---

## 三、R54 → R62b 改了什么

| 版本 | 主题 | 涉及文件 |
|---|---|---|
| R55 / R56 | 尤克里里指引反复调整 | `r9_stage_dashboard.v`、`r9_audio_monitor.v`、`hdmi_instrument_display.v` |
| R57 | 以 R54 为基线做 uke 双手指引 | 同上 + 左手总线读取（**实板更差，已废弃**） |
| R58 | 指引零负载 | 同上（仍自鸣，废弃） |
| **R59** | **修单弦持续自鸣** | **`paw3395_driver.v`** —— MOT=0 时清零 delta |
| R60 | ESP32 触发式曲谱指引 | `link_regs.v`、`cmd_dispatch.v`、`score_player.v`、`score_store.v`、`tang_mega_60k_top.v` |
| R61 | 延迟优先 | **新增 `latency_profile.vh`**、`paw3395_driver.v`、`bow_motion_tracker.v`、`ad7091r4_sensor_adapter.v`、`piezo_string_det.v`、`physical_performer_frontend.v` |
| R62 | 吞吐量 32 单元 | **新增 `harmonic_osc_bank.v`**、`tang_mega_60k_top.v` |
| R62b | 资源时序优化 | `harmonic_osc_bank.v` 等：相位 32→24 位、乘法 32×32→16×17 |

改动要点见 [`../CHANGELOG.md`](../CHANGELOG.md) 与 [`../docs/version-history.md`](../docs/version-history.md)。

---

## 四、目录内容

| 路径 | 内容 |
|---|---|
| `src/` | 93 个 RTL 文件 + `src/rom/` 下 9 个 `.hex` ROM |
| `constraints/tang_mega_60k.cst` | 引脚约束（**唯一权威**） |
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

## 六、验证判据

R62b 的实测指标（可作为"当前源码确实是最新"的校验基线）：

| 指标 | R62b 实测 | 阈值 |
|---|---|---|
| CLS | 25,585 / 29,952（86%） | **< 88%（≈26,358）** |
| BSRAM | 105 / 118 | **余量 ≥ 10 块** |
| hold | 0.183 ns | **< 0.10 ns 禁止上板；目标 ≥ 0.15** |
| setup | 1.866 ns | ≥ 1.0（像素域） |
| 系统 fmax | 58.514 MHz | — |
| 像素 fmax | 84.960 MHz | — |
| Latch | 0 | 必须为 0 |

> **hold 不能只看"最差值"这一个数字**：同一设计在不同布局下，最差路径可能落在完全
> 不同的位置（R54 的 place1 最差在 `u_onset`，非音频链）。要比较的是**同一条路径**在
> 各布局下的余量。选弦链是这个设计的固有临界路径。

---

## 七、若要重建 R54 源码

需**逆序**撤销 R55→R62b 共 9 个版本、约 10 个文件。注意：

1. R57/R58 的改动本身是错的（实板更差），撤销它们是"去掉缺陷"而非"回退功能"；
2. R62 是结构性新增（24 路振荡器），撤销等于删除 `harmonic_osc_bank.v` 及顶层例化；
3. R61 的 `latency_profile.vh` 是新增 include，撤销后 `physical_performer_frontend.v`
   的 include 也要一并回退，否则编译失败；
4. 撤销后**必须重跑 PnR 并与 R54 记录的资源数比对**才算还原成功。

工作量：熟悉代码者 1~2 小时；**不保证逐字节等价**（综合器对等价写法的资源映射可能不同）。

---

## 八、三条不可违反的实现约束

这些是用三次同型事故换来的（R38 / R44 / R57），改代码前必读：

1. **不许给关键信号加负载**。关键信号 = `pcm` / `gate_bus` / `i_fret_bus` /
   `i_left_valid` / `selected_strings` / `note_bus`。它们的扇出与消费者数量
   必须与基线逐项相同。新增功能只能用本模块独立信号，或从**下游已寄存输出**取样。
2. **位宽写窄不报错，会静默变值**。`i_guide_lane < 2'd4` 里 `2'd4` 等于 0，
   导致 R33~R56 的指引框从来没显示过，综合器还把整块比较逻辑优化掉。
3. **端口上的 mux 永远折叠不掉**。`force_on ? force_hot : auto` 里 manual/force 是端口，
   "默认值是 0" 不是免检理由（R52 的错）。

更多见 [`../docs/version-history.md`](../docs/version-history.md) 末尾的"一句话总结"。
