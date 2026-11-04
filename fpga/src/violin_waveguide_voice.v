// 双支路弓弦波导：弓点连接琴桥与琴枕的往返速度波传播延迟。
// 摩擦参考 Smith/STK 的速度差反射系数；琴体由 bank 公共 TDM 引擎处理。
// STK Bowed separates clear(), startBowing(), setFrequency() and stopBowing().
// Here cold starts clear logical history, while recontact keeps the string
// ringing. Coefficients and control mapping remain engineering presets.
module violin_waveguide_voice #(
    parameter integer DELAY_LINE_LENGTH = 2048,
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer SAMPLE_RATE_MILLIHZ = 48828125,
    parameter integer ENABLE_BOW_LIFECYCLE = 1,
    parameter integer ENABLE_FULL_SPEED_RANGE = 1,
    // 1: R8 reference LUT; 2: R9 sub-bin ROM interpolation.
    // Profile 1 retains 16 PCM/unit through 48, then 5 PCM/unit (max 1803).
    // Profile 2 uses 32+14*s for nonzero s<16 to reduce quantization-floor
    // control failures; joins the unchanged map at s=16 (256 PCM).
    // The monotonic map restores low/mid-control dynamics without increasing
    // the maximum bow target materially. Physical pressure/speed units
    // are not yet calibrated to a sensor bow; no unscaled Schelleng threshold
    // is applied here.
    parameter integer BOW_CONTROL_PROFILE = 2,
    parameter integer BOW_SLEW_PCM_PER_SAMPLE = 64,
    // ---- R22：摩擦注入模型（编译期二选一，未选中的分支不参与综合）----
    // 0 = R21 及以前：inject = slip × mu(|slip|·压力)，mu 从 252/256 降到 4/256。
    //     实测问题：粘着区 mu=0.984 而不是 1.0，弦点速度永远追不上弓速，
    //     slip 在过渡带里来回，一个基频周期出现 **4~5 次**粘滑跳变
    //     （真实弓弦每周期只有 1 次 Helmholtz corner）。听感就是"拉锯"。
    // 1 = 双状态库仑摩擦（默认）：|slip| <= F_slide 时 inject = slip（精确粘着，
    //     弦点速度 == 弓速，slip 被压到 0）；超过则 inject = ±F_slide（恒定滑动摩擦）。
    //     只多一个比较器 + 一个 mux，同时省掉 1024×8 的摩擦 ROM 与 17×9 乘法。
    parameter integer BOW_FRICTION_MODEL = 0,
    // 滑动摩擦力上限 F_slide = |v_bow| * pressure >> SLIDE_RATIO_SHIFT。
    // 为什么必须随弓速缩放：Schelleng 稳定区的上下界都正比于弓速
    //   F_min = v_bow*Z/(2*mu_s*beta)，F_max = 2*mu_d*Z*v_bow/beta。
    // 若取固定值，F_slide > v_bow 时弦只会被"粘着拖走"、永不进入滑动，
    // 低弓速（鼠标实测 28 mm/s -> speed8=36）直接不出声。
    // 取 pressure/512：pressure=192 -> F_slide = 0.375*|v_bow|（半量单位），
    // 对应弓点注入上限 0.375*v_bow，始终 < v_bow 所以能起振，
    // 同时 pressure 单调控制粘着占比与音量。
    parameter integer SLIDE_RATIO_SHIFT = 9,
    // R16 弓离弦主动阻尼：gate 落下后弦仍在环路里自由衰减（原泄漏只有
    // 1/512 per round trip，半衰期 ≈0.4 s @440 Hz），听感就是"弓拿走了
    // 声音还在拖"。这里在 bridge 读回路径上把泄漏临时加大到 1/2^SHIFT，
    // 每往返衰减 1/8（SHIFT=3）：440 Hz 下 46 ms 衰减 23 dB，100 ms 基本安静。
    // 跳弓（_bounce）会重新拉起 gate，w_contact_allowed 恢复 1，阻尼自动撤销，
    // 所以不需要额外的例外分支。置 0 关闭该行为（回到 R15 的自由衰减）。
    parameter integer BOW_OFF_DAMP_SHIFT = 3,
    // ---- R21：桥端一阶 IIR 低通（对应 STK Bowed 的 stringFilter_）----
    // 原来的 2 点平均在 4.4 kHz 每往返只有 −0.35 dB，锯齿的高次谐波能在弦上
    // 存活数秒，听感"像锯木头"（实测 h2..h5 与理想 1/n 误差 ≤0.9 dB）。
    // 一阶 IIR 给出 −5.6 dB/往返，40 ms 内耗散掉。
    // 取值：1 → p=0.5（群延迟 1 样本，最温和）
    //       2 → p=0.75（群延迟 3 样本，推荐；离线模型实测音准 −0.7~−3.4 音分）
    //       3 → p=0.875（群延迟 7 样本；实测会把 E5 打没，peak 2056→527，不要用）
    // 系数 p = 1 − 2^-SHIFT，纯移位实现，0 乘法器。
    parameter integer BOW_IIR_SHIFT = 2,
    // 环路泄漏。IIR 直流增益为 1，必须保留泄漏，否则弦能量永不衰减。
    parameter integer BOW_LEAK_SHIFT = 8,
    // 周期补偿（Q16 样本）。理论值 = 直流群延迟 p/(1-p) = 2^SHIFT - 1 = 3.000。
    // 但 RTL 的实际环路延迟还含采样时刻的结构性偏移，必须在 RTL 仿真里标定。
    //
    // R22 重标：弓位从 beta=1/16 改到 1/8 后，波形的谐波重心从 h3 移回 h1
    // （R21 实测 dom=h3，R22 dom=h1）。一阶 IIR 的群延迟是频率相关的
    // （DC 处 3.0 样本，高频更小），所以"能量在哪个谐波"会改变有效群延迟：
    //   beta=1/16, comp=154010 -> A4 -1.2 音分（h3 主导，群延迟偏小）
    //   beta=1/8,  comp=154010 -> A4 -3.8 音分（h1 主导，群延迟接近 3.0）
    // 斜率 16 音分/样本，补 0.2885 样本 -> 172900（2.639 样本）。
    // 四弦残差见 docs/implementation/r22_20261101/README.md。
    // 注意：这个值依赖环路的具体流水位置与弓位，两者任一改动都必须重标。
    parameter integer BOW_IIR_DELAY_Q16 = 172900,
    parameter integer SEPARATE_CONTROL_PREPARE = 0,
    parameter integer ENABLE_FINE_PITCH = 0,
    parameter integer ENABLE_MOVING_BOW_POSITION = 0,
    parameter integer SHARE_INTERPOLATION_MULTIPLIER = 0
) (
    input                                i_prepare_tick,
    input [31:0]                         i_period_q16,
    input                                i_clk,
    input                                i_reset,
    input                                i_sample_tick,       // 单周期采样使能
    input                                i_trigger,           // 开始接触；显式STOP后的首次为冷启动
    input                                i_stop,              // 显式STOP，保留被动尾音，下次冷启动
    input                                i_gate,              // 为 0 时停止注能
    input        [6:0]                   i_midi_note,
    input        [7:0]                   i_velocity,          // 弓压代理，0..255
    input signed [15:0]                  i_bow_speed,         // 弓速代理；按profile映射，不是物理速度
    input                                i_bow_direction,     // 额外反向标志
    input        [23:0]                  i_bow_position,      // Q0.24 接触位置
    output reg signed [SAMPLE_WIDTH-1:0] o_audio_sample,      // 有符号 16 位 PCM
    output                               o_ready
);
    // synthesis translate_off
    initial if (BOW_CONTROL_PROFILE != 1 && BOW_CONTROL_PROFILE != 2)
        $fatal(1, "Only friction profiles 1 and 2 are supported");
    // synthesis translate_on

    function integer memory_address_width;
        input integer memory_depth;
        integer address_capacity;
        begin
            memory_address_width = 0;
            for (address_capacity = 1; address_capacity < memory_depth;
                 address_capacity = address_capacity * 2)
                memory_address_width = memory_address_width + 1;
            if (memory_address_width < 1)
                memory_address_width = 1;
        end
    endfunction

    function signed [15:0] saturate_pcm;
        input signed [18:0] value;
        begin
            if (value > 19'sd32767)
                saturate_pcm = 16'sh7fff;
            else if (value < -19'sd32768)
                saturate_pcm = 16'sh8000;
            else
                saturate_pcm = value[15:0];
        end
    endfunction

    // Quarter-bin samples of the bounded R7 reflection curve. Expanding the
    // coefficient lookup removes the per-voice interpolation multiplier.
    // |rho| <= 252/256 keeps the reflection branch contractive; this alone
    // does not prove complete time-varying bowed-loop acoustic stability.
    function [7:0] friction_dense_q8;
        input [7:0] index;
        begin
            case (index)
                8'd0: friction_dense_q8 = 8'd252;
                8'd1: friction_dense_q8 = 8'd252;
                8'd2: friction_dense_q8 = 8'd252;
                8'd3: friction_dense_q8 = 8'd252;
                8'd4: friction_dense_q8 = 8'd252;
                8'd5: friction_dense_q8 = 8'd252;
                8'd6: friction_dense_q8 = 8'd252;
                8'd7: friction_dense_q8 = 8'd252;
                8'd8: friction_dense_q8 = 8'd252;
                8'd9: friction_dense_q8 = 8'd252;
                8'd10: friction_dense_q8 = 8'd252;
                8'd11: friction_dense_q8 = 8'd252;
                8'd12: friction_dense_q8 = 8'd252;
                8'd13: friction_dense_q8 = 8'd252;
                8'd14: friction_dense_q8 = 8'd252;
                8'd15: friction_dense_q8 = 8'd252;
                8'd16: friction_dense_q8 = 8'd252;
                8'd17: friction_dense_q8 = 8'd239;
                8'd18: friction_dense_q8 = 8'd226;
                8'd19: friction_dense_q8 = 8'd213;
                8'd20: friction_dense_q8 = 8'd201;
                8'd21: friction_dense_q8 = 8'd190;
                8'd22: friction_dense_q8 = 8'd180;
                8'd23: friction_dense_q8 = 8'd169;
                8'd24: friction_dense_q8 = 8'd159;
                8'd25: friction_dense_q8 = 8'd151;
                8'd26: friction_dense_q8 = 8'd143;
                8'd27: friction_dense_q8 = 8'd135;
                8'd28: friction_dense_q8 = 8'd127;
                8'd29: friction_dense_q8 = 8'd121;
                8'd30: friction_dense_q8 = 8'd115;
                8'd31: friction_dense_q8 = 8'd109;
                8'd32: friction_dense_q8 = 8'd104;
                8'd33: friction_dense_q8 = 8'd99;
                8'd34: friction_dense_q8 = 8'd95;
                8'd35: friction_dense_q8 = 8'd90;
                8'd36: friction_dense_q8 = 8'd86;
                8'd37: friction_dense_q8 = 8'd82;
                8'd38: friction_dense_q8 = 8'd78;
                8'd39: friction_dense_q8 = 8'd74;
                8'd40: friction_dense_q8 = 8'd71;
                8'd41: friction_dense_q8 = 8'd68;
                8'd42: friction_dense_q8 = 8'd65;
                8'd43: friction_dense_q8 = 8'd62;
                8'd44: friction_dense_q8 = 8'd59;
                8'd45: friction_dense_q8 = 8'd56;
                8'd46: friction_dense_q8 = 8'd54;
                8'd47: friction_dense_q8 = 8'd52;
                8'd48: friction_dense_q8 = 8'd50;
                8'd49: friction_dense_q8 = 8'd48;
                8'd50: friction_dense_q8 = 8'd46;
                8'd51: friction_dense_q8 = 8'd44;
                8'd52: friction_dense_q8 = 8'd42;
                8'd53: friction_dense_q8 = 8'd40;
                8'd54: friction_dense_q8 = 8'd39;
                8'd55: friction_dense_q8 = 8'd37;
                8'd56: friction_dense_q8 = 8'd36;
                8'd57: friction_dense_q8 = 8'd34;
                8'd58: friction_dense_q8 = 8'd33;
                8'd59: friction_dense_q8 = 8'd32;
                8'd60: friction_dense_q8 = 8'd31;
                8'd61: friction_dense_q8 = 8'd30;
                8'd62: friction_dense_q8 = 8'd29;
                8'd63: friction_dense_q8 = 8'd28;
                8'd64: friction_dense_q8 = 8'd27;
                8'd65: friction_dense_q8 = 8'd26;
                8'd66: friction_dense_q8 = 8'd25;
                8'd67: friction_dense_q8 = 8'd24;
                8'd68: friction_dense_q8 = 8'd23;
                8'd69: friction_dense_q8 = 8'd22;
                8'd70: friction_dense_q8 = 8'd21;
                8'd71: friction_dense_q8 = 8'd20;
                8'd72: friction_dense_q8 = 8'd20;
                8'd73: friction_dense_q8 = 8'd19;
                8'd74: friction_dense_q8 = 8'd19;
                8'd75: friction_dense_q8 = 8'd18;
                8'd76: friction_dense_q8 = 8'd18;
                8'd77: friction_dense_q8 = 8'd17;
                8'd78: friction_dense_q8 = 8'd17;
                8'd79: friction_dense_q8 = 8'd16;
                8'd80: friction_dense_q8 = 8'd16;
                8'd81: friction_dense_q8 = 8'd15;
                8'd82: friction_dense_q8 = 8'd15;
                8'd83: friction_dense_q8 = 8'd14;
                8'd84: friction_dense_q8 = 8'd14;
                8'd85: friction_dense_q8 = 8'd13;
                8'd86: friction_dense_q8 = 8'd13;
                8'd87: friction_dense_q8 = 8'd12;
                8'd88: friction_dense_q8 = 8'd12;
                8'd89: friction_dense_q8 = 8'd11;
                8'd90: friction_dense_q8 = 8'd11;
                8'd91: friction_dense_q8 = 8'd11;
                8'd92: friction_dense_q8 = 8'd11;
                8'd93: friction_dense_q8 = 8'd10;
                8'd94: friction_dense_q8 = 8'd10;
                8'd95: friction_dense_q8 = 8'd10;
                8'd96: friction_dense_q8 = 8'd10;
                8'd97: friction_dense_q8 = 8'd9;
                8'd98: friction_dense_q8 = 8'd9;
                8'd99: friction_dense_q8 = 8'd8;
                8'd100: friction_dense_q8 = 8'd8;
                8'd101: friction_dense_q8 = 8'd8;
                8'd102: friction_dense_q8 = 8'd8;
                8'd103: friction_dense_q8 = 8'd8;
                8'd104: friction_dense_q8 = 8'd8;
                8'd105: friction_dense_q8 = 8'd7;
                8'd106: friction_dense_q8 = 8'd7;
                8'd107: friction_dense_q8 = 8'd7;
                8'd108: friction_dense_q8 = 8'd7;
                8'd109: friction_dense_q8 = 8'd6;
                8'd110: friction_dense_q8 = 8'd6;
                8'd111: friction_dense_q8 = 8'd6;
                8'd112: friction_dense_q8 = 8'd6;
                8'd113: friction_dense_q8 = 8'd5;
                8'd114: friction_dense_q8 = 8'd5;
                8'd115: friction_dense_q8 = 8'd5;
                8'd116: friction_dense_q8 = 8'd5;
                8'd117: friction_dense_q8 = 8'd5;
                8'd118: friction_dense_q8 = 8'd5;
                8'd119: friction_dense_q8 = 8'd5;
                8'd120: friction_dense_q8 = 8'd5;
                8'd121: friction_dense_q8 = 8'd4;
                8'd122: friction_dense_q8 = 8'd4;
                8'd123: friction_dense_q8 = 8'd4;
                8'd124: friction_dense_q8 = 8'd4;
                8'd125: friction_dense_q8 = 8'd4;
                8'd126: friction_dense_q8 = 8'd4;
                8'd127: friction_dense_q8 = 8'd4;
                default: friction_dense_q8 = 8'd4;
            endcase
        end
    endfunction

    localparam integer BRIDGE_MEMORY_DEPTH = (DELAY_LINE_LENGTH / 4 < 2) ?
        2 : DELAY_LINE_LENGTH / 4;
    localparam integer NECK_MEMORY_DEPTH = (DELAY_LINE_LENGTH * 15 / 16 < 6) ?
        6 : DELAY_LINE_LENGTH * 15 / 16;
    localparam integer BRIDGE_ADDRESS_WIDTH = memory_address_width(BRIDGE_MEMORY_DEPTH);
    localparam integer NECK_ADDRESS_WIDTH = memory_address_width(NECK_MEMORY_DEPTH);
    // Lengths include capacity; addresses stop at capacity-1, even for
    // non-power-of-two neck RAM. Pre-clamp geometry keeps its original width.
    localparam integer BRIDGE_LENGTH_WIDTH = memory_address_width(BRIDGE_MEMORY_DEPTH + 1);
    localparam integer NECK_LENGTH_WIDTH = memory_address_width(NECK_MEMORY_DEPTH + 1);

    // 两个单写同步 RAM；地址只使用实际存储深度所需的位宽。
    reg signed [15:0] r_bridge_delay_line [0:BRIDGE_MEMORY_DEPTH-1];
    reg signed [15:0] r_neck_delay_line [0:NECK_MEMORY_DEPTH-1];
    reg signed [15:0] r_bridge_delay_sample;
    reg signed [15:0] r_neck_delay_sample;
    reg signed [15:0] r_bridge_new_tap;
    reg signed [15:0] r_neck_new_tap;
    reg signed [15:0] r_bridge_old_tap;
    reg signed [15:0] r_neck_old_tap;
    reg [BRIDGE_ADDRESS_WIDTH-1:0] r_bridge_index;
    reg [NECK_ADDRESS_WIDTH-1:0] r_neck_index;
    reg [NECK_ADDRESS_WIDTH-1:0] r_memory_init_index;
    reg r_memory_ready;
    reg r_active;
    reg r_require_cold_start;
    wire w_stop_active;
    wire w_cold_trigger;
    wire w_contact_allowed;
    // Only an explicit 1 asserts stop. An omitted i_stop is Z in old benches;
    // real hardware drives this bit and the compare synthesizes as a wire.
    assign w_stop_active = (i_stop === 1'b1);
    assign w_cold_trigger = i_trigger && !w_stop_active && (ENABLE_BOW_LIFECYCLE == 0 ||
        !r_active || r_require_cold_start);
    assign w_contact_allowed = i_gate && !w_stop_active &&
        (ENABLE_BOW_LIFECYCLE == 0 || !r_require_cold_start || i_trigger);
    // Fixed-capacity rings preserve wave histories across pitch changes.
    // A tap can only read a sample written since the most recent bow onset.
    reg [NECK_LENGTH_WIDTH-1:0] r_samples_since_trigger;
    reg [6:0] r_committed_note;
    reg [BRIDGE_LENGTH_WIDTH-1:0] r_committed_bridge_length;
    reg [NECK_LENGTH_WIDTH-1:0] r_committed_neck_length;
    reg [BRIDGE_LENGTH_WIDTH-1:0] r_old_bridge_length;
    reg [NECK_LENGTH_WIDTH-1:0] r_old_neck_length;
    reg [8:0] r_retune_blend;
    wire w_note_change;
    wire [8:0] w_retune_blend;
    wire [BRIDGE_LENGTH_WIDTH-1:0] w_old_bridge_length;
    wire [NECK_LENGTH_WIDTH-1:0] w_old_neck_length;
    wire [BRIDGE_ADDRESS_WIDTH-1:0] w_bridge_old_read_address;
    wire [NECK_ADDRESS_WIDTH-1:0] w_neck_old_read_address;
    wire signed [16:0] w_bridge_tap_difference;
    wire signed [16:0] w_neck_tap_difference;
    wire signed [26:0] w_bridge_tap_blend_product;
    // Split RAM -> subtraction -> DSP -> blend into system-clock shadows.
    // Carry the matching old tap and gain through both arithmetic stages.
    reg signed [16:0] r_bridge_tap_difference_stage1, r_neck_tap_difference_stage1;
    reg signed [9:0] r_tap_blend_gain_stage1;
    reg signed [15:0] r_bridge_old_tap_stage1, r_neck_old_tap_stage1;
    reg signed [15:0] r_bridge_old_tap_stage2, r_neck_old_tap_stage2;
    reg signed [26:0] r_bridge_tap_product_stage2, r_neck_tap_product_stage2;
    wire signed [26:0] w_neck_tap_blend_product;

    // 六级系统时钟流水：周期表、半样本补偿、乘法、桥限幅、枕减法、枕限幅。
    // total/fraction 跟随相同配置，最终桥/枕/小数一起提交；没有增加音频帧延迟。
    // 分离 prepare 模式在 phase3 准备、phase28 消费，覆盖几何与反馈稳定时间。
    // Gowin SUG550 5.17：小只读控制表映射 LUT；延迟线 RAM 仍可推断 BSRAM。
    // 其他综合器可忽略此注释属性，不改变 Verilog 行为与控制流水。
    reg [31:0] r_note_period_stage1 /* synthesis syn_romstyle = "logic" */;
    reg [7:0] r_bridge_ratio_stage1;
    reg [15:0] r_geometry_total_stage2 /* synthesis syn_preserve = 1 */;
    reg [7:0] r_geometry_fraction_stage2;
    reg [7:0] r_geometry_ratio_stage2;
    reg [23:0] r_geometry_product_stage3 /* synthesis syn_preserve = 1 */;
    reg [15:0] r_geometry_total_stage3;
    reg [7:0] r_geometry_fraction_stage3;
    reg [15:0] r_geometry_bridge_stage4 /* synthesis syn_preserve = 1 */;
    reg [15:0] r_geometry_total_stage4;
    reg [7:0] r_geometry_fraction_stage4;
    reg [15:0] r_geometry_neck_stage5 /* synthesis syn_preserve = 1 */;
    reg [15:0] r_geometry_bridge_stage5;
    reg [7:0] r_geometry_fraction_stage5;
    reg [BRIDGE_LENGTH_WIDTH-1:0] r_bridge_length_stage2;
    reg [NECK_LENGTH_WIDTH-1:0] r_neck_length_stage2;
    reg [7:0] r_delay_fraction_stage2;

    // 反馈历史在音频 tick 更新；反射量在系统时钟下提前流水计算。
    reg signed [16:0] r_previous_bridge_filtered;
    reg signed [17:0] r_bridge_reflection;
    reg signed [17:0] r_neck_reflection;
    // 弓控流水：速度差/压力 → 归一化乘积 → LUT → 注能；同阶段反射同行。
    reg signed [15:0] r_slip_velocity_stage1;
    reg [16:0] r_slip_magnitude;
    reg [8:0] r_pressure_scale;
    reg [25:0] r_normalized_slip;
    reg signed [15:0] r_slip_delayed;
    reg signed [15:0] r_slip_for_gain;
    reg signed [17:0] r_bridge_delayed;
    reg signed [17:0] r_neck_delayed;
    reg signed [17:0] r_bridge_for_gain;
    reg signed [17:0] r_neck_for_gain;
    reg [2:0] r_contact_pipeline;
    // 接触点几何在起弓时冻结，持续移动采用输出亮度变化，避免搬移RAM造成跳变。
    reg [7:0] r_contact_ratio_q8;
    reg [7:0] r_committed_ratio_q8;
    reg signed [15:0] r_position_lowpass;
    wire signed [16:0] w_position_error;
    wire signed [24:0] w_position_blend_product;
    wire signed [18:0] w_position_output;
    reg signed [16:0] r_position_error_stage1;
    reg signed [7:0] r_position_gain_stage1;
    reg signed [15:0] r_position_ac_stage1, r_position_ac_stage2;
    reg signed [24:0] r_position_product_stage2;
    reg signed [15:0] r_ac_sample_precomputed; // 去直流弦信号先寄存，再进入弓位混合乘法。
    wire [9:0] w_pressure_times_three;
    reg [7:0] r_friction_gain_stage1;
    reg signed [17:0] r_bridge_reflection_stage1;
    reg signed [17:0] r_neck_reflection_stage1;
    reg signed [15:0] r_bridge_outgoing;
    reg signed [15:0] r_neck_outgoing;
    reg signed [15:0] r_bow_injection;
    // 去直流状态低 8 位为小数。
    reg signed [23:0] r_dc_estimate_q8;

    wire [31:0] w_period_q16;
    wire [31:0] w_delay_period_q16;
    wire [15:0] w_total_delay;
    wire [7:0] w_delay_fraction_q8;
    wire [7:0] w_bridge_ratio_q8;
    wire [23:0] w_bridge_length_product;
    wire [15:0] w_bridge_length_raw;
    wire [15:0] w_bridge_length;
    wire [15:0] w_neck_length;
    wire [BRIDGE_ADDRESS_WIDTH-1:0] w_bridge_read_address;
    wire [NECK_ADDRESS_WIDTH-1:0] w_neck_read_address;
    wire signed [16:0] w_bridge_filtered;
    wire signed [17:0] w_bridge_interpolation_difference;
    wire signed [26:0] w_bridge_interpolation_product;
    wire signed [17:0] w_bridge_interpolated;
    reg signed [17:0] r_bridge_interpolation_difference_stage1;
    reg signed [8:0] r_bridge_fraction_stage1;
    reg signed [16:0] r_bridge_filtered_stage1, r_bridge_filtered_stage2;
    reg signed [26:0] r_bridge_interpolation_product_stage2;
    wire signed [16:0] w_signed_speed;
    wire signed [18:0] w_bow_target_velocity;
    wire signed [18:0] w_slip_velocity;
    wire signed [15:0] w_slip_velocity_bounded;
    wire [16:0] w_slip_magnitude;
    wire signed [24:0] w_friction_product;
    wire signed [18:0] w_injection;
    wire signed [18:0] w_bridge_outgoing_extended;
    wire signed [18:0] w_neck_outgoing_extended;
    wire signed [15:0] w_string_output;
    wire signed [24:0] w_dc_error_q8;
    wire signed [24:0] w_dc_next_q8;
    wire signed [18:0] w_ac_extended;
    wire signed [15:0] w_ac_sample;
    reg w_bridge_write_enable;
    reg w_neck_write_enable;
    reg [BRIDGE_ADDRESS_WIDTH-1:0] w_bridge_write_address;
    reg [NECK_ADDRESS_WIDTH-1:0] w_neck_write_address;
    reg signed [15:0] w_bridge_write_sample;
    reg signed [15:0] w_neck_write_sample;

    reg signed [18:0] r_performance_velocity;
    reg [7:0] r_performance_pressure;
    reg [7:0] r_performance_position;
    wire signed [19:0] w_performance_error;
    assign w_performance_error = $signed(w_bow_target_velocity) - $signed(r_performance_velocity);

    // ---- R22b：弓压随弓速补偿（Schelleng 最小弓压）----
    // 物理依据：Schelleng 稳定区的下界 F_min = v_bow*Z/(2*mu_s*beta) 正比于弓速，
    // 上界 F_max = 2*mu_d*Z*v_bow/beta 也正比于弓速。所以"够用的弓压"随弓速涨。
    // 现场证据（本工程 RTL 实测，A4，speed=200 固定）：
    //   pressure=128 -> 主谐波 h3，比基频高 20.2 dB（严重"杂"，CCRMA 说的二次冲激）
    //   pressure=192 -> 主谐波 h2，高 4.0 dB
    //   pressure=255 -> 主谐波 h1，h1..h6 = 0/-6.2/-10.1/-13.9/-17.4/-22.4（干净）
    // 所以 i_velocity 只当"基础压力"，超过拐点后按弓速线性补：
    //   p_eff = i_velocity + max(0, speed8 - PRESSURE_SPEED_KNEE) >> PRESSURE_SPEED_SHIFT
    // R24 重标（tb_violin_grid 实测，A4，速度 128）：
    //   p_eff 192 -> h2 比 h1 高 4.0 dB、rms 1132
    //   p_eff 224 -> h1 比 h2 高 6.4 dB、rms 2112（粘着主导台阶的上沿）
    //   台阶位置随弓速上移，所以基础值抬到 224（frontend 的 velocity_bus），
    //   拐点从 64 降到 32 —— 中速段（speed 80~140）原来落在 200~230 的
    //   台阶下方，正是用户听到的"弓压不够"。
    //
    // R24 二次修正（千问与 Kimi 独立给出同一条）：斜率 >>1 会让 speed=96 就
    // 顶到 255，中高速段（96~200）的弓压梯度被压平，动态全丢。改成 >>2 后
    //   speed 32/64/96/128/160/192 -> p_eff 224/232/240/248/255/255
    // 饱和点推到 speed≈160，而实测台阶在 speed=128 时只要 224、speed=200 时要 255，
    // 所以 128 的 248 仍在台阶上方（224 就已 h1 +6.4 dB），同时保住了梯度。
    parameter integer PRESSURE_TRACK_SPEED   = 1;
    parameter integer PRESSURE_SPEED_KNEE    = 32;
    parameter integer PRESSURE_SPEED_SHIFT   = 2;
    // 注意：w_pressure_target 的 assign 写在 w_control_speed 定义之后（约 590 行）。
    // w_control_speed 原本是内联声明，若在这里引用会退化成 1 位隐式 wire。
    wire [7:0] w_pressure_target;
    // 速度按可配置斜率建立/换向，压力/亮度最多2/样本。
    // 离弦/零压/零速仍立即禁用注能，平滑绝不作为运动保活。
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_performance_velocity <= 0;
            r_performance_pressure <= 0;
            r_performance_position <= 0;
        end
        else if (!r_active || w_cold_trigger)
        begin
            // Cold bow uses the supplied onset target. Forcing every onset
            // through one fixed ramp changed the low-speed friction orbit;
            // expressive onset trajectories belong to the control layer.
            r_performance_velocity <= w_bow_target_velocity;
            r_performance_pressure <= w_pressure_target;
            r_performance_position <= i_bow_position[23:16];
        end
        else if (SEPARATE_CONTROL_PREPARE != 0 ? i_prepare_tick : i_sample_tick)
        begin
            r_performance_velocity <= w_performance_error > BOW_SLEW_PCM_PER_SAMPLE ?
                r_performance_velocity + BOW_SLEW_PCM_PER_SAMPLE :
                w_performance_error < -BOW_SLEW_PCM_PER_SAMPLE ?
                r_performance_velocity - BOW_SLEW_PCM_PER_SAMPLE : w_bow_target_velocity;
            r_performance_pressure <= w_pressure_target > r_performance_pressure && w_pressure_target - r_performance_pressure > 2 ?
                r_performance_pressure + 8'd2 : r_performance_pressure > w_pressure_target && r_performance_pressure - w_pressure_target > 2 ?
                r_performance_pressure - 8'd2 : w_pressure_target;
            r_performance_position <= i_bow_position[23:16] > r_performance_position && i_bow_position[23:16] - r_performance_position > 2 ?
                r_performance_position + 8'd2 : r_performance_position > i_bow_position[23:16] && r_performance_position - i_bow_position[23:16] > 2 ?
                r_performance_position - 8'd2 : i_bow_position[23:16];
        end
    end


`include "src/instrument_pitch.vh"

    assign o_ready = r_memory_ready;
    assign w_period_q16 = ENABLE_FINE_PITCH != 0 ? i_period_q16 : midi_period_q16(i_midi_note);
    // 桥端低通的群延迟补偿（BOW_IIR_DELAY_Q16，见参数区）。
    //   R20 及以前是 2 点平均，直流群延迟 0.5 样本 -> 减 32768。
    //   R21 换成一阶 IIR 后，解析群延迟是 2^SHIFT - 1 样本（SHIFT=2 -> 3.0），
    //   但 RTL 实测环路延迟比解析值短 0.667 样本，所以用标定值 2.333 样本。
    //   不做补偿，四根弦会整体偏低（模型实测 -6.1/-4.1/-7.0/-11.5 音分）。
    //   注意：这一项与"L1-1 音准修正（32768->98304）"互斥，不要同时打开。
    assign w_delay_period_q16 = r_note_period_stage1 - BOW_IIR_DELAY_Q16;
    assign w_total_delay = w_delay_period_q16[31:16] < 16'd8 ?
        16'd8 : w_delay_period_q16[31:16];
    assign w_delay_fraction_q8 = w_delay_period_q16[31:16] < 16'd8 ?
        8'd0 : w_delay_period_q16[15:8];
    // 弓位基值。R21 及以前是 16（beta=1/16，第 16 次谐波才被梳状零点吃掉，
    // 听感偏亮偏硬）。R22 改 32（beta=1/8），第一零点移到第 8 次谐波
    // （A4 约 3.5 kHz），正好压掉"刺"的那一段，同时低次谐波相对增强。
    // 依据：千问与 Kimi 两轮独立评审都给出 beta 应在 1/8~1/10，
    // 且 current frontend 的 position_bus 恒为 0，所以基值就是实际弓位。
    parameter integer BOW_RATIO_BASE = 32;
    assign w_bridge_ratio_q8 = BOW_RATIO_BASE[7:0] + {3'd0, i_bow_position[23:19]};
    assign w_bridge_length_product = r_geometry_total_stage2 * r_geometry_ratio_stage2;
    assign w_bridge_length_raw = {1'b0, r_geometry_product_stage3[22:8]};
    assign w_bridge_length = w_bridge_length_raw < 16'd2 ?
        16'd2 : w_bridge_length_raw > BRIDGE_MEMORY_DEPTH ?
        BRIDGE_MEMORY_DEPTH : w_bridge_length_raw;
    assign w_neck_length = r_geometry_neck_stage5 > NECK_MEMORY_DEPTH ?
        NECK_MEMORY_DEPTH : r_geometry_neck_stage5;
    assign w_note_change = i_midi_note != r_committed_note ||
        (ENABLE_MOVING_BOW_POSITION != 0 && SEPARATE_CONTROL_PREPARE != 0 &&
         r_contact_ratio_q8 != r_committed_ratio_q8 &&
         (r_bridge_length_stage2 != r_committed_bridge_length ||
          r_neck_length_stage2 != r_committed_neck_length));
    assign w_retune_blend = w_note_change && !w_cold_trigger ? 9'd0 : r_retune_blend;
    assign w_old_bridge_length = w_note_change ? r_committed_bridge_length : r_old_bridge_length;
    assign w_old_neck_length = w_note_change ? r_committed_neck_length : r_old_neck_length;
    assign w_bridge_read_address = r_bridge_index >= r_bridge_length_stage2 ?
        r_bridge_index - r_bridge_length_stage2 : r_bridge_index + BRIDGE_MEMORY_DEPTH - r_bridge_length_stage2;
    assign w_neck_read_address = r_neck_index >= r_neck_length_stage2 ?
        r_neck_index - r_neck_length_stage2 : r_neck_index + NECK_MEMORY_DEPTH - r_neck_length_stage2;
    assign w_bridge_old_read_address = r_bridge_index >= w_old_bridge_length ?
        r_bridge_index - w_old_bridge_length : r_bridge_index + BRIDGE_MEMORY_DEPTH - w_old_bridge_length;
    assign w_neck_old_read_address = r_neck_index >= w_old_neck_length ?
        r_neck_index - w_old_neck_length : r_neck_index + NECK_MEMORY_DEPTH - w_old_neck_length;
    assign w_bridge_tap_difference = $signed(r_bridge_new_tap) - $signed(r_bridge_old_tap);
    assign w_neck_tap_difference = $signed(r_neck_new_tap) - $signed(r_neck_old_tap);
    assign w_bridge_tap_blend_product = r_bridge_tap_difference_stage1 * r_tap_blend_gain_stage1;
    assign w_neck_tap_blend_product = r_neck_tap_difference_stage1 * r_tap_blend_gain_stage1;

    // R21 桥端 IIR 状态（17 位：比样本宽 1 位，容纳"状态 + 差值/4"不溢出）
    reg signed [16:0] r_bridge_lp;

    // ---- R21：桥端一阶 IIR ----
    // 差分方程（与离线定点模型 waveguide_model.py 一致）：
    //     lp[n] = lp[n-1] + (x[n] - lp[n-1]) >>> SHIFT
    //     y[n]  = lp[n-1] - (lp[n-1] >>> LEAK) + (x[n] - lp[n-1]) >>> SHIFT
    //
    // 为什么泄漏项用 lp[n-1] 而不是 lp[n]：
    //   用 lp[n] 要多一级加法（减法→加法→泄漏减法 = 3 级），而 R20 全设计里
    //   波导不在关键路径上、但也没必要平白多一级。用 lp[n-1] 的差别只有
    //   (lp[n]-lp[n-1])>>>8 = 差值/1024，相对信号 <0.02%，直流增益仍是
    //   (1 - 2^-8)。深度回到 2 级（减 → 加），与原来的 2 点平均完全相同。
    //
    // 为什么 w_bridge_lp_leak / w_bridge_lp_mute 从寄存器直接算：
    //   它们只依赖 r_bridge_lp，组合逻辑在 x 到达之前就已经稳定，
    //   于是"x → 减法 → 加法 → 输出"成为唯一的两级路径。
    wire signed [16:0] w_bridge_lp_q    = $signed(r_bridge_lp);
    wire signed [16:0] w_bridge_lp_leak = w_bridge_lp_q - (w_bridge_lp_q >>> BOW_LEAK_SHIFT);
    wire signed [16:0] w_bridge_lp_mute = (BOW_OFF_DAMP_SHIFT <= 0) ? w_bridge_lp_leak :
        (w_bridge_lp_q - (w_bridge_lp_q >>> BOW_OFF_DAMP_SHIFT));
    // 一级：17 位减法
    wire signed [16:0] w_bridge_lp_diff =
        $signed({r_bridge_delay_sample[15], r_bridge_delay_sample}) - w_bridge_lp_q;
    // 二级：加法（正常/离弦两条并行，选择信号已寄存一拍）
    wire signed [16:0] w_bridge_normal = w_bridge_lp_leak + (w_bridge_lp_diff >>> BOW_IIR_SHIFT);
    wire signed [16:0] w_bridge_muted  = w_bridge_lp_mute + (w_bridge_lp_diff >>> BOW_IIR_SHIFT);
    // 状态更新。与输入同拍：r_bridge_lp 只依赖自身和 r_bridge_delay_sample。
    wire signed [16:0] w_bridge_lp_next = w_bridge_lp_q + (w_bridge_lp_diff >>> BOW_IIR_SHIFT);
    // 选择信号先寄存一拍：w_contact_allowed 由 gate/stop/冷启动标志组合而成，
    // 直接进 mux 会把这条组合链压到波导关键路径上（R16 首版本 Fmax 掉 3 MHz）。
    // 代价是阻尼晚一个采样（20 µs），对余音衰减无影响。
    reg r_bow_off;
    always @(posedge i_clk)begin
        if(i_reset) r_bow_off<=1'b0;
        else r_bow_off<=!w_contact_allowed;
    end
    assign w_bridge_filtered = r_bow_off ? w_bridge_muted : w_bridge_normal;
    assign w_bridge_interpolation_difference =
        $signed(r_previous_bridge_filtered) - $signed(w_bridge_filtered);
    assign w_bridge_interpolation_product = r_bridge_interpolation_difference_stage1 *
        r_bridge_fraction_stage1;
    assign w_bridge_interpolated = $signed(r_bridge_filtered_stage2) +
        $signed(r_bridge_interpolation_product_stage2[25:8]);

    assign w_signed_speed = i_bow_direction ?
        -$signed({i_bow_speed[15], i_bow_speed}) :
        $signed({i_bow_speed[15], i_bow_speed});
    wire [16:0] w_speed_magnitude = w_signed_speed[16] ? -w_signed_speed : w_signed_speed;
    wire [7:0] w_control_speed = w_speed_magnitude > 17'd255 ? 8'd255 : w_speed_magnitude[7:0];
    // ---- 弓压随弓速：p_eff = i_velocity + max(0, speed8-knee) >> shift ----
    wire [8:0] w_pressure_speed_excess = (w_control_speed > PRESSURE_SPEED_KNEE[7:0]) ?
        ({1'b0, w_control_speed} - {1'b0, PRESSURE_SPEED_KNEE[7:0]}) : 9'd0;
    wire [8:0] w_pressure_eff = {1'b0, i_velocity} +
        (PRESSURE_TRACK_SPEED != 0 ? (w_pressure_speed_excess >> PRESSURE_SPEED_SHIFT) : 9'd0);
    assign w_pressure_target = (w_pressure_eff > 9'd255) ? 8'd255 : w_pressure_eff[7:0];
    wire [10:0] w_speed_above_knee = w_control_speed > 8'd48 ? w_control_speed - 8'd48 : 11'd0;
    // Fixed-baseline double-Fs controls select the smallest tested weak-speed
    // floor with no invalid F0 in the 64 weak-speed boundary scenes. Pressure
    // and friction ROM stay unchanged; zero remains zero, s>=16 is bit exact.
    // This is a digital control calibration, not a physical sensor calibration.
    wire [12:0] w_companded_velocity =
        BOW_CONTROL_PROFILE == 2 && w_control_speed != 0 && w_control_speed < 8'd16 ?
        13'd32 + ({5'd0,w_control_speed} << 4) - ({5'd0,w_control_speed} << 1) :
        w_control_speed <= 8'd48 ? {1'b0,w_control_speed,4'd0} :
        13'd768 + (w_speed_above_knee << 2) + w_speed_above_knee;
    wire signed [18:0] w_mapped_velocity = w_signed_speed[16] ?
        -$signed({6'd0,w_companded_velocity}) : $signed({6'd0,w_companded_velocity});
    assign w_bow_target_velocity = !w_contact_allowed || i_velocity == 0 ? 19'sd0 :
        ENABLE_FULL_SPEED_RANGE != 0 ? w_mapped_velocity :
        w_signed_speed > 17'sd96 ? 19'sd3072 :
        w_signed_speed < -17'sd96 ? -19'sd3072 :
        $signed({{2{w_signed_speed[16]}}, w_signed_speed}) <<< 5;
    assign w_slip_velocity = r_performance_velocity -
        $signed(r_bridge_reflection) - $signed(r_neck_reflection);
    assign w_slip_velocity_bounded = saturate_pcm(w_slip_velocity);
    assign w_slip_magnitude = w_slip_velocity_bounded[15] ?
        -$signed({w_slip_velocity_bounded[15], w_slip_velocity_bounded}) :
        {1'b0, w_slip_velocity_bounded};
    // 连续压力缩放：scale=256-floor(3*pressure/4)，高压扩大粘着捕获区。
    // 不是物理牛顿值；保留LUT替换点，需实物标定压力与音色。
    assign w_pressure_times_three = {2'b0, r_performance_pressure} + {1'b0, r_performance_pressure, 1'b0};
    // ---- 摩擦注入：两条模型编译期二选一 ----
    generate
    if (BOW_FRICTION_MODEL == 0) begin: LUT_FRICTION
        assign w_friction_product = r_slip_for_gain *
            $signed({1'b0, (BOW_CONTROL_PROFILE == 2 && !r_contact_pipeline[2]) ? 8'd0 : r_friction_gain_stage1});
        assign w_injection = $signed(w_friction_product[24:8]);
    end else begin: COULOMB_FRICTION
        // 双状态库仑摩擦。物理依据：滑动摩擦力 F = mu_k * N，与相对速度大小无关；
        // 粘着阶段弓毛与弦无相对滑动，弦点速度被钉在弓速上。
        //
        // 为什么这样能消除"锯"：
        //   R21 的 inject = slip * 0.984 意味着"弦点速度 = 0.984 * 弓速 + 残留"，
        //   slip 永远不会归零，于是每个采样都在过渡带里改注入方向，
        //   一个周期出现 4~5 次局部跳变（实测 s=200 时 h4 比 h1 高 16.9 dB）。
        //   这里粘着段直接 inject = slip（增益精确 1.0），slip 被压到 0，
        //   弦点速度严格等于弓速，一个周期只剩滑动沿那一次 corner。
        //
        // 为什么不会失控：粘着段等效反射 = -1 + 1 = 0（无损），振幅会一直长到
        //   进入滑动段为止；滑动段注入被钉在 F_slide，输入功率恒定，
        //   振幅由"每周期输入能量 = 环路耗散"决定，这是标准的硬限幅极限环。
        //
        // 弓压 → F_slide：pressure 越大，粘着捕获区越宽，音量越大（物理正确，
        //   原来弓压只改查表索引，不直接改注入幅度）。
        // ---- 注入量必须是 slip 的一半，这一条是本轮最关键的修正 ----
        // 弓点的弦速 = 桥段出射波 + 颈段出射波（两路都从弓点出发，速度同号相加）：
        //     v_point = bridge_out + neck_out
        //             = (neck_refl + inj) + (bridge_refl + inj)
        //             = (bridge_refl + neck_refl) + 2*inj
        // 粘着时要求 v_point == v_bow，而 slip 定义为 v_bow - (bridge_refl+neck_refl)，
        // 所以必须 inj = slip/2。R21 及以前用 inj = slip*mu (mu=0.984)，
        // 等于过驱动 1.97 倍：v_point = 1.97*v_bow - 0.97*(反射和)，
        // 弦点被推过头，反过来又让 slip 反号 —— 这就是一个周期出现 4~5 次
        // 粘滑跳变、听感"拉锯"的直接原因（实测 s=200 时 h4 比 h1 高 16.9 dB）。
        // 除 2 只用一根线（算术右移），不增加任何逻辑。
        wire signed [18:0] w_slip_half_tmp = {{3{r_slip_delayed[15]}}, r_slip_delayed} >>> 1;
        wire signed [17:0] w_slip_half = w_slip_half_tmp[17:0];
        // |slip/2|：16 位有符号 -> 17 位
        wire [16:0] w_slip_abs = w_slip_half[17] ?
            -$signed({w_slip_half[17], w_slip_half}) :
             $signed({1'b0, w_slip_half});
        // F_slide 用上一拍的 |v_bow| 与压力算，变化率只有 2 LSB/样本，
        // 寄存一拍既无听感代价，又把乘法移出"比较->mux->写RAM"这条路径。
        wire [18:0] w_perf_abs = r_performance_velocity[18] ?
            -r_performance_velocity : r_performance_velocity;
        reg [18:0] r_slide_force;
        always @(posedge i_clk)
            if (i_reset) r_slide_force <= 19'sd0;
            else r_slide_force <= (w_perf_abs * r_performance_pressure) >>> SLIDE_RATIO_SHIFT;
        wire [18:0] w_slide_force = r_slide_force;
        wire        w_sliding = w_slip_abs > w_slide_force[16:0];
        wire signed [18:0] w_slide_push = w_slip_half[17] ?
            -$signed(w_slide_force) : $signed(w_slide_force);
        wire signed [18:0] w_stick_hold = {{1{w_slip_half[17]}}, w_slip_half};
        assign w_friction_product = 25'sd0;   // 该模型不用
        assign w_injection = !r_contact_pipeline[2] ? 19'sd0 :
                             (w_sliding ? w_slide_push : w_stick_hold);
    end
    endgenerate
    assign w_bridge_outgoing_extended = $signed(r_neck_reflection_stage1) + w_injection;
    assign w_neck_outgoing_extended = $signed(r_bridge_reflection_stage1) + w_injection;

    // Cold trigger emits r_bow_injection directly and resets local DC state.
    // Subsequent samples use the registered, DC-removed bridge signal.
    assign w_string_output = r_bridge_delay_sample;
    assign w_dc_error_q8 = $signed({w_string_output[15], w_string_output, 8'd0}) -
        $signed({r_dc_estimate_q8[23], r_dc_estimate_q8});
    assign w_dc_next_q8 = $signed({r_dc_estimate_q8[23], r_dc_estimate_q8}) +
        (w_dc_error_q8 >>> 8);
    assign w_ac_extended = $signed(w_string_output) - $signed(r_dc_estimate_q8[23:8]);
    assign w_ac_sample = saturate_pcm(w_ac_extended);

    always @(posedge i_clk)
        if (i_reset)
            r_ac_sample_precomputed <= 0;
        else
            r_ac_sample_precomputed <= w_ac_sample;
    assign w_position_error = $signed(r_ac_sample_precomputed) - $signed(r_position_lowpass);
    assign w_position_blend_product = r_position_error_stage1 * r_position_gain_stage1;
    assign w_position_output = $signed(r_position_ac_stage2) - (r_position_product_stage2 >>> 8);

    reg [1:0] r_mul_slot, r_mul_tag;
    reg signed [17:0] r_mul_operand;
    reg signed [9:0] r_mul_coefficient;
    reg signed [27:0] r_shared_product;
    reg signed [16:0] r_mul_reference;
    reg signed [16:0] w_mul_reference;
    always @*
    begin
        case(r_mul_slot)
            0: begin r_mul_operand=r_bridge_tap_difference_stage1; r_mul_coefficient=r_tap_blend_gain_stage1; w_mul_reference=r_bridge_old_tap_stage1; end
            1: begin r_mul_operand=r_neck_tap_difference_stage1; r_mul_coefficient=r_tap_blend_gain_stage1; w_mul_reference=r_neck_old_tap_stage1; end
            2: begin r_mul_operand=r_bridge_interpolation_difference_stage1; r_mul_coefficient=r_bridge_fraction_stage1; w_mul_reference=r_bridge_filtered_stage1; end
            default: begin r_mul_operand=r_position_error_stage1; r_mul_coefficient=r_position_gain_stage1; w_mul_reference=r_position_ac_stage1; end
        endcase
    end
    always @(posedge i_clk)
    begin
        if(i_reset)
        begin
            r_mul_slot<=0; r_mul_tag<=0; r_shared_product<=0; r_mul_reference<=0;
        end
        else
        begin
            r_mul_slot<=r_mul_slot+1'b1; r_mul_tag<=r_mul_slot;
            r_shared_product<=r_mul_operand*r_mul_coefficient;
            r_mul_reference<=w_mul_reference;
        end
    end
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_bridge_tap_difference_stage1 <= 0; r_neck_tap_difference_stage1 <= 0;
            r_tap_blend_gain_stage1 <= 0;
            r_bridge_old_tap_stage1 <= 0; r_neck_old_tap_stage1 <= 0;
            r_bridge_old_tap_stage2 <= 0; r_neck_old_tap_stage2 <= 0;
            r_bridge_tap_product_stage2 <= 0; r_neck_tap_product_stage2 <= 0;
            r_bridge_interpolation_difference_stage1 <= 0; r_bridge_fraction_stage1 <= 0;
            r_bridge_filtered_stage1 <= 0; r_bridge_filtered_stage2 <= 0;
            r_bridge_interpolation_product_stage2 <= 0;
            r_position_error_stage1 <= 0; r_position_gain_stage1 <= 0;
            r_position_ac_stage1 <= 0; r_position_ac_stage2 <= 0;
            r_position_product_stage2 <= 0;
        end
        else
        begin
            r_bridge_tap_difference_stage1 <= w_bridge_tap_difference;
            r_neck_tap_difference_stage1 <= w_neck_tap_difference;
            r_tap_blend_gain_stage1 <= $signed({1'b0,w_retune_blend});
            r_bridge_old_tap_stage1 <= r_bridge_old_tap;
            r_neck_old_tap_stage1 <= r_neck_old_tap;




            r_bridge_interpolation_difference_stage1 <= w_bridge_interpolation_difference;
            r_bridge_fraction_stage1 <= $signed({1'b0,r_delay_fraction_stage2});
            r_bridge_filtered_stage1 <= w_bridge_filtered;


            r_position_error_stage1 <= w_position_error;
            r_position_gain_stage1 <= $signed({1'b0,r_performance_position[7:1]});
            r_position_ac_stage1 <= r_ac_sample_precomputed;
            if(SHARE_INTERPOLATION_MULTIPLIER==0)
            begin
                r_bridge_tap_product_stage2 <= w_bridge_tap_blend_product;
                r_neck_tap_product_stage2 <= w_neck_tap_blend_product;
                r_bridge_old_tap_stage2 <= r_bridge_old_tap_stage1;
                r_neck_old_tap_stage2 <= r_neck_old_tap_stage1;
                r_bridge_interpolation_product_stage2 <= w_bridge_interpolation_product;
                r_bridge_filtered_stage2 <= r_bridge_filtered_stage1;
                r_position_product_stage2 <= w_position_blend_product;
                r_position_ac_stage2 <= r_position_ac_stage1;
            end
            else
            begin
                case(r_mul_tag)
                0: begin r_bridge_tap_product_stage2<=r_shared_product; r_bridge_old_tap_stage2<=r_mul_reference; end
                1: begin r_neck_tap_product_stage2<=r_shared_product; r_neck_old_tap_stage2<=r_mul_reference; end
                2: begin r_bridge_interpolation_product_stage2<=r_shared_product; r_bridge_filtered_stage2<=r_mul_reference; end
                3: begin r_position_product_stage2<=r_shared_product; r_position_ac_stage2<=r_mul_reference; end
                endcase
            end


        end
    end

    always @(posedge i_clk)
    begin
        if (i_reset)
            r_contact_ratio_q8 <= 8'd16;
        else if (w_cold_trigger)
            r_contact_ratio_q8 <= w_bridge_ratio_q8;
        else if (ENABLE_MOVING_BOW_POSITION != 0 && SEPARATE_CONTROL_PREPARE != 0 &&
                 i_prepare_tick && r_active && r_retune_blend == 9'd256)
        begin
            // Finish one 32-sample tap blend before accepting the next ratio
            // step. Latest input target wins; RAM and logical age are retained.
            if(r_contact_ratio_q8<w_bridge_ratio_q8)r_contact_ratio_q8<=r_contact_ratio_q8+1'b1;
            else if(r_contact_ratio_q8>w_bridge_ratio_q8)r_contact_ratio_q8<=r_contact_ratio_q8-1'b1;
        end
    end

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_note_period_stage1 <= 32'd524288;
            r_bridge_ratio_stage1 <= 8'd16;
            r_geometry_total_stage2 <= 16'd8;
            r_geometry_fraction_stage2 <= 8'd0;
            r_geometry_ratio_stage2 <= 8'd16;
            r_geometry_product_stage3 <= 24'd128;
            r_geometry_total_stage3 <= 16'd8;
            r_geometry_fraction_stage3 <= 8'd0;
            r_geometry_bridge_stage4 <= 16'd2;
            r_geometry_total_stage4 <= 16'd8;
            r_geometry_fraction_stage4 <= 8'd0;
            r_geometry_neck_stage5 <= 16'd6;
            r_geometry_bridge_stage5 <= 16'd2;
            r_geometry_fraction_stage5 <= 8'd0;
            r_bridge_length_stage2 <= 16'd2;
            r_neck_length_stage2 <= 16'd6;
            r_delay_fraction_stage2 <= 8'd0;
        end
        else
        begin
            r_note_period_stage1 <= w_period_q16;
            r_bridge_ratio_stage1 <= r_contact_ratio_q8;
            r_geometry_total_stage2 <= w_total_delay;
            r_geometry_fraction_stage2 <= w_delay_fraction_q8;
            r_geometry_ratio_stage2 <= r_bridge_ratio_stage1;
            r_geometry_product_stage3 <= w_bridge_length_product;
            r_geometry_total_stage3 <= r_geometry_total_stage2;
            r_geometry_fraction_stage3 <= r_geometry_fraction_stage2;
            r_geometry_bridge_stage4 <= w_bridge_length;
            r_geometry_total_stage4 <= r_geometry_total_stage3;
            r_geometry_fraction_stage4 <= r_geometry_fraction_stage3;
            r_geometry_neck_stage5 <= r_geometry_total_stage4 - r_geometry_bridge_stage4;
            r_geometry_bridge_stage5 <= r_geometry_bridge_stage4;
            r_geometry_fraction_stage5 <= r_geometry_fraction_stage4;
            r_bridge_length_stage2 <= r_geometry_bridge_stage5;
            r_neck_length_stage2 <= w_neck_length;
            r_delay_fraction_stage2 <= r_geometry_fraction_stage5;
        end
    end

    // The current bank prepare (55) precedes model commit (88) by 33 clocks, including geometry,
    // both RAM blends, bridge interpolation and the contact shadows.
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_bridge_reflection <= 18'sd0;
            r_neck_reflection <= 18'sd0;
            r_slip_velocity_stage1 <= 16'sd0;
            r_slip_magnitude <= 0;
            r_pressure_scale <= 9'd256;
            r_normalized_slip <= 0;
            r_slip_delayed <= 0;
            r_slip_for_gain <= 0;
            r_bridge_delayed <= 0;
            r_neck_delayed <= 0;
            r_bridge_for_gain <= 0;
            r_neck_for_gain <= 0;
            r_contact_pipeline <= 0;

            r_bridge_reflection_stage1 <= 18'sd0;
            r_neck_reflection_stage1 <= 18'sd0;
            r_bridge_outgoing <= 16'sd0;
            r_neck_outgoing <= 16'sd0;
            r_bow_injection <= 16'sd0;
        end
        else
        begin
            r_bridge_reflection <= -w_bridge_interpolated;
            r_neck_reflection <= -$signed({{2{r_neck_delay_sample[15]}}, r_neck_delay_sample});
            r_slip_velocity_stage1 <= w_slip_velocity_bounded;
            r_slip_magnitude <= w_slip_magnitude;
            r_pressure_scale <= 9'd256 - w_pressure_times_three[9:2];
            r_normalized_slip <= r_slip_magnitude * r_pressure_scale;
            r_slip_delayed <= r_slip_velocity_stage1;
            r_slip_for_gain <= r_slip_delayed;
            r_contact_pipeline <= {r_contact_pipeline[1:0], w_contact_allowed && i_velocity != 0 && i_bow_speed != 0};
            r_bridge_delayed <= r_bridge_reflection;
            r_neck_delayed <= r_neck_reflection;
            r_bridge_for_gain <= r_bridge_delayed;
            r_neck_for_gain <= r_neck_delayed;
            r_bridge_reflection_stage1 <= r_bridge_for_gain;
            r_neck_reflection_stage1 <= r_neck_for_gain;
            r_bridge_outgoing <= saturate_pcm(w_bridge_outgoing_extended);
            r_neck_outgoing <= saturate_pcm(w_neck_outgoing_extended);
            r_bow_injection <= saturate_pcm(w_injection);
        end
    end

    generate
        if(BOW_CONTROL_PROFILE==2 && BOW_FRICTION_MODEL==0)
        begin: SMOOTH_FRICTION
            // Eight linear substeps per R8 LUT bin. Coefficients are bounded
            // by 252/256; this is a quantization experiment, not a measured fit.
            // Synchronous read preserves the original coefficient latency.
            reg [7:0] curve [0:1023] /* synthesis syn_romstyle = "block_rom" */;
            integer index;
            integer lower_value, upper_value;
            initial
            begin
                for(index=0;index<1024;index=index+1)
                begin
                    lower_value=friction_dense_q8(index/8);
                    upper_value=friction_dense_q8(index/8+1);
                    curve[index]=(lower_value*(8-index%8)+upper_value*(index%8)+4)/8;
                end
            end
            always @(posedge i_clk)
            begin
                r_friction_gain_stage1<=curve[r_normalized_slip[25:19]!=0 ? 10'd1023 : r_normalized_slip[18:9]];
            end
        end
        else if(BOW_FRICTION_MODEL==0)
        begin: ORIGINAL_FRICTION
            always @(posedge i_clk)
            begin
                if(i_reset) r_friction_gain_stage1<=0;
                else
                begin
            r_friction_gain_stage1 <= !r_contact_pipeline[1] ? 8'd0 :
                friction_dense_q8(r_normalized_slip[25:20] != 0 ? 8'd255 : r_normalized_slip[19:12]);
                end
            end
        end
    endgenerate

    // 初始化、触发、反馈共用无 reset 的 RAM 写口，便于推断 BSRAM。
    always @*
    begin
        w_bridge_write_enable = 1'b0;
        w_neck_write_enable = 1'b0;
        w_bridge_write_address = r_bridge_index[BRIDGE_ADDRESS_WIDTH-1:0];
        w_neck_write_address = r_neck_index[NECK_ADDRESS_WIDTH-1:0];
        w_bridge_write_sample = 16'sd0;
        w_neck_write_sample = 16'sd0;
        if (!i_reset)
        begin
            if (!r_memory_ready)
            begin
                if (r_memory_init_index < BRIDGE_MEMORY_DEPTH)
                begin
                    w_bridge_write_enable = 1'b1;
                    w_bridge_write_address = r_memory_init_index[BRIDGE_ADDRESS_WIDTH-1:0];
                end
                w_neck_write_enable = 1'b1;
                w_neck_write_address = r_memory_init_index[NECK_ADDRESS_WIDTH-1:0];
            end
            else if (i_sample_tick && (w_cold_trigger || r_active))
            begin
                w_bridge_write_enable = 1'b1;
                w_neck_write_enable = 1'b1;
                if (w_cold_trigger)
                begin
                    w_bridge_write_address = 0;
                    w_neck_write_address = 0;
                    w_bridge_write_sample = r_bow_injection;
                    w_neck_write_sample = r_bow_injection;
                end
                else
                begin
                    w_bridge_write_sample = r_bridge_outgoing;
                    w_neck_write_sample = r_neck_outgoing;
                end
            end
        end
    end

    always @(posedge i_clk)
        if (w_bridge_write_enable)
            r_bridge_delay_line[w_bridge_write_address] <= w_bridge_write_sample;

    always @(posedge i_clk)
        if (w_neck_write_enable)
            r_neck_delay_line[w_neck_write_address] <= w_neck_write_sample;

    always @(posedge i_clk)
    begin
        r_bridge_new_tap <= r_samples_since_trigger >= r_bridge_length_stage2 && !w_cold_trigger ?
            r_bridge_delay_line[w_bridge_read_address] : 16'sd0;
        r_neck_new_tap <= r_samples_since_trigger >= r_neck_length_stage2 && !w_cold_trigger ?
            r_neck_delay_line[w_neck_read_address] : 16'sd0;
        r_bridge_old_tap <= r_samples_since_trigger >= w_old_bridge_length && !w_cold_trigger ?
            r_bridge_delay_line[w_bridge_old_read_address] : 16'sd0;
        r_neck_old_tap <= r_samples_since_trigger >= w_old_neck_length && !w_cold_trigger ?
            r_neck_delay_line[w_neck_old_read_address] : 16'sd0;
        r_bridge_delay_sample <= $signed(r_bridge_old_tap_stage2) + (r_bridge_tap_product_stage2 >>> 8);
        r_neck_delay_sample <= $signed(r_neck_old_tap_stage2) + (r_neck_tap_product_stage2 >>> 8);
    end

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_bridge_index <= 16'd0;
            r_neck_index <= 16'd0;
            r_memory_init_index <= 16'd0;
            r_memory_ready <= 1'b0;
            r_active <= 1'b0;
            r_require_cold_start <= 1'b1;
            r_samples_since_trigger <= 0;
            r_committed_note <= 7'd69;
            r_committed_ratio_q8 <= 8'd16;
            r_committed_bridge_length <= 16'd2;
            r_committed_neck_length <= 16'd6;
            r_old_bridge_length <= 16'd2;
            r_old_neck_length <= 16'd6;
            r_retune_blend <= 9'd256;
            r_position_lowpass <= 16'sd0;
            r_previous_bridge_filtered <= 17'sd0;
            r_bridge_lp <= 17'sd0;
            r_dc_estimate_q8 <= 24'sd0;
            o_audio_sample <= 0;
        end
        else if (!r_memory_ready)
        begin
            o_audio_sample <= 0;
            if (r_memory_init_index == NECK_MEMORY_DEPTH - 1)
                r_memory_ready <= 1'b1;
            else
                r_memory_init_index <= r_memory_init_index + 16'd1;
        end
        else if (i_sample_tick)
        begin
            // STOP prevents further contact work, but histories continue their
            // passive release. A later bow trigger uses a fresh logical age.
            if (i_stop == 1'b1) r_require_cold_start <= 1'b1;
            if (w_cold_trigger)
            begin
                r_require_cold_start <= 1'b0;
                r_bridge_index <= 16'd1;
                r_neck_index <= 16'd1;
                r_active <= 1'b1;
                r_samples_since_trigger <= 16'd1;
                r_committed_note <= i_midi_note;
                r_committed_ratio_q8 <= r_contact_ratio_q8;
                r_committed_bridge_length <= r_bridge_length_stage2;
                r_committed_neck_length <= r_neck_length_stage2;
                r_old_bridge_length <= r_bridge_length_stage2;
                r_old_neck_length <= r_neck_length_stage2;
                r_retune_blend <= 9'd256;
                r_position_lowpass <= 16'sd0;
                    r_previous_bridge_filtered <= 17'sd0;
            r_bridge_lp <= 17'sd0;
                r_dc_estimate_q8 <= 24'sd0;
                o_audio_sample <= r_bow_injection;
            end
            else if (r_active)
            begin
                r_bridge_index <= r_bridge_index + 16'd1 >= BRIDGE_MEMORY_DEPTH ?
                    16'd0 : r_bridge_index + 16'd1;
                r_neck_index <= r_neck_index + 16'd1 >= NECK_MEMORY_DEPTH ?
                    16'd0 : r_neck_index + 16'd1;
                if (r_samples_since_trigger < NECK_MEMORY_DEPTH)
                    r_samples_since_trigger <= r_samples_since_trigger + 16'd1;
                r_committed_note <= i_midi_note;
                r_committed_ratio_q8 <= r_contact_ratio_q8;
                r_committed_bridge_length <= r_bridge_length_stage2;
                r_committed_neck_length <= r_neck_length_stage2;
                if (w_note_change)
                begin
                    r_old_bridge_length <= r_committed_bridge_length;
                    r_old_neck_length <= r_committed_neck_length;
                    r_retune_blend <= 9'd8;
                end
                else if (r_retune_blend < 9'd256)
                    r_retune_blend <= r_retune_blend + 9'd8;
                r_previous_bridge_filtered <= w_bridge_filtered;
                // 桥端 IIR 状态每样本推进一次。**不能每拍推进**：
                // 本模块的算术是自由运行的（r_bridge_delay_sample 每拍都在
                // 重算，只是样本之间保持不变），若 IIR 每拍迭代，30 拍内就
                // 收敛到 x，一阶低通退化成直通，锯齿谐波全部回来。
                r_bridge_lp <= w_bridge_lp_next;
                r_dc_estimate_q8 <= w_dc_next_q8[23:0];
                r_position_lowpass <= $signed(r_position_lowpass) + (w_position_error >>> 2);
                o_audio_sample <= saturate_pcm(w_position_output);
            end
            else
                o_audio_sample <= 0;
        end
    end
endmodule
