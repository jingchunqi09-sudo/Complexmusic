`timescale 1ns/1ps
// Compare the routed-path refactor to the exact pre-refactor RTL, not to a
// duplicate expected-value implementation. Reference is an archived source.
module revision6_violin_pitch_pipeline_tb;
    parameter integer RATE=48828125;
    localparam integer SAMPLE_RATE_MILLIHZ=RATE;
    localparam integer DELAY_LINE_LENGTH=1024;
    reg clk=0,reset=1,tick=0,prepare=0,trigger=0,stop=0,gate=0;
    reg [6:0] note=69;
    reg [31:0] period=32'd7272730;
    reg [7:0] pressure=128;
    reg signed [15:0] speed=48;
    reg direction=0;
    reg [23:0] position=0;
    wire signed [15:0] actual_default,reference_default,actual_prepared,reference_prepared;
    wire [3:0] ready;
    integer n,p,k,frame_number,geometry_cases=0,pcm_checks=0,errors=0;
    `include "src/instrument_pitch.vh"
    always #10 clk=~clk;

    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE)) default_dut(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),.i_period_q16(period),
        .i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),
        .i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(position),
        .o_audio_sample(actual_default),.o_ready(ready[0]));
    revision6_violin_pitch_reference #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE)) default_ref(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),.i_period_q16(period),
        .i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),
        .i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(position),
        .o_audio_sample(reference_default),.o_ready(ready[1]));
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),
        .SEPARATE_CONTROL_PREPARE(1),.ENABLE_FINE_PITCH(1),.ENABLE_BODY_FILTER(0)) prepared_dut(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),.i_period_q16(period),
        .i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),
        .i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(position),
        .o_audio_sample(actual_prepared),.o_ready(ready[2]));
    revision6_violin_pitch_reference #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),
        .SEPARATE_CONTROL_PREPARE(1),.ENABLE_FINE_PITCH(1),.ENABLE_BODY_FILTER(0)) prepared_ref(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),.i_period_q16(period),
        .i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(pressure),
        .i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(position),
        .o_audio_sample(reference_prepared),.o_ready(ready[3]));

    task check;
        input valid;
        input [511:0] why;
        begin if(!valid)begin errors=errors+1;if(errors<=20)$display("FAIL %0s frame=%0d note=%0d",why,frame_number,note);end end
    endtask
    task compare_geometry;
        begin
            check(default_dut.r_bridge_length_stage2===default_ref.r_bridge_length_stage2 &&
                  default_dut.r_neck_length_stage2===default_ref.r_neck_length_stage2 &&
                  default_dut.r_delay_fraction_stage2===default_ref.r_delay_fraction_stage2,"default geometry mismatch");
            check(prepared_dut.r_bridge_length_stage2===prepared_ref.r_bridge_length_stage2 &&
                  prepared_dut.r_neck_length_stage2===prepared_ref.r_neck_length_stage2 &&
                  prepared_dut.r_delay_fraction_stage2===prepared_ref.r_delay_fraction_stage2,"fine geometry mismatch");
            geometry_cases=geometry_cases+2;
        end
    endtask
    task compare_pcm;
        begin
            check(actual_default===reference_default,"default PCM mismatch");
            check(actual_prepared===reference_prepared,"prepared fine PCM mismatch");
            check(default_dut.r_samples_since_trigger===default_ref.r_samples_since_trigger &&
                  prepared_dut.r_samples_since_trigger===prepared_ref.r_samples_since_trigger,"sample age mismatch");
            check(default_dut.r_require_cold_start===default_ref.r_require_cold_start &&
                  prepared_dut.r_require_cold_start===prepared_ref.r_require_cold_start,"lifecycle mismatch");
            pcm_checks=pcm_checks+2;
        end
    endtask
    task prepared_frame;
        begin
            @(negedge clk);prepare=1;
            @(negedge clk);prepare=0;
            repeat(24)@(negedge clk);
            tick=1;@(negedge clk);tick=0;
            compare_geometry;compare_pcm;
            repeat(4)@(negedge clk);
        end
    endtask
    task legacy_frame;
        begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;
            compare_pcm;
            // A standalone sample slot is 96 clocks, as in the verified
            // accelerated core renderer; the old 10-clock fixture did not
            // allow the added system-clock DSP shadows to settle.
            repeat(95)@(negedge clk);
        end
    endtask
    initial begin
        frame_number=0;
        repeat(3)@(negedge clk);reset=0;
        repeat(1030)@(negedge clk);check(&ready,"RAM initialization");
        // All MIDI table entries and all 32 onset contact ratios. Fine-period
        // cases also cross half-sample/minimum-delay/memory-clamp boundaries.
        trigger=1;
        for(n=0;n<128;n=n+1)for(p=0;p<32;p=p+1)begin
            note=n;position=p<<19;period=midi_period_q16(n)+(p<<8);
            repeat(8)@(negedge clk);compare_geometry;
        end
        for(k=0;k<16;k=k+1)begin
            case(k)
                0:period=0;1:period=1;2:period=32'd32767;3:period=32'd32768;
                4:period=32'd32769;5:period=32'd524287;6:period=32'd524288;
                7:period=32'd557055;8:period=32'd557056;9:period=32'hffffffff;
                10:period=32'h7fffffff;11:period=32'h80000000;
                default:period=(32'd65535<<16)+(k<<8);
            endcase
            for(p=0;p<32;p=p+1)begin position=p<<19;repeat(8)@(negedge clk);compare_geometry;end
        end
        trigger=0;reset=1;repeat(3)@(negedge clk);reset=0;
        repeat(1030)@(negedge clk);
        // Legacy cold onset: eight clocks of control setup; 96 clocks/sample.
        note=55;period=midi_period_q16(55);position=0;gate=1;trigger=1;
        repeat(8)@(negedge clk);legacy_frame;trigger=0;
        for(frame_number=0;frame_number<12000;frame_number=frame_number+1)legacy_frame;
        reset=1;gate=0;repeat(3)@(negedge clk);reset=0;repeat(1030)@(negedge clk);
        // Prepare-to-model distance is exactly 25 clocks as in the real core.
        note=55;period=midi_period_q16(55);pressure=128;speed=48;position=24'h800000;gate=1;trigger=1;
        for(frame_number=0;frame_number<18000;frame_number=frame_number+1)begin
            if(frame_number==1)trigger=0;
            if(frame_number==2000)begin note=62;period=midi_period_q16(62);end
            if(frame_number>=3000&&frame_number<3500)period=midi_period_q16(62)+(frame_number-3000)*10;
            if(frame_number==4000)begin pressure=255;speed=255;position=24'hffffff;end
            if(frame_number==6000)direction=1;
            if(frame_number==8000)gate=0;
            if(frame_number==9000)begin gate=1;trigger=1;end
            if(frame_number==9001)trigger=0;
            if(frame_number==11000)begin stop=1;trigger=1;end
            if(frame_number==11001)begin stop=0;trigger=0;gate=0;end
            if(frame_number==12000)begin trigger=1;gate=1;note=76;period=midi_period_q16(76);direction=0;end
            if(frame_number==12001)trigger=0;
            if(frame_number==14000)begin note=88;period=midi_period_q16(88);pressure=32;speed=16;end
            if(frame_number==16000)begin pressure=0;speed=0;end
            prepared_frame;
        end
        $display("VIOLIN_PIPELINE_RESULT errors=%0d geometry_cases=%0d pcm_checks=%0d rate=%0d",errors,geometry_cases,pcm_checks,RATE);
        if(errors==0)$display("PASS revision6_violin_pitch_pipeline_tb: archived twin numerical geometry/PCM and lifecycle");
        else $fatal(1,"violin pitch pipeline regression");
        $finish;
    end
endmodule
