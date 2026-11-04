// ============================================================
// web_ui.h —— 手机端单页界面（内嵌 PROGMEM，无 CDN 依赖）
//
// 设计原则：
//   1. 一个页面、六张卡片，滚到底就是全部功能，不做路由；
//   2. MIDI 在浏览器里解析（ESP32 的 RAM 和 JSON 栈都吃不下 MIDI 解析器），
//      解析结果压成 [t_ms, 弦, 音高, 力度] 四元组，每 32 条一批发给 ESP32；
//   3. 状态以服务端 20 Hz 推送为准，界面不做乐观更新
//      （FPGA 可能拒绝参数，乐观更新会造成"界面和声音不一致"）；
//   4. 不引入任何外链，断外网也能用。
// ============================================================
#pragma once
#include <Arduino.h>

const char kIndexHtml[] PROGMEM = R"rawliteral(<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tang60K 音乐工作台</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:12px 12px 40px;background:#0f1115;color:#e6e8ec;
     font:15px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
h1{font-size:17px;margin:0 0 10px;font-weight:600}
.card{background:#181b21;border:1px solid #262b34;border-radius:12px;
      padding:12px;margin:0 0 12px}
.card>h2{font-size:14px;margin:0 0 10px;color:#9aa4b2;font-weight:500;letter-spacing:.5px}
.row{display:flex;align-items:center;gap:10px;margin:8px 0}
.row>label{flex:0 0 76px;color:#9aa4b2;font-size:13px}
input[type=range]{flex:1;accent-color:#4c9ffe;height:26px}
input[type=number]{width:76px;background:#0f1115;color:#e6e8ec;border:1px solid #313847;
                   border-radius:8px;padding:6px}
.val{flex:0 0 54px;text-align:right;font-variant-numeric:tabular-nums;color:#c9d3e0}
button{background:#232833;color:#e6e8ec;border:1px solid #313847;
       border-radius:8px;padding:8px 12px;font-size:14px}
button:active{background:#2e3542}
button.primary{background:#2b6cb0;border-color:#2b6cb0}
button.danger{background:#7a2d2d;border-color:#7a2d2d}
.seg{display:flex;gap:6px;flex-wrap:wrap;flex:1}
.seg button{flex:1;min-width:64px}
.seg button.on{background:#2b6cb0;border-color:#2b6cb0}
.stat{display:grid;grid-template-columns:1fr 1fr;gap:6px 12px;
      font-size:13px;color:#9aa4b2}
.stat b{color:#e6e8ec;font-weight:500;font-variant-numeric:tabular-nums}
.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px}
.ok{background:#1d3a24;color:#7fd18b}.bad{background:#3a1d1d;color:#e08b8b}
textarea{width:100%;height:84px;background:#0f1115;color:#c9d3e0;
         border:1px solid #313847;border-radius:8px;padding:8px;font:13px/1.4 monospace}
.bar{height:6px;background:#232833;border-radius:3px;overflow:hidden;margin-top:6px}
.bar>i{display:block;height:100%;background:#4c9ffe;width:0;transition:width .2s}
.foot{color:#5b6472;font-size:12px;text-align:center;margin-top:12px}
.hint{color:#5b6472;font-size:12px;text-align:left;margin-top:8px}
</style></head><body>

<h1>Tang60K 音乐工作台 <span id="fw" class="pill bad">未连接</span></h1>

<div class="card"><h2>链路状态</h2>
<div class="stat">
<div>FPGA <b id="sLink">—</b></div><div>运行 <b id="sUp">—</b></div>
<div>好帧 <b id="sOk">—</b></div><div>坏帧 <b id="sBad">—</b></div>
<div>收字节 <b id="sRx">—</b></div><div>收字节/秒 <b id="sRxs">—</b></div>
<div>RX 空闲电平 <b id="sRxl">—</b></div><div>CRC错 <b id="sCrc">—</b></div>
<div>帧头命中 <b id="sSof">—</b></div><div>LEN错 <b id="sLenb">—</b></div>
<div>loop 心跳 <b id="sLpc">—</b></div>
<div style="grid-column:1/-1">前 8 字节 <b id="sSn" style="font-family:monospace">—</b><span id="sSnn"></span></div>
<div>曲谱 <b id="sSc">—</b></div><div>进度 <b id="sPos">—</b></div>
</div></div>

<div class="card"><h2>音量与音色</h2>
<div class="row"><label>音量</label>
  <input type="range" id="vol" min="0" max="255" value="128">
  <span class="val" id="volV">128</span>
  <button id="btnMute" style="flex:0 0 auto;padding:6px 10px">静音</button></div>
<div class="row"><label>音色倾斜</label>
  <input type="range" id="tilt" min="-100" max="100" value="0">
  <span class="val" id="tiltV">0</span></div>
<div class="hint">音量 128 = 0 dB，拖动时服务端会做软斜坡（每 5 ms 一小步），不会爆音。<br>
往右变亮（压基频、抬 800 Hz 以上），往左变暖（从 300 Hz 起往下压谐波）。<br>满量程 ±12 dB。模块带峰值归一化和削顶保护，转到头只会变音色、不会削顶。<br>
<span id="toneRb" class="mono" style="opacity:.85">硬件回读：--</span><br>
<span id="revWarn" style="display:none;color:#e05a5a">⚠ 混响当前是「启用」状态，会掩盖音色判断。到下面「混响 / 阻尼 / 尾音」点「旁路（干声）」。</span></div>
</div>

<div class="card"><h2>弦与定弦</h2>
<div class="row"><label>选择弦</label>
  <div class="seg" id="selStr">
    <button data-s="0" class="on">琴1</button><button data-s="1">琴2</button>
    <button data-s="2">琴3</button><button data-s="3">琴4</button>
    <button data-s="4">尤1</button><button data-s="5">尤2</button>
    <button data-s="6">尤3</button><button data-s="7">尤4</button></div></div>
<div class="row"><label>空弦音高</label>
  <input type="number" id="tuneN" min="24" max="96" value="55">
  <span class="val" id="tuneV">55</span>
  <span class="val" id="tuneHz">196.0 Hz</span>
  <button id="tuneSet">写入</button></div>
<div class="row"><label>频率微调</label>
  <button id="tuneDn" style="flex:0 0 auto;padding:6px 12px">− 半音</button>
  <button id="tuneUp" style="flex:0 0 auto;padding:6px 12px">+ 半音</button>
  <button id="tuneDef" style="flex:0 0 auto;padding:6px 10px">标准音</button></div>
<div class="hint mono" id="tuneAll" style="line-height:1.7">—</div>
<div class="hint mono" id="encDiag" style="opacity:.85">面板累计格数 ENC1/2/3/4 = -- / -- / -- / --</div>
<div class="hint mono" id="swDiag" style="opacity:.85">按键电平 ENC1/2/3/4 = -- （静置应全部为 1）</div>
<div class="hint">转一下任意旋钮，上面那行对应位置的数字必须涨；<b>四个都不动 = 面板没接好</b>
（先查 GND，再查 A/B 有没有接反）。<br>
面板 <b>ENC3</b>：旋转 = 当前弦 ±1 半音，<b>按一下 = 换下一根弦</b>
（琴1→琴2→琴3→琴4→尤1→尤2→尤3→尤4→琴1 循环），网页这里会自动跟着切。<br>
<b>ENC4 长按 1.5 秒 = 参数复位</b>（音量 / 音色 / 定弦 / 混响全部回默认，不重启、不断 WiFi）。<br>
ENC1 = 音量，ENC2 = 音色，ENC4 旋 = 混响湿声、按 = 旁路。</div>
<div class="hint">音高是 MIDI 号（G3=55 / D4=62 / A4=69 / E5=76）。改完立刻生效，
GUIDE 页的指法框会按新定弦重新换算品位。<br>
注：8 条物理弦在综合时固定为「4 弓弦 + 4 拨弦」，**不支持换乐器**，
所以这里没有小提琴/尤克里里开关（旧版那个开关是无效的）。</div>
</div>

<div class="card"><h2>混响 / 阻尼 / 尾音</h2>
<div class="row"><label>湿声</label>
  <input type="range" id="wet" min="0" max="255" value="64">
  <span class="val" id="wetV">64</span></div>
<div class="row"><label>阻尼</label>
  <input type="range" id="damp" min="0" max="255" value="128">
  <span class="val" id="dampV">128</span></div>
<div class="row"><label>尾音</label>
  <input type="range" id="tail" min="0" max="3" value="1">
  <span class="val" id="tailV">1</span></div>
<div class="row"><label>旁路</label>
  <div class="seg" id="selBp">
    <button data-b="1" class="on">旁路（干声）</button><button data-b="0">启用混响</button>
  </div></div>
</div>

<div class="card"><h2>曲谱（演奏指引，不发声）</h2>
<div class="row"><label>乐器</label>
  <select id="inst" style="flex:1">
    <option value="v">小提琴（屏幕不显示指引）</option>
    <option value="u">尤克里里（左手品 + 右手弦）</option>
  </select></div>
<div class="row"><label>文件</label>
  <input type="file" id="midi" accept=".mid,.midi,.txt" style="flex:1;font-size:13px"></div>
<div class="row"><label>速度</label>
  <input type="number" id="bpm" value="120" min="20" max="300">
  <button id="btnLoad" style="flex:1">解析并上传</button></div>
<textarea id="log" readonly placeholder="解析结果会显示在这里"></textarea>
<div class="bar"><i id="upBar"></i></div>
<div class="row" style="margin-top:10px">
  <button id="btnDemo" style="flex:1">生成演示曲谱</button></div>
<div class="row">
  <button class="primary" id="btnPlay" style="flex:1">开始指引</button>
  <button id="btnPause" style="flex:1">暂停</button>
  <button class="danger" id="btnStop" style="flex:1">停止</button></div>
<div class="hint">曲谱只驱动屏幕上的指法提示，**不会让琴自己发声**，演奏仍然完全由你控制。<br>
<b>R55 起只有尤克里里会显示指引</b>（小提琴曲谱照常上传、照常记录，但屏幕上不画框）：<br>
· <b>左手品</b>：目标品格框，黄色闪烁；空弦时显示为琴枕左侧的实心块<br>
· <b>右手弦</b>：该行上下两条琥珀线 + 最左空弦块<br>
· 那根弦真的响了 → 框和线一起变绿（尤克里里没有按品传感，绿色不代表"品按对了"）<br>
文本谱每行：<code>时间ms,弦0-7,音高0-127,力度0-127</code>（0-3 = 琴 1-4 弦，4-7 = 尤 1-4 弦）<br>
MIDI 按上面选的**乐器**分弦：小提琴走 0-3（G3/D4/A4/E5），尤克里里走 4-7（G4/C4/E4/A4）。</div>
</div>

<div class="card"><h2>曲谱指引（固定 17 步 · 触发式）</h2>
<div class="row">
  <button class="primary" id="btnGuideStart" style="flex:1">开始指引</button>
  <button class="danger" id="btnGuideStop" style="flex:1">停止</button></div>
<div class="row">
  <button id="btnGuidePrev" style="flex:1">上一步</button>
  <button id="btnGuideNext" style="flex:1">下一步</button>
  <button id="btnGuideAuto" data-on="1" style="flex:1">自动跟随：开</button></div>
<div class="hint" id="guideOut" style="line-height:2;font-size:15px">未进入指引</div>
<div class="hint">
<b>固定乐谱</b>：2弦空 → 4弦空 → 1弦5品 → 4弦空 → 3弦空 → 3弦2品 → 2弦空 → 1弦5品 →
4弦空 → 4弦空 → 3弦2品 → 1弦5品 → 4弦空 → 4弦空 → 1弦5品 → 2弦2品 → 1弦5品。<br>
「自动跟随」开着时：<b>弹对当前那根弦才跳到下一步</b>，拨错弦不会跳。<br>
屏幕只画"该按哪儿"，<b>不显示你的实际按压</b>；声音完全由你的演奏决定 ——
这条指引只写显示侧寄存器，FPGA 的发声链一个字都没接到它上面。</div>
</div>

<div class="card"><h2>面板接线自检</h2>
<div class="row">
  <button id="btnProbe" style="flex:1">读一次</button>
  <button id="btnProbeClr" style="flex:1">清零后监视</button></div>
<div class="hint mono" id="probeOut" style="line-height:1.8;word-break:break-all">—</div>
<div class="hint">显示 12 个编码器 GPIO 的<b>累计边沿数</b>。转<b>最左</b>那颗旋钮，看哪两个数在涨：<br>
<b>18 / 19</b> 在涨 = 反序排线（1↔14），当前固件的表就是这一套；<br>
<b>39 / 33</b> 在涨 = 同向排线（1-1），需要把引脚表整组换掉。<br>
再按一下最左旋钮，看哪个脚变 0：<b>34</b> = 反序，<b>32</b> = 同向。</div>
</div>

<div class="card"><h2>录音试听</h2>
<div class="row">
  <button class="primary" id="btnRec" style="flex:1">录 2 秒</button>
  <button id="btnRecPlay" style="flex:1">试听</button></div>
<div class="stat"><div>状态 <b id="sRec">—</b></div><div>采样点 <b id="sRecN">—</b></div></div>
<audio id="audio" controls style="width:100%;margin-top:8px"></audio>
<div class="hint"><b>录音取自 DAC 的输出</b>（R40 起），所以在手机上调音量会同时改变录音内容。<br>
格式 <b>12.2 kHz / 8 bit</b>：FPGA 侧只做抽取 + 截断，把新增逻辑压到最小，
避免挤动发声部分的布局（这是前两版乱响的根因）。<br>
若点"录 2 秒"后 0.8 秒内收不到任何样本，会提示 <code>no audio</code> —— 那是位流没开通录音。<br>
<b>录音期间请勿拖动参数</b>：命令应答与录音流共用一个发送缓冲。</div>
</div>

<div class="foot">Tang60K · LINK v2 · 230400 8N1 · A5 5A + CRC16-CCITT</div>

<script>
(function(){
  var ws, connected=false;
  var sLpcLast=null;
  var el=function(id){return document.getElementById(id)};
  var setT=function(id,v){var e=el(id); if(e) e.textContent=v;};
  var st={vol:128,tilt:0,mute:0,tune:[55,62,69,76,67,60,64,69],
          wet:64,damp:128,tail:1,bp:1,sel:0};
  // R52：MIDI -> Hz（A4=69=440）
  function midiHz(n){ return 440*Math.pow(2,(n-69)/12); }
  function hzTxt(n){
    var f=midiHz(n);
    return (f>=1000 ? f.toFixed(0) : f.toFixed(1))+' Hz';
  }
  var TN=['琴1','琴2','琴3','琴4','尤1','尤2','尤3','尤4'];
  var TDEF=[55,62,69,76,67,60,64,69];

  function send(o){ if(ws&&ws.readyState===1) ws.send(JSON.stringify(o)); }
  function log(s){ var t=el('log'); t.value += s+'\n'; t.scrollTop=t.scrollHeight; }
  function volText(v){ var db=20*Math.log10(Math.max(v,1)/128); return v+' ('+(db>=0?'+':'')+db.toFixed(1)+'dB)'; }

  function connect(){
    ws=new WebSocket('ws://'+location.hostname+':81/');
    ws.onopen=function(){connected=true;el('fw').className='pill ok';el('fw').textContent='已连接'};
    ws.onclose=function(){connected=false;el('fw').className='pill bad';
                          el('fw').textContent='断开';setTimeout(connect,1500)};
    ws.onmessage=function(e){
      var m; try{ m=JSON.parse(e.data); }catch(err){ return; }
      if(m.t==='hello'){
        st.vol=m.vol; st.tilt=m.tilt; st.tune=m.tune; st.mute=m.mute|0;
        st.wet=m.wet; st.damp=m.damp; st.tail=m.tail; st.bp=m.bp;
        el('fw').textContent='FW '+m.fw;
        el('vol').value=st.vol;   el('volV').textContent=volText(st.vol);
        el('tilt').value=st.tilt; el('tiltV').textContent=st.tilt;
        el('wet').value=st.wet;   el('wetV').textContent=st.wet;
        el('damp').value=st.damp; el('dampV').textContent=st.damp;
        el('tail').value=st.tail; el('tailV').textContent=st.tail;
        el('btnRec').disabled = !m.rec;
        if(!m.rec) el('btnRec').textContent='录音不可用';
        el('btnMute').textContent = st.mute ? '取消静音' : '静音';
        markSeg('selStr', st.sel);
        markSeg('selBp', st.bp);
        refreshTune();
      } else if(m.t==='st'){
        // R60：固定曲谱指引状态
        if(m.gs!==undefined){
          if(m.gs){
            el('guideOut').innerHTML =
              '第 <b>'+m.gi+'</b> / 17 步 &nbsp;·&nbsp; 第 <b>'+m.gl+'</b> 弦 &nbsp;·&nbsp; '+
              (m.gf ? ('第 <b>'+m.gf+'</b> 品') : '<b>空弦</b>');
          } else {
            el('guideOut').textContent = '未进入指引';
          }
          if(m.ga!==undefined){
            el('btnGuideAuto').setAttribute('data-on', m.ga ? '1' : '0');
            el('btnGuideAuto').textContent = '自动跟随：' + (m.ga ? '开' : '关');
          }
        }
        el('sLink').textContent = m.link ? '在线' : '离线';
        el('sLink').style.color = m.link ? '#7fd18b' : '#e08b8b';
        el('sUp').textContent = (m.up/1000).toFixed(1)+' s';
        el('sOk').textContent = m.ok;  el('sBad').textContent = m.bad;
        el('sRx').textContent = (m.rxb===undefined?'—':m.rxb);
        setT('sRxs', (m.rxs===undefined?'—':m.rxs+' /s'));
        setT('sRxl', (m.rxl===undefined?'—':(m.rxl?'高 3.3V':'低 0V')));
        if(m.rxl!==undefined) el('sRxl').style.color = m.rxl ? '#7fd18b' : '#e08b8b';
        el('sCrc').textContent = (m.crc===undefined?'—':m.crc);
        el('sSof').textContent = (m.sof===undefined?'—':m.sof);
        el('sLenb').textContent = (m.lenb===undefined?'—':m.lenb);
        el('sLpc').textContent = (m.lpc===undefined?'—':m.lpc);
        if(m.snn===0){
          el('sSn').textContent = '（一个字节都没收到）';
          el('sSn').style.color = '#e08b8b';
          setT('sSnn','');
        } else {
          el('sSn').textContent = (m.sn===undefined?'—':m.sn);
          el('sSn').style.color = '';
          setT('sSnn', '　已采 ' + m.snn + ' 字节');
        }
        if(m.lpc!==undefined){
          var grow = (sLpcLast!==null && m.lpc>sLpcLast);
          el('sLpc').style.color = grow ? '#7fd18b' : '#e08b8b';
          sLpcLast = m.lpc;
        }
        el('sSc').textContent = m.sc ? (m.sc+' 事件') : '空';
        el('sPos').textContent = m.sp;
        el('sRec').textContent = m.rec ? '录制中' : '空闲';
        el('sRecN').textContent = m.recn;
        // 3.5.5：音量双向同步。原来这一行有三个问题叠在一起：
        //   ① 只改数字，`el('vol').value` 从来没被面板旋钮改过 -> 滑块纹丝不动
        //   ② 用的是 m.vol（FPGA 状态回读，5 Hz 才更新一次）
        //   ③ 被 m.link 挡住，链路一断就彻底不更新
        // 面板旋钮和网页滑块共用同一个 gVolTarget，state 里的 vt 就是它，直接用。
        var vv = (m.vt!==undefined) ? (m.vt|0) : ((m.vol!==undefined) ? (m.vol|0) : -1);
        if(vv>=0 && document.activeElement!==el('vol')){
          st.vol=vv; el('vol').value=vv; el('volV').textContent=volText(vv);
        }
        // 尾音同理：周期推送也要更新滑块，否则面板长按复位后网页还停在旧值
        if(m.tail!==undefined && document.activeElement!==el('tail')){
          st.tail=m.tail|0; el('tail').value=st.tail; el('tailV').textContent=st.tail;
        }
        // 物理旋钮改了参数 → 同步界面（正在拖动的那一条不覆盖，避免手感和数据打架）
        if(m.mut!==undefined){ st.mute=m.mut; el('btnMute').textContent = st.mute ? '取消静音' : '静音'; }
        if(m.tilt!==undefined && document.activeElement!==el('tilt')){
          st.tilt=m.tilt; el('tilt').value=m.tilt; el('tiltV').textContent=m.tilt; }
        if(m.tw!==undefined){
          // 回读值 vs 滑杆期望值：一致说明帧真的到了 FPGA；不一致就是链路问题
          var ew=Math.round(2048+Math.max(-100,Math.min(100,st.tilt))*(-0.12)*170.67);
          var eb=Math.round(2048+Math.max(-100,Math.min(100,st.tilt))*( 0.12)*170.67);
          var ok = (Math.abs(m.tw-ew)<40 && Math.abs(m.tb-eb)<40);
          el('toneRb').textContent='硬件回读 warm='+m.tw+' bright='+m.tb+
            (ok?'  ✓ 与滑杆一致':'  ✗ 与滑杆不符（帧没到？）');
          el('toneRb').style.color = ok ? '' : '#e05a5a';
        }
        if(m.wet!==undefined && document.activeElement!==el('wet')){
          st.wet=m.wet; el('wet').value=m.wet; el('wetV').textContent=m.wet; }
        if(m.damp!==undefined && document.activeElement!==el('damp')){
          st.damp=m.damp; el('damp').value=m.damp; el('dampV').textContent=m.damp; }
        if(m.bp!==undefined && m.bp!==st.bp){ st.bp=m.bp; markSeg('selBp', st.bp); }
        // 3.5.2：面板 ENC3 按压换弦后，网页游标跟着切。
        // 不跟会出现"面板在第 3 根、网页还显示第 1 根"的分叉，改定弦会写错弦。
        if(m.tsel!==undefined && (m.tsel|0)!==st.sel){
          st.sel = m.tsel|0; markSeg('selStr', st.sel); refreshTune();
        }
        // 面板转出的定弦值：不接这段，转 ENC3 时网页数字不动，看着像"控制失败"
        if(m.tn!==undefined){
          var ta=String(m.tn).split(',');
          if(ta.length===8){
            var chg=false;
            for(var ti=0;ti<8;ti++){ var tv=+ta[ti]; if(st.tune[ti]!==tv){ st.tune[ti]=tv; chg=true; } }
            if(chg && document.activeElement!==el('tuneN')) refreshTune();
            else if(chg) el('tuneHz').textContent = hzTxt(st.tune[st.sel]);
          }
        }
        if(m.enc!==undefined)
          el('encDiag').textContent = '面板累计格数 ENC1/2/3/4 = ' + String(m.enc).replace(/,/g,' / ');
        // 3.5.5：按键电平。静置应全是 1；某位是 0 = 那一路 SW 接地/接错
        if(m.sw!==undefined){
          var s4=m.sw|0, t=[];
          for(var si=0;si<4;si++) t.push((s4>>si)&1);
          el('swDiag').textContent = '按键电平 ENC1/2/3/4 = '+t.join(' / ')+
            (s4===15 ? '  ✓ 正常' : '  ✗ 有引脚被拉低（查那一根 SW 线）');
          el('swDiag').style.color = (s4===15) ? '' : '#e05a5a';
        }
        if(m.bp!==undefined) el('revWarn').style.display = (m.bp|0)===0 ? '' : 'none';
      } else if(m.t==='recwarn'){
        el('sRec').textContent='位流未开通录音';
        log('录音无数据：当前位流没有把音频接进链路（LINK_PCM_TAP=0）');
      } else if(m.t==='sbatch'){
        el('upBar').style.width = (m.full?100:Math.min(100,(m.total/1365*100)|0))+'%';
      } else if(m.t==='ack' && m.c==='splay'){
        log(m.ok ? ('下发 '+m.n+' 事件，tick='+m.tick_us+'µs，已开始播放') : '下发失败');
      }
    };
  }

  function markSeg(id, val){
    Array.prototype.forEach.call(el(id).children, function(b){
      b.className = (+b.dataset.s===val || +b.dataset.t===val || +b.dataset.b===val) ? 'on' : '';
    });
  }
  function refreshTune(){
    // R37：lane 直接用弦号 0..7（0~3 小提琴，4~7 尤克里里）。
    var s=st.sel;
    el('tuneN').value = st.tune[s];
    el('tuneV').textContent = st.tune[s];
    el('tuneHz').textContent = hzTxt(st.tune[s]);
    // 8 弦一览：一次看全，改哪根弦立刻见频率
    var a=[];
    for(var i=0;i<8;i++) a.push(TN[i]+' '+st.tune[i]+'/'+hzTxt(st.tune[i]).replace(' Hz',''));
    el('tuneAll').textContent = a.slice(0,4).join('  ')+'\n'+a.slice(4).join('  ');
  }
  function setTune(v){
    v = Math.max(24, Math.min(96, v|0));
    st.tune[st.sel]=v;
    refreshTune();
    send({c:'tune', l:st.sel, n:v});
  }

  // ---- 音量 / 静音 / 音色倾斜 ----
  el('vol').oninput  = function(){ st.vol=+this.value; el('volV').textContent=volText(st.vol);
                                   st.mute=0; el('btnMute').textContent='静音';
                                   send({c:'vol',v:st.vol}); };
  // 拖动时实时下发（服务端每 60 ms 节流一次），松手再发一次保证终值
  el('tilt').oninput = function(){ st.tilt=+this.value; el('tiltV').textContent=st.tilt;
                                   send({c:'tone',t:st.tilt}); };
  el('btnMute').onclick=function(){
    st.mute = st.mute ? 0 : 1;
    el('btnMute').textContent = st.mute ? '取消静音' : '静音';
    send({c:'mute',v:st.mute});
  };

  // ---- 选弦 / 定弦 ----
  Array.prototype.forEach.call(el('selStr').children,function(b){
    b.onclick=function(){ st.sel=+b.dataset.s; markSeg('selStr',st.sel); refreshTune(); };
  });
  el('tuneSet').onclick=function(){ setTune(+el('tuneN').value); };
  el('tuneN').onchange =function(){ setTune(+el('tuneN').value); };
  el('tuneDn').onclick =function(){ setTune(st.tune[st.sel]-1); };
  el('tuneUp').onclick =function(){ setTune(st.tune[st.sel]+1); };
  el('tuneDef').onclick=function(){ setTune(TDEF[st.sel]); };


  // ---- FX ----
  ['wet','damp','tail'].forEach(function(k){
    el(k).oninput=function(){ st[k]=+this.value; el(k+'V').textContent=st[k];
      send({c:'fx',wet:st.wet,damp:st.damp,tail:st.tail,bp:st.bp}); };
  });
  Array.prototype.forEach.call(el('selBp').children,function(b){
    b.onclick=function(){ st.bp=+b.dataset.b; markSeg('selBp',st.bp);
      send({c:'fx',wet:st.wet,damp:st.damp,tail:st.tail,bp:st.bp}); };
  });

  // ---- MIDI 解析（浏览器侧） ----
  function parseMidi(buf){
    var dv=new DataView(buf);
    if(dv.getUint32(0)!==0x4d546864) throw new Error('不是 MIDI 文件');
    var hlen=dv.getUint32(4), ntrk=dv.getUint16(10), div=dv.getUint16(12)||480;
    var p=8+hlen, evs=[];
    for(var t=0;t<ntrk;t++){
      if(p+8>buf.byteLength) break;
      if(dv.getUint32(p)!==0x4d54726b) break;
      var len=dv.getUint32(p+4), q=p+8, end=q+len, tick=0, rs=0;
      while(q<end){
        var d=0,b;
        do{ b=dv.getUint8(q++); d=(d<<7)|(b&0x7f); }while(b&0x80);
        tick+=d;
        var stt=dv.getUint8(q);
        if(stt&0x80){ rs=stt; q++; } else { stt=rs; }
        var hi=stt&0xf0;
        if(hi===0x90){
          var n=dv.getUint8(q), v=dv.getUint8(q+1); q+=2;
          if(v>0) evs.push({tick:tick,note:n,vel:v});
        } else if(hi===0x80){ q+=2; }
        else if(hi===0xa0||hi===0xb0||hi===0xe0){ q+=2; }
        else if(hi===0xc0||hi===0xd0){ q+=1; }
        else if(stt===0xff){
          q++; var l=0,bb;
          do{ bb=dv.getUint8(q++); l=(l<<7)|(bb&0x7f); }while(bb&0x80);
          q+=l;
        } else if(stt===0xf0||stt===0xf7){
          var l2=0,bb2;
          do{ bb2=dv.getUint8(q++); l2=(l2<<7)|(bb2&0x7f); }while(bb2&0x80);
          q+=l2;
        } else { q++; }
      }
      p=end;
    }
    evs.sort(function(a,b){return a.tick-b.tick});
    return {evs:evs, div:div};
  }

  // 按**当前定弦**分弦（以前是写死 76/69/62 的阈值，改过定弦就会指错弦）
  // 把音高分到 base..base+count-1 这几根弦：
  //   找"不超过该音高的最高空弦"；全都比它高时取最低那根。
  // 不假设 st.tune 升序 —— 尤克里里默认定弦 G4/C4/E4/A4 = 67/60/64/69 本身不是升序。
  function pickString(n, base, count){
    var best=base, bestT=-1, i, t;
    for(i=base;i<base+count;i++){
      t=st.tune[i];
      if(t<=n && t>bestT){ bestT=t; best=i; }
    }
    if(bestT<0){
      var lo=st.tune[base]; best=base;
      for(i=base+1;i<base+count;i++) if(st.tune[i]<lo){ lo=st.tune[i]; best=i; }
    }
    return best;
  }
  function noteToString(n){ return pickString(n,0,4); }     // 小提琴 -> lane 0..3
  function noteToStringUke(n){ return pickString(n,4,4); } // 尤克里里 -> lane 4..7
  function parseText(txt){
    var out=[];
    txt.split(/\r?\n/).forEach(function(l){
      l=l.trim(); if(!l||l[0]==='#') return;
      var a=l.split(/[,\s]+/).map(Number);
      if(a.length<4||isNaN(a[0])) return;
      out.push({tMs:a[0], s:a[1]|0, n:a[2]|0, v:a[3]|0});
    });
    return out;
  }

  // 统一的上传流程：整理 -> 去重 -> 分批下发。手动导入和演示曲谱共用。
  function uploadList(list, fname){
    if(!list.length){ log('没有音符'); return; }

    // 同弦同一时刻只保留最高音：FPGA 每个 lane 只有一个音高寄存器
    var seen={}, uniq=[];
    list.forEach(function(e){
      var k=e.s+'@'+Math.round(e.tMs/30);
      if(seen[k]!==undefined){ if(e.n>uniq[seen[k]].n) uniq[seen[k]]=e; }
      else { seen[k]=uniq.length; uniq.push(e); }
    });
    uniq.sort(function(a,b){return a.tMs-b.tMs});
    var dur = uniq[uniq.length-1].tMs|0;
    if(uniq.length>1365){ log('事件 '+uniq.length+' 超 FPGA 容量 1365，请切短'); return; }

    var nv=0, nu=0;
    uniq.forEach(function(e){ if(e.s<4) nv++; else nu++; });
    log('解析 '+fname+'：'+uniq.length+' 事件（琴 '+nv+' / 尤 '+nu+'），时长 '+(dur/1000).toFixed(1)+' s');
    send({c:'sbegin', name:fname.slice(0,23), dur:dur});
    var i=0;
    (function batch(){
      if(i>=uniq.length){ send({c:'scommit',slot:0}); log('已存槽位 1，点"开始指引"下发到 FPGA'); return; }
      var chunk=[], n=0;
      while(i<uniq.length && n<32){
        var e=uniq[i++]; chunk.push([Math.round(e.tMs), e.s, e.n, e.v]); n++;
      }
      send({c:'sbatch', e:chunk});
      el('upBar').style.width = Math.min(100,(i/uniq.length*100)|0)+'%';
      setTimeout(batch, 30);
    })();
  }

  el('btnLoad').onclick=function(){
    var f=el('midi').files[0];
    var bpm=+el('bpm').value||120;
    var uke = el('inst').value === 'u';
    if(!f){ log('先选文件'); return; }
    var rd=new FileReader();
    rd.onload=function(){
      var list=[];
      try{
        if(/\.(mid|midi)$/i.test(f.name)){
          var r=parseMidi(rd.result);
          var usPerQuarter=60000000/bpm;
          list=r.evs.map(function(e){
            // 按上面选的乐器分弦：小提琴 0-3，尤克里里 4-7
            return {tMs: e.tick*usPerQuarter/r.div,
                    s: uke ? noteToStringUke(e.note) : noteToString(e.note),
                    n:e.note, v:e.vel};
          });
        } else { list=parseText(rd.result); }
      }catch(err){ log('解析失败: '+err.message); return; }
      uploadList(list, f.name);
    };
    if(/\.(mid|midi)$/i.test(f.name)) rd.readAsArrayBuffer(f);
    else rd.readAsText(f);
  };

  // 演示曲谱：尤克里里 4 根弦，每根先空弦、再 +3 半音（第 3 品），每步 0.9 s，两轮。
  // 用途：不需要任何文件就能验证"左手品框 + 右手弦线 + 命中变绿"整条链路 ——
  //       空弦那一步只看弦线（品框不画），+3 半音那一步品框会落在第 3 品格。
  // R55 起小提琴不再有屏幕指引，所以演示只走 lane 4..7。
  el('btnDemo').onclick=function(){
    var list=[], t=300, seq=[4,5,6,7], rep, k, lane;
    for(rep=0; rep<2; rep++){
      for(k=0; k<seq.length; k++){
        lane=seq[k];
        list.push({tMs:t, s:lane, n:st.tune[lane],     v:100});  // 空弦：只亮弦线
        t += 900;
        list.push({tMs:t, s:lane, n:st.tune[lane]+3,   v:100});  // 第 3 品：弦线 + 品框
        t += 900;
      }
    }
    log('演示曲谱：尤 1->尤 4，每根「空弦 -> 第 3 品」，共两轮（弦线变绿、品框落在第 3 格）');
    uploadList(list, 'demo-uke-fret');
  };

  // ---- 播放控制 ----
  el('btnPlay').onclick =function(){ send({c:'splay'}); log('下发曲谱…'); };
  el('btnPause').onclick=function(){ send({c:'sctrl',v:2}); };
  el('btnStop').onclick =function(){ send({c:'sctrl',v:0}); };

  // ---- 面板接线自检（3.5.10）----
  var probeTimer = null;
  function fetchProbe(clr){
    fetch('/encprobe'+(clr?'?clr=1':'')).then(function(r){return r.json();}).then(function(m){
      var a=[];
      for(var i=0;i<m.pins.length;i++) a.push(m.pins[i]+':'+m.edges[i]);
      el('probeOut').textContent = a.join('   ');
    }).catch(function(){});
  }
  // ---- R60：固定曲谱指引 ----
  function guideCmd(a, v){ send({c:'guide', a:a, v:(v===undefined?1:v)}); }
  el('btnGuideStart').onclick = function(){ guideCmd('start'); };
  el('btnGuideStop').onclick  = function(){ guideCmd('stop'); };
  el('btnGuidePrev').onclick  = function(){ guideCmd('prev'); };
  el('btnGuideNext').onclick  = function(){ guideCmd('next'); };
  el('btnGuideAuto').onclick  = function(){
    var on = el('btnGuideAuto').getAttribute('data-on') === '1';
    on = !on;
    el('btnGuideAuto').setAttribute('data-on', on ? '1' : '0');
    el('btnGuideAuto').textContent = '自动跟随：' + (on ? '开' : '关');
    guideCmd('auto', on ? 1 : 0);
  };

  el('btnProbe').onclick = function(){ fetchProbe(false); };
  el('btnProbeClr').onclick = function(){
    if(probeTimer){ clearInterval(probeTimer); probeTimer=null; el('btnProbeClr').textContent='清零后监视'; return; }
    fetchProbe(true);
    probeTimer = setInterval(function(){ fetchProbe(false); }, 500);
    el('btnProbeClr').textContent = '停止监视';
  };

  // ---- 录音 ----
  var recTimer=null;
  el('btnRec').onclick=function(){
    send({c:'rec',s:1,decim:1});
    el('sRec').textContent='录制中…';
    if(recTimer) clearTimeout(recTimer);
    recTimer=setTimeout(function(){
      send({c:'rec',s:0});
      el('audio').src='/rec.wav?t='+Date.now();
      log('录音已取回，点"试听"');
    }, 2400);
  };
  el('btnRecPlay').onclick=function(){
    el('audio').src='/rec.wav?t='+Date.now(); el('audio').play();
  };

  connect();
})();
</script></body></html>)rawliteral";
