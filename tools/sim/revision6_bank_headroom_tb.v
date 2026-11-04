`timescale 1ns/1ps
// Actual eight strings, public bodies and reverb. No forced model samples.
// Unison aligns triggers and same-bank seeds; V/U are different physical models.
module revision6_bank_headroom_tb;
    parameter integer RATE=48828125;
    parameter integer FRAMES=16000;
    parameter integer HEADROOM_SHIFT=2;
    reg clk=0,reset=1,tick=0,event_valid=0;
    reg [55:0] notes;
    reg [7:0] gates=0,triggers=0;
    reg [63:0] velocity;
    reg [127:0] speed;
    reg bypass=1;
    reg [31:0] sequence_number=0;
    wire signed [15:0] pcm;
    wire valid,ready;
    wire [127:0] voices;
    wire [31:0] clips,deadlines;
    wire [15:0] max_clocks;
    integer profile,speed_profile,layout,fx_mode,scenario=0;
    integer n,k,cycles,file_handle,summary_handle,failures=0;
    integer mix_peak,dry_peak,vbody_peak,ubody_peak,a;
    reg [63:0] ukulele_guards;
    real mix_squares,dry_squares,vbody_squares,ubody_squares;
    reg [2047:0] output_directory,path;
    always #10 clk=~clk;
    instrument_bank_core #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE),
                          .MIX_HEADROOM_SHIFT(HEADROOM_SHIFT)) dut(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_event(event_valid),
        .i_event_sequence(sequence_number),.i_event_clock(64'd0),
        .i_note_bus(notes),.i_gate_bus(gates),.i_trigger_bus(triggers),.i_stop_bus(8'd0),
        .i_velocity_bus(velocity),.i_speed_bus(speed),.i_position_bus({8{24'h800000}}),.i_direction_bus(8'd0),
        .i_vibrato_depth(32'd0),.i_vibrato_rate(32'h30303030),.i_glide_ms(32'd0),.i_auto_expression(4'd0),
        .i_emergency(1'b0),.i_fx_bypass(bypass),.i_wet(8'd255),.i_damping(8'd128),.i_tail(2'd3),
        .o_audio_sample(pcm),.o_audio_sample_valid(valid),.o_audio_first_sample(),.o_ready(ready),
        .o_voice_sample_bus(voices),.o_output_sequence(),.o_output_event_clock(),
        .o_output_first_sequence(),.o_output_event_count(),
        .o_body_guards(),.o_body_clips(),.o_reverb_guard(),.o_active_mask(),
        .o_deadline_count(deadlines),.o_max_compute_clocks(max_clocks),.o_clip_count(clips));
    task emit;
        input [7:0] trigger_mask;
        begin
            @(negedge clk);sequence_number=sequence_number+1;triggers=trigger_mask;event_valid=1;
            @(negedge clk);triggers=0;event_valid=0;repeat(4)@(negedge clk);
        end
    endtask
    task frame;
        begin
            if(!ready)$fatal(1,"headroom core not ready");
            @(negedge clk);tick=1;@(negedge clk);tick=0;cycles=0;
            while(!valid)begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>224)$fatal(1,"R9 headroom frame over 224 clocks");
            end
            if(cycles!=224)$fatal(1,"R9 headroom changed commit clock: %0d",cycles);
            if((^pcm)===1'bx||(^voices)===1'bx)$fatal(1,"unknown headroom samples");
            if(deadlines!=0)$fatal(1,"headroom deadline count");
            repeat(8)@(negedge clk);
        end
    endtask
    task measure;
        begin
            a=$signed(pcm);mix_squares=mix_squares+$itor(a)*$itor(a);if(a<0)a=-a;if(a>mix_peak)mix_peak=a;
            a=$signed(dut.r_dry);dry_squares=dry_squares+$itor(a)*$itor(a);if(a<0)a=-a;if(a>dry_peak)dry_peak=a;
            a=$signed(dut.w_body[0]);vbody_squares=vbody_squares+$itor(a)*$itor(a);if(a<0)a=-a;if(a>vbody_peak)vbody_peak=a;
            a=$signed(dut.w_body[1]);ubody_squares=ubody_squares+$itor(a)*$itor(a);if(a<0)a=-a;if(a>ubody_peak)ubody_peak=a;
        end
    endtask
    initial begin
        output_directory="sim/results/revision6_bank_headroom";
        if($value$plusargs("out_dir=%s",output_directory))begin end
        $sformat(path,"%0s/headroom_summary.csv",output_directory);summary_handle=$fopen(path,"w");
        if(!summary_handle)$fatal(1,"headroom summary export");
        $fwrite(summary_handle,"scenario,velocity_profile,bow_speed,unison,fx_enabled,frames,pcm_peak,pcm_rms,dry_peak,dry_rms,vbody_peak,vbody_rms,ubody_peak,ubody_rms,vbody_guard,vbody_clip,ubody_guard,ubody_clip,mix_clip,reverb_guard,max_compute,deadline,ukulele_guard\n");
        for(profile=0;profile<3;profile=profile+1)
        for(speed_profile=0;speed_profile<2;speed_profile=speed_profile+1)
        for(layout=0;layout<2;layout=layout+1)
        for(fx_mode=0;fx_mode<2;fx_mode=fx_mode+1)begin
            reset=1;gates=0;triggers=0;event_valid=0;tick=0;
            notes=layout ? {8{7'd69}} : {7'd73,7'd65,7'd60,7'd68,7'd78,7'd70,7'd63,7'd55};
            case(profile)
                0:velocity={8{8'd32}};
                1:velocity=64'hc0c0c0c080808080;
                2:velocity={8{8'd255}};
            endcase
            speed=speed_profile ? {8{16'd255}} : {8{16'd48}};
            bypass=fx_mode==0;
            mix_peak=0;dry_peak=0;vbody_peak=0;ubody_peak=0;
            mix_squares=0;dry_squares=0;vbody_squares=0;ubody_squares=0;
            repeat(5)@(negedge clk);reset=0;repeat(2200)@(negedge clk);
            if(!ready)$fatal(1,"headroom initialization");
            gates=8'h0f;emit(8'hff);
            $sformat(path,"%0s/scenario_%0d.txt",output_directory,scenario);file_handle=$fopen(path,"w");
            if(!file_handle)$fatal(1,"headroom PCM export");
            for(n=0;n<FRAMES;n=n+1)begin
                // Dense repeated U chords explicitly include live-tail replucks.
                if(n==6000||n==12000)emit(8'hf0);
                frame;measure;
                $fwrite(file_handle,"%0d %0d %0d %0d",$signed(pcm),$signed(dut.r_dry),$signed(dut.w_body[0]),$signed(dut.w_body[1]));
                for(k=0;k<8;k=k+1)$fwrite(file_handle," %0d",$signed(voices[k*16+:16]));
                $fwrite(file_handle,"\n");
            end
            $fclose(file_handle);
            ukulele_guards={32'd0,dut.PHYSICAL_STRING[4].PLUCKED.u_string.o_guard_count}+
                {32'd0,dut.PHYSICAL_STRING[5].PLUCKED.u_string.o_guard_count}+
                {32'd0,dut.PHYSICAL_STRING[6].PLUCKED.u_string.o_guard_count}+
                {32'd0,dut.PHYSICAL_STRING[7].PLUCKED.u_string.o_guard_count};
            $fwrite(summary_handle,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.6f,%0d,%.6f,%0d,%.6f,%0d,%.6f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                scenario,profile,speed_profile ? 255 : 48,layout,fx_mode,FRAMES,
                mix_peak,$sqrt(mix_squares/FRAMES),dry_peak,$sqrt(dry_squares/FRAMES),
                vbody_peak,$sqrt(vbody_squares/FRAMES),ubody_peak,$sqrt(ubody_squares/FRAMES),
                dut.PUBLIC_BODY[0].u_body.o_guard_count,dut.PUBLIC_BODY[0].u_body.o_clip_count,
                dut.PUBLIC_BODY[1].u_body.o_guard_count,dut.PUBLIC_BODY[1].u_body.o_clip_count,
                clips,dut.u_room.o_guard_count,max_clocks,deadlines,ukulele_guards);
            $display("HEADROOM scenario=%0d velocity_profile=%0d speed=%0d unison=%0d fx=%0d peak=%0d rms=%.3f vbody_guard=%0d vbody_clip=%0d ubody_guard=%0d ubody_clip=%0d mix_clip=%0d reverb_guard=%0d ukulele_guard=%0d",
                scenario,profile,speed_profile ? 255 : 48,layout,fx_mode,mix_peak,$sqrt(mix_squares/FRAMES),
                dut.PUBLIC_BODY[0].u_body.o_guard_count,dut.PUBLIC_BODY[0].u_body.o_clip_count,
                dut.PUBLIC_BODY[1].u_body.o_guard_count,dut.PUBLIC_BODY[1].u_body.o_clip_count,
                clips,dut.u_room.o_guard_count,ukulele_guards);
            if(clips!=0||dut.u_room.o_guard_count!=0||ukulele_guards!=0||
                dut.PUBLIC_BODY[0].u_body.o_guard_count!=0||dut.PUBLIC_BODY[0].u_body.o_clip_count!=0||
                dut.PUBLIC_BODY[1].u_body.o_guard_count!=0||dut.PUBLIC_BODY[1].u_body.o_clip_count!=0)failures=failures+1;
            scenario=scenario+1;
        end
        $fclose(summary_handle);
        if(failures!=0)$fatal(1,"headroom guarded scenarios=%0d; all measurements preserved",failures);
        $display("PASS revision6_bank_headroom_tb: 24 velocity/speed/phase/FX conditions, actual eight strings and two bodies");
        $finish;
    end
endmodule
