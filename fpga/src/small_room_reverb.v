// Independent short-room effect, written from the comb/allpass equations.
// No instrument body state is owned here. Ordinary STOP leaves these tails;
// i_clear is the explicit emergency/clock-loss reset and cancels pending PCM.
// Four comb RAMs and one segmented AP store hold signed 24-bit Q8 states.
// The three AP histories keep independent pointers; their accesses are serial.
// This is a mono effect before the existing duplicate-L/R DAC transport.
module small_room_reverb #(
    parameter integer SAMPLE_RATE_MILLIHZ = 48828125
) (
    input i_clk, input i_reset, input i_clear, input i_sample_tick,
    input signed [15:0] i_sample,
    input i_bypass, input [7:0] i_wet, input [7:0] i_damping, input [1:0] i_tail,
    output reg signed [15:0] o_sample,
    output reg o_sample_valid,
    output o_ready,
    output reg [31:0] o_guard_count
);
    function integer clog2;
        input integer count;
        integer value;
        begin value=count-1;clog2=0;while(value>0) begin clog2=clog2+1;value=value>>1;end
            if(clog2<1) clog2=1;end
    endfunction
    // Nearest integer length from a 48kHz reference, using 64-bit arithmetic.
    localparam integer C0=(64'd1559*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer C1=(64'd1613*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer C2=(64'd1699*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer C3=(64'd1783*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer A0=(64'd149*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer A1=(64'd211*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer A2=(64'd263*SAMPLE_RATE_MILLIHZ+24000000)/48000000;
    localparam integer CW=clog2(C3);
    localparam integer AP_WORDS=A0+A1+A2;
    localparam integer AP_AW=clog2(AP_WORDS);
    localparam [AP_AW-1:0] AP1_BASE=A0, AP2_BASE=A0+A1;
    localparam [3:0] IDLE=0,COMB_READ=1,SUM_PAIR=2,LP_PREP=3,LP_MUL=4,
        LP_COMMIT=5,FB_PREP=6,FB_MUL=7,COMB_WRITE=8,
        AP_READ=9,AP_Y=10,AP_WRITE=11,MIX_PREP=12,MIX_MUL=13,MIX_OUTPUT=14,AP_SELECT=15;
    // Q15 g=round(32768*10^(-3*D/(T60*48000))). T60 engineering candidates:
    // 0.18/0.32/0.55/0.85 seconds. Fs scaling keeps D/Fs within +/-0.5 sample.
    // These are per-loop low-frequency targets, not measured room/DAC T60.
    function signed [15:0] feedback_g;
        input [1:0] bank;
        input [1:0] tail;
        begin
            case({tail,bank})
                4'h0: feedback_g=16'sd9422; 4'h1: feedback_g=16'sd9024;
                4'h2: feedback_g=16'sd8424; 4'h3: feedback_g=16'sd7877;
                4'h4: feedback_g=16'sd16254;4'h5: feedback_g=16'sd15864;
                4'h6: feedback_g=16'sd15262;4'h7: feedback_g=16'sd14696;
                4'h8: feedback_g=16'sd21792;4'h9: feedback_g=16'sd21486;
                4'ha: feedback_g=16'sd21008;4'hb: feedback_g=16'sd20551;
                4'hc: feedback_g=16'sd25166;4'hd: feedback_g=16'sd24937;
                4'he: feedback_g=16'sd24577;default: feedback_g=16'sd24230;
            endcase
        end
    endfunction
    function is_guarded;
        input signed [31:0] value;
        begin is_guarded=value>32'sd8388607 || value< -32'sd8388608;end
    endfunction
    // Q15 feedback ramps are bounded, never overshoot a table endpoint.
    // Largest preset difference 16353 takes 256 frames (<5.334 ms at 48k).
    function signed [15:0] slew_feedback;
        input signed [15:0] current_value,target_value;
        begin
            if(target_value>current_value)
                slew_feedback=target_value-current_value>16'sd64 ? current_value+16'sd64 : target_value;
            else
                slew_feedback=current_value-target_value>16'sd64 ? current_value-16'sd64 : target_value;
        end
    endfunction
    function signed [23:0] state_value;
        input signed [31:0] value;
        begin
            if(value>32'sd8388607) state_value=24'sh7fffff;
            else if(value< -32'sd8388608) state_value=24'sh800000;
            // Kill inaudible sub-1/16 PCM-LSB states. Arithmetic floor can
            // otherwise retain a negative one-Q8-unit fixed-point limit cycle.
            else if(value> -32'sd16 && value<32'sd16) state_value=0;
            else state_value=value[23:0];
        end
    endfunction
    reg signed [23:0] r_comb0[0:C0-1],r_comb1[0:C1-1],r_comb2[0:C2-1],r_comb3[0:C3-1];
    // Explicit 16+8 planes avoid a 24-bit word being padded to a wider mode.
    // Depth remains parameterized; larger legal sample rates expand naturally.
    reg [15:0] r_ap_low[0:AP_WORDS-1] /* synthesis syn_ramstyle = "block_ram" */;
    reg [7:0] r_ap_high[0:AP_WORDS-1] /* synthesis syn_ramstyle = "block_ram" */;
    reg [15:0] r_ap_low_read;
    reg [7:0] r_ap_high_read;
    reg [clog2(C0)-1:0] r_c0;
    reg [clog2(C1)-1:0] r_c1;
    reg [clog2(C2)-1:0] r_c2;
    reg [clog2(C3)-1:0] r_c3;
    reg [clog2(A0)-1:0] r_a0;
    reg [clog2(A1)-1:0] r_a1;
    reg [clog2(A2)-1:0] r_a2;
    reg [CW-1:0] r_clear_index;
    reg r_initializing;
    reg [3:0] r_state;
    reg [1:0] r_bank,r_ap_bank,r_tail;
    reg [7:0] r_damping,r_wet,r_wet_smooth;
    reg signed [15:0] r_feedback0,r_feedback1,r_feedback2,r_feedback3;
    reg signed [15:0] w_feedback_current;
    wire signed [15:0] w_feedback_next = slew_feedback(w_feedback_current,feedback_g(r_bank,r_tail));
    // Effective wet target includes bypass. Delay/LP/AP histories keep running
    // during the fade and while bypassed; only reset/clear cancels them.
    wire [7:0] w_wet_target = i_bypass ? 8'd0 : i_wet;
    reg signed [23:0] r_input_q8;
    reg signed [23:0] r_delay0,r_delay1,r_delay2,r_delay3;
    reg signed [23:0] r_lp0,r_lp1,r_lp2,r_lp3,r_filtered;
    reg signed [24:0] r_pair0,r_pair1;
    reg signed [23:0] r_ap_x,r_ap_y;
    wire signed [23:0] r_ap_delay;
    reg signed [23:0] r_ap_selected;
    // One time-multiplexed 25x16 signed multiplier (27x18-class DSP candidate).
    reg signed [24:0] r_mult_a;
    reg signed [15:0] r_mult_b;
    reg signed [40:0] r_product;
    reg signed [23:0] w_delay,w_lp;
    reg signed [31:0] w_lp_value,w_comb_value,w_ap_y_value,w_ap_write_value,w_mix_value;
    reg w_numeric_guard;
    wire [1:0] w_guard_increment;
    wire signed [25:0] w_pair_sum;
    wire [AP_AW-1:0] w_ap_address;
    wire [23:0] w_ap_write_data;
    assign w_ap_address=r_ap_bank==0 ? r_a0 : r_ap_bank==1 ? AP1_BASE+r_a1 : AP2_BASE+r_a2;
    assign w_ap_write_data=state_value(w_ap_write_value);
    assign r_ap_delay={r_ap_high_read,r_ap_low_read};
    assign w_pair_sum=$signed({r_pair0[24],r_pair0})+$signed({r_pair1[24],r_pair1});
    // ready means initialized, as for the physical string cores. It must not
    // flicker during computation: board PA_EN uses the global ready signal.
    // The fixed scheduler supplies >=42 clocks between ordinary sample ticks.
    assign o_ready=!r_initializing && !i_clear && !i_reset;
    assign w_guard_increment={1'b0,w_numeric_guard}+{1'b0,(i_sample_tick && r_state!=IDLE)};
    always @*
    begin
        case(r_bank)
            0: begin w_delay=r_delay0;w_lp=r_lp0;w_feedback_current=r_feedback0;end
            1: begin w_delay=r_delay1;w_lp=r_lp1;w_feedback_current=r_feedback1;end
            2: begin w_delay=r_delay2;w_lp=r_lp2;w_feedback_current=r_feedback2;end
            default: begin w_delay=r_delay3;w_lp=r_lp3;w_feedback_current=r_feedback3;end
        endcase
        w_lp_value=$signed(w_delay)+($signed(r_product) >>>15);
        w_comb_value=$signed(r_input_q8)+($signed(r_product) >>>15);
        w_ap_y_value=$signed(r_ap_selected)-($signed(r_ap_x) >>>1);
        w_ap_write_value=$signed(r_ap_x)+($signed(r_ap_y) >>>1);
        w_mix_value=$signed(r_input_q8)+($signed(r_product) >>>15);
        w_numeric_guard=0;
        case(r_state)
            LP_COMMIT:w_numeric_guard=is_guarded(w_lp_value);
            COMB_WRITE:w_numeric_guard=is_guarded(w_comb_value);
            AP_Y:w_numeric_guard=is_guarded(w_ap_y_value);
            AP_WRITE:w_numeric_guard=is_guarded(w_ap_write_value);
            MIX_OUTPUT:w_numeric_guard=
                (w_mix_value>32'sd8388352 || w_mix_value< -32'sd8388608);
        endcase
    end
    // RAM resets are sequential address writes, never reset loops. Each bank
    // has one synchronous read port and one write port; read/write phases do
    // not overlap. Split init/normal address muxes preserve RAM inference.
    always @(posedge i_clk)
    begin
        if(r_initializing)
        begin
            if(r_clear_index<C0) r_comb0[r_clear_index]<=0;
            if(r_clear_index<C1) r_comb1[r_clear_index]<=0;
            if(r_clear_index<C2) r_comb2[r_clear_index]<=0;
            if(r_clear_index<C3) r_comb3[r_clear_index]<=0;
        end
        else
        begin
            if(r_state==COMB_READ)
            begin
                r_delay0<=r_comb0[r_c0];r_delay1<=r_comb1[r_c1];
                r_delay2<=r_comb2[r_c2];r_delay3<=r_comb3[r_c3];
            end
            if(r_state==COMB_WRITE)
                case(r_bank)
                    0: r_comb0[r_c0]<=state_value(w_comb_value);
                    1: r_comb1[r_c1]<=state_value(w_comb_value);
                    2: r_comb2[r_c2]<=state_value(w_comb_value);
                    3: r_comb3[r_c3]<=state_value(w_comb_value);
                endcase
        end
    end
    // Clear AP segments sequentially within the unchanged C3-clock window.
    // Both planes share address/enables and use the original one-clock read.
    // Reset/clear intentionally do not gate the separate memory always blocks:
    // a same-edge old-state write is followed by the original clearing process.
    always @(posedge i_clk)
    begin
        if(r_initializing) begin
            if(r_clear_index<AP_WORDS) r_ap_low[r_clear_index[AP_AW-1:0]]<=0;
        end else begin
            if(r_state==AP_READ && r_ap_bank<3) r_ap_low_read<=r_ap_low[w_ap_address];
            if(r_state==AP_WRITE && r_ap_bank<3) r_ap_low[w_ap_address]<=w_ap_write_data[15:0];
        end
    end
    always @(posedge i_clk)
    begin
        if(r_initializing) begin
            if(r_clear_index<AP_WORDS) r_ap_high[r_clear_index[AP_AW-1:0]]<=0;
        end else begin
            if(r_state==AP_READ && r_ap_bank<3) r_ap_high_read<=r_ap_high[w_ap_address];
            if(r_state==AP_WRITE && r_ap_bank<3) r_ap_high[w_ap_address]<=w_ap_write_data[23:16];
        end
    end
    always @(posedge i_clk)
    begin
        o_sample_valid<=0;
        if(i_reset || i_clear)
        begin
            r_initializing<=1;r_clear_index<=0;r_state<=IDLE;
            r_c0<=0;r_c1<=0;r_c2<=0;r_c3<=0;r_a0<=0;r_a1<=0;r_a2<=0;
            r_lp0<=0;r_lp1<=0;r_lp2<=0;r_lp3<=0;r_filtered<=0;
            r_bank<=0;r_ap_bank<=0;r_tail<=0;r_damping<=0;r_wet<=0;r_wet_smooth<=0;
            r_feedback0<=16'sd9422;r_feedback1<=16'sd9024;
            r_feedback2<=16'sd8424;r_feedback3<=16'sd7877;
            r_input_q8<=0;r_pair0<=0;r_pair1<=0;
            r_ap_x<=0;r_ap_y<=0;r_ap_selected<=0;r_mult_a<=0;r_mult_b<=0;r_product<=0;o_sample<=0;
            if(i_reset) o_guard_count<=0;
        end
        else if(r_initializing)
        begin
            o_sample<=0;
            if(r_clear_index==C3-1) begin r_initializing<=0;r_clear_index<=0;end
            else r_clear_index<=r_clear_index+1'b1;
        end
        else
        begin
            // A second tick while busy is explicitly counted and rejected.
            if(w_guard_increment!=0)
                o_guard_count<=o_guard_count>32'hffffffff-w_guard_increment ?
                    32'hffffffff : o_guard_count+w_guard_increment;
            case(r_state)
                IDLE: if(i_sample_tick)
                begin
                    r_input_q8<={i_sample,8'd0};r_tail<=i_tail;
                    if(r_damping<i_damping)r_damping<=r_damping+1'b1;
                    else if(r_damping>i_damping)r_damping<=r_damping-1'b1;
                    r_wet<=r_wet_smooth;
                    // One step per accepted transaction, including reversals.
                    // 255 steps + the existing snapshot delay: <=5.334 ms at 48k.
                    if(r_wet_smooth<w_wet_target) r_wet_smooth<=r_wet_smooth+1'b1;
                    else if(r_wet_smooth>w_wet_target) r_wet_smooth<=r_wet_smooth-1'b1;
                    r_bank<=0;r_state<=COMB_READ;
                end
                COMB_READ: r_state<=SUM_PAIR;
                SUM_PAIR:
                begin
                    r_pair0<=$signed({r_delay0[23],r_delay0})+$signed({r_delay1[23],r_delay1});
                    r_pair1<=$signed({r_delay2[23],r_delay2})+$signed({r_delay3[23],r_delay3});
                    r_state<=LP_PREP;
                end
                LP_PREP:
                begin
                    // lp = delay + damping/256 * (previous_lp-delay).
                    r_mult_a<=$signed({w_lp[23],w_lp})-$signed({w_delay[23],w_delay});
                    r_mult_b<=$signed({1'b0,r_damping,7'd0});
                    if(r_bank==0) r_ap_x<=w_pair_sum >>>3; // four-line mean, -6dB wet headroom
                    r_state<=LP_MUL;
                end
                LP_MUL: begin r_product<=r_mult_a*r_mult_b;r_state<=LP_COMMIT;end
                LP_COMMIT:
                begin
                    r_filtered<=state_value(w_lp_value);
                    case(r_bank)
                        0:r_lp0<=state_value(w_lp_value);1:r_lp1<=state_value(w_lp_value);
                        2:r_lp2<=state_value(w_lp_value);3:r_lp3<=state_value(w_lp_value);
                    endcase
                    r_state<=FB_PREP;
                end
                FB_PREP:
                begin
                    // Normalized comb: write = x + g*(lp-x), DC gain one.
                    r_mult_a<=$signed({r_filtered[23],r_filtered})-$signed({r_input_q8[23],r_input_q8});
                    r_mult_b<=w_feedback_next;
                    case(r_bank)
                        0:r_feedback0<=w_feedback_next;1:r_feedback1<=w_feedback_next;
                        2:r_feedback2<=w_feedback_next;3:r_feedback3<=w_feedback_next;
                    endcase
                    r_state<=FB_MUL;
                end
                FB_MUL: begin r_product<=r_mult_a*r_mult_b;r_state<=COMB_WRITE;end
                COMB_WRITE:
                begin
                    case(r_bank)
                        0:r_c0<=r_c0==C0-1 ? 0 : r_c0+1'b1;
                        1:r_c1<=r_c1==C1-1 ? 0 : r_c1+1'b1;
                        2:r_c2<=r_c2==C2-1 ? 0 : r_c2+1'b1;
                        3:r_c3<=r_c3==C3-1 ? 0 : r_c3+1'b1;
                    endcase
                    if(r_bank==3) begin r_ap_bank<=0;r_state<=AP_READ;end
                    else begin r_bank<=r_bank+1'b1;r_state<=LP_PREP;end
                end
                // Schroeder allpass with a=1/2: y=delayed-x/2; write=x+y/2.
                AP_READ:r_state<=AP_SELECT;
                // Preserve the original selected-data stage before arithmetic.
                // Packed storage removes the three-RAM mux, not its latency.
                AP_SELECT:begin r_ap_selected<=r_ap_delay;r_state<=AP_Y;end
                AP_Y:
                begin
                    r_ap_y<=state_value(w_ap_y_value);
                    r_state<=AP_WRITE;
                end
                AP_WRITE:
                begin
                    r_ap_x<=r_ap_y;
                    case(r_ap_bank)
                        0:r_a0<=r_a0==A0-1 ? 0 : r_a0+1'b1;
                        1:r_a1<=r_a1==A1-1 ? 0 : r_a1+1'b1;
                        2:r_a2<=r_a2==A2-1 ? 0 : r_a2+1'b1;
                    endcase
                    if(r_ap_bank==2) r_state<=MIX_PREP;
                    else begin r_ap_bank<=r_ap_bank+1'b1;r_state<=AP_READ;end
                end
                MIX_PREP:begin r_mult_a<={r_ap_x[23],r_ap_x};r_mult_b<=$signed({1'b0,r_wet,7'd0});r_state<=MIX_MUL;end
                MIX_MUL:begin r_product<=r_mult_a*r_mult_b;r_state<=MIX_OUTPUT;end
                MIX_OUTPUT:
                begin
                    // Dry unity is always present, from the current frame.
                    // No hard bypass mux: it would defeat the effective-wet fade.
                    if(w_mix_value>32'sd8388352) o_sample<=16'sh7fff;
                    else if(w_mix_value< -32'sd8388608) o_sample<=16'sh8000;
                    else o_sample<=w_mix_value >>>8;
                    o_sample_valid<=1;r_state<=IDLE;
                end
                default:r_state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(SAMPLE_RATE_MILLIHZ<8000000 || C3<2 || A0<2 || AP_WORDS>C3)
    begin $display("FAIL small_room_reverb: invalid sample rate/delay lengths");$finish;end
    // synthesis translate_on
endmodule
