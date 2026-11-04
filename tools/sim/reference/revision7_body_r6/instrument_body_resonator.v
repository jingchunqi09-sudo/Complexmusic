// Six-mode body radiation filter, outside the string feedback loop.
// Independently written shift/add state-space realization. The modal-bank
// organization is informed by STK, Rings and Maestre et al. (2017); no source
// code or measured instrument coefficients from those projects are copied.
//
// All presets are ENGINEERING VALUES for Fs=48828.125 Hz, not a measured
// violin/ukulele fit. This is one-way radiation, not passive bridge coupling.
// Each mode uses v'=(1-d)v+k(x-p), p'=p+v'. Radiation uses the velocity
// component with an approximate d/k gain, giving a near-unit resonance peak.
// Six velocity responses plus a half-amplitude dry path shape the spectrum.
// States are signed Q21.8 (30 bits), protected against wraparound. All
// constants use shifts/adds; the filter requires no multiplication DSPs.
//
// Inputs and audio state must settle for at least FIVE system clocks before
// i_sample_tick. The sample period in this design is 1024 system clocks.
// Shadow arithmetic runs continuously; sample_tick alone commits states.
// There is no ready signal and the body cannot stall the audio engine.
module instrument_body_resonator #(
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer PRESERVE_BYPASS_STATE = 0
) (
    input i_clk,
    input i_reset,
    input i_sample_tick,
    input i_trigger,
    input i_bypass,
    input i_instrument,             // 0: violin, 1: ukulele
    input signed [SAMPLE_WIDTH-1:0] i_sample,
    output reg signed [SAMPLE_WIDTH-1:0] o_sample,
    output reg [15:0] o_guard_count, // saturating count of guarded samples
    output reg [15:0] o_clip_count   // saturating count of output clips
);
    localparam integer STATE_WIDTH = SAMPLE_WIDTH+14;
    localparam integer WORK_WIDTH = STATE_WIDTH+2;
    localparam signed [WORK_WIDTH-1:0] STATE_MAX = (64'sd1 << (STATE_WIDTH-1))-1;
    localparam signed [WORK_WIDTH-1:0] STATE_MIN = -(64'sd1 << (STATE_WIDTH-1));
    localparam signed [WORK_WIDTH-1:0] PCM_MAX = (64'sd1 << (SAMPLE_WIDTH-1))-1;
    localparam signed [WORK_WIDTH-1:0] PCM_MIN = -(64'sd1 << (SAMPLE_WIDTH-1));
    reg signed [STATE_WIDTH-1:0] r_position_q8 [0:5];
    reg signed [STATE_WIDTH-1:0] r_velocity_q8 [0:5];
    reg signed [SAMPLE_WIDTH+8:0] r_dc_q8;
    wire signed [SAMPLE_WIDTH+8:0] w_input_q8;
    assign w_input_q8 = {i_sample[SAMPLE_WIDTH-1], i_sample, 8'd0};
    wire signed [SAMPLE_WIDTH+9:0] w_dc_error;
    assign w_dc_error = $signed(w_input_q8) - $signed(r_dc_q8);
    wire signed [WORK_WIDTH-1:0] w_drive_q8;
    assign w_drive_q8 = $signed(w_dc_error);

    reg signed [WORK_WIDTH-1:0] r_error_q8 [0:5];
    reg signed [WORK_WIDTH-1:0] r_spring_q8 [0:5];
    reg signed [WORK_WIDTH-1:0] r_velocity_next [0:5];
    reg signed [WORK_WIDTH-1:0] r_position_next [0:5];
    reg signed [WORK_WIDTH+1:0] r_radiation_pair [0:2];
    reg signed [WORK_WIDTH-1:0] r_output_next;
    integer mode;
    integer state_index;
    reg w_guard;

    function signed [WORK_WIDTH-1:0] spring;
        input integer index;
        input instrument;
        input signed [WORK_WIDTH-1:0] value;
        begin
            if (!instrument)
                case (index)
                    0: spring = (value >>> 10) + (value >>> 12);
                    1: spring = value >>> 8;
                    2: spring = (value >>> 8) + (value >>> 10) + (value >>> 11);
                    3: spring = (value >>> 7) + (value >>> 8) + (value >>> 9);
                    4: spring = (value >>> 5) + (value >>> 6);
                    default: spring = value >>> 3;
                endcase
            else
                case (index)
                    0: spring = (value >>> 9) + (value >>> 12);
                    1: spring = (value >>> 8) + (value >>> 9);
                    2: spring = (value >>> 7) + (value >>> 8) + (value >>> 9);
                    3: spring = value >>> 5;
                    4: spring = (value >>> 4) + (value >>> 6);
                    default: spring = (value >>> 3) + (value >>> 4);
                endcase
        end
    endfunction

    function signed [WORK_WIDTH-1:0] damping;
        input integer index;
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
        input integer index;
        input instrument;
        input signed [WORK_WIDTH-1:0] value;
        reg signed [WORK_WIDTH+1:0] extended;
        begin
            extended = {{2{value[WORK_WIDTH-1]}}, value};
            if (!instrument)
                case (index)
                    0: radiation = extended + (extended >>> 1);
                    1: radiation = extended;
                    2: radiation = (extended >>> 1) + (extended >>> 2);
                    3: radiation = extended >>> 1;
                    4: radiation = (extended >>> 2) + (extended >>> 4);
                    default: radiation = extended >>> 2;
                endcase
            else
                case (index)
                    0: radiation = extended + (extended >>> 1) + (extended >>> 2);
                    1: radiation = extended + (extended >>> 2);
                    2: radiation = extended;
                    3: radiation = extended >>> 1;
                    4: radiation = (extended >>> 2) + (extended >>> 3);
                    default: radiation = (extended >>> 2) + (extended >>> 4);
                endcase
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

    // Five clock stages: error, stiffness, velocity, position/pair, mix.
    // The 34-bit radiation accumulator prevents six-mode addition wrapping.
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            for (mode = 0; mode < 6; mode = mode + 1)
            begin
                r_error_q8[mode] <= 0;
                r_spring_q8[mode] <= 0;
                r_velocity_next[mode] <= 0;
                r_position_next[mode] <= 0;
            end
            r_radiation_pair[0] <= 0;
            r_radiation_pair[1] <= 0;
            r_radiation_pair[2] <= 0;
            r_output_next <= 0;
        end
        else
        begin
            for (mode = 0; mode < 6; mode = mode + 1)
            begin
                r_error_q8[mode] <= w_drive_q8 - $signed(r_position_q8[mode]);
                r_spring_q8[mode] <= spring(mode, i_instrument, r_error_q8[mode]);
                r_velocity_next[mode] <= $signed(r_velocity_q8[mode]) -
                    damping(mode, i_instrument, r_velocity_q8[mode]) + r_spring_q8[mode];
                r_position_next[mode] <= $signed(r_position_q8[mode]) + r_velocity_next[mode];
            end
            r_radiation_pair[0] <= radiation(0, i_instrument, r_velocity_next[0]) +
                radiation(1, i_instrument, r_velocity_next[1]);
            r_radiation_pair[1] <= radiation(2, i_instrument, r_velocity_next[2]) +
                radiation(3, i_instrument, r_velocity_next[3]);
            r_radiation_pair[2] <= radiation(4, i_instrument, r_velocity_next[4]) +
                radiation(5, i_instrument, r_velocity_next[5]);
            r_output_next <= (w_drive_q8 >>> 9) +
                (($signed(r_radiation_pair[0]) + $signed(r_radiation_pair[1]) +
                  $signed(r_radiation_pair[2])) >>> 9);
        end
    end

    always @(*)
    begin
        w_guard = 0;
        for (state_index = 0; state_index < 6; state_index = state_index + 1)
            if (r_position_next[state_index] > STATE_MAX ||
                r_position_next[state_index] < STATE_MIN ||
                r_velocity_next[state_index] > STATE_MAX ||
                r_velocity_next[state_index] < STATE_MIN)
                w_guard = 1;
    end

    integer commit_index;
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            for (commit_index = 0; commit_index < 6; commit_index = commit_index + 1)
            begin
                r_position_q8[commit_index] <= 0;
                r_velocity_q8[commit_index] <= 0;
            end
            r_dc_q8 <= 0;
            o_sample <= 0;
            o_guard_count <= 0;
            o_clip_count <= 0;
        end
        else if (i_sample_tick)
        begin
            if (i_trigger || (i_bypass && PRESERVE_BYPASS_STATE == 0))
            begin
                for (commit_index = 0; commit_index < 6; commit_index = commit_index + 1)
                begin
                    r_position_q8[commit_index] <= 0;
                    r_velocity_q8[commit_index] <= 0;
                end
                r_dc_q8 <= 0;
                o_sample <= i_bypass ? i_sample : {SAMPLE_WIDTH{1'b0}};
            end
            else
            begin
                for (commit_index = 0; commit_index < 6; commit_index = commit_index + 1)
                begin
                    r_position_q8[commit_index] <= bound_state(r_position_next[commit_index]);
                    r_velocity_q8[commit_index] <= bound_state(r_velocity_next[commit_index]);
                end
                r_dc_q8 <= $signed(r_dc_q8) + (w_dc_error >>> 8);
                o_sample <= i_bypass ? i_sample : bound_pcm(r_output_next);
                if (w_guard && o_guard_count != 16'hffff)
                    o_guard_count <= o_guard_count + 1'b1;
                if ((r_output_next > PCM_MAX || r_output_next < PCM_MIN) &&
                    o_clip_count != 16'hffff)
                    o_clip_count <= o_clip_count + 1'b1;
            end
        end
    end
endmodule
