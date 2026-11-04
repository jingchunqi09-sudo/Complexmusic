# 工具与仿真

| 目录 | 用途 |
|---|---|
| `build/` | 构建脚本（综合 / PnR / 参数生成 / 布局扫描） |
| `regression/` | 回归与仿真运行器（ModelSim） |
| `sim/` | 115 个 testbench + fixtures（单测、集成、边界） |

---

## 一、构建（`build/`）

主要脚本：

| 脚本 | 用途 |
|---|---|
| `build_batch.py` | 主构建入口：综合 → PnR → 打包 |
| `gowin_build_60k.tcl` / `.ps1` | 直接调用 gw_sh 的脚本 |
| `generate_left_hand_config.py` | 由 `fpga/config/left_hand_detection.json` 生成 `src/left_hand_vote_config.vh` |
| `pnr_place_sweep.py` | 只跑 PnR、扫 place/route 组合（复用已综合网表） |
| `physical_build_candidate.py` | 生成候选位流并落盘报告 |
| `verify_and_build_60k.ps1` | 校验 + 构建一体 |
| `check_port_contract.py` | 端口契约检查（防误改顶层端口） |
| `write_build_summary.py` | 生成构建摘要 JSON |

典型用法：

```bash
cd fpga
# 完整构建
python ../tools/build/build_batch.py --place 2 --jobs RX --early-copy ../out

# 只扫布局（复用 impl/gwsynthesis 的网表，不重跑综合）
python ../tools/build/pnr_place_sweep.py --tag R62b --places 2,3
python ../tools/build/pnr_place_sweep.py --tag R62b --combos 2:0,3:2
```

注意事项：

- **`build_batch.py` 每次都会重跑综合**，扫 place 请用 `pnr_place_sweep.py`；
- `--stage all` 在物理内存 < 3 GB 时会在 routing 阶段崩溃，建议拆成综合 + PnR 两段；
- 构建从启动到产物落地，**`src/` 一个字节都不能动**（改文件会让综合读到半写状态）。

---

## 二、回归（`regression/`）

| 脚本 | 组 |
|---|---|
| `run_physical_regression.ps1` | **总入口**，依次跑下面 6 组 |
| `run_physical_left_sim.ps1` | left（左手采集与判决） |
| `run_physical_piezo_sim.ps1` | piezo（压电选弦） |
| `run_physical_control_sim.ps1` | control（链路与寄存器） |
| `run_physical_pitch_sim.ps1` | pitch（音高映射） |
| `run_physical_bank_sim.ps1` | bank（八声部与琴体） |
| `run_body_sim.ps1` | 琴体共振单独仿真 |
| `run_sim_60k.ps1` / `run_video_sim.ps1` | 顶层 / 视频域仿真 |

```bash
cd tools/regression
powershell -NoProfile -ExecutionPolicy Bypass -File run_physical_regression.ps1
```

**已知预期失败**：八声部集成用例末尾的
`FAIL ... preserves independent pluck velocities`
是历史遗留断言与当前波导实现不兼容导致的，**不是回归破损**。

依赖：

- ModelSim SE-64 10.6d —— 安装路径因人而异，用 `run_physical_regression.ps1 -ModelSimBin "<你的路径>"` 指定；
- `main_piezo_test_20261024/sim/reference_adc_model.v` —— ADC 组的引脚级参考模型，
  由脚本按相对路径引用（原项目中位于项目根，**本仓库未包含**，跑 ADC 组需自行提供）。

---

## 三、仿真（`sim/`）

115 个 testbench，按用途分：

| 前缀 / 名称 | 覆盖 |
|---|---|
| `tb_link_*.v` | 链路帧、上电静音、寄存器回读 |
| `tb_piezo_*.v` | 压电选弦、起音判据、真实数据回放 |
| `tb_left_hand_*.v` / `tb_vote_r52.v` | 左手按品解码与投票 |
| `tb_violin_*.v` / `tb_bow_*.v` | 弓弦控制、离弦静音、琴桥滤波 |
| `tb_score_*.v` / `tb_r*_guide.v` | 曲谱播放与屏幕指引 |
| `tb_led_*.v` | 灯带规则 |
| `instrument_*_tb.v` / `revision6_*` | 八声部、琴体共振、混响、路由 |
| `video_timing_tb.v` / `display_*` | 视频时序与显示 |
| `fixtures/` | 曲谱帧、参考波形等测试数据 |

单跑某个 testbench：

```bash
cd tools/sim
vlib work
vlog -work work +incdir+../../fpga/src ../../fpga/src/*.v *.v
vsim -c -do "run -all; quit -f" work/tb_link_boot
```

> `$time` 在 ModelSim 中返回 **ps**，写断言时注意单位。
> `vsim -g<param>=<值>` 传参不可靠，扫参数请用 `vlog +define+XXX=`。
