`timescale 1ns/1ps
// Explicit 48-kHz model parameters. tick is accelerated in simulation; all
// propagation/filter state advances once per tick, never per testbench clock.
module revision5_bow_tb #(
    parameter integer SAMPLE_RATE_MILLIHZ=48000000,
    parameter [1023:0] RESULT_DIR="sim/results/revision5_bow"
);
    reg clk=0, reset=1, tick=0, trigger=0, gate=0, direction=0, stop=0;
    reg [6:0] note=55;
    reg [7:0] pressure=192;
    reg signed [15:0] speed=48;
    wire signed [15:0] raw_pcm, body_pcm, before_pcm;
    wire raw_ready, body_ready, before_ready;
    integer ni, pi, si, n, f, stick_count, slip_count, contact_delta, contact_force;
    integer previous_target, old_bridge, old_neck, old_age, tail_sum, diff_sum;
    reg signed [29:0] old_body_position;
    reg [1023:0] path;
    always #5 clk=~clk;
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),
        .ENABLE_BODY_FILTER(0)) raw (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(stop),
        .i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
        .i_bow_direction(direction),.i_bow_position(24'h800000),
        .o_audio_sample(raw_pcm),.o_ready(raw_ready));
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) dut (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(stop),
        .i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
        .i_bow_direction(direction),.i_bow_position(24'h800000),
        .o_audio_sample(body_pcm),.o_ready(body_ready));
    // Algorithmic A/B: old 96 plateau / restart policy, at the SAME 48-kHz Fs.
    // This is not the historical revision4 bitstream or a physical recording.
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ),
        .ENABLE_BOW_LIFECYCLE(0),.ENABLE_FULL_SPEED_RANGE(0),
        .BOW_SLEW_PCM_PER_SAMPLE(128)) before (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(stop),
        .i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
        .i_bow_direction(direction),.i_bow_position(24'h800000),
        .o_audio_sample(before_pcm),.o_ready(before_ready));
    task sample;
        begin
            repeat(24) @(negedge clk);
            contact_delta=$signed(raw.r_slip_for_gain);
            contact_force=$signed(raw.w_advanced_injection);
            if(contact_delta>0 && (contact_force<0 || contact_force>contact_delta))
                $fatal(1,"positive slip violated dissipative contact bound");
            if(contact_delta<0 && (contact_force>0 || contact_force<contact_delta))
                $fatal(1,"negative slip violated dissipative contact bound");
            tick=1; @(negedge clk); tick=0;
            repeat(24) @(negedge clk);
            if((^raw_pcm)===1'bx || (^body_pcm)===1'bx || (^before_pcm)===1'bx)
                $fatal(1,"unknown PCM");
            if(raw_pcm==32767 || raw_pcm==-32768 || body_pcm==32767 || body_pcm==-32768)
                $fatal(1,"new voice clipped n%0d p%0d s%0d",note,pressure,speed);
            if(dut.MODAL_BODY.u_body.o_guard_count!=0 || dut.MODAL_BODY.u_body.o_clip_count!=0)
                $fatal(1,"body protection fired");
        end
    endtask
    task clean_start;
        begin
            reset=1; trigger=0; gate=0; direction=0; stop=0;
            repeat(3) @(negedge clk); reset=0;
            repeat(1100) @(negedge clk);
            if(!raw_ready || !body_ready || !before_ready) $fatal(1,"RAM not ready");
            gate=1; trigger=1; sample; trigger=0;
            if(dut.r_samples_since_trigger!=1) $fatal(1,"cold start logical age wrong");
        end
    endtask
    initial begin
        // Control-domain scan proves there is no 96..255 plateau, including
        // signs, zero and out-of-protocol input protection.
        note=69; pressure=192; clean_start;
        previous_target=0;
        for(n=1;n<=255;n=n+1) begin
            speed=n; repeat(30) @(negedge clk);
            if($signed(dut.w_bow_target_velocity)<=previous_target)
                $fatal(1,"bow control plateau at %0d",n);
            previous_target=$signed(dut.w_bow_target_velocity);
        end
        if(previous_target!=1743) $fatal(1,"full speed exceeds calibrated bound");
        speed=32767; repeat(30) @(negedge clk);
        if(dut.w_bow_target_velocity!=1743) $fatal(1,"positive control clamp failed");
        speed=-32768; repeat(30) @(negedge clk);
        if(dut.w_bow_target_velocity!=-1743) $fatal(1,"negative control clamp failed");
        direction=1; repeat(30) @(negedge clk);
        if(dut.w_bow_target_velocity!=1743) $fatal(1,"signed direction inversion failed");
        $display("CONTROL distinct_nonzero_targets=255 maximum_velocity_pcm=1743");

        for(ni=0;ni<8;ni=ni+1)
            for(pi=0;pi<2;pi=pi+1)
                for(si=0;si<5;si=si+1) begin
                    note=ni==0?55:ni==1?62:ni==2?69:ni==3?76:
                         ni==4?67:ni==5?74:ni==6?81:88;
                    pressure=pi==0?128:192;
                    speed=si==0?16:si==1?48:si==2?96:si==3?160:255;
                    clean_start;
                    $sformat(path,"%0s/n%0d_p%0d_s%0d.txt",RESULT_DIR,note,pressure,speed);
                    f=$fopen(path,"w"); if(!f) $fatal(1,"PCM dump unavailable");
                    stick_count=0; slip_count=0;
                    for(n=0;n<16000;n=n+1) begin
                        sample;
                        $fwrite(f,"%0d %0d %0d\n",$signed(raw_pcm),$signed(body_pcm),$signed(before_pcm));
                        if(n>=4000) begin
                            if(raw.r_contact_sticking) stick_count=stick_count+1;
                            else slip_count=slip_count+1;
                        end
                    end
                    $fclose(f);
                    if(stick_count<12 || slip_count<12) $fatal(1,"contact locked n%0d p%0d s%0d",note,pressure,speed);
                    $display("CASE n%0d p%0d s%0d stick=%0d slip=%0d",note,pressure,speed,stick_count,slip_count);
                end

        // Same-string legato: trigger absent, ring heads/age continue.
        note=69; pressure=192; speed=48; clean_start; repeat(12000) sample;
        $sformat(path,"%0s/legato.txt",RESULT_DIR); f=$fopen(path,"w");
        for(n=0;n<30000;n=n+1) begin
            if(n==6000) begin
                old_bridge=dut.r_bridge_index; old_neck=dut.r_neck_index;
                old_age=dut.r_samples_since_trigger; note=71;
            end
            sample;
            if(n==6000 && (dut.r_bridge_index!=(old_bridge+1)%256 ||
                dut.r_neck_index!=(old_neck+1)%960 || dut.r_samples_since_trigger<old_age))
                $fatal(1,"legato restarted histories");
            if(n==6032 && dut.r_retune_blend!=256) $fatal(1,"retune not complete");
            $fwrite(f,"%0d %0d\n",$signed(body_pcm),$signed(before_pcm));
        end
        $fclose(f);

        // Direction reversal and brief lift/recontact both retain vibration.
        note=69; speed=48; clean_start; repeat(12000) sample;
        $sformat(path,"%0s/lifecycle.txt",RESULT_DIR); f=$fopen(path,"w");
        for(n=0;n<30000;n=n+1) begin
            if(n==6000) direction=1;
            if(n==12000) begin gate=0; speed=0; end
            if(n==12240) begin
                gate=1; speed=48; trigger=1;
                old_bridge=dut.r_bridge_index; old_neck=dut.r_neck_index;
                old_age=dut.r_samples_since_trigger;
                old_body_position=dut.MODAL_BODY.u_body.r_position_q8[0];
            end
            sample;
            if(n==6070 && dut.r_performance_velocity!=-1536) $fatal(1,"smooth reversal did not settle");
            if(n==12240) begin
                if(dut.r_bridge_index!=(old_bridge+1)%256 || dut.r_neck_index!=(old_neck+1)%960 ||
                    dut.r_samples_since_trigger!=old_age) $fatal(1,"recontact cleared ring history");
                if(old_body_position!=0 && dut.MODAL_BODY.u_body.r_position_q8[0]==0)
                    $fatal(1,"recontact cleared body history");
                trigger=0;
            end
            $fwrite(f,"%0d %0d\n",$signed(body_pcm),$signed(before_pcm));
        end
        $fclose(f);

        // Explicit STOP inhibits contact even if a stale nonzero speed/gate
        // remains. It preserves passive tail and requires a later cold trigger.
        stop=1; sample; stop=0;
        if(!dut.r_require_cold_start || dut.r_bow_injection!=0) $fatal(1,"explicit STOP failed");
        tail_sum=0;
        for(n=0;n<2400;n=n+1) begin
            sample;
            if(dut.r_bow_injection!=0) $fatal(1,"STOP stale controls restarted contact");
            if(n<240) tail_sum=tail_sum+(body_pcm<0?-$signed(body_pcm):$signed(body_pcm));
        end
        if(tail_sum<1000) $fatal(1,"STOP hard-cut passive tail");
        trigger=1; sample; trigger=0;
        if(dut.r_samples_since_trigger!=1 || dut.r_bridge_index!=1 || dut.r_neck_index!=1)
            $fatal(1,"STOP restart was not cold");
        repeat(10) sample;
        if(dut.r_neck_new_tap!=0) $fatal(1,"cold restart exposed old RAM");
        gate=0; sample;
        if(dut.r_bow_injection!=0) $fatal(1,"gate-off supplies force");
        gate=1; speed=0; sample;
        if(dut.r_bow_injection!=0) $fatal(1,"zero-speed supplies force");
        speed=255; pressure=0; sample;
        if(dut.r_bow_injection!=0) $fatal(1,"zero-pressure supplies force");
        $display("LIFECYCLE stop_tail_abs_sum_240=%0d",tail_sum);
        $display("PASS revision5_bow_tb: 80 cases Fs_mHz=%0d, 255 targets, passive contact, no clip, legato, reversal, recontact, STOP/cold restart",SAMPLE_RATE_MILLIHZ);
        $finish;
    end
endmodule
