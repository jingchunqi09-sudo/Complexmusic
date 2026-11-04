#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批量构建 R30/R31/R32（可指定 place 策略），产物存到 build/r24_bow/<name>.{fs,tr,rpt.txt}。

用法： python scripts/build_batch.py --place 1 --jobs R30,R31,R32
"""
import argparse, re, shutil, subprocess, sys, hashlib, pathlib, time

ROOT = pathlib.Path(r"D:\applicationstudy\Fpga\GOwin\documents\Tang Mega 60K MUSIC")
GW = r"D:\applicationstudy\Fpga\Gowin_vip\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
TOP = ROOT / "src" / "tang_mega_60k_top.v"
PNR_SRC = ROOT / "build" / "r24_bow" / "pnr_only.tcl"
SYN_TCL = ROOT / "build" / "r24_bow" / "syn_only.tcl"
OUT = ROOT / "build" / "r24_bow"

CFG = {
    "R30": (1, 0, 0),
    "R31": (1, 1, 0),
    "R32": (1, 1, 1),
    # R33 起：曲谱改为"演奏指引"（不发声）。三级重新出：
    #   R33 = 指引 + 参数（音量关，音频路径与 R29 一致，最安全）
    #   R34 = 指引 + 音量（DAC 经 audio_volume）
    #   R35 = 指引 + 音量 + 录音抽头
    "R33": (1, 0, 0),
    "R34": (1, 1, 0),
    "R35": (1, 1, 1),
    # R36：音量搬进 pt8211_tx 内部（valid 与样本仍同拍，走线与 R33 一致）
    #      (SCORE, VOLUME, PCM_TAP) = (1, 1, 0)
    "R36": (1, 1, 0),
    # R38：录音回传接通。与 R36 只差 LINK_PCM_TAP 一个字符，另修了 rec_stream
    #      的读指针预取 bug（首字节重复 + 尾字节丢失）。
    "R38": (1, 1, 1),
    # R39：录音抽头从 DAC 末端（pt8211_tx.o_frame_pcm）取，pcm 总线负载不增加；
    #      rec_ladpcm 搬出链路模块，链路只收 9 根低频字节线。
    "R39": (1, 1, 1),
    # R40：录音抽头换成极简版（rec_tap_u8，抽取 + 8 位截断，约 12 FF / <20 LUT），
    #      把新增逻辑砍到 LADPCM 的 1/20，尽量不挤动音频核的布局。
    "R40": (1, 1, 1),
    # R41：SK9822 灯带从「左手指板诊断」改成「呼吸灯 + 分弦配色」。
    #      只改 physical_performer_frontend.v 里 left_led_status 的颜色来源，
    #      帧结构 / sclk 相位 / 引脚（A15/A20）全部不动；音频通路一行未碰。
    "R41": (1, 1, 1),
    # R42：屏幕换成 v3.1 舞台显示（disp_v3_stage），替换 r9_stage_dashboard。
    #      音频通路一行未动；只动 hdmi 里的一行模块名 + 新增 4 个 disp_v3_*.v。
    "R42": (1, 1, 1),
    # R43：删除「换乐器」死逻辑。只动 cmd_dispatch / link_regs / tang_link_top /
    #      tang_mega_60k_top 四个文件里的 lane_enable 通路：
    #      去掉影子写口两级 8 位 MUX、lane_en_we/wr、TIMBRE 的换组表达式，
    #      r_lane_enable 改常量 0xFF（复位值本来就是 0xFF，行为等价）。
    #      端口 o_lane_enable 保留但输出常量，STATUS byte 7 仍为 0xFF（固件不用改）。
    "R43": (1, 1, 1),
    # R44：①左手灯恢复按品指示（left_led_status 加 i_fret_bus，按品那颗加亮 64）
    #      ②屏蔽物理坏灯 DEAD_PIXEL=23（可改，见模块注释）
    #      ③音色量程 +-6 dB -> +-9 dB（timbre_shaper 的 s2 系数 1/2 -> 3/4），
    #        固件 kToneStepDb 与 tiltToTone 同步改。
    #      默认档 2048/2048 时 timbre_shaper 仍严格直通（408 样本 0 差异）。
    "R44": (1, 1, 1),
    # R45：灯重新配色（用户要求"整条统一呼吸、弹弦才明显变化、不能太亮"）
    #      ①静默只保留一种底色青 (0,48,64)，31 颗完全一致（不再有故障列染红）
    #      ②弹弦：该弦列亮，其余列压暗到 0.3125 —— 靠对比而非抬亮
    #      ③BRI 4->3，全部色值 <= 96：最坏 32.0 mA（R41 是 90.3 mA）
    #      ④按品提示 +24，且排除 fret=0（原来 fret=0 也命中，品0 四颗恒亮）
    "R45": (1, 1, 1),
    # R46：灯回到 R41 的接口 —— **彻底删掉 i_fret_bus**。
    #      R44 给灯接了 20 位 fret，等于给选品链路的输出多挂一个消费者，
    #      综合后布局被推动，实板左手选品出问题。本版恢复 R41 原文件后只改灯内部：
    #      统一呼吸底色 + 弹弦对比高亮 + 坏灯屏蔽 + BRI 4->3。
    #      前 300 行（含选品全部连接）与 R41 逐字节相同，已用 diff 验证。
    "R46": (1, 1, 1),
    # R47：paw3395 驱动加自愈能力。
    #      ①S_ERROR 原来没有任何出口（SPI 一次错就永久死机，只能按复位键）
    #        -> 加 retry_cnt，100 ms 后回 S_RESET 重跑 0x3A + 140 条初始化
    #      ②运行期自检原为"读一次 ID 错一次就死" -> 改成连续 3 次才判错
    #      ③实测确认运行期自检读的是 Product_ID/Inverse_ID，**不是 CPI**
    #        （原分析说读 CPI 有误），所以两处判错分支都加了容错
    "R47": (1, 1, 1),
    # R48：总音色"听不出来"的修法。只动 timbre_shaper.v 一个文件。
    #      ①拐架交叉：低架 600->1200 Hz（管"亮"）、高架 1200->300 Hz（管"暖"）
    #      ②量程 +-9 -> +-12 dB（s2 系数 3/4 -> 1）
    #      ③亮方向响度回补最多 +6 dB（Gc 仍钳在 <=1，结构上不会抬过输入峰值）
    #      ④两个正向增益之和钳到 +12 dB（只影响 tone_console 的独立双滑杆）
    #      ⑤参数平滑加"接近即吸附"，回到中点后严格等于复位态
    #      中性档仍逐位直通（tb_timbre_r48 T1：2000 样本 0 差异）
    "R48": (1, 1, 1),
    # R49：以 **R41 为基础**重做（用户："你后面的几版代码都不行，以 R41 为基础"）。
    #      ①physical_performer_frontend.v 整体回退到 R41 原文件（灯带配色回 R41）
    #      ②paw3395_driver.v 保留自愈，但改成"软恢复"：
    #        R47 的恢复是 ready/init_error 拉低 + 100 ms 无采样 + 重跑 140 条初始化，
    #        前端是 .ready(paw_ready && !paw_error)，任一信号掉一拍
    #        bow_motion_tracker 就 gate<=0，恢复后整音重新起音 —— 这就是
    #        用户报的"一直有混响"（不是混响模块，它默认就是旁路）。
    #        R49 运行期只等 2 ms 重读 ID，ready/init_error 全程不动；
    #        仿真实测 sample_valid 最大间隔 2.07 ms < 8 ms 看门狗。
    #      ③timbre_shaper.v 沿用 R48 的可闻度版本（用户要求 ±9~12 dB 的明显变化）
    "R49": (1, 1, 1),
    # R50：灯带规则重做（在 R49 基础上）。
    #      ①只驱动前 31 颗（index 0..30），31..63 全部填黑
    #      ②L23 坏灯压黑：原理图链路 L01.SDO->DATA1->L02.SDI，即 L 位号 = 串联第几颗，
    #        L23 = 第 23 颗 = 0 起算 index 22 = 品5 弦2（R44/R46 写的 23 差了一颗）
    #      ③静默：31 颗统一青 (0,48,64) 同步呼吸 1.34 s
    #      ④弹弦：该弦整列变弦色，其余列压暗到 0.3125（加法），呼吸周期同时减半
    #      ⑤去掉故障染红（i_fault 常置位会让整列常年偏红 = 用户说的"乱"）
    #      ⑥BRI 4->3，最坏 31 颗 51.8 mA（R41 是 90.3 mA）
    #      帧结构/sclk 相位/引脚一个字没动，仍然发满 64 个字。
    "R50": (1, 1, 1),
    # R51：灯带"只有小提琴有反应"修复（在 R50 基础上，只动 left_led_status 的触发源）。
    #      根因：顶层 `next_gates={4'd0, selected_strings & {4{bow_gate}}}`
    #      → gate_bus[7:4] **恒为 0**，而 R50 把灯接在 gate_bus[3:0]|gate_bus[7:4] 上，
    #      所以弹尤克里里时灯完全不动。
    #      改法 1：换成 trigger_bus[7:4]（= p_trigger & ~bow_contact），并先打一拍隔离。
    #             灯内部 0.40 s 拖尾会把单拍记住。
    #      改法 2（评审发现、最关键）：L23 物理拆除后 DI/DO 短接，L24 会吃掉本该属于
    #             L23 的 32 bit，**整串前移一格**。必须补偿：接收者 r>=22 时逻辑索引取
    #             r+1（参数 SKIP_DEAD=1）。不补偿的表现是"一演奏就从第 6 列开始偏一格"。
    #      改法 3：删掉 R50 的 L23(index22) 压黑（灯已拆，物理不存在）。
    #      改法 4：新增 ROW_FLIP（默认 0），行序可整体翻转，给"上下颠倒"留一行出口。
    "R51": (1, 1, 1),
    # R52：选弦可控。改 piezo_string_vote / link_regs / link_pkg / frontend / 两个顶层。
    #      ① 快换弦：连续 2 窗同赢家就切（原来要 7 窗 9.2 ms），首次锁定仍走 6 票
    #      ② pick 超时释放：静默 76 窗(100 ms) 清 pick，消除 piezo_extra 污染
    #      ③ 琴体事件冻结投票（拍琴身不再把 pick 带偏）
    #      ④ 手动强制选弦 REG_SEL_MODE/FORCE（force 1..4 完全覆盖自动结果）
    #      ⑤ 选弦门限 REG_SEL_THR 可调；REG_SEL_STAT 只读回 pick
    #      **判据本身不改**：离线实测 argmax(es) 在拨弦数据上主/次比 9.9~35，
    #      ef-es 只有 4.7~10.7，改了反而更差（策划里的 P0-A 已被数据否掉）。
    "R52": (1, 1, 1),
    # R52b：**紧急回退**。R52 实板出现"弹完乱响好几次 / 一拉就识别四根弦 / 声音特别大"。
    #      根因：R52 给 vote 加了 QUIET_WIN=76 把 pick 在静默 100ms 后清零，而
    #      `pick_eff = pick ? pick : (enabled_w ? argmax : FALLBACK_MASK)` ——
    #      pick=0 且 enabled_w=0（静默期、起音最初几毫秒）时回退成 1111 四弦齐鸣。
    #      本版把 vote 的 always 块整段恢复成 R51 原样（快换弦 + 超时释放全删），
    #      判据与状态机零改动。只保留：手动强制 REG_SEL_FORCE / 门限 REG_SEL_THR /
    #      状态回读 REG_SEL_STAT（默认全中性，不改变任何自动行为）。
    "R52b": (1, 1, 1),
    # R53：**R52/R52b 控制面彻底清理**。R52b 上板 S1 乱响不停，效果不如 R51。
    #      根因不是逻辑（force_on 默认恒 0），而是物理：
    #      force mux 插在 `selected_strings -> next_gates -> gate_bus` 这条**发声门控本身**
    #      上，多一级 mux + 一个移位器；同时 o_sel_stat 给 piezo_pick 加扇出。
    #      本工程 hold 余量只有 43~45 ps（R41 是 180），任何新增连线都推动布局。
    #      本版把 6 个 RTL 文件的 R52 改动**全部删除**：
    #        piezo_string_vote / physical_performer_frontend / link_regs / link_pkg
    #        tang_link_top / tang_mega_60k_top
    #      selected_strings 表达式逐字回到 R51；REG_MAX 回 0x30。
    #      ESP32 只保留**纯网页**改进（8 弦定弦 + Hz + ±半音 + 标准音），删选弦卡片。
    # ！！R53 要盯 hold：< 0.12 ns 就换 place 重跑（同一网表 hold 每次都不同）。
    "R53": (1, 1, 1),
    # R54：GUIDE 页加"尤克里里弦指引"（lane 4..7 只标弦不标品）。
    #      只动三个显示模块：r9_stage_dashboard / r9_audio_monitor / hdmi_instrument_display。
    #      音频链、选品链、灯带、链路寄存器**一行未动**；顶层端口零新增
    #      （i_instruments 是 hdmi 模块内部已有的信号，只多接一组）。
    #      顺手修掉 R33 遗留的 latch：g_xl/g_xr/g_yc 从"按需赋值的 reg"改成组合 wire。
    #      仿真 sim/tb_r54_uke_guide.v 全过（含小提琴框回归）。
    # ！！R54 同样要盯 hold：< 0.12 ns 就换 place 重跑。
    "R54": (1, 1, 1),
    # R55：GUIDE 页**只指引尤克里里**，并且左手品 + 右手弦一起给（用户要求）。
    #      ① 删掉 R33 的小提琴指引目标框（lane 0..3 不再画任何东西）
    #      ② uke 分支加品格框：x=g_xl/g_xr，y 用 uke_yc 行（g_yc 已删 ——
    #         它对 lane>=4 会算出 334，超出琴颈 154..314）
    #      ③ 纵向分层 yc-8..yc-6 弦线 / yc-5..yc+19 品框 / yc+20..yc+22 弦线，
    #         三段互不重叠（R54 的下弦线和品框下边原本会撞同一像素）
    #      只动 r9_stage_dashboard.v 一个文件；顶层端口零新增，音频/选品/灯带未动。
    #      仿真 sim/tb_r55_uke_guide_fret.v 21 项全过，tb_r54 回归通过。
    # ！！R55 同样要盯 hold：< 0.12 ns 就换 place 重跑。
    "R55": (1, 1, 1),
    # R56：以 R54 的行为基线修 R55 的两个问题（用户 06:06 反馈"会自己乱响"）。
    #   ① 曲谱播完后指引不消失：score_player 的 END 在模块内部就被吃掉
    #      （score_player.v:202 直接回 IDLE，不发 ev_valid），所以 R33 那套
    #      "靠 STOP 清目标"对整首结束无效，最后一个框会一直闪。
    #      → 顶层加 lk_score_state 回 0 后 1 s 自动清 g_valid（+28 FF）。
    #      → 仿真 sim/tb_r56_guide_expire.v 验证 +0.5s 还在 / +1.2s 已清。
    #   ② uke 品格提示从"画边框"改成"整格填充"：比较器 8 组 -> 2 组，
    #      减 LUT；视觉上整格高亮比 1 px 边框更醒目。
    #   音频链、选弦链、灯带、链路寄存器**一行未动**；顶层端口零新增。
    # ！！R56 必须同时看 hold 和 setup：route_option 0 能把 hold 抬到 0.182，
    #    但像素域 setup 会从 2.486 掉到 0.092 —— 不能只挑 hold 大的。
    "R56": (1, 1, 1),
    # R61：延迟优先档。**只改感知链的时基与判决参数**，音频核 / 选弦链 /
    #   灯带 / 曲谱 / 链路寄存器一行未动。改动集中在：
    #     src/latency_profile.vh（新增，唯一真源）
    #     src/paw3395_driver.v（轮询 1 ms -> 120 us，SPI 1 MHz -> 1.92 MHz，
    #                          ID 自检 / SQUAL 按 16 轮分频）
    #     src/bow_motion_tracker.v（ATTACK_N 3 -> 2）
    #     src/ad7091r4_sensor_adapter.v / piezo_string_det.v（单通道 24.9 -> 50 kSPS）
    #     config/left_hand_detection.json（槽 1.25 ms -> 0.32 ms，分组 4 -> 2）
    #   ！！本档的 hold 风险来自布局漂移（常量改动也会动网表），必须看 hold。
    "R61": (1, 1, 1),
    # R62：吞吐量 + 时序。新增 8 路加法合成振荡单元（harmonic_osc_bank），
    #   振荡单元 8 -> 16，吞吐量 390,624 -> 781,248 osc·Hz（+100%）。
    #   不动采样率、不动任何滤波器系数、不动左手/右手时基。
    #   资源：1 块 BSRAM（正弦表）+ 2 个 DSP + 约 700 FF。
    #   ！！必须看 CLS 是否仍 <26358 且 BSRAM 仍留 10 块。
    "R62": (1, 1, 1),
}


def patch_switches(score, vol, tap):
    s = TOP.read_text(encoding="utf-8")
    s = re.sub(r"localparam integer LINK_SCORE_ENABLE\s*=\s*\d+;",
               f"localparam integer LINK_SCORE_ENABLE  = {score};", s)
    s = re.sub(r"localparam integer LINK_VOLUME_ENABLE\s*=\s*\d+;",
               f"localparam integer LINK_VOLUME_ENABLE = {vol};", s)
    s = re.sub(r"localparam integer LINK_PCM_TAP\s*=\s*\d+;",
               f"localparam integer LINK_PCM_TAP       = {tap};", s)
    TOP.write_text(s, encoding="utf-8")
    return [m.group(0) for m in re.finditer(r"localparam integer LINK_\w+\s*=\s*\d+;", s)]


def make_pnr_tcl(place):
    s = PNR_SRC.read_text(encoding="utf-8")
    s2 = re.sub(r"set_option -place_option \d+", f"set_option -place_option {place}", s)
    if s2 == s and f"place_option {place}" not in s:
        raise SystemExit("place_option 替换失败")
    p = OUT / f"pnr_place{place}.tcl"
    p.write_text(s2, encoding="utf-8")
    assert p.stat().st_size > 200, "tcl 副本异常"
    return p


def run(tcl, log):
    with open(log, "w", encoding="utf-8", errors="ignore") as fh:
        r = subprocess.run([GW, str(tcl)], stdout=fh, stderr=subprocess.STDOUT,
                           cwd=str(ROOT))
    return r.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--place", type=int, default=1)
    ap.add_argument("--jobs", default="R30,R31,R32")
    # 每完成一个就先复制到指定目录，用户不必等整批跑完才拿到第一个位流
    ap.add_argument("--early-copy", default="", help="构建完一个就复制 .fs 到的目录")
    a = ap.parse_args()

    pnr = make_pnr_tcl(a.place)
    print(f"pnr tcl = {pnr.name} ({pnr.stat().st_size} B)")

    early = pathlib.Path(a.early_copy) if a.early_copy else None
    if early:
        early.mkdir(parents=True, exist_ok=True)
        print(f"early copy -> {early}")

    for name in a.jobs.split(","):
        score, vol, tap = CFG[name]
        cur = patch_switches(score, vol, tap)
        print(f"\n=== {name} score={score} vol={vol} tap={tap} place={a.place} "
              f"{time.strftime('%H:%M:%S')}", flush=True)
        for c in cur:
            print("   ", c)

        syn_log = OUT / f"syn_{name}.log"
        run(SYN_TCL, syn_log)
        syn_txt = syn_log.read_text(encoding="utf-8", errors="ignore")
        nerr = len(re.findall(r"ERROR", syn_txt))
        print(f"    syn errors={nerr}", flush=True)
        if nerr:
            print(syn_txt[-2000:])
            return 1
        shutil.copy2(ROOT / "impl/gwsynthesis/tang_mega_60k_syn_rsc.xml", OUT / f"{name}_rsc.xml")

        pnr_log = OUT / f"pnr_{name}.log"
        run(pnr, pnr_log)
        pnr_txt = pnr_log.read_text(encoding="utf-8", errors="ignore")
        done = "Bitstream generation completed" in pnr_txt
        print(f"    bitstream={done}", flush=True)
        if not done:
            print(pnr_txt[-1500:])
            return 1

        for src, dst in ((ROOT / "impl/pnr/tang_mega_60k.fs", OUT / f"{name}.fs"),
                         (ROOT / "impl/pnr/tang_mega_60k.tr", OUT / f"{name}.tr"),
                         (ROOT / "impl/pnr/tang_mega_60k.rpt.txt", OUT / f"{name}.rpt.txt")):
            if dst.exists():
                dst.unlink()
            shutil.copy2(src, dst)
        h = hashlib.sha256((OUT / f"{name}.fs").read_bytes()).hexdigest().upper()
        sz = (OUT / f"{name}.fs").stat().st_size
        tr = (OUT / f"{name}.tr").read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"system_clock_50mhz\s+50\.000\(MHz\)\s+([0-9.]+)", tr)
        first = re.search(r"^\s+1\s+(-?\d+\.\d+)", tr, re.M)
        print(f"    sha={h[:16]} bytes={sz} fmax={m.group(1) if m else '?'} "
              f"worst_slack={first.group(1) if first else '?'}", flush=True)
        # 立刻交付这一个——用户不必等整批
        if early is not None:
            cp = early / f"{name}.fs"
            shutil.copy2(OUT / f"{name}.fs", cp)
            print(f"    EARLY_READY {cp}  {h}", flush=True)
    print("\nDONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
