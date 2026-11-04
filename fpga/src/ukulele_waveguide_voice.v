// 尤克里里拨弦波导：速度行波激励、音区/T60损耗、三点FIR、双偏振与琴体。
// high-G / low-G 使用同一引擎的独立调弦表，不存录音、不额外实例化吉他或贝斯。
// 分数延迟降低整数音高误差；输出 DC blocker 不改变反馈环的音准。
module ukulele_waveguide_voice #(
    parameter integer DELAY_LINE_LENGTH = 2048,
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer SAMPLE_RATE_MILLIHZ = 48828125,
    parameter integer ENABLE_PICK_COMB = 1,
    parameter integer PLUCK_POSITION_Q8 = 96,
    parameter integer DECAY_T60_MILLISECONDS = 4000,
    parameter integer EXTENDED_DECAY = 1,
    parameter integer ENABLE_DUAL_POLARIZATION = 1,
    parameter integer ENABLE_PHYSICAL_EXCITATION = 1,
    parameter integer SHARE_POLARIZATION_MULTIPLIERS = 1,
    parameter integer ENABLE_EXTERNAL_PITCH = 0
) (
    input [31:0]                         i_external_period_q16,
    input [15:0]                         i_external_excitation_step,
    input                                i_clk,
    input                                i_reset,
    input                                i_sample_tick,       // 单周期音频采样使能
    input                                i_trigger,           // 单次拨弦，允许重触发
    input                                i_gate,              // 兼容控制接口，包络由上层处理
    input        [6:0]                   i_midi_note,
    input        [7:0]                   i_velocity,          // 拨弦力度/亮度，0..255
    input                                i_stop,              // 可选；未连接保留旧接口行为
    output reg signed [SAMPLE_WIDTH-1:0] o_audio_sample,      // 有符号 16 位 PCM
    output                               o_ready,
    output reg [31:0]                    o_guard_count
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


    // Quotient/remainder form of symmetric nearest rounding (half away from
    // zero). Keeps the legacy 16/17-bit return truncation and avoids wide abs.
    function automatic signed [15:0] round_fir_legacy;
      input signed [24:0] value;
      reg signed [17:0] quotient;
      begin
        quotient={value[24],value[24:8]};
        round_fir_legacy=quotient+((value[7] && (!value[24] || |value[6:0])) ? 18'sd1:18'sd0);
      end
    endfunction
    function automatic signed [16:0] round_loss_legacy;
      input signed [32:0] value;
      reg signed [17:0] quotient;
      begin
        quotient={value[32],value[32:16]};
        round_loss_legacy=quotient+((value[15] && (!value[32] || |value[14:0])) ? 18'sd1:18'sd0);
      end
    endfunction

    localparam integer DELAY_ADDRESS_WIDTH = memory_address_width(DELAY_LINE_LENGTH);
    // Index/remaining: 0..D-1. Length and excitation age include D.
    // Keep the independent saturating decay age at its original 13 bits.
    localparam integer DELAY_LENGTH_WIDTH = memory_address_width(DELAY_LINE_LENGTH + 1);
    reg signed [15:0] r_delay_line [0:DELAY_LINE_LENGTH-1];
    // 独立偏振的传播、滤波和分数调谐状态；不是同一延迟输出的复制。
    reg signed [15:0] r_secondary_delay_line [0:DELAY_LINE_LENGTH-1];
    reg signed [15:0] r_secondary_delay_sample;
    reg [DELAY_ADDRESS_WIDTH-1:0] r_secondary_delay_index;
    reg [DELAY_ADDRESS_WIDTH-1:0] r_secondary_excitation_remaining;
    reg signed [15:0] r_secondary_previous_sample;
    reg signed [15:0] r_secondary_older_sample;
    reg signed [16:0] r_secondary_previous_filtered;
    reg signed [16:0] r_secondary_filtered_precomputed;
    reg [DELAY_LENGTH_WIDTH-1:0] r_secondary_length_stage2;
    reg [7:0] r_secondary_fraction_stage2;
    reg signed [15:0] r_delay_sample;
    reg [DELAY_ADDRESS_WIDTH-1:0] r_delay_index;                // 当前循环地址，单位为音频样本
    reg [DELAY_ADDRESS_WIDTH-1:0] r_excitation_remaining;       // 噪声填充尚余样本数
    reg [15:0] r_lfsr;                       // 固定可重现的 16 位噪声状态
    reg signed [15:0] r_previous_sample;    // 对称三点FIR的中心历史
    reg signed [15:0] r_older_sample;
    reg [7:0] r_pluck_velocity;             // 拨弦完成后不因控制力度变化而重塑旧弦
    reg signed [15:0] r_delay_sample_capture /* synthesis syn_preserve = 1 */;
    reg signed [15:0] r_secondary_delay_sample_capture /* synthesis syn_preserve = 1 */;
    reg signed [17:0] r_damping_curvature_stage /* synthesis syn_preserve = 1 */;
    reg signed [17:0] r_secondary_damping_curvature_stage /* synthesis syn_preserve = 1 */;
    reg signed [15:0] r_damping_center_stage, r_secondary_damping_center_stage;
    reg signed [24:0] r_damping_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [24:0] r_secondary_damping_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [24:0] r_damping_center_q8, r_secondary_damping_center_q8;
    reg signed [24:0] r_damping_acc_stage /* synthesis syn_preserve = 1 */;
    reg signed [24:0] r_secondary_damping_acc_stage /* synthesis syn_preserve = 1 */;
    // Convex FIR and symmetric rounding remain inside the signed16 RAM range.
    reg signed [15:0] r_damping_precomputed /* synthesis syn_preserve = 1 */;
    reg signed [15:0] r_secondary_damping_precomputed /* synthesis syn_preserve = 1 */;
    // Three multipliers alternate between the two independent polarizations.
    // Only the combinational arithmetic is shared; RAM, filter state, rounding,
    // saturation and coupling retain their original per-polarization values.
    reg r_multiply_secondary;
    wire signed [17:0] w_shared_damping_input;
    wire signed [24:0] w_shared_damping_product;
    wire signed [15:0] w_shared_loss_input;
    wire signed [15:0] w_shared_loss_coefficient;
    wire signed [31:0] w_shared_loss_product;
    wire signed [17:0] w_shared_interpolation_input;
    wire signed [8:0] w_shared_interpolation_fraction;
    wire signed [26:0] w_shared_interpolation_product;
    reg signed [31:0] r_loss_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [31:0] r_secondary_loss_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [15:0] r_loss_input_stage, r_secondary_loss_input_stage;
    reg signed [32:0] r_attenuated_stage /* synthesis syn_preserve = 1 */;
    reg signed [32:0] r_secondary_attenuated_stage /* synthesis syn_preserve = 1 */;
    reg signed [17:0] r_interpolation_difference_stage /* synthesis syn_preserve = 1 */;
    reg signed [17:0] r_secondary_interpolation_difference_stage /* synthesis syn_preserve = 1 */;
    reg signed [26:0] r_interpolation_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [26:0] r_secondary_interpolation_product_stage /* synthesis syn_preserve = 1 */;
    reg signed [16:0] r_interpolation_center_stage1, r_interpolation_center_stage2;
    reg signed [16:0] r_secondary_interpolation_center_stage1, r_secondary_interpolation_center_stage2;
    reg signed [16:0] r_previous_filtered;  // 分数延迟插值历史
    reg signed [15:0] r_excitation_lowpass; // 力度→带宽的激励低通状态
    reg signed [23:0] r_dc_estimate_q8;      // Q8 输出直流估计
    // h(z)=(1-z^-M)/2，仅作用激励，不改变反馈相位/衰减。
    // M约为弦周期的3/8；工程几何/接触等效值，实际拨弦点待录音标定。
    localparam integer PICK_DEPTH = DELAY_LINE_LENGTH / 2;
    localparam integer PICK_ADDRESS_WIDTH = memory_address_width(PICK_DEPTH);
    localparam integer PICK_LENGTH_WIDTH = memory_address_width(PICK_DEPTH + 1);
    reg signed [15:0] r_pick_history [0:PICK_DEPTH-1];
    reg signed [15:0] r_pick_delayed;
    reg signed [15:0] r_pick_precomputed;
    reg [PICK_ADDRESS_WIDTH-1:0] r_pick_index;
    reg [PICK_LENGTH_WIDTH-1:0] r_pick_length;
    reg [DELAY_LENGTH_WIDTH-1:0] r_excitation_age;
    reg [15:0] r_excitation_phase_q16;
    reg [15:0] r_excitation_step_stage2;
    wire signed [15:0] w_release_velocity_sample;
    // 三角初始位移的斜率/速度行波；有限指腹低通平滑拐角。
    localparam integer SAFE_PLUCK_POSITION = PLUCK_POSITION_Q8 < 16 ? 16 :
        PLUCK_POSITION_Q8 > 240 ? 240 : PLUCK_POSITION_Q8;
    localparam integer RELEASE_DENOMINATOR = SAFE_PLUCK_POSITION > 128 ?
        SAFE_PLUCK_POSITION : 256 - SAFE_PLUCK_POSITION;
    localparam integer RELEASE_NEGATIVE = (32767 * (256 - SAFE_PLUCK_POSITION)) / RELEASE_DENOMINATOR;
    localparam integer RELEASE_POSITIVE = (32767 * SAFE_PLUCK_POSITION) / RELEASE_DENOMINATOR;
    wire signed [19:0] w_excitation_shape;
    wire signed [28:0] w_physical_excitation_product;
    wire signed [16:0] w_pick_difference;
    wire [23:0] w_pick_length_product;
    reg r_active;
    reg [12:0] r_decay_age;
    reg [DELAY_ADDRESS_WIDTH-1:0] r_memory_init_index;
    reg r_memory_ready;
    // 小周期只读表放 LUT，避免大量小表各占整块 BSRAM；依据 SUG550 5.17。
    reg [31:0] r_note_period_stage1 /* synthesis syn_romstyle = "logic" */;
    reg [DELAY_LENGTH_WIDTH-1:0] r_delay_length_stage2;      // 第二周期补偿滤波群延迟后的整数长度
    reg [7:0] r_delay_fraction_stage2;     // 同帧 Q0.8 分数延迟，供反馈凸组合
    // 选品只更新目标；实际传播/损耗/激励周期仅在拨弦tick原子锁存。
    reg [31:0] r_target_period;
    reg [DELAY_LENGTH_WIDTH-1:0] r_target_length, r_target_secondary_length;
    reg [15:0] r_target_excitation_step;
    reg [7:0] r_target_fraction, r_target_secondary_fraction;
    reg r_stopped;
    reg r_replucking;
    wire w_stop = (i_stop === 1'b1);
    reg signed [15:0] r_feedback_saturated, r_secondary_feedback_saturated;
    reg signed [15:0] r_coupled_precomputed, r_secondary_coupled_precomputed;
    reg signed [15:0] r_write_precomputed, r_secondary_write_precomputed;
    wire signed [15:0] w_injection;
    wire signed [18:0] w_injected, w_secondary_injected;
    reg r_write_guard_precomputed;

    wire [31:0] w_period_q16;
    wire [31:0] w_delay_period_q16;
    wire [31:0] w_secondary_delay_period_q16;
    wire [15:0] w_secondary_requested_period;
    wire [7:0] w_secondary_fraction_q8;
    wire [15:0] w_requested_period;
    wire [7:0] w_fraction_q8;
    reg signed [16:0] r_filtered_precomputed; // 系统时钟预计算寄存器，非音频历史。
    // g=exp(-ln(1000)/(f*T60)); 1-g的一阶近似使用Q16，最大1/8。
    // 4.0s -> 8.0s为工程目标，未从真实尼龙弦录音拟合；FIR/插值另有频率相关损耗。
    // period=Fs/f，比例除法仅对参数常量，综合不产生可变除法器。
    localparam [15:0] LOSS_PERIOD_SCALE_Q6 =
        (64'd28972377341952 + (SAMPLE_RATE_MILLIHZ * (64'd1 * DECAY_T60_MILLISECONDS) / 2)) /
        (SAMPLE_RATE_MILLIHZ * (64'd1 * DECAY_T60_MILLISECONDS));
    wire [47:0] w_period_loss_product;
    reg [15:0] r_initial_loss_precomputed;
    reg [15:0] r_loss_precomputed;
    wire [15:0] w_initial_loss_q16;
    wire [15:0] w_tail_loss_q16;
    wire [28:0] w_loss_transition_product;
    wire [15:0] w_loss_q16;
    wire [15:0] w_secondary_loss_q16;
    wire signed [15:0] w_loss_coefficient, w_secondary_loss_coefficient;
    wire signed [31:0] w_loss_product;
    wire signed [32:0] w_primary_attenuated_q16;
    wire signed [32:0] w_secondary_attenuated_q16;
    wire [5:0] w_damping_side_q8;
    wire signed [17:0] w_damping_curvature;
    wire signed [17:0] w_secondary_damping_curvature;
    wire signed [24:0] w_damping_product;
    wire signed [24:0] w_secondary_damping_product;
    wire signed [24:0] w_damping_acc_q8;
    wire signed [24:0] w_secondary_damping_acc_q8;
    wire signed [17:0] w_interpolation_difference;
    wire signed [26:0] w_interpolation_product;
    wire signed [18:0] w_feedback_extended;
    wire signed [15:0] w_feedback_sample;
    wire signed [31:0] w_secondary_loss_product;
    wire signed [17:0] w_secondary_interpolation_difference;
    wire signed [26:0] w_secondary_interpolation_product;
    wire signed [18:0] w_secondary_feedback_extended;
    wire signed [15:0] w_secondary_feedback_sample;
    wire signed [17:0] w_coupling_difference;
    wire signed [17:0] w_coupling_step;
    wire signed [18:0] w_primary_coupled_extended;
    wire signed [18:0] w_secondary_coupled_extended;
    wire signed [15:0] w_primary_coupled_sample;
    wire signed [15:0] w_secondary_coupled_sample;
    wire signed [15:0] w_primary_raw_sample;
    wire signed [15:0] w_secondary_raw_sample;
    wire signed [18:0] w_polarization_mix;
    wire signed [8:0] w_velocity_positive;
    wire signed [24:0] w_noise_product;
    reg signed [15:0] r_noise_sample_precomputed; // 系统时钟预计算寄存器，非音频历史。
    wire signed [24:0] w_initial_noise_product;
    reg signed [15:0] r_initial_noise_precomputed; // 系统时钟预计算寄存器，非音频历史。
    // alpha=(32+velocity*3/8)/256，范围1/8..约1/2；无64/128档位跳变。
    wire [9:0] w_velocity_times_three;
    wire [7:0] w_excitation_alpha_q8;
    wire signed [16:0] w_excitation_error;
    // One exact signed 17x9 multiplier selects the consumer active for the
    // current trigger state. Inputs settle before the existing tick contract.
    wire signed [16:0] w_shared_excitation_input = i_trigger ?
        $signed({r_initial_noise_precomputed[15],r_initial_noise_precomputed}) :
        w_excitation_error;
    wire signed [25:0] w_shared_excitation_product = w_shared_excitation_input *
        $signed({1'b0,w_excitation_alpha_q8});
    wire signed [25:0] w_excitation_step_product;
    wire signed [24:0] w_initial_excitation_product;

    reg signed [16:0] r_excitation_filtered_precomputed; // 系统时钟预计算寄存器，非音频历史。
    reg signed [15:0] r_initial_excitation_precomputed; // 系统时钟预计算寄存器，非音频历史。
    wire signed [15:0] w_output_raw;
    wire signed [24:0] w_dc_error_q8;
    wire signed [24:0] w_dc_next_q8;
    wire signed [18:0] w_ac_extended;
    wire [DELAY_ADDRESS_WIDTH-1:0] w_delay_read_address;
    reg w_delay_write_enable;
    reg [DELAY_ADDRESS_WIDTH-1:0] w_delay_write_address;
    reg signed [15:0] w_delay_write_sample;
    wire [DELAY_ADDRESS_WIDTH-1:0] w_secondary_read_address;
    reg w_secondary_write_enable;
    reg [DELAY_ADDRESS_WIDTH-1:0] w_secondary_write_address;
    reg signed [15:0] w_secondary_write_sample;

    // 50MHz连续预计算的截止合同：目标note/velocity/trigger/stop在tick前
    // 共享模式至少稳定24clk(480ns)，旧并行模式至少16clk(320ns)。
    // RAM读出后独立capture、curvature、DSP、
    // FIR sum/round、loss DSP/subtract/round、interpolation diff/DSP/round、
    // coupling与injection均有明确寄存边界；交替乘法每级最多再等1clk。
    // tick一次提交单状态，不新增音频帧等待；上层必须独立保证控制稳定合同。
    // 该周期合同由TB验证；实际50MHz路径余量仍须完整新PNR/STA。
`include "src/instrument_pitch.vh"
    // 一周期有限速度行波的相位步进。每个除数是编译期音符常量，
    // 这里只生成参数系数表，不存录音，也不综合运行时可变除法器。
`include "src/instrument_excitation.vh"


    // Full 24-bit unsigned product: zero-extend before shifting. The static
    // coefficient bits elaborate away; all clamped positions 16..240 remain.
    wire [23:0] w_pick_operand = r_target_length;
    wire [23:0] w_pick_sum [0:8];
    assign w_pick_sum[0] = 24'd0;
    genvar pick_bit;
    generate for (pick_bit=0; pick_bit<8; pick_bit=pick_bit+1) begin: PICK_CONSTANT
        assign w_pick_sum[pick_bit+1] = w_pick_sum[pick_bit] +
            (((SAFE_PLUCK_POSITION >> pick_bit) & 1) != 0 ?
                (w_pick_operand << pick_bit) : 24'd0);
    end endgenerate
    assign w_pick_length_product = w_pick_sum[8];
    assign w_pick_difference = $signed(r_excitation_filtered_precomputed) -
        (r_excitation_age >= r_pick_length ? $signed(r_pick_delayed) : 16'sd0);
    always @(posedge i_clk)
    begin
        r_pick_delayed <= r_pick_history[r_pick_index[PICK_ADDRESS_WIDTH-1:0]];
        if (i_sample_tick && r_memory_ready && (i_trigger || r_excitation_remaining != 0))
            r_pick_history[i_trigger ? {PICK_ADDRESS_WIDTH{1'b0}} : r_pick_index[PICK_ADDRESS_WIDTH-1:0]] <=
                i_trigger ? r_initial_excitation_precomputed : r_excitation_filtered_precomputed[15:0];
        if (i_reset)
            r_pick_precomputed <= 0;
        else
            r_pick_precomputed <= ENABLE_PICK_COMB != 0 ?
                (w_pick_difference >>> 1) : r_excitation_filtered_precomputed[15:0];
    end

    assign o_ready = r_memory_ready;
    assign w_period_q16 = ENABLE_EXTERNAL_PITCH != 0 ? i_external_period_q16 : midi_period_q16(i_midi_note);
    assign w_delay_period_q16 = r_target_period - 32'd65536;
    // 第二偏振的周期增加 1/1024，频率约低 1.69 cent。
    // 两个环都补偿对称三点FIR的1样本群延迟；亮度不移动其中心。
    assign w_secondary_delay_period_q16 = r_target_period +
        (r_target_period >> 10) - 32'd65536;
    assign w_secondary_requested_period = w_secondary_delay_period_q16[31:16] < 16'd8 ?
        16'd8 : w_secondary_delay_period_q16[31:16] > DELAY_LINE_LENGTH ?
        DELAY_LINE_LENGTH : w_secondary_delay_period_q16[31:16];
    assign w_secondary_fraction_q8 = w_secondary_delay_period_q16[31:16] < 16'd8 ?
        8'd0 : w_secondary_delay_period_q16[15:8];
    assign w_requested_period = w_delay_period_q16[31:16] < 16'd8 ?
        16'd8 : w_delay_period_q16[31:16] > DELAY_LINE_LENGTH ?
        DELAY_LINE_LENGTH : w_delay_period_q16[31:16];
    assign w_fraction_q8 = w_delay_period_q16[31:16] < 16'd8 ?
        8'd0 : w_delay_period_q16[15:8];
    // 幅度系数按每一圈传播施加，不能按每音频采样全局T60推导。
    // Q16逐音频率损耗取代粗糙音区跳变；前4096样本平滑过渡到较慢尾音。
    assign w_period_loss_product = r_note_period_stage1 * LOSS_PERIOD_SCALE_Q6;
    assign w_initial_loss_q16 = (w_period_loss_product >> 22) > 8192 ?
        16'd8192 : (w_period_loss_product >> 22) < 1 ? 16'd1 : w_period_loss_product[37:22];
    assign w_tail_loss_q16 = (r_initial_loss_precomputed >> 1);
    assign w_loss_transition_product = (r_initial_loss_precomputed - w_tail_loss_q16) * r_decay_age;
    assign w_loss_q16 = EXTENDED_DECAY == 0 ? (r_initial_loss_precomputed << 1) :
        r_initial_loss_precomputed - (w_loss_transition_product >> 12);
    assign w_secondary_loss_q16 = r_loss_precomputed >> 1;
    // 三点对称凸FIR [b,256-2b,b]/256。力度锁存在trigger，硬拨弦保留更多高次谐波。
    assign w_damping_side_q8 = 6'd8 + ((8'd255 - r_pluck_velocity) >> 3);
    assign w_damping_curvature = $signed(r_delay_sample_capture) -
        ($signed({r_previous_sample[15],r_previous_sample}) <<< 1) + $signed(r_older_sample);
    assign w_secondary_damping_curvature = $signed(r_secondary_delay_sample_capture) -
        ($signed({r_secondary_previous_sample[15],r_secondary_previous_sample}) <<< 1) + $signed(r_secondary_older_sample);
    assign w_shared_damping_input = r_multiply_secondary ?
        r_secondary_damping_curvature_stage : r_damping_curvature_stage;
    assign w_shared_damping_product = w_shared_damping_input * $signed({1'b0,w_damping_side_q8});
    assign w_shared_loss_input = r_multiply_secondary ?
        r_secondary_damping_precomputed : r_damping_precomputed;
    assign w_shared_loss_coefficient = r_multiply_secondary ?
        w_secondary_loss_coefficient : w_loss_coefficient;
    assign w_shared_loss_product = w_shared_loss_input * w_shared_loss_coefficient;
    assign w_shared_interpolation_input = r_multiply_secondary ?
        r_secondary_interpolation_difference_stage : r_interpolation_difference_stage;
    assign w_shared_interpolation_fraction = $signed({1'b0, r_multiply_secondary ?
        r_secondary_fraction_stage2 : r_delay_fraction_stage2});
    assign w_shared_interpolation_product = w_shared_interpolation_input * w_shared_interpolation_fraction;
    assign w_damping_product = r_damping_curvature_stage * $signed({1'b0,w_damping_side_q8});
    assign w_secondary_damping_product = r_secondary_damping_curvature_stage * $signed({1'b0,w_damping_side_q8});
    assign w_damping_acc_q8 = r_damping_center_q8 + r_damping_product_stage;
    assign w_secondary_damping_acc_q8 = r_secondary_damping_center_q8 + r_secondary_damping_product_stage;
    // Loss is clamped to <=16384 (EXTENDED_DECAY=0); signed16 is sufficient.
    assign w_loss_coefficient = $signed({1'b0,r_loss_precomputed[14:0]});
    assign w_secondary_loss_coefficient = $signed({1'b0,w_secondary_loss_q16[14:0]});
    assign w_loss_product = r_damping_precomputed * w_loss_coefficient;
    assign w_secondary_loss_product = r_secondary_damping_precomputed * w_secondary_loss_coefficient;
    assign w_primary_attenuated_q16 = ($signed(r_loss_input_stage) <<< 16) - $signed(r_loss_product_stage);
    assign w_secondary_attenuated_q16 = ($signed(r_secondary_loss_input_stage) <<< 16) - $signed(r_secondary_loss_product_stage);
    assign w_interpolation_difference = $signed(r_previous_filtered) - $signed(r_filtered_precomputed);
    assign w_interpolation_product = r_interpolation_difference_stage *
        $signed({1'b0, r_delay_fraction_stage2});
    // 0<=fraction<1：线性插值是凸组合，不会扩大被动反馈增益。
    assign w_feedback_extended = $signed(r_interpolation_center_stage2) + $signed(r_interpolation_product_stage[25:8]);
    assign w_feedback_sample = saturate_pcm(w_feedback_extended);
    assign w_secondary_interpolation_difference = $signed(r_secondary_previous_filtered) -
        $signed(r_secondary_filtered_precomputed);
    assign w_secondary_interpolation_product = r_secondary_interpolation_difference_stage *
        $signed({1'b0, r_secondary_fraction_stage2});
    assign w_secondary_feedback_extended = $signed(r_secondary_interpolation_center_stage2) +
        $signed(r_secondary_interpolation_product_stage[25:8]);
    assign w_secondary_feedback_sample = saturate_pcm(w_secondary_feedback_extended);
    // 对称1/128凸组合桥耦合，交换并耗散差模能量，不加入主动增益。
    // 差值移位向零舍入，避免两环同时受算术右移的负偏置影响。
    assign w_coupling_difference = $signed(r_secondary_feedback_saturated) - $signed(r_feedback_saturated);
    assign w_coupling_step = !r_active || r_excitation_remaining != 0 ||
        r_secondary_excitation_remaining != 0 ? 18'sd0 : w_coupling_difference < 0 ?
        -((-w_coupling_difference) >>> 7) : (w_coupling_difference >>> 7);
    assign w_primary_coupled_extended = $signed(r_feedback_saturated) +
        (ENABLE_DUAL_POLARIZATION != 0 ? w_coupling_step : 18'sd0);
    assign w_secondary_coupled_extended = $signed(r_secondary_feedback_saturated) - w_coupling_step;
    assign w_primary_coupled_sample = saturate_pcm(w_primary_coupled_extended);
    assign w_secondary_coupled_sample = saturate_pcm(w_secondary_coupled_extended);
    // 力度只需 9 位正 signed 数；不扩大成无用的 17 位乘法操作数。
    assign w_velocity_positive = $signed({1'b0, i_trigger ? i_velocity : r_pluck_velocity});
    assign w_noise_product = $signed(r_lfsr) * w_velocity_positive;
    assign w_initial_noise_product = -16'sd21535 * w_velocity_positive;
    // 行波变量明确取速度/斜率，而非把对称位移三角直接当桥端音频。
    // 分段速度参考非中心三角位移的导数；7:1释放噪声只在首次填环期间注入。
    // 额外comb是经验接触/读出整形，与几何轮廓并非严格的同一乐器拟合。
    // 这是约化SDL激励，尚未实现真实指腹-弦碰撞或拟合实际桥端传递函数。
    assign w_release_velocity_sample = r_excitation_phase_q16 < (SAFE_PLUCK_POSITION * 256) ?
        -RELEASE_NEGATIVE : RELEASE_POSITIVE;
    assign w_excitation_shape = ($signed(w_release_velocity_sample) <<< 3) -
        $signed(w_release_velocity_sample) + $signed(r_lfsr);
    assign w_physical_excitation_product = w_excitation_shape * w_velocity_positive;
    // 凸组合低通仅塑造起音，不放在循环反馈内，避免改变标定音高。
    assign w_velocity_times_three = {1'b0, w_velocity_positive} + (w_velocity_positive << 1);
    assign w_excitation_alpha_q8 = 8'd32 + w_velocity_times_three[9:3];
    assign w_excitation_error = $signed(r_noise_sample_precomputed) - $signed(r_excitation_lowpass);
    assign w_excitation_step_product = w_shared_excitation_product;
    assign w_initial_excitation_product = w_shared_excitation_product[24:0];
    // 一周期有界新激励叠加在现有行波上，重拨期间保留3/4旧反馈。
    // STOP锁存1/2传播阻尼；下次合法拨弦解除，不清RAM或反馈历史。
    assign w_injection = w_stop || r_stopped && !i_trigger ? 16'sd0 :
        i_trigger ? (ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed) :
        r_excitation_remaining != 0 ? r_pick_precomputed : 16'sd0;
    assign w_injected = (w_stop || r_stopped && !i_trigger ? ($signed(r_coupled_precomputed) >>> 1) :
        (i_trigger && r_active || r_replucking && r_excitation_remaining != 0) ?
        $signed(r_coupled_precomputed) - ($signed(r_coupled_precomputed) >>> 2) : $signed(r_coupled_precomputed)) + $signed(w_injection);
    assign w_secondary_injected = (w_stop || r_stopped && !i_trigger ? ($signed(r_secondary_coupled_precomputed) >>> 1) :
        (i_trigger && r_active || r_replucking && r_secondary_excitation_remaining != 0) ?
        $signed(r_secondary_coupled_precomputed) - ($signed(r_secondary_coupled_precomputed) >>> 2) : $signed(r_secondary_coupled_precomputed)) +
        $signed((i_trigger || r_secondary_excitation_remaining != 0) ? w_injection : 16'sd0);
    assign w_primary_raw_sample = i_trigger || r_excitation_remaining != 0 ? r_write_precomputed : r_delay_sample;
    assign w_secondary_raw_sample = i_trigger || r_secondary_excitation_remaining != 0 ? r_secondary_write_precomputed : r_secondary_delay_sample;
    assign w_polarization_mix = $signed(w_primary_raw_sample) +
        ((($signed(w_secondary_raw_sample) - $signed(w_primary_raw_sample))) >>> 2);
    assign w_output_raw = ENABLE_DUAL_POLARIZATION != 0 ?
        saturate_pcm(w_polarization_mix) : w_primary_raw_sample;
    assign w_dc_error_q8 = $signed({w_output_raw[15], w_output_raw, 8'd0}) -
        $signed({r_dc_estimate_q8[23], r_dc_estimate_q8});
    assign w_dc_next_q8 = $signed({r_dc_estimate_q8[23], r_dc_estimate_q8}) +
        (w_dc_error_q8 >>> 8);
    assign w_ac_extended = $signed(w_output_raw) - $signed(r_dc_estimate_q8[23:8]);
    assign w_delay_read_address = i_trigger && r_delay_index >= r_target_length ?
        {DELAY_ADDRESS_WIDTH{1'b0}} : r_delay_index[DELAY_ADDRESS_WIDTH-1:0];
    assign w_secondary_read_address = i_trigger && r_secondary_delay_index >= r_target_secondary_length ?
        {DELAY_ADDRESS_WIDTH{1'b0}} : r_secondary_delay_index[DELAY_ADDRESS_WIDTH-1:0];

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_multiply_secondary <= 0;
            r_noise_sample_precomputed <= 0;
            r_initial_noise_precomputed <= 0;
            r_initial_loss_precomputed <= 16'd1;
            r_loss_precomputed <= 16'd1;
            r_delay_sample_capture <= 0; r_secondary_delay_sample_capture <= 0;
            r_damping_curvature_stage <= 0; r_secondary_damping_curvature_stage <= 0;
            r_damping_center_stage <= 0; r_secondary_damping_center_stage <= 0;
            r_damping_product_stage <= 0; r_secondary_damping_product_stage <= 0;
            r_damping_center_q8 <= 0; r_secondary_damping_center_q8 <= 0;
            r_damping_acc_stage <= 0; r_secondary_damping_acc_stage <= 0;
            r_loss_product_stage <= 0; r_secondary_loss_product_stage <= 0;
            r_loss_input_stage <= 0; r_secondary_loss_input_stage <= 0;
            r_attenuated_stage <= 0; r_secondary_attenuated_stage <= 0;
            r_interpolation_difference_stage <= 0; r_secondary_interpolation_difference_stage <= 0;
            r_interpolation_product_stage <= 0; r_secondary_interpolation_product_stage <= 0;
            r_interpolation_center_stage1 <= 0; r_interpolation_center_stage2 <= 0;
            r_secondary_interpolation_center_stage1 <= 0; r_secondary_interpolation_center_stage2 <= 0;
            r_damping_precomputed <= 0;
            r_secondary_damping_precomputed <= 0;
            r_filtered_precomputed <= 0;
            r_secondary_filtered_precomputed <= 0;
            r_excitation_filtered_precomputed <= 0;
            r_initial_excitation_precomputed <= 0;
            r_feedback_saturated <= 0;
            r_secondary_feedback_saturated <= 0;
            r_coupled_precomputed <= 0;
            r_secondary_coupled_precomputed <= 0;
            r_write_precomputed <= 0;
            r_secondary_write_precomputed <= 0;
            r_write_guard_precomputed <= 0;
        end
        else
        begin
            r_multiply_secondary <= ENABLE_DUAL_POLARIZATION != 0 ? !r_multiply_secondary : 1'b0;
            r_initial_loss_precomputed <= w_initial_loss_q16;
            r_loss_precomputed <= w_loss_q16;
            r_delay_sample_capture <= r_delay_sample;
            r_secondary_delay_sample_capture <= r_secondary_delay_sample;
            r_damping_curvature_stage <= w_damping_curvature;
            r_secondary_damping_curvature_stage <= w_secondary_damping_curvature;
            r_damping_center_stage <= r_previous_sample;
            r_secondary_damping_center_stage <= r_secondary_previous_sample;
            if (SHARE_POLARIZATION_MULTIPLIERS != 0)
            begin
                if (r_multiply_secondary)
                begin
                    r_secondary_damping_product_stage <= w_shared_damping_product;
                end
                else
                begin
                    r_damping_product_stage <= w_shared_damping_product;
                end
            end
            else
            begin
                r_damping_product_stage <= w_damping_product;
                r_secondary_damping_product_stage <= w_secondary_damping_product;
            end
            r_damping_center_q8 <= $signed(r_damping_center_stage) <<< 8;
            r_secondary_damping_center_q8 <= $signed(r_secondary_damping_center_stage) <<< 8;
            r_damping_acc_stage <= w_damping_acc_q8;
            r_secondary_damping_acc_stage <= w_secondary_damping_acc_q8;
            // RAM/FIR/DSP/round separated; shared mode requires 24clk control setup.
            // FIR/增益最近舍入，正负半周对称；系数凸/被动，峰值仍不超过整数输入。
            r_damping_precomputed <= round_fir_legacy(r_damping_acc_stage);
            r_secondary_damping_precomputed <= round_fir_legacy(r_secondary_damping_acc_stage);
            if (SHARE_POLARIZATION_MULTIPLIERS != 0)
            begin
                if (r_multiply_secondary)
                begin
                    r_secondary_loss_product_stage <= w_shared_loss_product;
                end
                else
                begin
                    r_loss_product_stage <= w_shared_loss_product;
                end
            end
            else
            begin
                r_loss_product_stage <= w_loss_product;
                r_secondary_loss_product_stage <= w_secondary_loss_product;
            end
            r_loss_input_stage <= r_damping_precomputed;
            r_secondary_loss_input_stage <= r_secondary_damping_precomputed;
            r_attenuated_stage <= w_primary_attenuated_q16;
            r_secondary_attenuated_stage <= w_secondary_attenuated_q16;
            r_filtered_precomputed <= round_loss_legacy(r_attenuated_stage);
            r_secondary_filtered_precomputed <= round_loss_legacy(r_secondary_attenuated_stage);
            r_interpolation_difference_stage <= w_interpolation_difference;
            r_secondary_interpolation_difference_stage <= w_secondary_interpolation_difference;
            r_interpolation_center_stage1 <= r_filtered_precomputed;
            r_secondary_interpolation_center_stage1 <= r_secondary_filtered_precomputed;
            if (SHARE_POLARIZATION_MULTIPLIERS != 0)
            begin
                if (r_multiply_secondary)
                begin
                    r_secondary_interpolation_product_stage <= w_shared_interpolation_product;
                end
                else
                begin
                    r_interpolation_product_stage <= w_shared_interpolation_product;
                end
            end
            else
            begin
                r_interpolation_product_stage <= w_interpolation_product;
                r_secondary_interpolation_product_stage <= w_secondary_interpolation_product;
            end
            r_interpolation_center_stage2 <= r_interpolation_center_stage1;
            r_secondary_interpolation_center_stage2 <= r_secondary_interpolation_center_stage1;
            // 预留6dB激励余量；音色的增益/尾音须由RTL导出波形测量。
            r_noise_sample_precomputed <= ENABLE_PHYSICAL_EXCITATION != 0 ?
                (w_physical_excitation_product >>> 12) : $signed(w_noise_product[23:8]);
            r_initial_noise_precomputed <= ENABLE_PHYSICAL_EXCITATION != 0 ?
                (((-20'sd7 * RELEASE_NEGATIVE - 20'sd21535) * w_velocity_positive) >>> 12) : $signed(w_initial_noise_product[23:8]);
            r_excitation_filtered_precomputed <= $signed(r_excitation_lowpass) + (w_excitation_step_product >>> 8);
            r_initial_excitation_precomputed <= w_initial_excitation_product >>> 8;
            // FIR/loss -> interpolation/saturation -> coupling/saturation -> injection/RAM.
            // Shared arithmetic settles within24clk before sample_tick.
            r_feedback_saturated <= w_feedback_sample;
            r_secondary_feedback_saturated <= w_secondary_feedback_sample;
            r_coupled_precomputed <= w_primary_coupled_sample;
            r_secondary_coupled_precomputed <= w_secondary_coupled_sample;
            r_write_precomputed <= saturate_pcm(w_injected);
            r_secondary_write_precomputed <= saturate_pcm(w_secondary_injected);
            r_write_guard_precomputed <= w_feedback_extended > 32767 || w_feedback_extended < -32768 ||
                w_primary_coupled_extended > 32767 || w_primary_coupled_extended < -32768 ||
                w_injected > 32767 || w_injected < -32768 || w_ac_extended > 32767 || w_ac_extended < -32768 ||
                (ENABLE_DUAL_POLARIZATION != 0 && (w_secondary_injected > 32767 || w_secondary_injected < -32768 ||
                w_secondary_feedback_extended > 32767 || w_secondary_feedback_extended < -32768 ||
                w_secondary_coupled_extended > 32767 || w_secondary_coupled_extended < -32768));
        end
    end

    // 目标音高预计算两级；R8 core提供36clk准备期覆盖共享模式24clk合同。
    // 此流水完全不写正在发声的周期或损耗参数。
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_target_period <= 32'd524288;
            r_target_length <= 16'd8;
            r_target_fraction <= 0;
            r_target_secondary_length <= 16'd8;
            r_target_secondary_fraction <= 0;
            r_target_excitation_step <= 16'd8192;
        end
        else
        begin
            r_target_period <= w_period_q16;
            r_target_length <= w_requested_period;
            r_target_fraction <= w_fraction_q8;
            r_target_secondary_length <= w_secondary_requested_period;
            r_target_secondary_fraction <= w_secondary_fraction_q8;
            r_target_excitation_step <= ENABLE_EXTERNAL_PITCH != 0 ? i_external_excitation_step : excitation_step_q16(i_midi_note);
        end
    end

    // 初始化、激励、反馈统一通过无 reset 的单写 RAM 端口。
    always @*
    begin
        w_delay_write_enable = 1'b0;
        w_delay_write_address = w_delay_read_address;
        w_delay_write_sample = 16'sd0;
        if (!i_reset)
        begin
            if (!r_memory_ready)
            begin
                w_delay_write_enable = 1'b1;
                w_delay_write_address = r_memory_init_index[DELAY_ADDRESS_WIDTH-1:0];
            end
            else if (i_sample_tick)
            begin
                if (i_trigger)
                begin
                    w_delay_write_enable = 1'b1;
                    w_delay_write_sample = r_write_precomputed;
                end
                else if (r_active)
                begin
                    w_delay_write_enable = 1'b1;
                    w_delay_write_sample = r_write_precomputed;
                end
            end
        end
    end

    always @(posedge i_clk)
        if (w_delay_write_enable)
            r_delay_line[w_delay_write_address] <= w_delay_write_sample;

    always @(posedge i_clk)
        r_delay_sample <= r_delay_line[w_delay_read_address];

    // 独立RAM单写端口：反馈+有限新激励，不清旧环、滤波或琴体状态。
    always @*
    begin
        w_secondary_write_enable = 1'b0;
        w_secondary_write_address = w_secondary_read_address;
        w_secondary_write_sample = 16'sd0;
        if (!i_reset && ENABLE_DUAL_POLARIZATION != 0)
        begin
            if (!r_memory_ready)
            begin
                w_secondary_write_enable = 1'b1;
                w_secondary_write_address = r_memory_init_index[DELAY_ADDRESS_WIDTH-1:0];
            end
            else if (i_sample_tick)
            begin
                if (i_trigger)
                begin
                    w_secondary_write_enable = 1'b1;
                    w_secondary_write_sample = r_secondary_write_precomputed;
                end
                else if (r_active)
                begin
                    w_secondary_write_enable = 1'b1;
                    w_secondary_write_sample = r_secondary_write_precomputed;
                end
            end
        end
    end
    always @(posedge i_clk)
    begin
        if (w_secondary_write_enable)
            r_secondary_delay_line[w_secondary_write_address] <= w_secondary_write_sample;
        r_secondary_delay_sample <= ENABLE_DUAL_POLARIZATION != 0 ?
            r_secondary_delay_line[w_secondary_read_address] : 16'sd0;
    end

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_delay_index <= 16'd0;
            r_excitation_remaining <= 16'd0;
            r_secondary_delay_index <= 16'd0;
            r_secondary_excitation_remaining <= 16'd0;
            r_secondary_previous_sample <= 16'sd0;
            r_secondary_older_sample <= 16'sd0;
            r_secondary_previous_filtered <= 17'sd0;
            r_lfsr <= 16'hace1;
            r_previous_sample <= 16'sd0;
            r_older_sample <= 16'sd0;
            r_pluck_velocity <= 8'd0;
            r_previous_filtered <= 17'sd0;
            r_excitation_lowpass <= 16'sd0;
            r_dc_estimate_q8 <= 24'sd0;
            r_active <= 1'b0;
            r_decay_age <= 0;
            r_pick_index <= 0;
            r_pick_length <= 1;
            r_excitation_age <= 0;
            r_excitation_phase_q16 <= 0;
            r_memory_init_index <= 16'd0;
            r_memory_ready <= 1'b0;
            o_audio_sample <= 0;
            r_note_period_stage1 <= 32'd524288;
            r_delay_length_stage2 <= 16'd8;
            r_delay_fraction_stage2 <= 0;
            r_secondary_length_stage2 <= 16'd8;
            r_secondary_fraction_stage2 <= 0;
            r_excitation_step_stage2 <= 16'd8192;
            r_stopped <= 0;
            r_replucking <= 0;
            o_guard_count <= 0;
        end
        else if (!r_memory_ready)
        begin
            o_audio_sample <= 0;
            if (r_memory_init_index == DELAY_LINE_LENGTH - 1)
                r_memory_ready <= 1'b1;
            else
                r_memory_init_index <= r_memory_init_index + 16'd1;
        end
        else if (i_sample_tick)
        begin
            if (r_write_guard_precomputed && o_guard_count != 32'hffffffff)
                o_guard_count <= o_guard_count + 1'b1;
            if (w_stop)
            begin
                r_stopped <= 1'b1;
                r_excitation_remaining <= 0;
                r_secondary_excitation_remaining <= 0;
            end
            if (i_trigger && !w_stop)
            begin
                r_note_period_stage1 <= r_target_period;
                r_delay_length_stage2 <= r_target_length;
                r_delay_fraction_stage2 <= r_target_fraction;
                r_secondary_length_stage2 <= r_target_secondary_length;
                r_secondary_fraction_stage2 <= r_target_secondary_fraction;
                r_excitation_step_stage2 <= r_target_excitation_step;
                r_stopped <= 0;
                r_replucking <= r_active;
                r_decay_age <= 0;
                r_pluck_velocity <= i_velocity;
                // Active retrigger keeps the same string output/DC path; only cold
                // legacy onset retains the immediate initial-excitation sample.
                o_audio_sample <= saturate_pcm(w_ac_extended);
                r_pick_length <= w_pick_length_product[23:8] < 2 ? 2 :
                    w_pick_length_product[23:8] > PICK_DEPTH ? PICK_DEPTH : w_pick_length_product[23:8];
                r_pick_index <= 1;
                r_excitation_age <= 1;
                r_excitation_lowpass <= r_initial_excitation_precomputed;
                r_older_sample <= r_previous_sample;
                r_previous_sample <= r_delay_sample;
                r_previous_filtered <= r_filtered_precomputed;
                r_secondary_older_sample <= r_secondary_previous_sample;
                r_secondary_previous_sample <= r_secondary_delay_sample;
                r_secondary_previous_filtered <= r_secondary_filtered_precomputed;
                r_delay_index <= w_delay_read_address + 16'd1 >= r_target_length ? 0 : w_delay_read_address + 16'd1;
                r_excitation_remaining <= r_target_length - 16'd1;
                r_secondary_delay_index <= w_secondary_read_address + 16'd1 >= r_target_secondary_length ? 0 : w_secondary_read_address + 16'd1;
                r_secondary_excitation_remaining <= r_target_secondary_length - 16'd1;
                r_excitation_phase_q16 <= r_target_excitation_step;
                r_active <= 1'b1;
            end
            else if (r_active)
            begin
                if (!r_decay_age[12]) r_decay_age <= r_decay_age + 1'b1;
                r_older_sample <= r_previous_sample;
                r_secondary_older_sample <= r_secondary_previous_sample;
                o_audio_sample <= saturate_pcm(w_ac_extended);
                r_dc_estimate_q8 <= w_dc_next_q8[23:0];
                if (r_excitation_remaining != 0)
                begin
                    r_excitation_remaining <= w_stop ? 0 : r_excitation_remaining - 16'd1;
                    r_previous_sample <= r_delay_sample;
                    r_excitation_age <= r_excitation_age + 1'b1;
                    r_pick_index <= r_pick_index + 1 >= r_pick_length ? 0 : r_pick_index + 1'b1;
                    r_excitation_lowpass <= r_excitation_filtered_precomputed[15:0];
                    r_previous_filtered <= r_filtered_precomputed;
                    r_excitation_phase_q16 <= r_excitation_phase_q16 + r_excitation_step_stage2;
                end
                else
                begin
                    r_previous_sample <= r_delay_sample;
                    r_previous_filtered <= r_filtered_precomputed;
                end
                if (r_secondary_excitation_remaining != 0)
                begin
                    r_secondary_excitation_remaining <= w_stop ? 0 : r_secondary_excitation_remaining - 16'd1;
                    r_secondary_previous_sample <= r_secondary_delay_sample;
                    r_secondary_previous_filtered <= r_secondary_filtered_precomputed;
                end
                else
                begin
                    r_secondary_previous_sample <= r_secondary_delay_sample;
                    r_secondary_previous_filtered <= r_secondary_filtered_precomputed;
                end
                r_lfsr <= {r_lfsr[14:0],
                    r_lfsr[15] ^ r_lfsr[13] ^ r_lfsr[12] ^ r_lfsr[10]};
                r_delay_index <= r_delay_index + 16'd1 >= r_delay_length_stage2 ?
                    16'd0 : r_delay_index + 16'd1;
                r_secondary_delay_index <= r_secondary_delay_index + 16'd1 >= r_secondary_length_stage2 ?
                    16'd0 : r_secondary_delay_index + 16'd1;
            end
            else
                o_audio_sample <= 0;
        end
    end
endmodule
