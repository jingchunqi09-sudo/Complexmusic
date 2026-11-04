// 尤克里里拨弦波导：有限拨弦轮廓、双偏振波导和被动耦合。
// high-G / low-G 使用同一引擎的独立调弦表，不存录音、不额外实例化吉他或贝斯。
// 分数延迟降低整数音高误差；输出 DC blocker 不改变反馈环的音准。
module ukulele_waveguide_voice #(
    parameter integer DELAY_LINE_LENGTH = 2048,
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer SAMPLE_RATE_MILLIHZ = 48828125,
    parameter integer ENABLE_PICK_COMB = 1,
    parameter integer PLUCK_POSITION_Q8 = 64,
    parameter integer EXTENDED_DECAY = 1,
    parameter integer ENABLE_DUAL_POLARIZATION = 1,
    parameter integer ENABLE_PHYSICAL_EXCITATION = 1,
    parameter integer ENABLE_BODY_RESONATOR = 1
) (
    input                                i_clk,
    input                                i_reset,
    input                                i_sample_tick,       // 单周期音频采样使能
    input                                i_trigger,           // 单次拨弦，允许重触发
    input                                i_gate,              // 兼容控制接口，包络由上层处理
    input        [6:0]                   i_midi_note,
    input        [7:0]                   i_velocity,          // 拨弦力度/亮度，0..255
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

    localparam integer DELAY_ADDRESS_WIDTH = memory_address_width(DELAY_LINE_LENGTH);
    reg signed [15:0] r_delay_line [0:DELAY_LINE_LENGTH-1];
    // 独立偏振的传播、滤波和分数调谐状态；不是同一延迟输出的复制。
    reg signed [15:0] r_secondary_delay_line [0:DELAY_LINE_LENGTH-1];
    reg signed [15:0] r_secondary_delay_sample;
    reg [15:0] r_secondary_delay_index;
    reg [15:0] r_secondary_excitation_remaining;
    reg signed [15:0] r_secondary_previous_sample;
    reg signed [16:0] r_secondary_previous_filtered;
    reg signed [16:0] r_secondary_filtered_precomputed;
    reg [15:0] r_secondary_length_stage2;
    reg [7:0] r_secondary_fraction_stage2;
    reg signed [15:0] r_delay_sample;
    reg [15:0] r_delay_index;                // 当前循环地址，单位为音频样本
    reg [15:0] r_excitation_remaining;       // 噪声填充尚余样本数
    reg [15:0] r_lfsr;                       // 固定可重现的 16 位噪声状态
    reg signed [15:0] r_previous_sample;    // 两点弦损耗滤波历史
    reg signed [16:0] r_previous_filtered;  // 分数延迟插值历史
    reg signed [15:0] r_excitation_lowpass; // 力度→带宽的激励低通状态
    reg signed [23:0] r_dc_estimate_q8;      // Q8 输出直流估计
    reg signed [23:0] r_radiation_dc_q8;    // 琴体后Q8直流；消除定点模态舍入偏置。
    // h(z)=(1-z^-M)/2，仅作用激励，不改变反馈相位/衰减。
    // M约为弦周期的1/4；实际拨弦点待参考乐器标定。
    localparam integer PICK_DEPTH = DELAY_LINE_LENGTH / 2;
    localparam integer PICK_ADDRESS_WIDTH = memory_address_width(PICK_DEPTH);
    reg signed [15:0] r_pick_history [0:PICK_DEPTH-1];
    reg signed [15:0] r_pick_delayed;
    reg signed [15:0] r_pick_precomputed;
    reg [15:0] r_pick_index;
    reg [15:0] r_pick_length;
    reg [15:0] r_excitation_age;
    reg [15:0] r_excitation_phase_q16;
    reg [15:0] r_excitation_step_stage2;
    wire signed [15:0] w_triangle_sample;
    wire signed [19:0] w_excitation_shape;
    wire signed [28:0] w_physical_excitation_product;
    wire signed [16:0] w_pick_difference;
    wire [23:0] w_pick_length_product;
    reg r_active;
    reg [12:0] r_decay_age;
    reg [15:0] r_memory_init_index;
    reg r_memory_ready;
    // 小周期只读表放 LUT，避免大量小表各占整块 BSRAM；依据 SUG550 5.17。
    reg [31:0] r_note_period_stage1 /* synthesis syn_romstyle = "logic" */;
    reg [15:0] r_delay_length_stage2;      // 第二周期补偿滤波群延迟后的整数长度
    reg [7:0] r_delay_fraction_stage2;     // 同帧 Q0.8 分数延迟，供反馈凸组合

    wire [31:0] w_period_q16;
    wire [31:0] w_delay_period_q16;
    wire [31:0] w_secondary_delay_period_q16;
    wire [15:0] w_secondary_requested_period;
    wire [7:0] w_secondary_fraction_q8;
    wire [15:0] w_requested_period;
    wire [7:0] w_fraction_q8;
    wire signed [16:0] w_average;
    reg signed [16:0] r_filtered_precomputed; // 系统时钟预计算寄存器，非音频历史。
    wire [3:0] w_loss_q8;
    wire signed [21:0] w_loss_product;
    wire signed [15:0] w_body_sample;
    wire signed [24:0] w_radiation_dc_error;
    wire signed [24:0] w_radiation_dc_next;
    wire signed [18:0] w_radiation_ac;
    wire signed [17:0] w_interpolation_difference;
    wire signed [26:0] w_interpolation_product;
    wire signed [18:0] w_feedback_extended;
    wire signed [15:0] w_feedback_sample;
    wire signed [16:0] w_secondary_average;
    wire signed [21:0] w_secondary_loss_product;
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
    wire signed [25:0] w_excitation_step_product;
    wire signed [24:0] w_initial_excitation_product;
    wire signed [16:0] w_excitation_error;
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

    // 系统时钟预计算，切断噪声乘法→激励乘法→DC→琴体的长路径。
    // 数据在音频使能之间稳定；板级快照提前12clk，未增加音频帧等待。
    reg signed [15:0] r_body_input_sample;
    generate
        if (ENABLE_BODY_RESONATOR != 0) begin: MODAL_BODY
            instrument_body_resonator u_body (
                .i_clk(i_clk), .i_reset(i_reset), .i_sample_tick(i_sample_tick && r_memory_ready),
                .i_trigger(i_trigger), .i_bypass(1'b0), .i_instrument(1'b1),
                .i_sample(r_body_input_sample), .o_sample(w_body_sample),
                .o_guard_count(), .o_clip_count()
            );
        end else begin: LEGACY_BODY
            plucked_body_filter u_body (
                .i_clk(i_clk), .i_reset(i_reset), .i_sample_tick(i_sample_tick && r_memory_ready),
                .i_trigger(i_trigger), .i_sample(r_body_input_sample), .o_sample(w_body_sample)
            );
        end
    endgenerate

`include "src/instrument_pitch.vh"
    // 一周期三角形初始位移的相位步进。每个除数是编译期音符常量，
    // 这里只生成参数系数表，不存录音，也不综合运行时可变除法器。
    function [15:0] excitation_step_q16;
        input [6:0] note;
        begin
            case (note)
            7'd0: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd0) >> 1)) / midi_period_q16(7'd0);
            7'd1: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd1) >> 1)) / midi_period_q16(7'd1);
            7'd2: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd2) >> 1)) / midi_period_q16(7'd2);
            7'd3: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd3) >> 1)) / midi_period_q16(7'd3);
            7'd4: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd4) >> 1)) / midi_period_q16(7'd4);
            7'd5: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd5) >> 1)) / midi_period_q16(7'd5);
            7'd6: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd6) >> 1)) / midi_period_q16(7'd6);
            7'd7: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd7) >> 1)) / midi_period_q16(7'd7);
            7'd8: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd8) >> 1)) / midi_period_q16(7'd8);
            7'd9: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd9) >> 1)) / midi_period_q16(7'd9);
            7'd10: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd10) >> 1)) / midi_period_q16(7'd10);
            7'd11: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd11) >> 1)) / midi_period_q16(7'd11);
            7'd12: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd12) >> 1)) / midi_period_q16(7'd12);
            7'd13: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd13) >> 1)) / midi_period_q16(7'd13);
            7'd14: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd14) >> 1)) / midi_period_q16(7'd14);
            7'd15: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd15) >> 1)) / midi_period_q16(7'd15);
            7'd16: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd16) >> 1)) / midi_period_q16(7'd16);
            7'd17: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd17) >> 1)) / midi_period_q16(7'd17);
            7'd18: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd18) >> 1)) / midi_period_q16(7'd18);
            7'd19: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd19) >> 1)) / midi_period_q16(7'd19);
            7'd20: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd20) >> 1)) / midi_period_q16(7'd20);
            7'd21: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd21) >> 1)) / midi_period_q16(7'd21);
            7'd22: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd22) >> 1)) / midi_period_q16(7'd22);
            7'd23: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd23) >> 1)) / midi_period_q16(7'd23);
            7'd24: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd24) >> 1)) / midi_period_q16(7'd24);
            7'd25: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd25) >> 1)) / midi_period_q16(7'd25);
            7'd26: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd26) >> 1)) / midi_period_q16(7'd26);
            7'd27: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd27) >> 1)) / midi_period_q16(7'd27);
            7'd28: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd28) >> 1)) / midi_period_q16(7'd28);
            7'd29: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd29) >> 1)) / midi_period_q16(7'd29);
            7'd30: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd30) >> 1)) / midi_period_q16(7'd30);
            7'd31: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd31) >> 1)) / midi_period_q16(7'd31);
            7'd32: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd32) >> 1)) / midi_period_q16(7'd32);
            7'd33: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd33) >> 1)) / midi_period_q16(7'd33);
            7'd34: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd34) >> 1)) / midi_period_q16(7'd34);
            7'd35: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd35) >> 1)) / midi_period_q16(7'd35);
            7'd36: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd36) >> 1)) / midi_period_q16(7'd36);
            7'd37: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd37) >> 1)) / midi_period_q16(7'd37);
            7'd38: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd38) >> 1)) / midi_period_q16(7'd38);
            7'd39: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd39) >> 1)) / midi_period_q16(7'd39);
            7'd40: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd40) >> 1)) / midi_period_q16(7'd40);
            7'd41: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd41) >> 1)) / midi_period_q16(7'd41);
            7'd42: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd42) >> 1)) / midi_period_q16(7'd42);
            7'd43: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd43) >> 1)) / midi_period_q16(7'd43);
            7'd44: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd44) >> 1)) / midi_period_q16(7'd44);
            7'd45: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd45) >> 1)) / midi_period_q16(7'd45);
            7'd46: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd46) >> 1)) / midi_period_q16(7'd46);
            7'd47: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd47) >> 1)) / midi_period_q16(7'd47);
            7'd48: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd48) >> 1)) / midi_period_q16(7'd48);
            7'd49: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd49) >> 1)) / midi_period_q16(7'd49);
            7'd50: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd50) >> 1)) / midi_period_q16(7'd50);
            7'd51: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd51) >> 1)) / midi_period_q16(7'd51);
            7'd52: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd52) >> 1)) / midi_period_q16(7'd52);
            7'd53: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd53) >> 1)) / midi_period_q16(7'd53);
            7'd54: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd54) >> 1)) / midi_period_q16(7'd54);
            7'd55: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd55) >> 1)) / midi_period_q16(7'd55);
            7'd56: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd56) >> 1)) / midi_period_q16(7'd56);
            7'd57: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd57) >> 1)) / midi_period_q16(7'd57);
            7'd58: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd58) >> 1)) / midi_period_q16(7'd58);
            7'd59: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd59) >> 1)) / midi_period_q16(7'd59);
            7'd60: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd60) >> 1)) / midi_period_q16(7'd60);
            7'd61: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd61) >> 1)) / midi_period_q16(7'd61);
            7'd62: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd62) >> 1)) / midi_period_q16(7'd62);
            7'd63: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd63) >> 1)) / midi_period_q16(7'd63);
            7'd64: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd64) >> 1)) / midi_period_q16(7'd64);
            7'd65: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd65) >> 1)) / midi_period_q16(7'd65);
            7'd66: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd66) >> 1)) / midi_period_q16(7'd66);
            7'd67: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd67) >> 1)) / midi_period_q16(7'd67);
            7'd68: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd68) >> 1)) / midi_period_q16(7'd68);
            7'd69: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd69) >> 1)) / midi_period_q16(7'd69);
            7'd70: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd70) >> 1)) / midi_period_q16(7'd70);
            7'd71: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd71) >> 1)) / midi_period_q16(7'd71);
            7'd72: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd72) >> 1)) / midi_period_q16(7'd72);
            7'd73: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd73) >> 1)) / midi_period_q16(7'd73);
            7'd74: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd74) >> 1)) / midi_period_q16(7'd74);
            7'd75: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd75) >> 1)) / midi_period_q16(7'd75);
            7'd76: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd76) >> 1)) / midi_period_q16(7'd76);
            7'd77: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd77) >> 1)) / midi_period_q16(7'd77);
            7'd78: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd78) >> 1)) / midi_period_q16(7'd78);
            7'd79: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd79) >> 1)) / midi_period_q16(7'd79);
            7'd80: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd80) >> 1)) / midi_period_q16(7'd80);
            7'd81: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd81) >> 1)) / midi_period_q16(7'd81);
            7'd82: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd82) >> 1)) / midi_period_q16(7'd82);
            7'd83: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd83) >> 1)) / midi_period_q16(7'd83);
            7'd84: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd84) >> 1)) / midi_period_q16(7'd84);
            7'd85: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd85) >> 1)) / midi_period_q16(7'd85);
            7'd86: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd86) >> 1)) / midi_period_q16(7'd86);
            7'd87: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd87) >> 1)) / midi_period_q16(7'd87);
            7'd88: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd88) >> 1)) / midi_period_q16(7'd88);
            7'd89: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd89) >> 1)) / midi_period_q16(7'd89);
            7'd90: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd90) >> 1)) / midi_period_q16(7'd90);
            7'd91: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd91) >> 1)) / midi_period_q16(7'd91);
            7'd92: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd92) >> 1)) / midi_period_q16(7'd92);
            7'd93: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd93) >> 1)) / midi_period_q16(7'd93);
            7'd94: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd94) >> 1)) / midi_period_q16(7'd94);
            7'd95: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd95) >> 1)) / midi_period_q16(7'd95);
            7'd96: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd96) >> 1)) / midi_period_q16(7'd96);
            7'd97: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd97) >> 1)) / midi_period_q16(7'd97);
            7'd98: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd98) >> 1)) / midi_period_q16(7'd98);
            7'd99: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd99) >> 1)) / midi_period_q16(7'd99);
            7'd100: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd100) >> 1)) / midi_period_q16(7'd100);
            7'd101: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd101) >> 1)) / midi_period_q16(7'd101);
            7'd102: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd102) >> 1)) / midi_period_q16(7'd102);
            7'd103: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd103) >> 1)) / midi_period_q16(7'd103);
            7'd104: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd104) >> 1)) / midi_period_q16(7'd104);
            7'd105: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd105) >> 1)) / midi_period_q16(7'd105);
            7'd106: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd106) >> 1)) / midi_period_q16(7'd106);
            7'd107: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd107) >> 1)) / midi_period_q16(7'd107);
            7'd108: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd108) >> 1)) / midi_period_q16(7'd108);
            7'd109: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd109) >> 1)) / midi_period_q16(7'd109);
            7'd110: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd110) >> 1)) / midi_period_q16(7'd110);
            7'd111: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd111) >> 1)) / midi_period_q16(7'd111);
            7'd112: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd112) >> 1)) / midi_period_q16(7'd112);
            7'd113: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd113) >> 1)) / midi_period_q16(7'd113);
            7'd114: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd114) >> 1)) / midi_period_q16(7'd114);
            7'd115: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd115) >> 1)) / midi_period_q16(7'd115);
            7'd116: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd116) >> 1)) / midi_period_q16(7'd116);
            7'd117: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd117) >> 1)) / midi_period_q16(7'd117);
            7'd118: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd118) >> 1)) / midi_period_q16(7'd118);
            7'd119: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd119) >> 1)) / midi_period_q16(7'd119);
            7'd120: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd120) >> 1)) / midi_period_q16(7'd120);
            7'd121: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd121) >> 1)) / midi_period_q16(7'd121);
            7'd122: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd122) >> 1)) / midi_period_q16(7'd122);
            7'd123: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd123) >> 1)) / midi_period_q16(7'd123);
            7'd124: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd124) >> 1)) / midi_period_q16(7'd124);
            7'd125: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd125) >> 1)) / midi_period_q16(7'd125);
            7'd126: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd126) >> 1)) / midi_period_q16(7'd126);
            7'd127: excitation_step_q16 = (64'd4294967296 + (midi_period_q16(7'd127) >> 1)) / midi_period_q16(7'd127);
            default: excitation_step_q16 = 16'd0;
            endcase
        end
    endfunction


    assign w_pick_length_product = r_delay_length_stage2 * PLUCK_POSITION_Q8;
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
    assign w_radiation_dc_error = $signed({w_body_sample[15], w_body_sample, 8'd0}) -
        $signed({r_radiation_dc_q8[23], r_radiation_dc_q8});
    assign w_radiation_dc_next = $signed(r_radiation_dc_q8) + (w_radiation_dc_error >>> 8);
    assign w_radiation_ac = $signed(w_body_sample) - $signed(r_radiation_dc_q8[23:8]);
    assign w_period_q16 = midi_period_q16(i_midi_note);
    assign w_delay_period_q16 = r_note_period_stage1 - 32'd32768;
    // 第二偏振的周期增加 1/1024，频率约低 1.69 cent。
    // 两个环都补偿两点平均滤波的 0.5 样本群延迟。
    assign w_secondary_delay_period_q16 = r_note_period_stage1 +
        (r_note_period_stage1 >> 10) - 32'd32768;
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
    assign w_average = {r_delay_sample[15], r_delay_sample} +
        {r_previous_sample[15], r_previous_sample};
    // 逐音区环损耗：低音每圈损耗稍大，高音每秒往返多，减少损耗维持尾音。
    // 7/256..2/256为工程初值，需真实尼龙弦录音拟合T60；不能称为实测参数。
    assign w_loss_q8 = i_midi_note <= 60 ? 4'd7 : i_midi_note <= 64 ? 4'd5 :
        i_midi_note <= 69 ? 4'd4 : i_midi_note <= 76 ? 4'd3 : 4'd2;
    assign w_loss_product = w_average * $signed({1'b0, w_loss_q8});
    assign w_interpolation_difference = $signed(r_previous_filtered) - $signed(r_filtered_precomputed);
    assign w_interpolation_product = w_interpolation_difference *
        $signed({1'b0, r_delay_fraction_stage2});
    // 0<=fraction<1：线性插值是凸组合，不会扩大被动反馈增益。
    assign w_feedback_extended = $signed(r_filtered_precomputed) + $signed(w_interpolation_product[25:8]);
    assign w_feedback_sample = saturate_pcm(w_feedback_extended);
    assign w_secondary_average = $signed({r_secondary_delay_sample[15], r_secondary_delay_sample}) +
        $signed({r_secondary_previous_sample[15], r_secondary_previous_sample});
    assign w_secondary_loss_product = w_secondary_average * $signed({1'b0, w_loss_q8});
    assign w_secondary_interpolation_difference = $signed(r_secondary_previous_filtered) -
        $signed(r_secondary_filtered_precomputed);
    assign w_secondary_interpolation_product = w_secondary_interpolation_difference *
        $signed({1'b0, r_secondary_fraction_stage2});
    assign w_secondary_feedback_extended = $signed(r_secondary_filtered_precomputed) +
        $signed(w_secondary_interpolation_product[25:8]);
    assign w_secondary_feedback_sample = saturate_pcm(w_secondary_feedback_extended);
    // 对称的 1/64 凸组合耦合，只交换能量，不加入主动增益。
    // 差值移位向零舍入，避免两环同时受算术右移的负偏置影响。
    assign w_coupling_difference = $signed(w_secondary_feedback_sample) - $signed(w_feedback_sample);
    assign w_coupling_step = !r_active || r_excitation_remaining != 0 ||
        r_secondary_excitation_remaining != 0 ? 18'sd0 : w_coupling_difference < 0 ?
        -((-w_coupling_difference) >>> 6) : (w_coupling_difference >>> 6);
    assign w_primary_coupled_extended = $signed(w_feedback_sample) +
        (ENABLE_DUAL_POLARIZATION != 0 ? w_coupling_step : 18'sd0);
    assign w_secondary_coupled_extended = $signed(w_secondary_feedback_sample) - w_coupling_step;
    assign w_primary_coupled_sample = saturate_pcm(w_primary_coupled_extended);
    assign w_secondary_coupled_sample = saturate_pcm(w_secondary_coupled_extended);
    // 力度只需 9 位正 signed 数；不扩大成无用的 17 位乘法操作数。
    assign w_velocity_positive = $signed({1'b0, i_velocity});
    assign w_noise_product = $signed(r_lfsr) * w_velocity_positive;
    assign w_initial_noise_product = -16'sd21535 * w_velocity_positive;
    // 有限三角位移以小比例、可复现的噪声模拟指腹/指甲释放；力度低通使角点圆钝。
    // 系数均为工程初值，未宣称从真实尼龙弦录音拟合。
    assign w_triangle_sample = r_excitation_phase_q16[15] ?
        17'sd32767 - $signed({1'b0, r_excitation_phase_q16[14:0], 1'b0}) :
        -17'sd32768 + $signed({1'b0, r_excitation_phase_q16[14:0], 1'b0});
    assign w_excitation_shape = ($signed(w_triangle_sample) <<< 3) -
        $signed(w_triangle_sample) + $signed(r_lfsr);
    assign w_physical_excitation_product = w_excitation_shape * w_velocity_positive;
    // 凸组合低通仅塑造起音，不放在循环反馈内，避免改变标定音高。
    assign w_velocity_times_three = {2'b0, i_velocity} + {1'b0, i_velocity, 1'b0};
    assign w_excitation_alpha_q8 = 8'd32 + w_velocity_times_three[9:3];
    assign w_excitation_error = $signed(r_noise_sample_precomputed) - $signed(r_excitation_lowpass);
    assign w_excitation_step_product = w_excitation_error * $signed({1'b0, w_excitation_alpha_q8});
    assign w_initial_excitation_product = r_initial_noise_precomputed * $signed({1'b0, w_excitation_alpha_q8});
    assign w_primary_raw_sample = i_trigger ? (ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed) :
        r_excitation_remaining != 0 ? r_pick_precomputed : r_delay_sample;
    assign w_secondary_raw_sample = i_trigger ? (ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed) :
        r_secondary_excitation_remaining != 0 ? r_pick_precomputed : r_secondary_delay_sample;
    assign w_polarization_mix = $signed(w_primary_raw_sample) +
        ((($signed(w_secondary_raw_sample) - $signed(w_primary_raw_sample))) >>> 2);
    assign w_output_raw = ENABLE_DUAL_POLARIZATION != 0 ?
        saturate_pcm(w_polarization_mix) : w_primary_raw_sample;
    assign w_dc_error_q8 = $signed({w_output_raw[15], w_output_raw, 8'd0}) -
        $signed({r_dc_estimate_q8[23], r_dc_estimate_q8});
    assign w_dc_next_q8 = $signed({r_dc_estimate_q8[23], r_dc_estimate_q8}) +
        (w_dc_error_q8 >>> 8);
    assign w_ac_extended = $signed(w_output_raw) - $signed(r_dc_estimate_q8[23:8]);
    assign w_delay_read_address = r_delay_index[DELAY_ADDRESS_WIDTH-1:0];
    assign w_secondary_read_address = r_secondary_delay_index[DELAY_ADDRESS_WIDTH-1:0];

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_noise_sample_precomputed <= 0;
            r_initial_noise_precomputed <= 0;
            r_filtered_precomputed <= 0;
            r_secondary_filtered_precomputed <= 0;
            r_excitation_filtered_precomputed <= 0;
            r_initial_excitation_precomputed <= 0;
            r_body_input_sample <= 0;
        end
        else
        begin
            // 主偏振沿用两阶段被动损耗；次偏振每次往返损耗更小。
            // 此处不增加反馈低通极点，因此 0.5 样本的调谐补偿仍成立。
            r_filtered_precomputed <= (w_average >>> 1) -
                (EXTENDED_DECAY == 0 ? (w_loss_product >>> 9) :
                 r_decay_age[12] ? (w_loss_product >>> 11) : (w_loss_product >>> 10));
            r_secondary_filtered_precomputed <= (w_secondary_average >>> 1) -
                (EXTENDED_DECAY == 0 ? (w_secondary_loss_product >>> 10) :
                 r_decay_age[12] ? (w_secondary_loss_product >>> 12) : (w_secondary_loss_product >>> 11));
            // 三角激励的能量集中于基频；再预留 6dB，让四弦相干叠加仍有余量。
            r_noise_sample_precomputed <= ENABLE_PHYSICAL_EXCITATION != 0 ?
                (w_physical_excitation_product >>> 12) : $signed(w_noise_product[23:8]);
            r_initial_noise_precomputed <= ENABLE_PHYSICAL_EXCITATION != 0 ?
                ((-25'sd31364 * w_velocity_positive) >>> 9) : $signed(w_initial_noise_product[23:8]);
            r_excitation_filtered_precomputed <= $signed(r_excitation_lowpass) + (w_excitation_step_product >>> 8);
            r_initial_excitation_precomputed <= w_initial_excitation_product >>> 8;
            r_body_input_sample <= saturate_pcm(w_ac_extended);
        end
    end

    // 音高预计算为两级；集成琴体与控制流水由 core 提供12clk稳定期。
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_note_period_stage1 <= 32'd524288;
            r_delay_length_stage2 <= 16'd8;
            r_delay_fraction_stage2 <= 8'd0;
            r_secondary_length_stage2 <= 16'd8;
            r_secondary_fraction_stage2 <= 8'd0;
            r_excitation_step_stage2 <= 16'd8192;
        end
        else
        begin
            r_note_period_stage1 <= w_period_q16;
            r_delay_length_stage2 <= w_requested_period;
            r_delay_fraction_stage2 <= w_fraction_q8;
            r_secondary_length_stage2 <= w_secondary_requested_period;
            r_secondary_fraction_stage2 <= w_secondary_fraction_q8;
            r_excitation_step_stage2 <= excitation_step_q16(i_midi_note);
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
                    w_delay_write_address = 0;
                    w_delay_write_sample = ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed;
                end
                else if (r_active)
                begin
                    w_delay_write_enable = 1'b1;
                    w_delay_write_sample = r_excitation_remaining != 0 ?
                        r_pick_precomputed : w_primary_coupled_sample;
                end
            end
        end
    end

    always @(posedge i_clk)
        if (w_delay_write_enable)
            r_delay_line[w_delay_write_address] <= w_delay_write_sample;

    always @(posedge i_clk)
        r_delay_sample <= r_delay_line[w_delay_read_address];

    // 独立 RAM 单写端口。每次重拨从地址 0 覆盖次偏振的完整有效周期；
    // 填充期间只输出新激励，旧音内容既不输出，也不参与反馈耦合。
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
                    w_secondary_write_address = 0;
                    w_secondary_write_sample = ENABLE_PICK_COMB != 0 ?
                        (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed;
                end
                else if (r_active)
                begin
                    w_secondary_write_enable = 1'b1;
                    w_secondary_write_sample = r_secondary_excitation_remaining != 0 ?
                        r_pick_precomputed : w_secondary_coupled_sample;
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
            r_secondary_previous_filtered <= 17'sd0;
            r_lfsr <= 16'hace1;
            r_previous_sample <= 16'sd0;
            r_previous_filtered <= 17'sd0;
            r_excitation_lowpass <= 16'sd0;
            r_dc_estimate_q8 <= 24'sd0;
            r_radiation_dc_q8 <= 24'sd0;
            r_active <= 1'b0;
            r_decay_age <= 0;
            r_pick_index <= 0;
            r_pick_length <= 1;
            r_excitation_age <= 0;
            r_excitation_phase_q16 <= 0;
            r_memory_init_index <= 16'd0;
            r_memory_ready <= 1'b0;
            o_audio_sample <= 0;
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
            if (i_trigger)
            begin
                r_decay_age <= 0;
                o_audio_sample <= ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed;
                r_pick_length <= w_pick_length_product[23:8] < 2 ? 2 :
                    w_pick_length_product[23:8] > PICK_DEPTH ? PICK_DEPTH : w_pick_length_product[23:8];
                r_pick_index <= 1;
                r_excitation_age <= 1;
                r_previous_sample <= ENABLE_PICK_COMB != 0 ? (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed;
                r_previous_filtered <= 17'sd0;
                r_secondary_previous_sample <= ENABLE_PICK_COMB != 0 ?
                    (r_initial_excitation_precomputed >>> 1) : r_initial_excitation_precomputed;
                r_secondary_previous_filtered <= 17'sd0;
                r_excitation_lowpass <= r_initial_excitation_precomputed;
                r_dc_estimate_q8 <= 24'sd0;
                r_radiation_dc_q8 <= 24'sd0;
                r_delay_index <= 16'd1;
                r_excitation_remaining <= r_delay_length_stage2 - 16'd1;
                r_secondary_delay_index <= 16'd1;
                r_secondary_excitation_remaining <= r_secondary_length_stage2 - 16'd1;
                r_excitation_phase_q16 <= r_excitation_step_stage2;
                r_lfsr <= 16'h59c3;
                r_active <= 1'b1;
            end
            else if (r_active)
            begin
                if (!r_decay_age[12]) r_decay_age <= r_decay_age + 1'b1;
                o_audio_sample <= saturate_pcm(w_radiation_ac);
                r_radiation_dc_q8 <= w_radiation_dc_next[23:0];
                r_dc_estimate_q8 <= w_dc_next_q8[23:0];
                if (r_excitation_remaining != 0)
                begin
                    r_excitation_remaining <= r_excitation_remaining - 16'd1;
                    r_previous_sample <= r_pick_precomputed;
                    r_excitation_age <= r_excitation_age + 1'b1;
                    r_pick_index <= r_pick_index + 1 >= r_pick_length ? 0 : r_pick_index + 1'b1;
                    r_excitation_lowpass <= r_excitation_filtered_precomputed[15:0];
                    r_previous_filtered <= 17'sd0;
                    r_excitation_phase_q16 <= r_excitation_phase_q16 + r_excitation_step_stage2;
                end
                else
                begin
                    r_previous_sample <= r_delay_sample;
                    r_previous_filtered <= r_filtered_precomputed;
                end
                if (r_secondary_excitation_remaining != 0)
                begin
                    r_secondary_excitation_remaining <= r_secondary_excitation_remaining - 16'd1;
                    r_secondary_previous_sample <= r_pick_precomputed;
                    r_secondary_previous_filtered <= 17'sd0;
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
