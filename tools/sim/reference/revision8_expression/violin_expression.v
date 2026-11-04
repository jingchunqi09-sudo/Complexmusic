// Deterministic, independently controlled period-domain glide and triangular vibrato.
// Coefficients are engineering controls; no measured-instrument fit is claimed.
// Shift/add modulation avoids four additional variable-width DSP multipliers.
// Glide transaction: tick captures a difference, tick+1 prepares the step,
// tick+2 commits the period. Ticks must be separated by at least three clocks.
// The continuously updated vibrato/output path settles by tick+6; consumers
// must wait until tick+7 before sampling it.
module violin_expression #(
parameter integer DELAY_LINE_LENGTH=1024,
parameter integer SAMPLE_RATE_MILLIHZ=48828125
)(
input i_clk, input i_reset, input i_tick, input i_gate,
input [6:0] i_note, input [7:0] i_depth_cents,
input [7:0] i_rate_decihz, input [7:0] i_glide_ms,
input i_auto, output reg [31:0] o_period_q16
);
`include "src/instrument_pitch.vh"
function integer value_width;
    input [63:0] maximum;
    reg [63:0] remaining;
    integer width;
    begin
        remaining=maximum; width=0;
        while(remaining!=0) begin remaining=remaining>>1; width=width+1; end
        value_width=width<1 ? 1 : width;
    end
endfunction
// Inclusive D<<16 endpoint needs 27 bits at D=1024, not 26.
// Retargeting exactly to current retains the original one-LSB undershoot.
localparam integer PERIOD_WIDTH=DELAY_LINE_LENGTH>=8 && DELAY_LINE_LENGTH<=65535 ?
    value_width(DELAY_LINE_LENGTH*64'd65536) : 32;
localparam integer STEP_WIDTH=PERIOD_WIDTH>8 ? PERIOD_WIDTH-8 : 1;
localparam integer PHASE_PER_DECIHZ=(64'd4294967296000/(SAMPLE_RATE_MILLIHZ*10));
localparam integer AUTO_DELAY_SAMPLES=SAMPLE_RATE_MILLIHZ/3000;
reg [PERIOD_WIDTH-1:0] r_target, r_current, r_goal;
reg [STEP_WIDTH-1:0] r_step;
reg [31:0] r_phase, r_held;
reg r_gate;
// Only D=1024 uses the proved bounds. All other parameters preserve 32-bit math.
localparam integer SEED_WIDTH=DELAY_LINE_LENGTH==1024 ? 16 : 32;
localparam integer SPAN_WIDTH=DELAY_LINE_LENGTH==1024 ? 22 : 32;
localparam integer PRODUCT_WIDTH=DELAY_LINE_LENGTH==1024 ? 29 : 32;
localparam integer OFFSET_WIDTH=DELAY_LINE_LENGTH==1024 ? 23 : 32;
reg [SPAN_WIDTH-1:0] r_span, r_magnitude;
reg signed [OFFSET_WIDTH-1:0] r_offset;
reg [7:0] triangle_magnitude;
reg r_magnitude_negative;
reg [7:0] depth, rate, glide;
reg [4:0] glide_shift;
// One arithmetic pipeline serves both a new target and an existing glide.
// Every input needed after i_tick is captured, including a mid-glide retarget.
reg [1:0] r_glide_valid;
reg [PERIOD_WIDTH-1:0] r_delta_stage1;
reg [PERIOD_WIDTH-1:0] r_origin_stage1;
reg [PERIOD_WIDTH-1:0] r_goal_stage1;
reg [STEP_WIDTH-1:0] r_step_stage1;
reg [4:0] r_shift_stage1;
reg r_up_stage1;
reg r_retarget_stage1;
reg r_snap_stage1;
reg [PERIOD_WIDTH-1:0] r_origin_stage2;
reg [PERIOD_WIDTH-1:0] r_goal_stage2;
reg [STEP_WIDTH-1:0] r_step_stage2;
reg r_up_stage2;
reg r_retarget_stage2;
reg r_snap_stage2;
wire [PERIOD_WIDTH-1:0] w_selected_goal;
wire [PERIOD_WIDTH-1:0] w_distance_stage1;
wire [STEP_WIDTH-1:0] w_new_step_stage1;
assign w_selected_goal = r_target;
assign w_distance_stage1 = r_up_stage1 ? r_delta_stage1 : -r_delta_stage1;
assign w_new_step_stage1 = w_distance_stage1 >> r_shift_stage1;
reg [31:0] seed, total, auto_age;
reg [SEED_WIDTH-1:0] seed_pair0, seed_pair1, seed_total;
reg [SPAN_WIDTH-1:0] depth_pair0, depth_pair1, depth_pair2, depth_total;
reg [PRODUCT_WIDTH-1:0] magnitude_pair0, magnitude_pair1, magnitude_pair2, magnitude_total;
wire signed [31:0] offset_q16={{(32-OFFSET_WIDTH){r_offset[OFFSET_WIDTH-1]}},r_offset};
wire signed [OFFSET_WIDTH-1:0] magnitude_signed=r_magnitude;
wire [31:0] current_q16={{(32-PERIOD_WIDTH){1'b0}},r_current};
always @(posedge i_clk)
begin
    if(i_reset)
    begin
        r_target<=32'd524288; r_current<=32'd524288; r_goal<=32'd524288;
        r_step<=1; r_phase<=0; r_held<=0; r_gate<=0;
        r_glide_valid<=0;
        r_delta_stage1<=0; r_origin_stage1<=32'd524288; r_goal_stage1<=32'd524288;
        r_step_stage1<=1; r_shift_stage1<=8;
        r_up_stage1<=0; r_retarget_stage1<=0; r_snap_stage1<=1;
        r_origin_stage2<=32'd524288; r_goal_stage2<=32'd524288; r_step_stage2<=1;
        r_up_stage2<=0; r_retarget_stage2<=0; r_snap_stage2<=1;
        r_span<=0; r_magnitude<=0; r_magnitude_negative<=0; r_offset<=0; o_period_q16<=32'd524288;
    end
    else
    begin
        r_target<=midi_period_q16(i_note);
        depth=i_depth_cents>63 ? 63 : i_depth_cents;
        if(depth==0 && i_auto && r_held>=AUTO_DELAY_SAMPLES)
        begin
            auto_age=r_held-AUTO_DELAY_SAMPLES;
            depth=auto_age>=768 ? 12 : (auto_age>>6)+1;
        end
        rate=i_rate_decihz==0 && i_auto ? 48 : i_rate_decihz;
        glide=i_glide_ms==0 && i_auto ? 6 : i_glide_ms;
        glide_shift=glide<=5 ? 8 : glide<=10 ? 9 : glide<=20 ? 10 :
        glide<=40 ? 11 : glide<=80 ? 12 : glide<=160 ? 13 : 14;
        r_glide_valid <= {r_glide_valid[0], i_tick};
        if (i_tick)
        begin
            // Stage 1 has one period subtract, without the downstream
            // absolute value, variable shift, zero clamp or current add.
            r_delta_stage1 <= w_selected_goal - r_current;
            r_origin_stage1 <= r_current;
            r_goal_stage1 <= w_selected_goal;
            r_step_stage1 <= r_step;
            r_shift_stage1 <= glide_shift;
            r_up_stage1 <= w_selected_goal > r_current;
            r_retarget_stage1 <= r_target != r_goal;
            r_snap_stage1 <= !i_gate || !r_gate || glide == 0;
            r_gate <= i_gate;
            if (!i_gate)
            begin
                r_held <= 0;
            end
            else if (!r_gate)
            begin
                r_held <= 0;
                r_phase <= 0;
            end
            else
            begin
                if (r_held != 32'hffffffff)
                begin
                    r_held <= r_held + 1'b1;
                end
                r_phase <= r_phase + rate * PHASE_PER_DECIHZ;
            end
        end
        if (r_glide_valid[0])
        begin
            // Stage 2 prepares the bounded increment. An exactly equal
            // retarget intentionally keeps R7's one-LSB downward step.
            r_origin_stage2 <= r_origin_stage1;
            r_goal_stage2 <= r_goal_stage1;
            r_up_stage2 <= r_up_stage1;
            r_retarget_stage2 <= r_retarget_stage1 && !r_snap_stage1;
            r_snap_stage2 <= r_snap_stage1 ||
                (!r_retarget_stage1 && w_distance_stage1 <= r_step_stage1);
            r_step_stage2 <= r_retarget_stage1 ?
                (w_new_step_stage1 == 0 ? 1 : w_new_step_stage1) : r_step_stage1;
        end
        if (r_glide_valid[1])
        begin
            // Stage 3 only selects an endpoint or performs the final add.
            r_goal <= r_goal_stage2;
            if (r_snap_stage2)
            begin
                r_current <= r_goal_stage2;
            end
            else
            begin
                r_current <= r_up_stage2 ? r_origin_stage2 + r_step_stage2 :
                    r_origin_stage2 - r_step_stage2;
            end
            if (r_retarget_stage2)
            begin
                r_step <= r_step_stage2;
            end
        end
        // Approx ln(2)/1200 = 37.75/65536; <0.4% span error for small depth.
        // Balanced 32-bit trees preserve every original modulo-2^32 sum.
        seed_pair0=(current_q16>>11)+(current_q16>>14);
        seed_pair1=(current_q16>>16)+(current_q16>>17);
        seed_total=(seed_pair0+seed_pair1)+(current_q16>>18);
        seed={{(32-SEED_WIDTH){1'b0}},seed_total};
        depth_pair0=(depth[0] ? seed : 32'd0)+(depth[1] ? seed<<1 : 32'd0);
        depth_pair1=(depth[2] ? seed<<2 : 32'd0)+(depth[3] ? seed<<3 : 32'd0);
        depth_pair2=(depth[4] ? seed<<4 : 32'd0)+(depth[5] ? seed<<5 : 32'd0);
        depth_total=(depth_pair0+depth_pair1)+depth_pair2;
        total={{(32-SPAN_WIDTH){1'b0}},depth_total};
        r_span<=depth_total;
        // Four quadrants: 0 -> +127 -> 0 -> -127 -> 0, no half-cycle jump.
        triangle_magnitude=r_phase[30] ? 8'd127-{1'b0,r_phase[29:23]} :
        {1'b0,r_phase[29:23]};
        magnitude_pair0=(triangle_magnitude[0] ? r_span : 32'd0)+
            (triangle_magnitude[1] ? r_span<<1 : 32'd0);
        magnitude_pair1=(triangle_magnitude[2] ? r_span<<2 : 32'd0)+
            (triangle_magnitude[3] ? r_span<<3 : 32'd0);
        magnitude_pair2=(triangle_magnitude[4] ? r_span<<4 : 32'd0)+
            (triangle_magnitude[5] ? r_span<<5 : 32'd0);
        magnitude_total=(magnitude_pair0+magnitude_pair1)+(magnitude_pair2+
            (triangle_magnitude[6] ? r_span<<6 : 32'd0));
        total={{(32-PRODUCT_WIDTH){1'b0}},magnitude_total};
        r_magnitude<=magnitude_total>>7;
        r_magnitude_negative<=r_phase[31];
        r_offset<=r_magnitude_negative ? -magnitude_signed : magnitude_signed;
        // Old negative offset may briefly wrap after a large period change.
        // Keep the original 32-bit addition, including those transient bits.
        o_period_q16<=i_gate ? current_q16+offset_q16 : current_q16;
    end
end
endmodule

