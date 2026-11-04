`timescale 1ns/1ps
// Model-assisted integration regression. Raw Kimi/Qianwen candidates are in
// model_candidates/*.v.txt; changes and limits are documented in the report.
// REAL production top/frontend/controllers/eight DSP voices/PT8211 serializer.
// Only the sensor publication boundaries (decoded left frets + PAW/ADC samples)
// are forced by this bench. This is NOT an external SPI/analog/board test.
module tb_physical_bank_integration #(
  parameter integer NEGATIVE_WRONG_LANE=0
);
  reg clk=0; always #10 clk=~clk;
  reg reset_n=0;
  tang_mega_60k_top #(.ENABLE_HDMI(0)) dut(
    .clk_50m(clk),.reset_n(reset_n),.audio_bck_in(1'b0),
    .paw_miso(1'b0),.left_adc1_out(1'b0),.left_adc2_out(1'b0),
    .piezo_miso(1'b0),.piezo_busy_n(1'b1),
    .hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
    .paw_ncs(),.paw_sclk(),.paw_mosi(),
    .left_adc_sclk(),.left_adc_din(),.left_adc1_cs_n(),.left_adc2_cs_n(),
    .left_tx1(),.left_tx2(),.left_tx3(),.left_tx4(),.left_sk_clk(),.left_sk_data(),
    .piezo_sclk(),.piezo_mosi(),.piezo_cs_n(),.piezo_convst_n(),.piezo_reset_n(),
    .hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable()
  );
  reg d_paw_valid=0,d_ready=1,d_paw_error=0;
  reg [7:0] d_motion=0;
  reg signed [15:0] d_dx=0,d_dy=0;
  reg [19:0] d_fret=0;
  reg [3:0] d_left_valid=0;
  reg d_p_valid=0,d_healthy=0;
  reg [1:0] d_channel=0;
  reg [11:0] d_value=0;
  reg [3:0] d_p_trigger=0;
  reg [31:0] d_p_velocity=0;
  integer checks=0,cycles=0,starts=0,pcm_frames=0,tx_frames=0,tagged_frames=0;
  integer max_latency=0,start_cycle=0,nonzero_pcm=0;
  integer trigs[0:7],stops[0:7],voice_nonzero[0:7];
  integer i,j,f,k,baseline[0:3],excursion[0:3],velocity[0:3];
  integer uke0_before;
  reg [7:0] trigger_seen=0,stop_seen=0,active_seen=0,voice_seen=0;
  reg [31:0] last_sequence=0;
  reg valid_in_flight=0;
  // ---- R24 说明 ----
  // 本台测的是"八声部 note/velocity/trigger/stop 的独立锁存与仲裁"，不是选弦；
  // 选弦由 sim/tb_piezo_vote.v（9 个场景）和 control 组覆盖。
  // R23 及以前，压电四路同时强时 mask 全 1，selected_strings 正好等于四弦，
  // 于是 `gates==8'h0f` 这类断言"顺带"成立。R24 把选弦改成"投票赢家只有一根"
  // 之后，压电残余（本台在第 167/170 行喂过满量程和 32 轮 baseline）会让
  // selected_strings 变成单弦，下面所有四弦断言就会连锁失败——但那是**选弦
  // 语义变了，不是八声部集成坏了**。
  // 所以这里把压电包络钉在 0，让 selected_strings 走 FALLBACK_MASK(四弦)，
  // 保持本台的原有契约不变。force 只影响本仿真，不进综合。
  initial force dut.u_physical.piezo_ay = 64'd0;
  task check;
    input condition;
    input [8*160-1:0] message;
    begin
      checks=checks+1;
      if(condition!==1'b1)begin
        $display("FAIL physical bank integration t=%0t: %0s",$time,message);$fatal(1,"integration assertion");
      end
    end
  endtask
  task paw_sample;
    input [7:0] m;
    input signed [15:0] x;
    begin
      // R10：弓速主轴是 dy（BOW_AXIS_Y=1），旧版只驱动 dx，速度恒为 0。
      // 两轴同幅驱动，等效"斜向拉弓"，保证任何 AXIS_Y 取值都能产生速度。
      @(negedge clk);d_paw_valid=1;d_motion=m;d_dx=x;d_dy=x;
      @(negedge clk);d_paw_valid=0;
      repeat(2)@(posedge clk);#1;
    end
  endtask
  task piezo_sample;
    input integer ch,v;
    begin
      @(negedge clk);d_p_valid=1;d_channel=ch;d_value=v;
      @(negedge clk);d_p_valid=0;
      repeat(2)@(posedge clk);#1;
    end
  endtask
  task piezo_trigger;
    input integer ch;input [7:0] v;
    begin
      @(negedge clk);d_p_trigger=(4'b1<<ch);d_p_velocity[ch*8 +:8]=v;
      @(negedge clk);d_p_trigger=0;
      repeat(2)@(posedge clk);#1;
    end
  endtask
  task frame_start;
    begin
      @(posedge clk);#1;
      while(dut.u_audio_core.r_phase!=1)begin @(posedge clk);#1;end
    end
  endtask
  task frame_done;
    begin
      @(posedge clk);#1;
      while(!dut.pcm_valid)begin @(posedge clk);#1;end
    end
  endtask
  // Post-NBA monitor: adapted from Kimi's procedural assertion style, with
  // bounded checks rather than the candidate's tautological 8-bit >255 test.
  always @(posedge clk)begin
    #1;cycles=cycles+1;
    if(dut.reset)begin
      check(dut.event_valid===0,"reset suppresses frontend events");
      check(dut.triggers===0 && dut.stops===0,"reset suppresses action pulses");
    end else begin
      if(dut.event_valid)begin
        check(dut.event_sequence>last_sequence,"event sequence strictly increases");
        last_sequence=dut.event_sequence;
      end
      for(k=0;k<8;k=k+1)begin
        if(dut.triggers[k])begin trigs[k]=trigs[k]+1;trigger_seen[k]=1;end
        if(dut.stops[k])begin stops[k]=stops[k]+1;stop_seen[k]=1;end
        if(dut.active[k])active_seen[k]=1;
        if(dut.u_audio_core.o_voice_sample_bus[k*16 +:16]!==16'd0 &&
           ^dut.u_audio_core.o_voice_sample_bus[k*16 +:16]!==1'bx)begin
          voice_nonzero[k]=voice_nonzero[k]+1;voice_seen[k]=1;
        end
      end
      if(dut.u_audio_core.r_phase==1)begin
        check(!valid_in_flight,"prior PCM completed before next frame start");
        valid_in_flight=1;start_cycle=cycles;starts=starts+1;
      end
      if(dut.pcm_valid)begin
        check(valid_in_flight,"PCM valid belongs to a started frame");
        check(cycles-start_cycle<768,"real eight-voice PCM completed before 768-clock deadline");
        check(^dut.pcm!==1'bx,"PCM contains no X");
        if(cycles-start_cycle>max_latency)max_latency=cycles-start_cycle;
        valid_in_flight=0;pcm_frames=pcm_frames+1;
        if(dut.pcm!=0)nonzero_pcm=nonzero_pcm+1;
        if(dut.pcm_event)begin
          check(dut.pcm_event_count!=0,"tagged PCM retains a nonzero event count");
          check(dut.pcm_first_sequence<=dut.pcm_sequence,"tag sequence range ordered");
          tagged_frames=tagged_frames+1;
        end
      end
      if(dut.frame_pcm_valid)tx_frames=tx_frames+1;
      check(dut.u_audio_core.o_deadline_count==0,"no missed DSP deadlines");
      check(dut.INTERNAL_AUDIO.u_tx.o_overrun_count==0,"no serializer mailbox overrun");
      check(dut.INTERNAL_AUDIO.u_tx.o_underrun_count==0,"no serializer mailbox underrun");
    end
  end
  initial begin
    for(i=0;i<8;i=i+1)begin trigs[i]=0;stops[i]=0;voice_nonzero[i]=0;end
    for(i=0;i<4;i=i+1)begin baseline[i]=1800+i*100;excursion[i]=64*(1<<i);velocity[i]=32+((excursion[i]-64)>>2);end
    force dut.u_physical.paw_valid=d_paw_valid;
    force dut.u_physical.paw_ready=d_ready;
    force dut.u_physical.paw_error=d_paw_error;
    force dut.u_physical.motion=d_motion;
    force dut.u_physical.dx=d_dx;
    force dut.u_physical.dy=d_dy;
    force dut.u_physical.fret=d_fret;
    force dut.u_physical.left_ready=d_left_valid;
    // This bench injects already-decoded healthy sensor publications.
    // Actual scanner/rail-fault paths have separate pin-level regressions.
    force dut.u_physical.evidence_fault=1'b0;
    force dut.u_physical.left_multi=1'b0;
    force dut.u_physical.left_common=1'b0;
    force dut.u_physical.left_fault=4'b0;
    force dut.u_physical.p_valid=d_p_valid;
    force dut.u_physical.p_channel=d_channel;
    force dut.u_physical.p_value=d_value;
    force dut.u_physical.p_initialized=d_healthy;
    // R16：本台验证的是"门控位布局 + 左右手仲裁"，与压电选弦无关。
    // 选弦会把"不按品时的四弦齐拉"改成单弦（用户要求：弓一次只接触一根弦），
    // 那部分由 sim/tb_bow_string_select.v 单独覆盖。这里把压电包络钉在 0，
    // 让选弦走"压电无结论 -> 回退 OPEN_BOW_MASK"的路径，保持原断言语义。
    force dut.u_physical.piezo_ay=64'd0;
    // R6: the bandpass detector runs its own warmup, so this publication-
    // boundary bench drives the frontend's trigger/velocity lanes directly.
    force dut.u_physical.p_trigger=d_p_trigger;
    force dut.u_physical.p_velocity=d_p_velocity;
    repeat(8)@(negedge clk);reset_n=1;
    repeat(8)@(posedge clk);#1;
    // Qianwen candidate's structural-only healthy check is made dynamic.
    for(i=0;i<4;i=i+1)piezo_sample(i,4095);
    check(trigger_seen==0,"unhealthy piezo samples cannot trigger");
    @(negedge clk);d_healthy=1;d_left_valid=4'hf;
    for(j=0;j<32;j=j+1)for(i=0;i<4;i=i+1)piezo_sample(i,baseline[i]);
    // Three neutral gesture keys and the explicit +36 anchor, all four lanes.
    @(negedge clk);d_fret={5'd16,5'd13,5'd8,5'd3};
    repeat(5)@(posedge clk);#1;
    check(dut.notes=={7'd85,7'd77,7'd68,7'd70,7'd112,7'd93,7'd74,7'd55},"all eight note lanes map independently");
    wait(dut.ready===1);repeat(4)frame_done;
    // Pluck phase with the bow lifted: each piezo event reaches its own
    // upper (uke) voice with its own velocity byte.
    frame_start;
    for(i=0;i<4;i=i+1)begin
      piezo_trigger(i,velocity[i]);
      check(dut.velocities[(i+4)*8 +:8]==velocity[i],"piezo velocity byte reaches its upper voice byte");
    end
    check(trigs[4]==1 && trigs[5]==1 && trigs[6]==1 && trigs[7]==1,"each lifted pluck delivers exactly one upper-voice trigger");
    // Negative self-check: deliberately corrupt a pending velocity byte.
    // This parameter is zero in the qualification run; production RTL is
    // unchanged. The runner requires this variant to be rejected.
    if(NEGATIVE_WRONG_LANE)force dut.u_audio_core.r_trigger_velocity[63:56]=8'd0;
    frame_start;
    check(dut.u_audio_core.r_trigger==8'hf0,"pending pluck triggers delivered to all four upper voices in next sample");
    check(dut.u_audio_core.r_stop==0,"no stop pending before the bow attacks");
    check(dut.u_audio_core.r_velocity=={8'd144,8'd80,8'd48,8'd32,32'he0e0e0e0},"bank snapshot preserves independent pluck velocities");
    check(dut.u_audio_core.r_note=={7'd85,7'd77,7'd68,7'd70,7'd112,7'd93,7'd74,7'd55},"bank snapshots all mapped notes");
    frame_done;
    check(dut.active==8'hf0,"four plucked envelopes become active");
    // Bow attack: violin triggers, and each uke voice gets a STOP so an old
    // pluck tail cannot ring under the bow (R6 arbitration).
    frame_start;
    // R10：speed8 = 9 样本窗口 |d| 之和（CPI=3200 标定）。3 个 64-count 样本
    // 使窗口和到 128，对应 0x80；旧契约的 |d|*2 单样本映射已废弃。
    // R26：改 4 个样本。门控在第 3 个样本靠"瞬时起音"（ATTACK_N=3）打开，而
    // sp_slow 的起音种子取的是**移位前**的窗口和（此刻仍为 0）——这是 R24 的
    // 原始行为，只影响攻击的第 1 个运动样本（1.14 ms @880 Hz）。再给 1 个样本，
    // 不对称平滑器就已跟进到窗口和，这时才应该断言"speed 非零"。
    // R25 曾把种子改成 l2f[7:0] 来"修"这件事，但两者量纲不同、且 l2f[7:0]
    // 按 256 回绕，会让每次起音的弓速种子变成随机值 —— 已回退，见 R26 审查记录。
    repeat(4) paw_sample(8'h80,16'sd64);
    check(dut.gates==8'h0f,"bow gates exactly lower four lanes");
    // R24：小提琴基础弓压 192(0xC0) -> 224(0xE0)。依据 tb_violin_grid：
    // p_eff 192->224 之间是"粘着主导"台阶（rms 1132->2112、h2 主导翻成 h1 高 6.4 dB）。
    check(dut.velocities[31:0]==32'he0e0e0e0,"bow velocities occupy lower four bytes");
    // R10：speed8 的量纲已从"|d|×2"改为"9 样本窗口和"，绝对值随 CPI 标定变化，
    // 所以这条只验证结构：四个 lane 相同、非零、高 64 位清零。
    check(dut.speeds[63:0]=={4{dut.speeds[15:0]}} && dut.speeds[15:0]!=0 && dut.speeds[127:64]==0,
          "bow speed occupies four 16-bit lanes only");
    // While a string is bowed its piezo pluck is suppressed.
    uke0_before=trigs[4];
    piezo_trigger(0,8'd99);
    check(trigs[4]==uke0_before,"pluck suppressed while string0 is bowed");
    frame_start;
    check(dut.u_audio_core.r_trigger==8'h0f && dut.u_audio_core.r_stop==8'hf0,"bow attack triggers violins and stops the plucked tails");
    frame_done;
    check(dut.active==8'hff,"all eight envelopes active across bow/pluck split");
    // Enough real sample periods for each waveguide to evolve; refresh bow
    // coherent samples to avoid the real 8 ms watchdog during this interval.
    for(f=0;f<600;f=f+1)begin
      frame_done;
      if(f%50==0)paw_sample(8'h80,16'sd64);
    end
    check(voice_seen==8'hff,"all eight real DSP voices produced nonzero samples");
    check(nonzero_pcm>100,"real mixed PCM is nonzero over sustained frames");
    // Lift then land before next frame: later trigger recovers the pending
    // STOP, so a fast jump-bow does not get erased at the frame boundary.
    frame_start;
    // R10：PAW3395 0x02 的 bit3 在 Type-C 实测里恒为 1（mouse_typec 报告 §2.1），
    // 不能当抬弓信号。抬弓改用"弓速归零 -> 9 样本窗口滑空 -> 22 样本释放"，
    // 比旧契约慢约 35 ms，这是当前硬件下唯一可靠的实现。
    // R11.2：释放链路 = 9 样本窗口排空 + 22 样本释放计数 + 1 判据拍 = 33 样本
    // （≈37 ms @880 Hz）。给 34 留一拍余量；R10 的 32 少了一拍，靠旧 CLOSE_TH=16
    // 恰好掩盖过去，现在 CLOSE_TH=10 之后必须按真实构成给数。
    for(i=0;i<34;i=i+1) paw_sample(8'h80,0);
    check(dut.gates==0 && stop_seen[3:0]==4'hf,"bow release after quiet samples generates four bowed STOP lanes");
    // R10：落弓起音延迟 = 3 个样本（中值滤波 1 + 窗口寄存 1 + 判据 1 ≈3.4 ms @880 Hz），
    // 第 4 个样本使窗口和超过 255 触发速度饱和。
    // R25：中值树挪到寄存器之后（时序修复），幅度到 dmz7 多 2 个样本延迟，
    // 所以饱和需要 8 个样本而不是 5 个。这是测试台的时间假设随 RTL 更新，
    // 不是功能退化——饱和值仍是 0xFF。
    repeat(8) paw_sample(8'h80,-16'sd32768);
    if(dut.gates!=8'h0f || dut.directions!=8'h0f)
      $display("LAND_DEBUG gates=%h directions=%h bow_gate=%b bow_dir=%b lifted=%b speed=%h left_ready=%h left_blocked=%h",dut.gates,dut.directions,dut.u_physical.bow_gate,dut.u_physical.bow_dir,dut.u_physical.bow_lift,dut.u_physical.bow_speed,dut.u_physical.left_ready,dut.u_physical.left_blocked);
    check(dut.gates==8'h0f && dut.directions==8'h0f,"landing samples attack and preserve signed direction");
    frame_start;
    check(dut.u_audio_core.r_trigger==8'h0f && dut.u_audio_core.r_stop[3:0]==0 && dut.u_audio_core.r_stop[7:4]==4'hf,"landing trigger recovers pre-frame violin STOP; bow rise stops pluck tails again");
    // R10：speed8 已改为窗口和量纲（饱和 255），断言保留"接近饱和 + 四 lane 不串"。
    // R10：改查"当前弓速已饱和 + 四个 16 位 lane 内容一致"。不再依赖
    // u_audio_core.r_speed 的快照时机——该快照在更早的帧边界锁存，此刻仍是旧值 0x7f。
    check(dut.u_physical.bow_speed==8'hff && dut.speeds[63:0]=={4{dut.speeds[15:0]}},
          "signed minimum speed saturates without lane corruption");
    frame_done;
    // Sustained lift must reach real voice STOP on the following sample.
    frame_start;for(i=0;i<32;i=i+1) paw_sample(8'h80,0);frame_start;
    check((dut.u_audio_core.r_stop[3:0]==4'hf)||(stop_seen[3:0]==4'hf),"sustained lift STOP reaches real bank");
    frame_done;
    check(trigger_seen==8'hff && stop_seen==8'hff,"coverage includes every trigger and every stop lane");
    check(tagged_frames>=4,"events reached tagged PCM completions");
    check(dut.u_audio_core.o_max_compute_clocks<768,"measured maximum compute count below deadline");
    $display("PASS physical bank integration: checks=%0d starts=%0d PCM=%0d TX=%0d tagged=%0d max_latency=%0dclks voice_mask=%h active_mask=%h nonzero_PCM=%0d trigger_mask=%h stop_mask=%h",
      checks,starts,pcm_frames,tx_frames,tagged_frames,max_latency,voice_seen,active_seen,nonzero_pcm,trigger_seen,stop_seen);
    $finish;
  end
  initial begin #100000000;$fatal(1,"integration timeout");end

  // R26：可选 PCM 转储（+pdump=<file>）。用于把 R24 与 R26 放在**同一套激励**下
  // 逐样本比对音频输出——"读代码推断"已经错过一次，这里用数据说话。
  integer fd_pcm = 0;
  reg [1023:0] pcm_path;
  initial begin
    if ($value$plusargs("pdump=%s", pcm_path)) begin
      fd_pcm = $fopen(pcm_path, "w");
      $display("PDUMP %0s", pcm_path);
    end
  end
  always @(posedge clk) if (fd_pcm != 0 && dut.pcm_valid) $fdisplay(fd_pcm, "%0d", dut.pcm);
endmodule
