`timescale 1ns/1ps
// Real RTL A/B at exactly 48 kHz. Accelerated sample spacing leaves 12 core clocks
// for the documented pipeline; it does not claim physical DAC/board evidence.
module revision5_ukulele_tb;
    reg clk=0,reset=1,tick=0,trigger=0,stop=0;
    reg [6:0] note=69;
    reg [7:0] velocity=224;
    wire signed [15:0] pcm,old_pcm,weak_pcm,position_pcm;
    wire ready,old_ready,weak_ready,position_ready;
    wire [15:0] envelope;
    integer n,k,fc,peak,a,b,c,d,mx,cmx,old_dry,new_dry;
    integer baseline[0:2047];
    reg [511:0] path;
    reg [63:0] energy,weak_energy;
    integer square;
    always #10 clk=~clk;
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000)) dut (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(velocity),.o_audio_sample(pcm),.o_ready(ready));
    revision4_ukulele_baseline #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000)) old (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(velocity),.o_audio_sample(old_pcm),.o_ready(old_ready));
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000)) weak_voice (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(8'd32),.o_audio_sample(weak_pcm),.o_ready(weak_ready));
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000),.PLUCK_POSITION_Q8(128)) position_voice (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(velocity),.o_audio_sample(position_pcm),.o_ready(position_ready));
    voice_envelope env (.i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),
        .i_gate(1'b0),.i_plucked(1'b1),.i_stop(stop),.i_attack_step(8'd96),.i_decay_step(8'd24),
        .i_sustain_level(8'd192),.i_release_step(8'd24),.o_envelope(envelope));
    task sample;
        begin
            repeat(12) @(negedge clk);
            new_dry=$signed(dut.r_body_input_sample);old_dry=$signed(old.r_body_input_sample);
            if(dut.r_active && dut.r_excitation_remaining==0 && dut.r_secondary_excitation_remaining==0) begin
                a=$signed(dut.w_feedback_sample);b=$signed(dut.w_secondary_feedback_sample);
                c=$signed(dut.w_primary_coupled_sample);d=$signed(dut.w_secondary_coupled_sample);
                mx=(a<0?-a:a)>(b<0?-b:b)?(a<0?-a:a):(b<0?-b:b);
                cmx=(c<0?-c:c)>(d<0?-d:d)?(c<0?-c:c):(d<0?-d:d);
                if(cmx>mx) $fatal(1,"coupling expanded maximum magnitude");
                mx=$signed(dut.r_delay_sample);if(mx<0)mx=-mx;
                a=$signed(dut.r_previous_sample);if(a<0)a=-a;if(a>mx)mx=a;
                a=$signed(dut.r_older_sample);if(a<0)a=-a;if(a>mx)mx=a;
                a=$signed(dut.r_filtered_precomputed);if(a<0)a=-a;
                if(a>mx) $fatal(1,"passive FIR/gain expanded maximum input magnitude");
                if(dut.w_feedback_extended>32767 || dut.w_feedback_extended < -32768 ||
                   dut.w_secondary_feedback_extended>32767 || dut.w_secondary_feedback_extended < -32768)
                    $fatal(1,"feedback clipping");
            end
            tick=1;@(negedge clk);tick=0;repeat(2) @(negedge clk);
            if((^pcm)===1'bx || (^old_pcm)===1'bx || (^weak_pcm)===1'bx || (^position_pcm)===1'bx)
                $fatal(1,"unknown PCM");
            if(pcm==32767 || pcm==-32768 || old_pcm==32767 || old_pcm==-32768 ||
               weak_pcm==32767 || weak_pcm==-32768 || position_pcm==32767 || position_pcm==-32768)
                $fatal(1,"output rails");
            if(dut.MODAL_BODY.u_body.o_clip_count!=0 || dut.MODAL_BODY.u_body.o_guard_count!=0 ||
               weak_voice.MODAL_BODY.u_body.o_clip_count!=0 || weak_voice.MODAL_BODY.u_body.o_guard_count!=0 ||
               position_voice.MODAL_BODY.u_body.o_clip_count!=0 || position_voice.MODAL_BODY.u_body.o_guard_count!=0)
                $fatal(1,"modal guard/clip");
        end
    endtask
    task initialize;
        begin
            reset=1;repeat(3) @(negedge clk);reset=0;repeat(1050) @(negedge clk);
            if(!ready || !old_ready || !weak_ready || !position_ready) $fatal(1,"memory init");
        end
    endtask
    task pluck;
        begin
            trigger=1;sample;trigger=0;
            if(velocity!=0 && pcm==0) $fatal(1,"silent trigger");
            if(dut.r_excitation_remaining!=dut.r_delay_length_stage2-1 ||
               dut.r_secondary_excitation_remaining!=dut.r_secondary_length_stage2-1)
                $fatal(1,"incomplete repluck overwrite");
        end
    endtask
    initial begin
        // Use +quick for 1.5 s A4 development only; full invocation is the deliverable.
        if (!$test$plusargs("quick")) begin
            for(k=55;k<=84;k=k+1) begin
                initialize;note=k;velocity=255;repeat(12) @(negedge clk);pluck;
                $sformat(path,"sim/results/revision5_ukulele/n%0d.txt",k);fc=$fopen(path,"w");
                if(!fc)$fatal(1,"cannot write pitch");
                for(n=0;n<12000;n=n+1) begin sample;$fwrite(fc,"%0d\n",$signed(pcm));end
                $fclose(fc);
            end
            for(k=0;k<5;k=k+1) begin
                initialize;note=(k==0?55:k==1?60:k==2?64:k==3?67:69);velocity=224;
                repeat(12) @(negedge clk);pluck;
                $sformat(path,"sim/results/revision5_ukulele/open%0d.txt",note);fc=$fopen(path,"w");
                if(!fc)$fatal(1,"cannot write open string");
                for(n=0;n<144000;n=n+1) begin
                    sample;$fwrite(fc,"%0d %0d %0d %0d\n",$signed(pcm),$signed(old_pcm),new_dry,old_dry);
                end
                $fclose(fc);
            end
        end
        initialize;note=69;velocity=224;repeat(12) @(negedge clk);pluck;
        energy=0;weak_energy=0;fc=$fopen("sim/results/revision5_ukulele/a4.txt","w");
        if(!fc)$fatal(1,"cannot write A4");
        for(n=0;n<($test$plusargs("quick")?72000:144000);n=n+1) begin
            sample;
            if(n<2048)baseline[n]=$signed(pcm);
            if(n<8192)begin
                square=$signed(pcm)*$signed(pcm);energy=energy+square;
                square=$signed(weak_pcm)*$signed(weak_pcm);weak_energy=weak_energy+square;
            end
            $fwrite(fc,"%0d %0d %0d %0d %0d %0d %0d\n",$signed(pcm),$signed(old_pcm),new_dry,old_dry,$signed(weak_pcm),$signed(position_pcm),envelope);
        end
        $fclose(fc);
        if(energy<=weak_energy*4)$fatal(1,"velocity response");
        pluck;for(n=0;n<2048;n=n+1)begin sample;if($signed(pcm)!=baseline[n])$fatal(1,"stale repluck %0d",n);end
        // KEEP/gate=0 leaves the physical tail running; fret update changes both rings without a trigger.
        note=72;for(n=0;n<4096;n=n+1)sample;
        if(!dut.r_active || dut.r_excitation_remaining!=0 || envelope!=30720)$fatal(1,"tail/KEEP semantics");
        stop=1;sample;stop=0;for(n=0;n<1400;n=n+1)sample;
        if(envelope!=0)$fatal(1,"STOP did not finish release");
        // STOP wins over simultaneous trigger at the enclosing envelope.
        trigger=1;stop=1;sample;trigger=0;stop=0;
        if(envelope!=0)$fatal(1,"STOP/trigger priority");
        initialize;velocity=0;repeat(12) @(negedge clk);pluck;
        for(n=0;n<2048;n=n+1)begin sample;if(pcm!=0)$fatal(1,"zero velocity audible");end
        $display("PASS revision5_ukulele_tb: pitch, A/B, passive FIR/gain/coupling, velocity, repluck, tail fret, STOP, zero velocity");
        $finish;
    end
endmodule
