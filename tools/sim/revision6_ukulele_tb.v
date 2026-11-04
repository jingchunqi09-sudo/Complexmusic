`timescale 1ns/1ps
// Lifecycle/PCM evidence, without a DAC or board claim. 16 stable control clocks.
module revision6_ukulele_tb;
    parameter integer RATE = 48000000;
    reg clk=0,reset=1,tick=0,trigger=0,stop=0;
    reg [6:0] note=69,reference_note=69;
    reg [7:0] velocity=224;
    wire signed [15:0] pcm,reference_pcm,body_pcm,weak_pcm;
    wire ready,reference_ready,body_ready,weak_ready;
    wire [31:0] guards,reference_guards,body_guards;
    integer n,k,fc,peak,body_peak,saved_index,saved_secondary_index;
    integer saved_dc,saved_previous,saved_secondary_previous,tail_differences;
    reg [31:0] saved_period;
    reg [2047:0] path,output_directory;
    reg [63:0] tail_energy,stopped_energy,loud_energy,weak_energy;
    integer a,square;
    always #10 clk=~clk;
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),.OUTPUT_BARE_STRING(1)) dut (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(velocity),.i_stop(stop),
        .o_audio_sample(pcm),.o_ready(ready),.o_guard_count(guards));
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),.OUTPUT_BARE_STRING(1)) reference (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(reference_note),.i_velocity(velocity),.i_stop(1'b0),
        .o_audio_sample(reference_pcm),.o_ready(reference_ready),.o_guard_count(reference_guards));
    // Z models the optional legacy named-port omission; old R5 TB verifies omission.
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE)) body_voice (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(velocity),.i_stop(1'bz),.o_audio_sample(body_pcm),.o_ready(body_ready),.o_guard_count(body_guards));
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),.OUTPUT_BARE_STRING(1)) weak_voice (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(8'd32),.i_stop(stop),.o_audio_sample(weak_pcm),.o_ready(weak_ready),.o_guard_count());
    task sample;
        begin
            repeat(16) @(negedge clk);tick=1;@(negedge clk);tick=0;
            if((^pcm)===1'bx || (^reference_pcm)===1'bx || (^body_pcm)===1'bx)
                $fatal(1,"unknown PCM");
            if(dut.r_delay_index>=dut.r_delay_length_stage2 || dut.r_secondary_delay_index>=dut.r_secondary_length_stage2)
                $fatal(1,"out-of-period RAM address");
            if(pcm==32767 || pcm==-32768 || body_pcm==32767 || body_pcm==-32768)
                $fatal(1,"output clipped");
            if(body_voice.MODAL_BODY.u_body.o_guard_count!=0 || body_voice.MODAL_BODY.u_body.o_clip_count!=0)
                $fatal(1,"modal body guard/clip");
        end
    endtask
    task initialize;
        begin
            reset=1;trigger=0;stop=0;repeat(3) @(negedge clk);
            reset=0;repeat(1050) @(negedge clk);
            if(!ready || !reference_ready || !body_ready || !weak_ready)$fatal(1,"RAM not ready");
        end
    endtask
    task pluck;
        begin
            trigger=1;sample;trigger=0;
            if(velocity!=0 && pcm==0)$fatal(1,"silent first pluck frame");
            if(dut.r_note_period_stage1!=dut.r_target_period)$fatal(1,"target period not committed");
        end
    endtask
    initial begin
        output_directory="sim/results/revision6_ukulele";
        if($value$plusargs("out_dir=%s",output_directory)) begin end
        initialize;pluck;loud_energy=0;weak_energy=0;
        for(n=0;n<1200;n=n+1)begin
            sample;
            square=$signed(pcm)*$signed(pcm);loud_energy=loud_energy+square;
            square=$signed(weak_pcm)*$signed(weak_pcm);weak_energy=weak_energy+square;
        end
        if(loud_energy<=weak_energy*4)$fatal(1,"loud/weak energy response lost");
        saved_period=dut.r_note_period_stage1;
        note=71;velocity=32;
        for(n=0;n<4800;n=n+1) begin
            sample;
            if(pcm!==reference_pcm)$fatal(1,"ordinary fret changed tail sample %0d",n);
            if(dut.r_note_period_stage1!==saved_period)$fatal(1,"ordinary fret retuned active period");
        end
        velocity=224;
        repeat(16) @(negedge clk);
        saved_index=dut.r_delay_index;saved_secondary_index=dut.r_secondary_delay_index;
        saved_dc=dut.r_dc_estimate_q8;
        saved_previous=dut.r_previous_sample;saved_secondary_previous=dut.r_secondary_previous_sample;
        pluck;
        if(dut.r_delay_length_stage2==reference.r_delay_length_stage2)$fatal(1,"next pluck did not retune");
        if(dut.r_older_sample!==saved_previous || dut.r_secondary_older_sample!==saved_secondary_previous)
            $fatal(1,"repluck erased FIR history");
        if(dut.r_dc_estimate_q8!==saved_dc)$fatal(1,"repluck erased DC history");
        if(dut.r_delay_index==1 && saved_index!=0 && saved_index<dut.r_delay_length_stage2-1)
            $fatal(1,"repluck restarted RAM pointer");
        for(n=0;n<12000;n=n+1)sample;
        // STOP has source damping as well as outer envelope semantics.
        tail_energy=0;stopped_energy=0;reference_note=note;
        initialize;pluck;for(n=0;n<4800;n=n+1)sample;
        stop=1;sample;stop=0;
        for(n=0;n<4800;n=n+1)begin
            sample;
            if(n>2400)begin
                square=$signed(pcm)*$signed(pcm);stopped_energy=stopped_energy+square;
                square=$signed(reference_pcm)*$signed(reference_pcm);tail_energy=tail_energy+square;
            end
        end
        if(stopped_energy*100>=tail_energy)$fatal(1,"STOP did not damp physical tail");
        trigger=1;stop=1;sample;trigger=0;stop=0;
        if(dut.r_excitation_remaining!=0 || !dut.r_stopped)$fatal(1,"STOP did not win over pluck");
        pluck;if(dut.r_stopped)$fatal(1,"new pluck did not release stopped state");
        for(n=0;n<1000;n=n+1)sample;
        // Replucks while excitation is unfinished and strong tail survives.
        for(k=0;k<12;k=k+1)begin
            note=69+(k%3);reference_note=note;velocity=255;pluck;
            for(n=0;n<24;n=n+1)sample;
        end
        if(guards!=0 || reference_guards!=0 || body_guards!=0)$fatal(1,"nominal repluck injection guard");
        initialize;velocity=0;pluck;
        for(n=0;n<2048;n=n+1)begin sample;if(pcm!=0 || body_pcm!=0)$fatal(1,"zero velocity audible");end
        // 30-note cold pluck coverage supplies independent FFT measurements.
        for(k=55;k<=84;k=k+1)begin
            note=k;reference_note=k;velocity=255;initialize;pluck;
            $sformat(path,"%0s/n%0d.txt",output_directory,k);fc=$fopen(path,"w");
            if(!fc)$fatal(1,"PCM output failed");peak=0;body_peak=0;
            for(n=0;n<12000;n=n+1)begin
                sample;$fwrite(fc,"%0d %0d\n",$signed(pcm),$signed(body_pcm));
                a=$signed(pcm);if(a<0)a=-a;if(a>peak)peak=a;
                a=$signed(body_pcm);if(a<0)a=-a;if(a>body_peak)body_peak=a;
            end
            $fclose(fc);
            if(peak<20 || body_peak<20)$fatal(1,"silent note %0d",k);
            if(guards!=0 || body_guards!=0)$fatal(1,"nominal note guard %0d",k);
        end
        $display("MEASURE stop_energy=%0d unstopped_energy=%0d control_setup=16clk feedback_pipeline=14clk",stopped_energy,tail_energy);
        $display("MEASURE loud_energy=%0d weak_energy=%0d",loud_energy,weak_energy);
        $display("PASS revision6_ukulele_tb: target lock, exact unchanged tail, retained history, unfinished repluck, STOP, bounds, 30 pitches");
        $finish;
    end
endmodule
