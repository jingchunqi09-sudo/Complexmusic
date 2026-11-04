"""Render fresh Gowin results; reject source/bitstream drift before reporting."""
import hashlib, json, re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'build/results/gowin_60k_build_manifest.json').read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
for item in manifest['Sources']:
    assert sha(root/item['Path'])==item['SHA256'], 'Changed source: '+item['Path']
assert sha(root/manifest['BitstreamPath'])==manifest['BitstreamSHA256'], 'Changed bitstream'
assert sha(root/'impl/pnr/tang_mega_60k.tr')==manifest['TimingReportSHA256'], 'Changed STA'
pnr=(root/'impl/pnr/tang_mega_60k.rpt.txt').read_text(encoding='utf-8',errors='replace')
sta=(root/'impl/pnr/tang_mega_60k.tr').read_text(encoding='utf-8',errors='replace')
resources={}
for name in ['Logic','Register','BSRAM','DSP','CLS']:
    m=re.search(r'^\s*'+name+r'\s*\|\s*([\d.]+)/([\d.]+)',pnr,re.M)
    assert m, 'Missing resource '+name
    resources[name]={'used':float(m.group(1)),'total':float(m.group(2))}
clocks=[]
for name in ['system_clock_50mhz','video_pixel_clock']:
    m=re.search(name+r'\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)',sta)
    assert m,'Missing clock '+name
    clocks.append(f'- {name}: 约束{m.group(1)}MHz，报告Fmax {m.group(2)}MHz。')
timing=manifest['Timing']
assert timing['SetupViolatedEndpoints']==timing['HoldViolatedEndpoints']==0
previous={'Logic':35103,'Register':17680,'BSRAM':36,'DSP':60.5,'CLS':23789}
rows='\n'.join(f"| {name} | {previous[name]} | {r['used']:g}/{r['total']:g} | {r['used']/r['total']*100:.1f}% | {r['used']-previous[name]:+g} |" for name,r in resources.items())
text=f"""# Tang Mega 60K：R5构建证据

构建时间：{manifest['BuiltAt']}；Gowin V1.9.12.03，{manifest['Device']}。
当前音频配置：{manifest['AudioClock']}，Fs={manifest['SampleRateHz']}Hz。外部1.536MHz/V13候选不是此默认位流的生效配置。

- Setup/Hold违例：0/0。
- 最小setup **+{timing['MinimumSetupSlackNs']:.3f}ns**；hold **+{timing['MinimumHoldSlackNs']:.3f}ns**。
- Recovery +{timing['MinimumRecoverySlackNs']:.3f}ns；Removal +{timing['MinimumRemovalSlackNs']:.3f}ns；Pulse Width +{timing['MinimumPulseWidthSlackNs']:.3f}ns。
- 位流SHA256：\x60{manifest['BitstreamSHA256']}\x60。
- STA SHA256：\x60{manifest['TimingReportSHA256']}\x60。
- 本脚本逐文件核对构建源与位流哈希，历史位流来源差异由本次新构建解决，不绑定旧STA。

## 资源

| 项目 | R4历史报告 | R5/器件容量 | 使用率 | 差值 |
|---|---:|---:|---:|---:|
{rows}

DSP为工具等效计量，0.5不能当作完整宏块。四根弦保留独立状态，琴体使用低阶移位加法；没有为复杂而增加32声部、DDR或大型卷积。更多效果器须重新预算。

## 时序范围

"""+'\n'.join(clocks)+"""
- 当前生效音频在50MHz域；没有新增音频多周期/false-path豁免。
- 外部BCK候选的CDC功能仿真另列，不用默认内部配置的STA冒充外部配置通过。
- 视频PLL像素73.333333MHz、1650×750总时序、59.259259Hz；约366.667MHz串行时钟的普通FF Fmax不等于TMDS电气证据。
- 异步UART/reset/MISO、系统与视频观察边界及PLL LOCK复位例外仍受约束范围限制。
- V22通用时钟路由PR1014及实际模拟/传感器/HDMI验证边界须检查构建日志，不能由STA替代。

详细模型、测试和未测项见[R5报告](../../docs/implementation_revision5_20261003_cn.md)。此为数字实现证据；没有自动烧录、真实COM或模拟录音。
"""
(root/'build/results/gowin_60k_summary.md').write_text(text,encoding='utf-8')
(root/'build/results/revision5_resources.json').write_text(json.dumps({'resources':resources,'timing':timing,'clocks':clocks},indent=2),encoding='utf-8')
print('PASS current build summary / manifest hashes',resources,timing)

