`include "instrument_constants.vh"
// Tang Mega 60K: one 50MHz control/audio domain; video owns its PLL.
// CN2/H4/H6 are the only performer inputs. No UART test path is synthesized.
module tang_mega_60k_top #(
    parameter integer CLOCK_HZ=`INST_CLOCK_HZ,
    parameter integer ENABLE_HDMI=1,
    parameter integer USE_EXTERNAL_AUDIO_CLOCK=0,
    parameter integer BCLK_HZ=`INST_PT8211_BCLK_HZ,
    parameter integer ENABLE_AUDIO_SMOKE=0,
    parameter integer BOW_AXIS_Y=1
)(
    input clk_50m,audio_bck_in,reset_n,input mode_n,
    // R19：ESP32 链路（LINK v2）。E14 = ESP_TX -> FPGA，E13 = FPGA -> ESP_RX，
    // 经 R6/R5 33R 串联。第一次提交只验证资源，参数输出暂不接入。
    input uart_rx_i,output uart_tx_o,
    output hp_bck,hp_ws,hp_din,output reg pa_en,
    output paw_ncs,paw_sclk,paw_mosi,input paw_miso,
    output left_adc_sclk,left_adc_din,left_adc1_cs_n,input left_adc1_out,
    output left_adc2_cs_n,input left_adc2_out,
    output left_tx1,left_tx2,left_tx3,left_tx4,left_sk_clk,left_sk_data,
    output piezo_sclk,piezo_mosi,input piezo_miso,
    output piezo_cs_n,piezo_convst_n,piezo_reset_n,input piezo_busy_n,
    output [2:0] hdmi_data_p,hdmi_data_n,
    output hdmi_clock_p,hdmi_clock_n,hdmi_tx_enable
);
    localparam integer HALF_BCLK_DIV=CLOCK_HZ/(2*BCLK_HZ);
    // ================= R29：链路拆成 4 个独立开关 =================
    // 用户实测：R25=S2 自鸣 / R26=S3 自鸣 / R27(链路不例化)=正常 / R28(链路在,抽头断开)=正常。
    // 结论：问题出在"把真实音频接进链路"这一步（R26→R28 只差这一行），
    // 所以不需要一根一根盲试，按下面四个开关逐级放行即可，每级只多开一件事。
    //
    //   LINK_ENABLE        : 链路模块是否例化。0 = 完全不例化（E13 空闲高、无 6 块 BSRAM）
    //   LINK_AUDIO_ENABLE  : 参数通路——定弦 / FX / 表现参数 / 颤音深度
    //   LINK_SCORE_ENABLE  : 曲谱通路——lane_arbiter + score 事件合流
    //   LINK_VOLUME_ENABLE : 音量是否由 ESP32 控制（0 = 固定 0 dB）。
//                        R36 起音量在 pt8211_tx 内部做，不再另插一级、不再延迟 valid
    //                        **这一项是已知会引出自鸣的那一步，必须最后开**
    localparam integer LINK_ENABLE        = 1;
    localparam integer LINK_AUDIO_ENABLE  = 1;
    localparam integer LINK_SCORE_ENABLE  = 1;
    localparam integer LINK_VOLUME_ENABLE = 1;
    // R31 起新增：录音抽头单独一个开关。
    // 为什么要拆开：i_pcm 原来同时喂 audio_volume（DAC 用）与 rec_ladpcm（录音用），
    // 关掉录音就等于关掉音量输入。拆成 i_pcm / i_rec_pcm 两组端口之后，
    // "音量开、录音关" 成为一个可测的中间态——如果它正常、只有 TAP=1 才自鸣，
    // 就说明问题只在 rec_ladpcm（LADPCM 编码器持续翻转），与 audio_volume 无关。
    localparam integer LINK_PCM_TAP       = 1;
    localparam integer SAMPLE_RATE_MILLIHZ=USE_EXTERNAL_AUDIO_CLOCK ? 48000000 :
        (64'd1000*CLOCK_HZ)/(64*HALF_BCLK_DIV);
    reg [2:0] reset_release=0;
    always @(posedge clk_50m)begin
        if(!reset_n)reset_release<=0;else reset_release<={reset_release[1:0],1'b1};
    end
    wire reset=~reset_release[2];
    // R11.2：恢复 R9 的三页切换。KEY1(AB13) 短按循环 GUIDE->PLAY->MONITOR，
    // 长按 1 s 请求左手重标定。R11.1 把它砍成固定 2'b00(GUIDE)，导致
    // 用户看不到 PLAY 页的琴颈选品与小提琴联动。
    wire [1:0] display_mode;
    wire left_recalib;
    stage_mode_button #(.DEBOUNCE_TICKS(CLOCK_HZ/100),.LONG_TICKS(CLOCK_HZ)) u_mode(
        .clk(clk_50m),.reset(reset),.key_n(mode_n),
        .mode(display_mode),.recalib(left_recalib));
    wire [55:0] notes;
    wire [7:0] gates,triggers,stops,directions,active;
    wire [63:0] velocities;
    wire [127:0] speeds;
    wire [191:0] positions;
    wire [3:0] view;
    wire event_valid;
    wire [31:0] event_sequence;
    wire [63:0] event_clock;
    wire [15:0] left_status;
    // R7 传感器显示信号
    wire [63:0] w_piezo_ay;
    wire [3:0] w_piezo_warm,w_piezo_fire;
    wire [7:0] w_piezo_vibrato;   // R17：拍琴身 -> 颤音深度
    wire w_piezo_ev_valid;
    wire [3:0] w_piezo_ev_strings;
    wire [15:0] w_piezo_ev_total;
    wire [7:0] w_bow_debug,w_bow_speed;
    wire signed [15:0] w_bow_pos_x,w_bow_pos_y;
    wire w_piezo_smpl_valid;
    wire [1:0] w_piezo_smpl_ch;
    wire [19:0] w_left_fret;
    // ---- R25：LINK v2 参数总线 ----
    // 全部必须在 u_physical(74 行) 与 u_audio_core(110 行) 之前显式声明：
    // Verilog 会给"先用后声明"的标识符隐式建一根 1 bit 线网，之后显式声明就报重复。
    // 上电默认值见 src/link_regs.v，逐条等于 R24 的硬编码常量。
    wire [11:0] lk_tone_warm, lk_tone_bright;
    wire        lk_tone_enable;
    // R52：选弦控制。默认全中性（manual=0/force=0/thr=32），
    // 与 link_regs 复位值和 LINK_OFF 分支逐位一致。
    wire        lk_sel_manual, lk_sel_freeze;
    wire [2:0]  lk_sel_force;
    wire [7:0]  lk_sel_thr;
    wire [7:0]  sel_stat;
    wire [15:0] tone_clip;
    wire [7:0]  lk_volume, lk_wet, lk_damping, lk_sens;   // R43: lk_lane_en 删除
    wire [1:0]  lk_tail;
    wire        lk_bypass, lk_mute;
    wire [31:0] lk_vdep, lk_vrate, lk_glide;
    wire [3:0]  lk_auto;
    wire [15:0] lk_bow_db;
    wire [55:0] lk_tune;
    wire        lk_ev_valid;
    wire [1:0]  lk_ev_kind;
    wire [2:0]  lk_ev_lane;
    wire [6:0]  lk_ev_note, lk_ev_vel;
    wire [7:0]  lk_score_state;
    wire        lk_pcm_valid;
    wire signed [15:0] lk_pcm;
    wire [7:0]  lk_err, lk_ok, lk_bad, lk_drop;
    // 颤音深度：取值逻辑见下面 R26 的 aud_vib（要和 LINK_AUDIO_ENABLE 一起折叠，
    // 所以不能在这里提前算成一个独立 wire，否则合成器会在 =0 时也留一个 mux）。
    wire [55:0] smoke_notes;
    wire [7:0] smoke_gates,smoke_triggers,smoke_stops;
    wire smoke_event;
    wire [31:0] smoke_sequence;
    wire [63:0] smoke_clock;
    wire [127:0] smoke_speeds={64'd0,{4{16'd64}}};
    audio_smoke_driver #(.CLOCK_HZ(CLOCK_HZ)) u_smoke(
        .clk(clk_50m),.reset(reset),.note_bus(smoke_notes),.gate_bus(smoke_gates),
        .trigger_bus(smoke_triggers),.stop_bus(smoke_stops),.event_valid(smoke_event),
        .event_sequence(smoke_sequence),.event_clock(smoke_clock));
    physical_performer_frontend #(.CLOCK_HZ(CLOCK_HZ),.BOW_AXIS_Y(BOW_AXIS_Y)) u_physical(
        .clk_50m(clk_50m),.reset(reset),.paw_ncs(paw_ncs),.paw_sclk(paw_sclk),
        .paw_mosi(paw_mosi),.paw_miso(paw_miso),.left_adc_sclk(left_adc_sclk),
        .left_adc_din(left_adc_din),.left_adc1_cs_n(left_adc1_cs_n),.left_adc1_out(left_adc1_out),
        .left_adc2_cs_n(left_adc2_cs_n),.left_adc2_out(left_adc2_out),
        .left_tx1(left_tx1),.left_tx2(left_tx2),.left_tx3(left_tx3),.left_tx4(left_tx4),
        .left_sk_clk(left_sk_clk),.left_sk_data(left_sk_data),.piezo_sclk(piezo_sclk),
        .piezo_mosi(piezo_mosi),.piezo_miso(piezo_miso),.piezo_cs_n(piezo_cs_n),
        .piezo_convst_n(piezo_convst_n),.piezo_reset_n(piezo_reset_n),.piezo_busy_n(piezo_busy_n),
        .note_bus(notes),.gate_bus(gates),.trigger_bus(triggers),.stop_bus(stops),
        .i_tune((LINK_AUDIO_ENABLE!=0) ? lk_tune : 56'd0),
        // R52：选弦控制（默认中性，等价于 R51）
        .i_sel_thr(lk_sel_thr), .i_sel_freeze(lk_sel_freeze),
        .i_sel_manual(lk_sel_manual), .i_sel_force(lk_sel_force),
        .o_sel_stat(sel_stat),
        .velocity_bus(velocities),.speed_bus(speeds),.position_bus(positions),
        .direction_bus(directions),.view_instrument(view),.event_valid(event_valid),
        .event_sequence(event_sequence),.event_clock(event_clock),.sensor_ready(),.sensor_fault(),.left_status(left_status),
        .piezo_ay(w_piezo_ay),.piezo_warm(w_piezo_warm),
        .piezo_ev_valid(w_piezo_ev_valid),.piezo_ev_strings(w_piezo_ev_strings),.piezo_ev_total(w_piezo_ev_total),
        .bow_gate_debug(w_bow_debug),.bow_speed_debug(w_bow_speed),
        .paw_dx_debug(),.paw_dy_debug(),.bow_pos_x(w_bow_pos_x),.bow_pos_y(w_bow_pos_y),
        .piezo_smpl_valid(w_piezo_smpl_valid),.piezo_smpl_ch(w_piezo_smpl_ch),
        .left_fret_bus(w_left_fret),.piezo_fire(w_piezo_fire),
        .piezo_vibrato(w_piezo_vibrato)
    );
    wire signed [15:0] pcm,frame_pcm;
    wire pcm_valid,pcm_event,ready,sample_tick,frame_pcm_valid;
    wire [31:0] pcm_sequence,pcm_first_sequence;
    wire [63:0] pcm_event_clock;
    wire [15:0] pcm_event_count;
    wire event_complete,frame_complete;
    wire [31:0] frame_sequence,frame_first_sequence;
    wire [63:0] frame_event_clock;
    wire [15:0] frame_event_count;
    // 总音色控制（来自 ESP32 链路）。声明已上移到 w_left_fret 之后，
    // 因为 u_physical 也要用 lk_tune。
    // ================= R33：曲谱只做"演奏指引"，不参与发声 =================
    // 用户明确要求：曲谱导入是为了**提示演奏者该按哪根弦、哪个品**，不是自动播放。
    // 所以这里不再把曲谱事件合并进演奏总线：
    //   · 演奏总线（note / gate / trigger / stop / speed / event）全部直连物理前端，
    //     与用户已验证正常的 R29 逐位一致。
    //     R30 把 lane_arbiter 串进这条总线之后出现"第二弦不正常"，而 R29→R30
    //     的唯一差别就是它，所以这一步同时消除了该异常。
    //   · 曲谱事件只用来锁存"当前指引目标"，送显示域画目标框。
    //
    // lane_arbiter.v 仍保留在工程里（未例化）。若将来确实需要自动演奏，
    // 再把它接回来，并单独验证一次（它会改变演奏总线网表）。
    //
    // lane_enable 说明：`instrument_bank_core` 并没有 i_lane_enable 端口
    // （grep 可见只有 VIOLIN_TRIM_SHIFT），所以 SET_TIMBRE 原本只能屏蔽
    // gate/trigger，做不到"把某根弦换成尤克里里"。这次一并去掉掩码，
    // 避免它在演奏总线上多出一级与门、破坏与 R29 的逐位一致性。
    wire [55:0]  aud_note   = notes;
    wire [7:0]   aud_gate   = gates;
    wire [7:0]   aud_trig   = triggers;
    wire [7:0]   aud_stop   = stops;
    wire [7:0]   aud_dir    = directions;
    wire         aud_ev     = event_valid;
    wire [63:0]  aud_vel    = velocities;
    wire [127:0] aud_spd    = speeds;
    wire [55:0]  aud_tune   = (LINK_AUDIO_ENABLE!=0) ? lk_tune    : 56'd0;
    wire [31:0]  aud_vdep   = (LINK_AUDIO_ENABLE!=0) ? lk_vdep    : 32'd0;
    wire [31:0]  aud_vrate  = (LINK_AUDIO_ENABLE!=0) ? lk_vrate   : 32'h30303030;
    wire [31:0]  aud_glide  = (LINK_AUDIO_ENABLE!=0) ? lk_glide   : 32'd0;
    wire [3:0]   aud_auto   = (LINK_AUDIO_ENABLE!=0) ? lk_auto    : 4'hf;
    wire         aud_bypass = (LINK_AUDIO_ENABLE!=0) ? lk_bypass  : 1'b1;
    wire [7:0]   aud_wet    = (LINK_AUDIO_ENABLE!=0) ? lk_wet     : 8'd64;
    wire [7:0]   aud_damp   = (LINK_AUDIO_ENABLE!=0) ? lk_damping : 8'd128;
    wire [1:0]   aud_tail   = (LINK_AUDIO_ENABLE!=0) ? lk_tail    : 2'd1;
    // 颤音深度：0 = 完全等于 R17 的"拍琴身→颤音"；1 = ESP32 设了非零值才接管
    wire [7:0]   aud_vib    = (LINK_AUDIO_ENABLE!=0 && lk_vdep[7:0]!=8'd0) ?
                              lk_vdep[7:0] : w_piezo_vibrato;

    // ---------------- R33：曲谱指引目标（只给显示用） ----------------
    // 曲谱事件仍是 6 字节格式（kind/lane/note/vel/tick），但**不再驱动发声**。
    // 这里把"最近一个音符事件"锁存成指引目标：弦号 + 音高，再按定弦换算品位。
    // STOP 事件只清除该弦的目标；换音（新的 BOW/PLUCK）直接覆盖。
    reg [2:0]  g_lane;
    reg [6:0]  g_note;
    reg        g_valid;
    always @(posedge clk_50m) begin
        if (reset) begin
            g_lane  <= 3'd0;
            g_note  <= 7'd0;
            g_valid <= 1'b0;
        end else if (LINK_SCORE_ENABLE == 0) begin
            g_lane  <= 3'd0;
            g_note  <= 7'd0;
            g_valid <= 1'b0;
        end else if (lk_ev_valid) begin
            if (lk_ev_kind == 2'd2) begin           // STOP：目标消失
                if (lk_ev_lane == g_lane) g_valid <= 1'b0;
            end else if (lk_ev_kind != 2'd3) begin  // PLUCK / BOW：换成新目标
                g_lane  <= lk_ev_lane;
                g_note  <= lk_ev_note;
                g_valid <= 1'b1;
            end
        end
        // 为什么不在这里判断 score_state==0 就清目标：
        // 短曲谱（比如单音练习只有一个事件）会在 1 ms 内播完、state 立刻回 0，
        // 目标框只闪一下就没，完全没法跟弹（实测 tb_score_guide 的 G2 点）。
        // 改成"保留到下一次事件/STOP/关闭指引"，符合跟弹的实际用法。
    end

    // 该弦的空弦音高（定弦可被 ESP32 改；AUDIO 关闭时用默认值）
    reg [6:0] g_open;
    always @(*) begin
        case (g_lane)
            3'd0: g_open = lk_tune[6:0];
            3'd1: g_open = lk_tune[13:7];
            3'd2: g_open = lk_tune[20:14];
            3'd3: g_open = lk_tune[27:21];
            3'd4: g_open = lk_tune[34:28];
            3'd5: g_open = lk_tune[41:35];
            3'd6: g_open = lk_tune[48:42];
            default: g_open = lk_tune[55:49];
        endcase
    end
    // 品位 = 音高 - 空弦。琴颈图只画 16 品，超出的按 16 显示（仍能提示"高把位"）。
    wire [7:0] g_diff  = (LINK_AUDIO_ENABLE!=0 && g_note >= g_open) ?
                         ({1'b0, g_note} - {1'b0, g_open}) : 8'd0;
    wire [4:0] g_fret  = (g_diff > 8'd16) ? 5'd16 : g_diff[4:0];
    wire       g_show  = g_valid && (LINK_SCORE_ENABLE != 0);

    // ---------------- R39：录音抽头从 DAC 末端取，绝不碰音频总线 ----------------
    // 事故链（全部是实板实测，仿真里三态逐样本相同的）：R26 把 pcm 同时喂 audio_volume
    // 和 rec_ladpcm → 一根弦自鸣；R34 把 16 根 pcm 绕进链路模块再折回 → 弦 2 乱响；
    // R38 只是把 pcm 经一级寄存器送进链路模块 → S1/S2 随机自鸣。
    // 三次都是同一个机制：**音频总线被拉进别的区域**（长线 + 反相翻转电流 + 扇出翻倍），
    // 而不是逻辑算错。所以任何"把 pcm 引出去"的写法都是隐患，无论寄存器几级。
    //
    // R39 改成从 pt8211_tx 的 o_frame_pcm 取样——那是 DAC 实际装载的、已经寄存的样本，
    // 每帧跟着 o_frame_pcm_valid 一个单拍脉冲。这样：
    //   · pcm 总线的负载**一个都不增加**：它仍然只连 pt8211_tx 一个模块；
    //   · 录音抽头在 DAC 之后，单向，物理上不存在回灌发声的通路；
    //   · 链路模块只看到 byte_valid + byte_data[7:0]，9 根 12.2 KB/s 的低频线。
    // 代价：录的是**音量之后**的信号 —— 在手机上调音量会同时改变录音内容。
    // 这是刻意取舍："绝不干扰发声"优先于"录音不受音量影响"。
    wire        rec_byte_valid;
    wire [7:0]  rec_byte_data;
    wire [7:0]  lk_rec_ctrl;

    generate if (LINK_PCM_TAP != 0 && LINK_ENABLE != 0) begin: REC_TAP
        // R40：改用极简抽头（抽取 + 8 位截断，约 12 FF / <20 LUT），
        // 不再用 rec_ladpcm（250+ LUT）。原因见 src/rec_tap_u8.v 顶部注释。
        rec_tap_u8 u_rec_tap (
            .clk(clk_50m), .reset(reset),
            .enable(lk_rec_ctrl[0]), .decim(lk_rec_ctrl[3:1]),
            .pcm_valid(frame_pcm_valid), .pcm(frame_pcm),
            .byte_valid(rec_byte_valid), .byte_data(rec_byte_data)
        );
    end else begin: REC_OFF
        assign rec_byte_valid = 1'b0;
        assign rec_byte_data  = 8'd0;
    end endgenerate
    // ---- R36：DAC 输入固定直连 pcm（与 R33 完全一致）----
    // 音量不再在 DAC 前面另插一级，而是搬进 pt8211_tx 内部的帧装载处
    // （见 src/pt8211_tx.v 的 i_volume 注释）。这样：
    //   · i_sample_valid 与 i_sample 仍然同拍 —— mailbox 的边沿敏感握手不受影响
    //   · 16 根 pcm 网络的走线长度与 R33 完全相同
    //   · vol=128（上电默认）时逐位直通，DAC 输出与 R33 逐字节相同
    // R34 就是把这两条同时破坏了：多一级寄存器让 valid 晚一拍，于是
    // r_requested/r_pending 握手错位 → 漏帧/重复帧 → 持续的粗糙噪声。
    wire signed [15:0] dac_pcm   = pcm;
    wire               dac_valid = pcm_valid;
    // 音量来源：LINK_VOLUME_ENABLE=1 时由 ESP32 的 REG_VOLUME 控制，否则固定 0 dB。
    // 0 dB 时 pt8211_tx 内部走直通分支，乘法器被常量折叠 —— DAC 输出与 R33 逐位相同。
    wire [7:0] dac_volume = (LINK_VOLUME_ENABLE!=0) ? lk_volume : 8'd128;
    // Preserve the qualified 4V+4U waveguide/TDM schedule and sound parameters.
    instrument_bank_core #(.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) u_audio_core(
        .i_clk(clk_50m),.i_reset(reset),.i_sample_tick(sample_tick),
        .i_event(ENABLE_AUDIO_SMOKE!=0?smoke_event:aud_ev),
        .i_event_sequence(ENABLE_AUDIO_SMOKE!=0?smoke_sequence:event_sequence),
        .i_event_clock(ENABLE_AUDIO_SMOKE!=0?smoke_clock:event_clock),
        .i_note_bus(ENABLE_AUDIO_SMOKE!=0?smoke_notes:aud_note),
        .i_gate_bus(ENABLE_AUDIO_SMOKE!=0?smoke_gates:aud_gate),
        .i_trigger_bus(ENABLE_AUDIO_SMOKE!=0?smoke_triggers:aud_trig),
        .i_stop_bus(ENABLE_AUDIO_SMOKE!=0?smoke_stops:aud_stop),
        .i_velocity_bus(aud_vel),.i_speed_bus(ENABLE_AUDIO_SMOKE!=0?smoke_speeds:aud_spd),.i_position_bus(positions),
        .i_direction_bus(aud_dir),.i_vibrato_depth({4{aud_vib}}),.i_vibrato_rate(aud_vrate),
        .i_glide_ms(aud_glide),.i_auto_expression(aud_auto),.i_emergency(1'b0),
        .i_fx_bypass(aud_bypass),.i_wet(aud_wet),.i_damping(aud_damp),.i_tail(aud_tail),
        .i_tone_bright(lk_tone_bright),.i_tone_warm(lk_tone_warm),.i_tone_enable(lk_tone_enable),
        .o_tone_clip(tone_clip),
        .o_audio_sample(pcm),.o_audio_sample_valid(pcm_valid),.o_audio_first_sample(pcm_event),
        .o_ready(ready),.o_voice_sample_bus(),.o_active_mask(active),.o_body_guards(),.o_body_clips(),
        .o_output_sequence(pcm_sequence),.o_output_event_clock(pcm_event_clock),
        .o_output_first_sequence(pcm_first_sequence),.o_output_event_count(pcm_event_count),
        .o_reverb_guard(),.o_deadline_count(),.o_max_compute_clocks(),.o_clip_count()
    );
    wire audio_lost,audio_ready;
    reg [15:0] bck_age;
    reg [2:0] bck_sync;
    reg bck_previous,external_qualified;
    assign audio_lost=USE_EXTERNAL_AUDIO_CLOCK && bck_age>=CLOCK_HZ/1000;
    assign audio_ready=ready && (!USE_EXTERNAL_AUDIO_CLOCK || (!audio_lost && external_qualified));
    always @(posedge clk_50m)begin
        if(reset)begin bck_age<=0;bck_sync<=0;bck_previous<=0;external_qualified<=0;end
        else if(USE_EXTERNAL_AUDIO_CLOCK)begin
            bck_sync<={bck_sync[1:0],audio_bck_in};bck_previous<=bck_sync[2];
            if(bck_sync[2]!=bck_previous)bck_age<=0;
            else if(bck_age<CLOCK_HZ/1000)bck_age<=bck_age+1'b1;
            if(audio_lost)external_qualified<=0;else if(frame_complete)external_qualified<=1;
        end else begin bck_age<=0;bck_sync<=0;bck_previous<=0;external_qualified<=1;end
        pa_en<=reset || !audio_ready;
    end
    generate if(USE_EXTERNAL_AUDIO_CLOCK)begin: EXTERNAL_AUDIO
        pt8211_external_tx u_tx(
            .i_clk(clk_50m),.i_reset(reset||audio_lost),.i_bck(audio_bck_in),
            // R25：经 audio_volume（vol=128 时逐位直通）后再送 DAC。
            // 延迟 +1 个采样周期（20.5 µs @48.8 kHz），valid 与 sample 同步延后。
            .i_sample(dac_pcm),.i_sample_valid(dac_valid),.i_sample_event(pcm_event),.i_sample_ready(ready),
            .i_sample_sequence(pcm_sequence),.i_sample_event_clock(pcm_event_clock),
            .i_sample_first_sequence(pcm_first_sequence),.i_sample_event_count(pcm_event_count),
            .o_frame_first_sequence(frame_first_sequence),.o_frame_event_count(frame_event_count),
            .o_frame_event_sequence(frame_sequence),.o_frame_event_clock(frame_event_clock),
            .o_hp_bck(hp_bck),.o_hp_ws(hp_ws),.o_hp_din(hp_din),.o_sample_tick(sample_tick),
            .o_frame_pcm(frame_pcm),.o_frame_pcm_valid(frame_pcm_valid),.o_left_word_complete(),
            .o_frame_word_complete(frame_complete),.o_event_frame_complete(event_complete),
            .o_underrun_count(),.o_overrun_count(),.o_frame_sequence()
        );
    end else begin: INTERNAL_AUDIO
        pt8211_tx #(.CLOCK_HZ(CLOCK_HZ),.BCLK_HZ(BCLK_HZ),.USE_VALID_MAILBOX(1)) u_tx(
            .i_clk(clk_50m),.i_reset(reset),.i_sample(dac_pcm),.i_sample_valid(dac_valid),
            .i_volume(dac_volume),
            .i_sample_event(pcm_event),.i_sample_ready(ready),
            .i_sample_sequence(pcm_sequence),.i_sample_event_clock(pcm_event_clock),
            .i_sample_first_sequence(pcm_first_sequence),.i_sample_event_count(pcm_event_count),
            .o_frame_first_sequence(frame_first_sequence),.o_frame_event_count(frame_event_count),
            .o_frame_event_sequence(frame_sequence),.o_frame_event_clock(frame_event_clock),
            .o_hp_bck(hp_bck),.o_hp_ws(hp_ws),.o_hp_din(hp_din),.o_sample_tick(sample_tick),
            .o_first_sample(),.o_frame_pcm(frame_pcm),.o_frame_pcm_valid(frame_pcm_valid),
            .o_left_word_complete(),.o_frame_word_complete(frame_complete),
            .o_event_frame_complete(event_complete),.o_underrun_count(),.o_overrun_count(),.o_frame_sequence()
        );
    end endgenerate
    wire [31:0] latency_us;
    latency_probe #(.CLOCK_HZ(CLOCK_HZ),.MAX_WAIT_CYCLES(CLOCK_HZ/200)) u_latency(
        .i_clk(clk_50m),.i_reset(reset),.i_event(event_valid),.i_audio_first_sample(event_complete),
        // E14/E13 connect to the mainboard ESP32 UART. Keep measurement
        // internal until a physically unshared observation connector is wired.
        .o_gpio_event(),.o_gpio_audio(),.o_measure_valid(),
        .o_cycles(),.o_microseconds(latency_us),.o_timeout(),.o_overrun()
    );
    wire [27:0] view_notes;
    wire [3:0] view_gates,view_directions;
    wire [31:0] view_velocities,view_speeds;
    wire [95:0] view_positions;
    genvar v;
    generate for(v=0;v<4;v=v+1)begin: DISPLAY_VIEW
        assign view_notes[v*7 +:7]=view[v]?notes[(v+4)*7 +:7]:notes[v*7 +:7];
        assign view_gates[v]=view[v]?active[v+4]:active[v];
        assign view_velocities[v*8 +:8]=view[v]?velocities[(v+4)*8 +:8]:velocities[v*8 +:8];
        assign view_speeds[v*8 +:8]=speeds[v*16 +:8];
        assign view_positions[v*24 +:24]=positions[v*24 +:24];
        assign view_directions[v]=directions[v];
    end endgenerate
    assign hdmi_tx_enable=(ENABLE_HDMI!=0);
    generate if(ENABLE_HDMI)begin: VIDEO
        hdmi_instrument_display u_display(
            // R10.1: R9 显示需要一个模式请求位；当前无按键模块，固定 GUIDE(0)。
            .i_mode(display_mode),
            .i_open_notes(`INST_DEFAULT_OPEN_NOTES),.i_bow_speeds(view_speeds),
            .i_bow_positions(view_positions),.i_directions(view_directions),
            .i_clk_50m(clk_50m),.i_reset(reset),.i_pcm_valid(frame_pcm_valid),.i_pcm(frame_pcm),
            .i_notes(view_notes),.i_gates(view_gates),.i_instruments(view),.i_velocities(view_velocities),
            // R33：曲谱指引目标（只显示，不发声）
            .i_guide_lane(g_lane),.i_guide_fret(g_fret),.i_guide_valid(g_show),
            .i_latency_us(latency_us),.i_audio_ready(audio_ready),
            .i_fret_bus(w_left_fret),.i_left_valid(left_status[15:12]),
            .i_left_fault(left_status[3:0]|left_status[7:4]),
            .i_bow_pos_x(w_bow_pos_x),.i_bow_pos_y(w_bow_pos_y),
            .i_bow_speed(w_bow_speed),.i_bow_dir(directions[0]),.i_bow_gates(gates[3:0]),
            .i_ev_valid(w_piezo_ev_valid),.i_ev_strings(w_piezo_ev_strings),.i_ev_total(w_piezo_ev_total),
            .i_fire(w_piezo_fire),.i_piezo_warm(w_piezo_warm),
            .i_bow_debug(w_bow_debug),.i_piezo_ay(w_piezo_ay),
            .i_piezo_smpl_valid(w_piezo_smpl_valid),.i_piezo_smpl_ch(w_piezo_smpl_ch),
            .o_tmds_data_p(hdmi_data_p),
            .o_tmds_data_n(hdmi_data_n),.o_tmds_clock_p(hdmi_clock_p),.o_tmds_clock_n(hdmi_clock_n)
        );
    end else begin: NO_VIDEO
        assign hdmi_data_p=0;assign hdmi_data_n=0;assign hdmi_clock_p=0;assign hdmi_clock_n=0;
    end endgenerate

    // ================= ESP32 链路（LINK v2）第二次提交 =================
    // R24 及以前：只有音色三项接通，其余参数输出全部悬空、PCM 输入接 0。
    // R25：FX 四项 / 表现参数 / 音量 / 录音 / 定弦 / lane_enable / 曲谱播放
    //      全部接通。每一项的上电默认值都等于 R24 的硬编码常量（见 link_regs.v），
    //      所以 ESP32 不插线时，声音路径与 R24 逐位相同。
    // 声明已上移到 u_audio_core 之前（隐式 1 bit 线网陷阱），此处只做例化。

    generate if (LINK_ENABLE != 0) begin: LINK_ON
    tang_link_top u_link (
        .clk(clk_50m), .reset(reset),
        .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
        .o_volume(lk_volume), .o_wet(lk_wet), .o_damping(lk_damping),
        .o_tail(lk_tail), .o_fx_bypass(lk_bypass),
        .o_sens_pluck(lk_sens), .o_bow_deadband(lk_bow_db),
        .o_vib_depth(lk_vdep), .o_vib_rate(lk_vrate), .o_glide_ms(lk_glide),
        .o_auto_expr(lk_auto),          // R43: .o_lane_enable 不再引出
        .o_mute(lk_mute), .o_tune(lk_tune),
        .o_tone_warm(lk_tone_warm), .o_tone_bright(lk_tone_bright),
        .o_tone_enable(lk_tone_enable), .i_tone_clip(tone_clip),
        .o_sel_manual(lk_sel_manual), .o_sel_freeze(lk_sel_freeze),
        .o_sel_force(lk_sel_force), .o_sel_thr(lk_sel_thr),
        .i_sel_stat(sel_stat),
        .o_ev_valid(lk_ev_valid), .o_ev_kind(lk_ev_kind), .o_ev_lane(lk_ev_lane),
        .o_ev_note(lk_ev_note), .o_ev_vel(lk_ev_vel),
        .o_score_state(lk_score_state),
        // R28：录音/音量抽头**默认不接**（与 R24 一致，硬接 0）。
        // 原因：R25/R26 把真实音频接进 audio_volume + rec_ladpcm 之后，多了一个
        // 18×18 乘法器和一组 16 位寄存器在 48.8 kHz 上持续翻转；R24 时它们是静止的
        // （pcm_in 恒 0 → product 恒 0）。这是 R24 与 R26 之间**唯一新增的持续翻转
        // 数据通路**，而实测 R26 会有一根弦自鸣、R27（链路整个不例化）正常。
        // 录音功能需要 LINK_AUDIO_ENABLE=1 才接通——那时链路本来就是"全功能"形态。
        // R36：链路自己的 audio_volume 不再参与 DAC 通路（音量已搬进 pt8211_tx）。
        // 这里把 i_pcm 固定接 0，让 u_vol 像 R33 那样被完全优化掉，
        // 保证默认构建的音频网表与 R33 逐门一致。
        // 录音源只受 LINK_PCM_TAP 控制（不再依赖 LINK_VOLUME_ENABLE）——
        // 音量与录音彻底解耦，这也是 R31/R32 当初要拆开的那个结构性问题。
        .i_pcm_valid(1'b0),
        .i_pcm(16'sd0),
        .i_rec_byte_valid(rec_byte_valid),
        .i_rec_byte_data(rec_byte_data),
        .o_rec_ctrl(lk_rec_ctrl),
        .o_pcm_valid(lk_pcm_valid), .o_pcm(lk_pcm),
        .o_stat_err(lk_err), .o_stat_ok(lk_ok), .o_stat_bad(lk_bad),
        .o_rec_drop(lk_drop)
    );
    end else begin: LINK_OFF
        // 链路不例化：所有参数钉在 R24 的硬编码常量上，UART 输出恒定空闲高。
        // 这些值必须和 link_regs.v 的复位值逐条相同——否则"关掉链路"本身就成了
        // 一次参数改动。校验见 sim/tb_link_boot.v 的同名断言。
        assign uart_tx_o      = 1'b1;
        assign lk_volume      = 8'd128;
        assign lk_wet         = 8'd64;
        assign lk_damping     = 8'd128;
        assign lk_tail        = 2'd1;
        assign lk_bypass      = 1'b1;
        assign lk_sens        = 8'd0;
        assign lk_bow_db      = 16'd0;
        assign lk_vdep        = 32'd0;
        assign lk_vrate       = 32'h30303030;
        assign lk_glide       = 32'd0;
        assign lk_auto        = 4'hf;
        assign lk_mute        = 1'b0;
        assign lk_rec_ctrl    = 8'd0;   // R39：录音控制寄存器在链路内，关掉链路时钉 0
        assign lk_tune        = {7'd69, 7'd64, 7'd60, 7'd67, 7'd76, 7'd69, 7'd62, 7'd55};
        assign lk_tone_warm   = 12'h800;
        assign lk_tone_bright = 12'h800;
        assign lk_tone_enable = 1'b1;
        // R52：关掉链路时选弦控制钉在"全自动"，与 link_regs 复位值一致。
        // 注意 freeze 必须是 0 —— 置 1 会让投票永久冻结。
        assign lk_sel_manual = 1'b0;
        assign lk_sel_freeze = 1'b0;
        assign lk_sel_force  = 3'd0;
        assign lk_sel_thr    = 8'd32;
        assign lk_ev_valid    = 1'b0;
        assign lk_ev_kind     = 2'd0;
        assign lk_ev_lane     = 3'd0;
        assign lk_ev_note     = 7'd0;
        assign lk_ev_vel      = 7'd0;
        assign lk_score_state = 8'd0;
        assign lk_pcm_valid   = 1'b0;
        assign lk_pcm         = 16'sd0;
        assign lk_err         = 8'd0;
        assign lk_ok          = 8'd0;
        assign lk_bad         = 8'd0;
        assign lk_drop        = 8'd0;
    end endgenerate
endmodule
