// Deterministic, independently controlled period-domain glide and triangular vibrato.
// Coefficients are engineering controls; no measured-instrument fit is claimed.
// Shift/add modulation avoids four additional variable-width DSP multipliers.
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
localparam integer PHASE_PER_DECIHZ=(64'd4294967296000/(SAMPLE_RATE_MILLIHZ*10));
localparam integer AUTO_DELAY_SAMPLES=SAMPLE_RATE_MILLIHZ/3000;
reg [31:0] r_target, r_current, r_goal, r_step, r_phase, r_held;
reg r_gate;
reg [31:0] r_span, r_magnitude;
reg signed [31:0] r_offset;
reg [7:0] triangle_magnitude;
reg r_magnitude_negative;
reg [7:0] depth, rate, glide;
reg [4:0] glide_shift;
reg [31:0] difference, step, seed, total, auto_age;
integer bit_index;
always @(posedge i_clk)
begin
    if(i_reset)
    begin
        r_target<=32'd524288; r_current<=32'd524288; r_goal<=32'd524288;
        r_step<=1; r_phase<=0; r_held<=0; r_gate<=0;
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
        if(i_tick)
        begin
            r_gate<=i_gate;
            if(!i_gate)
            begin
                r_held<=0; r_current<=r_target; r_goal<=r_target;
            end
            else if(!r_gate)
            begin
                r_held<=0; r_current<=r_target; r_goal<=r_target; r_phase<=0;
            end
            else
            begin
                if(r_held!=32'hffffffff) r_held<=r_held+1'b1;
                r_phase<=r_phase+rate*PHASE_PER_DECIHZ;
                if(glide==0)
                begin
                    r_current<=r_target; r_goal<=r_target;
                end
                else if(r_target!=r_goal)
                begin
                    difference=r_target>r_current ? r_target-r_current : r_current-r_target;
                    step=difference>>glide_shift;
                    if(step==0) step=1;
                    r_step<=step; r_goal<=r_target;
                    r_current<=r_target>r_current ? r_current+step : r_current-step;
                end
                else if(r_current!=r_goal)
                begin
                    difference=r_goal>r_current ? r_goal-r_current : r_current-r_goal;
                    if(difference<=r_step) r_current<=r_goal;
                    else r_current<=r_goal>r_current ? r_current+r_step : r_current-r_step;
                end
            end
        end
        // Approx ln(2)/1200 = 37.75/65536; <0.4% span error for small depth.
        seed=(r_current>>11)+(r_current>>14)+(r_current>>16)+
        (r_current>>17)+(r_current>>18);
        total=0;
        for(bit_index=0;bit_index<6;bit_index=bit_index+1)
        if(depth[bit_index]) total=total+(seed<<bit_index);
        r_span<=total;
        // Four quadrants: 0 -> +127 -> 0 -> -127 -> 0, no half-cycle jump.
        triangle_magnitude=r_phase[30] ? 8'd127-{1'b0,r_phase[29:23]} :
        {1'b0,r_phase[29:23]};
        total=0;
        for(bit_index=0;bit_index<7;bit_index=bit_index+1)
        if(triangle_magnitude[bit_index]) total=total+(r_span<<bit_index);
        r_magnitude<=total>>7;
        r_magnitude_negative<=r_phase[31];
        r_offset<=r_magnitude_negative ? -$signed(r_magnitude) : $signed(r_magnitude);
        o_period_q16<=i_gate ? r_current+$signed(r_offset) : r_current;
    end
end
endmodule

