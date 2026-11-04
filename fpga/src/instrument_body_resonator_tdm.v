// Two independent public radiation bodies, sharing one shift/add datapath.
// Mathematical reference: instrument_body_resonator.v (no DSP multipliers).
// Six modes per body keep the reference Q format, per-mode rounding, state
// saturation, modulo radiation sum and per-sample guard/clip accounting.
// Inputs are captured on i_start && o_ready. Both outputs are valid 78 clocks
// later; i_start while busy is ignored. Synchronous reset aborts an in-flight
// sample and clears all state/counters, including for an emergency reset.
module instrument_body_resonator_tdm #(
    parameter integer SAMPLE_WIDTH = 18,
    parameter integer PRESERVE_BYPASS_STATE = 1,
    parameter integer BODY0_VIOLIN_RADIATION_MIX = 2,
    parameter integer BODY1_VIOLIN_RADIATION_MIX = 0
) (
    input i_clk,
    input i_reset,
    input i_start,
    input [1:0] i_trigger,
    input [1:0] i_bypass,
    input [1:0] i_instrument,
    input [2*SAMPLE_WIDTH-1:0] i_sample_bus,
    output [2*SAMPLE_WIDTH-1:0] o_sample_bus,
    output [31:0] o_guard_count,
    output [31:0] o_clip_count,
    output reg o_valid,
    output o_ready
);
    localparam integer STATE_WIDTH = SAMPLE_WIDTH + 14;
    localparam integer WORK_WIDTH = STATE_WIDTH + 2;
    localparam signed [WORK_WIDTH-1:0] STATE_MAX = (64'sd1 << (STATE_WIDTH-1))-1;
    localparam signed [WORK_WIDTH-1:0] STATE_MIN = -(64'sd1 << (STATE_WIDTH-1));
    localparam signed [WORK_WIDTH-1:0] PCM_MAX = (64'sd1 << (SAMPLE_WIDTH-1))-1;
    localparam signed [WORK_WIDTH-1:0] PCM_MIN = -(64'sd1 << (SAMPLE_WIDTH-1));
    localparam [3:0] IDLE = 0, BANK_PREP = 1, MODE_READ = 2,
        MODE_ERROR = 3, MODE_SPRING = 4, MODE_VELOCITY = 5,
        MODE_POSITION = 6, MODE_COMMIT = 7, BANK_MIX = 8, BANK_OUTPUT = 9;

    reg [3:0] r_phase;
    reg r_bank;
    reg [2:0] r_mode;
    reg [3:0] r_state_index;
    reg [2*SAMPLE_WIDTH-1:0] r_samples;
    reg [1:0] r_trigger, r_bypass, r_instrument;
    reg r_clear, r_guard;
    reg [11:0] r_state_valid;
    reg signed [STATE_WIDTH-1:0] r_position_q8 [0:11];
    reg signed [STATE_WIDTH-1:0] r_velocity_q8 [0:11];
    reg signed [SAMPLE_WIDTH+8:0] r_dc_q8 [0:1];
    reg signed [SAMPLE_WIDTH-1:0] r_sample [0:1];
    reg [15:0] r_guard_count [0:1];
    reg [15:0] r_clip_count [0:1];
    reg signed [STATE_WIDTH-1:0] r_position, r_velocity;
    wire signed [STATE_WIDTH-1:0] w_position, w_velocity;
    reg signed [WORK_WIDTH-1:0] r_drive, r_error, r_spring;
    reg signed [WORK_WIDTH-1:0] r_velocity_next, r_position_next;
    reg signed [WORK_WIDTH+1:0] r_radiation, r_radiation_sum;
    reg signed [WORK_WIDTH-1:0] r_output;
    wire signed [SAMPLE_WIDTH-1:0] w_sample;
    wire signed [SAMPLE_WIDTH+8:0] w_input_q8;
    wire signed [SAMPLE_WIDTH+9:0] w_dc_error;
    wire w_instrument;
    wire w_clear;
    wire w_dry_quarter, w_radiation_full;
    wire signed [WORK_WIDTH-1:0] w_dry;
    wire signed [WORK_WIDTH+1:0] w_modal;
    assign w_sample = r_bank ? r_samples[2*SAMPLE_WIDTH-1:SAMPLE_WIDTH] : r_samples[SAMPLE_WIDTH-1:0];
    assign w_input_q8 = {w_sample[SAMPLE_WIDTH-1], w_sample, 8'd0};
    assign w_dc_error = $signed(w_input_q8) - $signed(r_dc_q8[r_bank]);
    assign w_instrument = r_instrument[r_bank];
    assign w_clear = r_trigger[r_bank] || (r_bypass[r_bank] && PRESERVE_BYPASS_STATE == 0);
    assign w_dry_quarter = !w_instrument && (r_bank ? BODY1_VIOLIN_RADIATION_MIX != 0 : BODY0_VIOLIN_RADIATION_MIX != 0);
    assign w_radiation_full = !w_instrument && (r_bank ? BODY1_VIOLIN_RADIATION_MIX == 2 : BODY0_VIOLIN_RADIATION_MIX == 2);
    assign w_dry = w_dry_quarter ? (r_drive >>> 10) : (r_drive >>> 9);
    assign w_modal = w_radiation_full ? (r_radiation_sum >>> 8) : (r_radiation_sum >>> 9);
    assign o_sample_bus = {r_sample[1], r_sample[0]};
    assign o_guard_count = {r_guard_count[1], r_guard_count[0]};
    assign o_clip_count = {r_clip_count[1], r_clip_count[0]};
    assign o_ready = r_phase == IDLE;
    assign w_position = r_state_valid[r_state_index] ? r_position : {STATE_WIDTH{1'b0}};
    assign w_velocity = r_state_valid[r_state_index] ? r_velocity : {STATE_WIDTH{1'b0}};

    function signed [WORK_WIDTH-1:0] spring;
        input [2:0] index;
        input instrument;
        input signed [WORK_WIDTH-1:0] value;
        reg signed [WORK_WIDTH-1:0] term0, term1, term2;
        begin
            if (!instrument)
                case (index)
                    0: begin term0 = (value >>> 10); term1 = (value >>> 12); term2 = 0; end
                    1: begin term0 = value >>> 8; term1 = 0; term2 = 0; end
                    2: begin term0 = (value >>> 8); term1 = (value >>> 10); term2 = (value >>> 11); end
                    3: begin term0 = (value >>> 7); term1 = (value >>> 8); term2 = (value >>> 9); end
                    4: begin term0 = (value >>> 5); term1 = (value >>> 6); term2 = 0; end
                    default: begin term0 = value >>> 3; term1 = 0; term2 = 0; end
                endcase
            else
                case (index)
                    0: begin term0 = (value >>> 9); term1 = (value >>> 12); term2 = 0; end
                    1: begin term0 = (value >>> 8); term1 = (value >>> 9); term2 = 0; end
                    2: begin term0 = (value >>> 7); term1 = (value >>> 8); term2 = (value >>> 9); end
                    3: begin term0 = value >>> 5; term1 = 0; term2 = 0; end
                    4: begin term0 = (value >>> 4); term1 = (value >>> 6); term2 = 0; end
                    default: begin term0 = (value >>> 3); term1 = (value >>> 4); term2 = 0; end
                endcase
            // Select already shifted terms, then share one addition network.
            // Each arithmetic shift retains its original rounding independently.
            spring = term0 + term1 + term2;
        end
    endfunction

    function signed [WORK_WIDTH-1:0] damping;
        input [2:0] index;
        input instrument;
        input signed [STATE_WIDTH-1:0] value;
        begin
            if (!instrument)
                case (index)
                    0: damping = value >>> 9;
                    1, 2: damping = value >>> 8;
                    3: damping = value >>> 7;
                    4: damping = value >>> 6;
                    default: damping = value >>> 5;
                endcase
            else
                case (index)
                    0: damping = value >>> 8;
                    1: damping = value >>> 7;
                    2, 3: damping = value >>> 6;
                    4: damping = value >>> 5;
                    default: damping = value >>> 4;
                endcase
        end
    endfunction

    function signed [WORK_WIDTH+1:0] radiation;
        input [2:0] index;
        input instrument;
        input signed [WORK_WIDTH-1:0] value;
        reg signed [WORK_WIDTH+1:0] extended;
        reg signed [WORK_WIDTH+1:0] term0, term1, term2;
        begin
            extended = {{2{value[WORK_WIDTH-1]}}, value};
            if (!instrument)
                case (index)
                    0: begin term0 = extended; term1 = (extended >>> 1); term2 = 0; end
                    1: begin term0 = extended; term1 = 0; term2 = 0; end
                    2: begin term0 = (extended >>> 1); term1 = (extended >>> 2); term2 = 0; end
                    3: begin term0 = extended >>> 1; term1 = 0; term2 = 0; end
                    4: begin term0 = (extended >>> 2); term1 = (extended >>> 4); term2 = 0; end
                    default: begin term0 = extended >>> 2; term1 = 0; term2 = 0; end
                endcase
            else
                case (index)
                    0: begin term0 = extended; term1 = (extended >>> 1); term2 = (extended >>> 2); end
                    1: begin term0 = extended; term1 = (extended >>> 2); term2 = 0; end
                    2: begin term0 = extended; term1 = 0; term2 = 0; end
                    3: begin term0 = extended >>> 1; term1 = 0; term2 = 0; end
                    4: begin term0 = (extended >>> 2); term1 = (extended >>> 3); term2 = 0; end
                    default: begin term0 = (extended >>> 2); term1 = (extended >>> 4); term2 = 0; end
                endcase
            // Select already shifted terms, then share one addition network.
            // Each arithmetic shift retains its original rounding independently.
            radiation = term0 + term1 + term2;
        end
    endfunction

    function signed [STATE_WIDTH-1:0] bound_state;
        input signed [WORK_WIDTH-1:0] value;
        begin
            if (value > STATE_MAX) bound_state = STATE_MAX[STATE_WIDTH-1:0];
            else if (value < STATE_MIN) bound_state = STATE_MIN[STATE_WIDTH-1:0];
            else bound_state = value[STATE_WIDTH-1:0];
        end
    endfunction

    function signed [SAMPLE_WIDTH-1:0] bound_pcm;
        input signed [WORK_WIDTH-1:0] value;
        begin
            if (value > PCM_MAX) bound_pcm = PCM_MAX[SAMPLE_WIDTH-1:0];
            else if (value < PCM_MIN) bound_pcm = PCM_MIN[SAMPLE_WIDTH-1:0];
            else bound_pcm = value[SAMPLE_WIDTH-1:0];
        end
    endfunction

    // RAM bits need no reset. A reset-invalid entry reads mathematically as
    // zero; the first commit writes its bounded value before setting valid.
    always @(posedge i_clk)
    begin
        // Explicit write-through infers GW5AT's supported WRITE_MODE=01.
        // READ_BEFORE_WRITE (10) is rejected by this device's PNR flow.
        // The FSM consumes read registers only after MODE_READ.
        if (!i_reset && r_phase == MODE_COMMIT)
        begin
            r_position_q8[r_state_index] <= r_clear ? 0 : bound_state(r_position_next);
            r_velocity_q8[r_state_index] <= r_clear ? 0 : bound_state(r_velocity_next);
            r_position <= r_clear ? 0 : bound_state(r_position_next);
            r_velocity <= r_clear ? 0 : bound_state(r_velocity_next);
        end
        else
        begin
            r_position <= r_position_q8[r_state_index];
            r_velocity <= r_velocity_q8[r_state_index];
        end
    end

    integer reset_index;
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_phase <= IDLE;
            r_bank <= 0;
            r_mode <= 0;
            r_state_index <= 0;
            r_samples <= 0;
            r_trigger <= 0;
            r_bypass <= 0;
            r_instrument <= 0;
            r_clear <= 0;
            r_guard <= 0;
            r_drive <= 0;
            r_error <= 0;
            r_spring <= 0;
            r_velocity_next <= 0;
            r_position_next <= 0;
            r_radiation <= 0;
            r_radiation_sum <= 0;
            r_output <= 0;
            o_valid <= 0;
            r_state_valid <= 0;
            for (reset_index = 0; reset_index < 2; reset_index = reset_index + 1)
            begin
                r_dc_q8[reset_index] <= 0;
                r_sample[reset_index] <= 0;
                r_guard_count[reset_index] <= 0;
                r_clip_count[reset_index] <= 0;
            end
        end
        else
        begin
            o_valid <= 0;
            case (r_phase)
                IDLE:
                begin
                    if (i_start)
                    begin
                        r_samples <= i_sample_bus;
                        r_trigger <= i_trigger;
                        r_bypass <= i_bypass;
                        r_instrument <= i_instrument;
                        r_bank <= 0;
                        r_mode <= 0;
                        r_state_index <= 0;
                        r_phase <= BANK_PREP;
                    end
                end
                BANK_PREP:
                begin
                    r_drive <= $signed(w_dc_error);
                    r_dc_q8[r_bank] <= w_clear ? 0 : $signed(r_dc_q8[r_bank]) + (w_dc_error >>> 8);
                    r_clear <= w_clear;
                    r_guard <= 0;
                    r_radiation_sum <= 0;
                    r_phase <= MODE_READ;
                end
                MODE_READ:
                begin
                    r_phase <= MODE_ERROR;
                end
                MODE_ERROR:
                begin
                    r_error <= r_drive - $signed(w_position);
                    r_phase <= MODE_SPRING;
                end
                MODE_SPRING:
                begin
                    r_spring <= spring(r_mode, w_instrument, r_error);
                    r_phase <= MODE_VELOCITY;
                end
                MODE_VELOCITY:
                begin
                    r_velocity_next <= $signed(w_velocity) - damping(r_mode, w_instrument, w_velocity) + r_spring;
                    r_phase <= MODE_POSITION;
                end
                MODE_POSITION:
                begin
                    r_position_next <= $signed(w_position) + r_velocity_next;
                    r_radiation <= radiation(r_mode, w_instrument, r_velocity_next);
                    r_phase <= MODE_COMMIT;
                end
                MODE_COMMIT:
                begin
                    r_state_valid[r_state_index] <= 1'b1;
                    r_radiation_sum <= r_radiation_sum + r_radiation;
                    if (r_position_next > STATE_MAX || r_position_next < STATE_MIN ||
                        r_velocity_next > STATE_MAX || r_velocity_next < STATE_MIN)
                        r_guard <= 1;
                    r_state_index <= r_state_index + 1'b1;
                    if (r_mode == 5)
                        r_phase <= BANK_MIX;
                    else
                    begin
                        r_mode <= r_mode + 1'b1;
                        r_phase <= MODE_READ;
                    end
                end
                BANK_MIX:
                begin
                    r_output <= $signed(w_dry) + $signed(w_modal);
                    r_phase <= BANK_OUTPUT;
                end
                BANK_OUTPUT:
                begin
                    r_sample[r_bank] <= r_bypass[r_bank] ? w_sample : (r_clear ? 0 : bound_pcm(r_output));
                    if (!r_clear)
                    begin
                        if (r_guard && r_guard_count[r_bank] != 16'hffff)
                            r_guard_count[r_bank] <= r_guard_count[r_bank] + 1'b1;
                        if ((r_output > PCM_MAX || r_output < PCM_MIN) && r_clip_count[r_bank] != 16'hffff)
                            r_clip_count[r_bank] <= r_clip_count[r_bank] + 1'b1;
                    end
                    if (r_bank)
                    begin
                        o_valid <= 1;
                        r_phase <= IDLE;
                    end
                    else
                    begin
                        r_bank <= 1;
                        r_mode <= 0;
                        r_phase <= BANK_PREP;
                    end
                end
                default: r_phase <= IDLE;
            endcase
        end
    end
endmodule
