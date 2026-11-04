// 双支路弓弦波导：弓点连接琴桥与琴枕的往返速度波传播延迟。
// 摩擦参考 Smith/STK 的速度差反射系数；琴体为独立六模态辐射近似。
// STK Bowed separates clear(), startBowing(), setFrequency() and stopBowing().
// Here cold starts clear logical history, while recontact keeps the string/body
// ringing. Coefficients and control mapping remain engineering presets.
module violin_waveguide_voice #(
    parameter integer DELAY_LINE_LENGTH = 2048,
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer SAMPLE_RATE_MILLIHZ = 48828125,
    parameter integer ENABLE_BODY_FILTER = 1,
    parameter integer ENABLE_ADVANCED_FRICTION = 1,
    parameter integer ENABLE_BODY_RESONATOR = 1,
    parameter integer ENABLE_BOW_LIFECYCLE = 1,
    parameter integer ENABLE_FULL_SPEED_RANGE = 1,
    parameter integer BOW_SLEW_PCM_PER_SAMPLE = 64,
    parameter integer SEPARATE_CONTROL_PREPARE = 0,
    parameter integer ENABLE_FINE_PITCH = 0
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
    input signed [15:0]                  i_bow_speed,         // 速度，32 PCM/单位
    input                                i_bow_direction,     // 额外反向标志
    input        [23:0]                  i_bow_position,      // Q0.24 接触位置
    output reg signed [SAMPLE_WIDTH-1:0] o_audio_sample,      // 有符号 16 位 PCM
    output                               o_ready
);
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

    // Kinetic branch: 1/(1+|relative velocity|/1024), Q0.8.
    // The pressure force limit and release/reattach hysteresis remain separate.
    // Engineering PCM calibration: this is not a measured rosin law in newtons.
    function [7:0] kinetic_curve_q8;
        input [5:0] index;
        begin
            case (index)
                0: kinetic_curve_q8=255; 1: kinetic_curve_q8=228; 2: kinetic_curve_q8=205; 3: kinetic_curve_q8=186;
                4: kinetic_curve_q8=171; 5: kinetic_curve_q8=158; 6: kinetic_curve_q8=146; 7: kinetic_curve_q8=137;
                8: kinetic_curve_q8=128; 9: kinetic_curve_q8=120; 10: kinetic_curve_q8=114; 11: kinetic_curve_q8=108;
                12: kinetic_curve_q8=102; 13: kinetic_curve_q8=98; 14: kinetic_curve_q8=93; 15: kinetic_curve_q8=89;
                16: kinetic_curve_q8=85; 17: kinetic_curve_q8=82; 18: kinetic_curve_q8=79; 19: kinetic_curve_q8=76;
                20: kinetic_curve_q8=73; 21: kinetic_curve_q8=71; 22: kinetic_curve_q8=68; 23: kinetic_curve_q8=66;
                24: kinetic_curve_q8=64; 25: kinetic_curve_q8=62; 26: kinetic_curve_q8=60; 27: kinetic_curve_q8=59;
                28: kinetic_curve_q8=57; 29: kinetic_curve_q8=55; 30: kinetic_curve_q8=54; 31: kinetic_curve_q8=53;
                32: kinetic_curve_q8=51; 33: kinetic_curve_q8=50; 34: kinetic_curve_q8=49; 35: kinetic_curve_q8=48;
                36: kinetic_curve_q8=47; 37: kinetic_curve_q8=46; 38: kinetic_curve_q8=45; 39: kinetic_curve_q8=44;
                40: kinetic_curve_q8=43; 41: kinetic_curve_q8=42; 42: kinetic_curve_q8=41; 43: kinetic_curve_q8=40;
                44: kinetic_curve_q8=39; 45: kinetic_curve_q8=39; 46: kinetic_curve_q8=38; 47: kinetic_curve_q8=37;
                48: kinetic_curve_q8=37; 49: kinetic_curve_q8=36; 50: kinetic_curve_q8=35; 51: kinetic_curve_q8=35;
                52: kinetic_curve_q8=34; 53: kinetic_curve_q8=34; 54: kinetic_curve_q8=33; 55: kinetic_curve_q8=33;
                56: kinetic_curve_q8=32; 57: kinetic_curve_q8=32; 58: kinetic_curve_q8=31; 59: kinetic_curve_q8=31;
                60: kinetic_curve_q8=30; 61: kinetic_curve_q8=30; 62: kinetic_curve_q8=29; default: kinetic_curve_q8=29;
            endcase
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

    function signed [25:0] saturate_body_state;
        input signed [27:0] value;
        begin
            if (value > 28'sd33554431)
                saturate_body_state = 26'sh1ffffff;
            else if (value < -28'sd33554432)
                saturate_body_state = 26'sh2000000;
            else
                saturate_body_state = value[25:0];
        end
    endfunction

    // rho=clamp((0.75+index/16)^(-4), 1/64, 63/64)，输出 Q0.8。
    // 不包含真实松香温度、摩擦滞回或弓毛动力学，未来可替换此表。
    function [7:0] friction_coefficient_q8;
        input [5:0] index;
        begin
            case (index)
                6'd0, 6'd1, 6'd2, 6'd3, 6'd4: friction_coefficient_q8 = 8'd252;
                6'd5:  friction_coefficient_q8 = 8'd201;
                6'd6:  friction_coefficient_q8 = 8'd159;
                6'd7:  friction_coefficient_q8 = 8'd127;
                6'd8:  friction_coefficient_q8 = 8'd104;
                6'd9:  friction_coefficient_q8 = 8'd86;
                6'd10: friction_coefficient_q8 = 8'd71;
                6'd11: friction_coefficient_q8 = 8'd59;
                6'd12: friction_coefficient_q8 = 8'd50;
                6'd13: friction_coefficient_q8 = 8'd42;
                6'd14: friction_coefficient_q8 = 8'd36;
                6'd15: friction_coefficient_q8 = 8'd31;
                6'd16: friction_coefficient_q8 = 8'd27;
                6'd17: friction_coefficient_q8 = 8'd23;
                6'd18: friction_coefficient_q8 = 8'd20;
                6'd19: friction_coefficient_q8 = 8'd18;
                6'd20: friction_coefficient_q8 = 8'd16;
                6'd21: friction_coefficient_q8 = 8'd14;
                6'd22: friction_coefficient_q8 = 8'd12;
                6'd23: friction_coefficient_q8 = 8'd11;
                6'd24: friction_coefficient_q8 = 8'd10;
                6'd25: friction_coefficient_q8 = 8'd8;
                6'd26: friction_coefficient_q8 = 8'd8;
                6'd27: friction_coefficient_q8 = 8'd7;
                6'd28: friction_coefficient_q8 = 8'd6;
                6'd29: friction_coefficient_q8 = 8'd5;
                6'd30: friction_coefficient_q8 = 8'd5;
                6'd31: friction_coefficient_q8 = 8'd4;
                default: friction_coefficient_q8 = 8'd4;
            endcase
        end
    endfunction

    // 分段线性摩擦表：系数仍在[4,252]/256，被动反射有界。
    function [7:0] friction_interpolated_q8;
        input [5:0] index;
        input [7:0] fraction;
        reg signed [8:0] difference;
        reg signed [17:0] product;
        begin
            difference = $signed({1'b0, friction_coefficient_q8(index == 63 ? 6'd63 : index + 6'd1)}) -
                         $signed({1'b0, friction_coefficient_q8(index)});
            product = difference * $signed({1'b0, fraction});
            friction_interpolated_q8 = friction_coefficient_q8(index) + (product >>> 8);
        end
    endfunction

    localparam integer BRIDGE_MEMORY_DEPTH = (DELAY_LINE_LENGTH / 4 < 2) ?
        2 : DELAY_LINE_LENGTH / 4;
    localparam integer NECK_MEMORY_DEPTH = (DELAY_LINE_LENGTH * 15 / 16 < 6) ?
        6 : DELAY_LINE_LENGTH * 15 / 16;
    localparam integer BRIDGE_ADDRESS_WIDTH = memory_address_width(BRIDGE_MEMORY_DEPTH);
    localparam integer NECK_ADDRESS_WIDTH = memory_address_width(NECK_MEMORY_DEPTH);

    // 两个单写同步 RAM；地址只使用实际存储深度所需的位宽。
    reg signed [15:0] r_bridge_delay_line [0:BRIDGE_MEMORY_DEPTH-1];
    reg signed [15:0] r_neck_delay_line [0:NECK_MEMORY_DEPTH-1];
    reg signed [15:0] r_bridge_delay_sample;
    reg signed [15:0] r_neck_delay_sample;
    reg signed [15:0] r_bridge_new_tap;
    reg signed [15:0] r_neck_new_tap;
    reg signed [15:0] r_bridge_old_tap;
    reg signed [15:0] r_neck_old_tap;
    reg [15:0] r_bridge_index;
    reg [15:0] r_neck_index;
    reg [15:0] r_memory_init_index;
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
    reg [15:0] r_samples_since_trigger;
    reg [6:0] r_committed_note;
    reg [15:0] r_committed_bridge_length;
    reg [15:0] r_committed_neck_length;
    reg [15:0] r_old_bridge_length;
    reg [15:0] r_old_neck_length;
    reg [8:0] r_retune_blend;
    wire w_note_change;
    wire [8:0] w_retune_blend;
    wire [15:0] w_old_bridge_length;
    wire [15:0] w_old_neck_length;
    wire [BRIDGE_ADDRESS_WIDTH-1:0] w_bridge_old_read_address;
    wire [NECK_ADDRESS_WIDTH-1:0] w_neck_old_read_address;
    wire signed [16:0] w_bridge_tap_difference;
    wire signed [16:0] w_neck_tap_difference;
    wire signed [26:0] w_bridge_tap_blend_product;
    wire signed [26:0] w_neck_tap_blend_product;

    // 六级系统时钟流水：周期表、半样本补偿、乘法、桥限幅、枕减法、枕限幅。
    // total/fraction 跟随相同配置，最终桥/枕/小数一起提交；没有增加音频帧延迟。
    // 分离 prepare 模式在 phase3 准备、phase20 消费，覆盖几何与反馈稳定时间。
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
    reg [15:0] r_bridge_length_stage2;
    reg [15:0] r_neck_length_stage2;
    reg [7:0] r_delay_fraction_stage2;

    // 反馈历史在音频 tick 更新；反射量在系统时钟下提前流水计算。
    reg signed [15:0] r_previous_bridge_sample;
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
    reg signed [15:0] r_position_lowpass;
    wire signed [16:0] w_position_error;
    wire signed [24:0] w_position_blend_product;
    wire signed [18:0] w_position_output;
    reg signed [15:0] r_body_sample_precomputed; // 琴体输出先寄存，再进入弓位混合乘法。
    wire [9:0] w_pressure_times_three;
    reg [7:0] r_friction_gain_stage1 /* synthesis syn_romstyle = "logic" */;
    reg signed [17:0] r_bridge_reflection_stage1;
    reg signed [17:0] r_neck_reflection_stage1;
    reg signed [15:0] r_bridge_outgoing;
    reg signed [15:0] r_neck_outgoing;
    reg signed [15:0] r_bow_injection;
    // Exposed internal state for numerical/physical-mechanism regression.
    reg r_contact_sticking;
    reg signed [15:0] r_advanced_injection_stage1;
    // Separate nonlinear lookup, kinetic-force multiplication, and sign/bound
    // stages. Every stage carries matching contact metadata. These are SYSTEM
    // clocks, not sample delays; histories still commit only on sample_tick.
    reg [7:0] r_kinetic_gain_stage1 /* synthesis syn_romstyle = "logic" */;
    reg [9:0] r_half_static_force_stage1;
    reg signed [15:0] r_contact_delta_stage1;
    reg [16:0] r_contact_magnitude_stage1;
    reg r_contact_enabled_stage1;
    reg r_contact_sticking_stage1;
    reg [17:0] r_kinetic_product_stage2;
    reg signed [15:0] r_contact_delta_stage2;
    reg [16:0] r_contact_magnitude_stage2;
    reg r_contact_enabled_stage2;
    reg r_contact_sticking_stage2;
    wire [16:0] w_contact_delta_magnitude;
    wire [15:0] w_static_force_velocity_limit;
    wire [15:0] w_reattach_velocity_limit;
    wire [5:0] w_kinetic_index;
    wire [17:0] w_kinetic_force_product;
    wire [15:0] w_kinetic_force_magnitude;
    wire [15:0] w_bounded_kinetic_force;
    wire w_contact_sticking_next;
    wire signed [15:0] w_advanced_injection;

    // 下列状态低 8 位为小数；琴体多 2 整数位，保留共振峰余量。
    reg signed [23:0] r_dc_estimate_q8;
    reg signed [25:0] r_body_low_position_q8;
    reg signed [25:0] r_body_low_velocity_q8;
    reg signed [25:0] r_body_high_position_q8;
    reg signed [25:0] r_body_high_velocity_q8;

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
    wire signed [16:0] w_bridge_sum;
    wire signed [16:0] w_bridge_filtered;
    wire signed [17:0] w_bridge_interpolation_difference;
    wire signed [26:0] w_bridge_interpolation_product;
    wire signed [17:0] w_bridge_interpolated;
    wire signed [16:0] w_signed_speed;
    wire signed [18:0] w_bow_target_velocity;
    wire signed [18:0] w_slip_velocity;
    wire signed [15:0] w_slip_velocity_bounded;
    wire [16:0] w_slip_magnitude;
    wire [16:0] w_friction_index_extended;
    wire [5:0] w_friction_index;
    wire signed [24:0] w_friction_product;
    wire signed [18:0] w_injection;
    wire signed [18:0] w_bridge_outgoing_extended;
    wire signed [18:0] w_neck_outgoing_extended;
    wire signed [15:0] w_string_output;
    wire signed [24:0] w_dc_error_q8;
    wire signed [24:0] w_dc_next_q8;
    wire signed [18:0] w_ac_extended;
    wire signed [15:0] w_ac_sample;
    wire signed [25:0] w_body_input_q8;
    reg signed [25:0] r_body_input_precomputed;
    reg signed [27:0] r_body_low_velocity_precomputed;
    reg signed [27:0] r_body_high_velocity_precomputed;
    wire signed [26:0] w_body_low_error;
    wire signed [26:0] w_body_high_error;
    wire signed [27:0] w_body_low_velocity_next;
    wire signed [27:0] w_body_high_velocity_next;
    wire signed [27:0] w_body_low_position_next;
    wire signed [27:0] w_body_high_position_next;
    wire signed [18:0] w_body_output_extended;
    wire signed [27:0] w_body_output_full;

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
            r_performance_pressure <= i_velocity;
            r_performance_position <= i_bow_position[23:16];
        end
        else if (SEPARATE_CONTROL_PREPARE != 0 ? i_prepare_tick : i_sample_tick)
        begin
            r_performance_velocity <= w_performance_error > BOW_SLEW_PCM_PER_SAMPLE ?
                r_performance_velocity + BOW_SLEW_PCM_PER_SAMPLE :
                w_performance_error < -BOW_SLEW_PCM_PER_SAMPLE ?
                r_performance_velocity - BOW_SLEW_PCM_PER_SAMPLE : w_bow_target_velocity;
            r_performance_pressure <= i_velocity > r_performance_pressure && i_velocity - r_performance_pressure > 2 ?
                r_performance_pressure + 8'd2 : r_performance_pressure > i_velocity && r_performance_pressure - i_velocity > 2 ?
                r_performance_pressure - 8'd2 : i_velocity;
            r_performance_position <= i_bow_position[23:16] > r_performance_position && i_bow_position[23:16] - r_performance_position > 2 ?
                r_performance_position + 8'd2 : r_performance_position > i_bow_position[23:16] && r_performance_position - i_bow_position[23:16] > 2 ?
                r_performance_position - 8'd2 : i_bow_position[23:16];
        end
    end


`include "src/instrument_pitch.vh"

    assign o_ready = r_memory_ready;
    assign w_period_q16 = ENABLE_FINE_PITCH != 0 ? i_period_q16 : midi_period_q16(i_midi_note);
    // 两点平均的群延迟约 0.5 样本；其余小数用稳定线性插值补齐。
    assign w_delay_period_q16 = r_note_period_stage1 - 32'd32768;
    assign w_total_delay = w_delay_period_q16[31:16] < 16'd8 ?
        16'd8 : w_delay_period_q16[31:16];
    assign w_delay_fraction_q8 = w_delay_period_q16[31:16] < 16'd8 ?
        8'd0 : w_delay_period_q16[15:8];
    // 归一化接触位置映射到弦长约 1/16..3/16 的常用弓区。
    assign w_bridge_ratio_q8 = 8'd16 + {3'd0, i_bow_position[23:19]};
    assign w_bridge_length_product = r_geometry_total_stage2 * r_geometry_ratio_stage2;
    assign w_bridge_length_raw = {1'b0, r_geometry_product_stage3[22:8]};
    assign w_bridge_length = w_bridge_length_raw < 16'd2 ?
        16'd2 : w_bridge_length_raw > BRIDGE_MEMORY_DEPTH ?
        BRIDGE_MEMORY_DEPTH : w_bridge_length_raw;
    assign w_neck_length = r_geometry_neck_stage5 > NECK_MEMORY_DEPTH ?
        NECK_MEMORY_DEPTH : r_geometry_neck_stage5;
    assign w_note_change = i_midi_note != r_committed_note;
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
    assign w_bridge_tap_blend_product = w_bridge_tap_difference * $signed({1'b0,w_retune_blend});
    assign w_neck_tap_blend_product = w_neck_tap_difference * $signed({1'b0,w_retune_blend});

    assign w_bridge_sum = {r_bridge_delay_sample[15], r_bridge_delay_sample} +
        {r_previous_bridge_sample[15], r_previous_bridge_sample};
    assign w_bridge_filtered = (w_bridge_sum >>> 1) - (w_bridge_sum >>> 9);
    assign w_bridge_interpolation_difference =
        $signed(r_previous_bridge_filtered) - $signed(w_bridge_filtered);
    assign w_bridge_interpolation_product = w_bridge_interpolation_difference *
        $signed({1'b0, r_delay_fraction_stage2});
    assign w_bridge_interpolated = $signed(w_bridge_filtered) +
        $signed(w_bridge_interpolation_product[25:8]);

    assign w_signed_speed = i_bow_direction ?
        -$signed({i_bow_speed[15], i_bow_speed}) :
        $signed({i_bow_speed[15], i_bow_speed});
    wire [16:0] w_speed_magnitude = w_signed_speed[16] ? -w_signed_speed : w_signed_speed;
    wire [7:0] w_control_speed = w_speed_magnitude > 17'd255 ? 8'd255 : w_speed_magnitude[7:0];
    wire [10:0] w_speed_above_knee = w_control_speed > 8'd48 ? w_control_speed - 8'd48 : 11'd0;
    // All 0..255 controls remain distinct: 32 PCM/unit through 48, then
    // 1 PCM/unit. Maximum 1743 PCM keeps upper controls near the stable
    // operating region instead of applying an unbounded 8192-PCM target.
    // This is a controller companding curve, not a physical cm/s calibration.
    wire [12:0] w_companded_velocity = w_control_speed <= 8'd48 ?
        {w_control_speed,5'd0} : 13'd1536 + w_speed_above_knee;
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
    assign w_friction_index_extended = r_normalized_slip >> 14;
    assign w_friction_index = w_friction_index_extended > 17'd63 ?
        6'd63 : w_friction_index_extended[5:0];
    assign w_friction_product = r_slip_for_gain *
        $signed({1'b0, r_friction_gain_stage1});
    assign w_contact_delta_magnitude = r_slip_for_gain[15] ?
        -$signed({r_slip_for_gain[15],r_slip_for_gain}) : {1'b0,r_slip_for_gain};
    // Fn/(2Z), in engineering PCM-velocity units. Static force scales with
    // pressure; a 5/8 reattachment boundary supplies explicit contact memory.
    assign w_static_force_velocity_limit = {5'd0,r_performance_pressure,3'd0};
    assign w_reattach_velocity_limit = (w_static_force_velocity_limit >> 1) +
        (w_static_force_velocity_limit >> 3);
    assign w_contact_sticking_next = r_contact_pipeline[1] &&
        (r_contact_sticking ? w_contact_delta_magnitude <= w_static_force_velocity_limit :
            w_contact_delta_magnitude <= w_reattach_velocity_limit);
    assign w_kinetic_index = w_contact_delta_magnitude > 17'd8063 ? 6'd63 :
        w_contact_delta_magnitude[12:7];
    assign w_kinetic_force_product = r_half_static_force_stage1 * r_kinetic_gain_stage1;
    assign w_kinetic_force_magnitude = {6'd0,r_kinetic_product_stage2[17:8]};
    // Same sign as delta and |injection|<=|delta|: contact slip work is
    // injection*(delta-injection)>=0. The moving bow can still supply energy.
    assign w_bounded_kinetic_force = w_kinetic_force_magnitude > r_contact_magnitude_stage2 ?
        r_contact_magnitude_stage2[15:0] : w_kinetic_force_magnitude;
    assign w_advanced_injection = !r_contact_enabled_stage2 ? 16'sd0 :
        r_contact_sticking_stage2 ? r_contact_delta_stage2 : r_contact_delta_stage2[15] ?
            -$signed(w_bounded_kinetic_force) : $signed(w_bounded_kinetic_force);
    assign w_injection = ENABLE_ADVANCED_FRICTION != 0 ?
        $signed(r_advanced_injection_stage1) : $signed(w_friction_product[24:8]);
    assign w_bridge_outgoing_extended = $signed(r_neck_reflection_stage1) + w_injection;
    assign w_neck_outgoing_extended = $signed(r_bridge_reflection_stage1) + w_injection;

    // Cold trigger emits r_bow_injection directly and resets body/DC states.
    // The body path is consumed only on subsequent active samples; selecting
    // injection here added a redundant trigger -> DC -> two-mode timing path.
    assign w_string_output = r_bridge_delay_sample;
    assign w_dc_error_q8 = $signed({w_string_output[15], w_string_output, 8'd0}) -
        $signed({r_dc_estimate_q8[23], r_dc_estimate_q8});
    assign w_dc_next_q8 = $signed({r_dc_estimate_q8[23], r_dc_estimate_q8}) +
        (w_dc_error_q8 >>> 8);
    assign w_ac_extended = $signed(w_string_output) - $signed(r_dc_estimate_q8[23:8]);
    assign w_ac_sample = saturate_pcm(w_ac_extended);

    // Legacy fallback only (ENABLE_BODY_RESONATOR=0); default uses the separate
    // six-mode instrument_body_resonator. Unselected legacy state is trimmed.
    // 两个模态无阻尼参考约 300/543 Hz；d=1/32 后极点振荡约 273/533 Hz。
    // v'=(1-d)v+k(x-y)，y'=y+v'，k=3/2048 或 5/1024；极点在单位圆内。
    // 移位替代系数乘法。26 位状态饱和另防止恶意输入导致整数回绕。
    // System-clock shadow pipeline. Audio/DC/modal histories still advance
    // only on sample_tick; >=6 clocks settle before consumption in the core.
    // Keep full 28-bit velocity for position integration before saturation.
    always @(posedge i_clk)
    begin
        if(i_reset)
        begin
            r_body_input_precomputed <= 0;
            r_body_low_velocity_precomputed <= 0;
            r_body_high_velocity_precomputed <= 0;
        end
        else
        begin
            r_body_input_precomputed <= {{2{w_ac_sample[15]}}, w_ac_sample, 8'd0};
            r_body_low_velocity_precomputed <= w_body_low_velocity_next;
            r_body_high_velocity_precomputed <= w_body_high_velocity_next;
        end
    end

    always @(posedge i_clk)
        if (i_reset)
        begin
            r_contact_sticking <= 1'b0;
            r_advanced_injection_stage1 <= 0;
            r_kinetic_gain_stage1 <= 0;
            r_half_static_force_stage1 <= 0;
            r_contact_delta_stage1 <= 0;
            r_contact_magnitude_stage1 <= 0;
            r_contact_enabled_stage1 <= 0;
            r_contact_sticking_stage1 <= 0;
            r_kinetic_product_stage2 <= 0;
            r_contact_delta_stage2 <= 0;
            r_contact_magnitude_stage2 <= 0;
            r_contact_enabled_stage2 <= 0;
            r_contact_sticking_stage2 <= 0;
        end
        else
        begin
            r_kinetic_gain_stage1 <= kinetic_curve_q8(w_kinetic_index);
            r_half_static_force_stage1 <= w_static_force_velocity_limit[10:1];
            r_contact_delta_stage1 <= r_slip_for_gain;
            r_contact_magnitude_stage1 <= w_contact_delta_magnitude;
            r_contact_enabled_stage1 <= r_contact_pipeline[1];
            r_contact_sticking_stage1 <= w_contact_sticking_next;
            r_kinetic_product_stage2 <= w_kinetic_force_product;
            r_contact_delta_stage2 <= r_contact_delta_stage1;
            r_contact_magnitude_stage2 <= r_contact_magnitude_stage1;
            r_contact_enabled_stage2 <= r_contact_enabled_stage1;
            r_contact_sticking_stage2 <= r_contact_sticking_stage1;
            r_advanced_injection_stage1 <= w_advanced_injection;
            if (i_sample_tick)
                r_contact_sticking <= w_cold_trigger ? 1'b0 : r_contact_sticking_stage2;
        end
    assign w_body_input_q8 = r_body_input_precomputed;
    assign w_body_low_error = $signed(w_body_input_q8) - $signed(r_body_low_position_q8);
    assign w_body_high_error = $signed(w_body_input_q8) - $signed(r_body_high_position_q8);
    assign w_body_low_velocity_next = $signed(r_body_low_velocity_q8) -
        (r_body_low_velocity_q8 >>> 5) +
        (w_body_low_error >>> 10) + (w_body_low_error >>> 11);
    assign w_body_high_velocity_next = $signed(r_body_high_velocity_q8) -
        (r_body_high_velocity_q8 >>> 5) +
        (w_body_high_error >>> 8) + (w_body_high_error >>> 10);
    assign w_body_low_position_next = $signed(r_body_low_position_q8) +
        r_body_low_velocity_precomputed;
    assign w_body_high_position_next = $signed(r_body_high_position_q8) +
        r_body_high_velocity_precomputed;
    assign w_body_output_full = $signed({{12{w_ac_sample[15]}}, w_ac_sample}) -
        ($signed({{12{w_ac_sample[15]}}, w_ac_sample}) >>> 2) +
        ($signed({{2{r_body_low_position_q8[25]}}, r_body_low_position_q8}) >>> 11) +
        ($signed({{2{r_body_high_position_q8[25]}}, r_body_high_position_q8}) >>> 11);
    // |dry|<=24576，两模态各 |position/2048|<=16384；总和在19位范围内。
    // 上面28位和的被删高位只有符号扩展，随后再对16位PCM饱和。
    assign w_body_output_extended = w_body_output_full[18:0];

    // 弓位连续改变干声/平滑声比例；只作用输出，不向反馈环增加能量。
    // The modal radiation path replaces the former two-mode colour filter.
    // It is outside the string feedback loop and cannot backpressure audio.
    wire signed [15:0] w_modal_body_sample;
    generate
        if (ENABLE_BODY_RESONATOR != 0 && ENABLE_BODY_FILTER != 0) begin: MODAL_BODY
            instrument_body_resonator u_body (
                .i_clk(i_clk), .i_reset(i_reset), .i_sample_tick(i_sample_tick && r_memory_ready),
                .i_trigger(w_cold_trigger), .i_bypass(1'b0), .i_instrument(1'b0),
                .i_sample(w_ac_sample), .o_sample(w_modal_body_sample),
                .o_guard_count(), .o_clip_count()
            );
        end else begin: NO_MODAL_BODY
            assign w_modal_body_sample = 16'sd0;
        end
    endgenerate
    always @(posedge i_clk)
        if (i_reset)
            r_body_sample_precomputed <= 0;
        else
            r_body_sample_precomputed <= ENABLE_BODY_FILTER == 0 ? w_ac_sample :
                ENABLE_BODY_RESONATOR != 0 ? w_modal_body_sample : saturate_pcm(w_body_output_extended);
    assign w_position_error = $signed(r_body_sample_precomputed) - $signed(r_position_lowpass);
    assign w_position_blend_product = w_position_error * $signed({1'b0, r_performance_position[7:1]});
    assign w_position_output = $signed(r_body_sample_precomputed) - (w_position_blend_product >>> 8);

    always @(posedge i_clk)
    begin
        if (i_reset)
            r_contact_ratio_q8 <= 8'd16;
        else if (w_cold_trigger)
            r_contact_ratio_q8 <= w_bridge_ratio_q8;
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

    // 常规弓控至少提前6clk；变更音高/冷起弓几何需提前17clk，覆盖RAM及摩擦流水。
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
            r_friction_gain_stage1 <= 8'd0;
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
            r_friction_gain_stage1 <= r_contact_pipeline[1] ? friction_interpolated_q8(w_friction_index, w_friction_index_extended > 63 ? 8'd0 : r_normalized_slip[13:6]) : 8'd0;
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
        r_bridge_delay_sample <= $signed(r_bridge_old_tap) + (w_bridge_tap_blend_product >>> 8);
        r_neck_delay_sample <= $signed(r_neck_old_tap) + (w_neck_tap_blend_product >>> 8);
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
            r_committed_bridge_length <= 16'd2;
            r_committed_neck_length <= 16'd6;
            r_old_bridge_length <= 16'd2;
            r_old_neck_length <= 16'd6;
            r_retune_blend <= 9'd256;
            r_position_lowpass <= 16'sd0;
            r_previous_bridge_sample <= 16'sd0;
            r_previous_bridge_filtered <= 17'sd0;
            r_dc_estimate_q8 <= 24'sd0;
            r_body_low_position_q8 <= 26'sd0;
            r_body_low_velocity_q8 <= 26'sd0;
            r_body_high_position_q8 <= 26'sd0;
            r_body_high_velocity_q8 <= 26'sd0;
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
                r_committed_bridge_length <= r_bridge_length_stage2;
                r_committed_neck_length <= r_neck_length_stage2;
                r_old_bridge_length <= r_bridge_length_stage2;
                r_old_neck_length <= r_neck_length_stage2;
                r_retune_blend <= 9'd256;
                r_position_lowpass <= 16'sd0;
                r_previous_bridge_sample <= 16'sd0;
                r_previous_bridge_filtered <= 17'sd0;
                r_dc_estimate_q8 <= 24'sd0;
                r_body_low_position_q8 <= 26'sd0;
                r_body_low_velocity_q8 <= 26'sd0;
                r_body_high_position_q8 <= 26'sd0;
                r_body_high_velocity_q8 <= 26'sd0;
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
                r_previous_bridge_sample <= r_bridge_delay_sample;
                r_previous_bridge_filtered <= w_bridge_filtered;
                r_dc_estimate_q8 <= w_dc_next_q8[23:0];
                r_body_low_position_q8 <= saturate_body_state(w_body_low_position_next);
                r_body_low_velocity_q8 <= saturate_body_state(r_body_low_velocity_precomputed);
                r_body_high_position_q8 <= saturate_body_state(w_body_high_position_next);
                r_body_high_velocity_q8 <= saturate_body_state(r_body_high_velocity_precomputed);
                r_position_lowpass <= $signed(r_position_lowpass) + (w_position_error >>> 2);
                o_audio_sample <= saturate_pcm(w_position_output);
            end
            else
                o_audio_sample <= 0;
        end
    end
endmodule
