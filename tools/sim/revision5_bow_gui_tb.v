`timescale 1ns/1ps
// Explicitly test the current GUI's normal bow-control area, not only extremes.
module revision5_bow_gui_tb;
    reg clk=0, reset=1, tick=0, trigger=0, gate=0;
    reg [6:0] note=55;
    reg [7:0] pressure=139;
    reg signed [15:0] speed=70;
    wire signed [15:0] raw_pcm, body_pcm;
    wire raw_ready, body_ready;
    integer ni,pi,si,n,f,stick_count,slip_count;
    reg [1023:0] path;
    always #5 clk=~clk;
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000),
        .ENABLE_BODY_FILTER(0)) raw (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(1'b0),
        .i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
        .i_bow_direction(1'b0),.i_bow_position(24'h800000),
        .o_audio_sample(raw_pcm),.o_ready(raw_ready));
    violin_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000)) dut (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(1'b0),
        .i_gate(gate),.i_midi_note(note),.i_velocity(pressure),.i_bow_speed(speed),
        .i_bow_direction(1'b0),.i_bow_position(24'h800000),
        .o_audio_sample(body_pcm),.o_ready(body_ready));
    task sample;
        begin
            repeat(24) @(negedge clk); tick=1; @(negedge clk); tick=0;
            repeat(24) @(negedge clk);
            if((^raw_pcm)===1'bx || (^body_pcm)===1'bx) $fatal(1,"unknown GUI PCM");
            if(raw_pcm==32767 || raw_pcm==-32768 || body_pcm==32767 || body_pcm==-32768)
                $fatal(1,"GUI voice clipped");
            if(dut.MODAL_BODY.u_body.o_guard_count!=0 || dut.MODAL_BODY.u_body.o_clip_count!=0)
                $fatal(1,"GUI body guard fired");
        end
    endtask
    initial begin
        for(ni=0;ni<8;ni=ni+1)
            for(pi=0;pi<4;pi=pi+1)
                for(si=0;si<2;si=si+1) begin
                    note=ni==0?55:ni==1?62:ni==2?69:ni==3?76:
                         ni==4?67:ni==5?74:ni==6?81:88;
                    pressure=pi==0?139:pi==1?160:pi==2?176:192;
                    speed=si==0?70:72;
                    reset=1; trigger=0; gate=0;
                    repeat(3) @(negedge clk); reset=0;
                    repeat(1100) @(negedge clk);
                    if(!raw_ready || !body_ready) $fatal(1,"GUI RAM not ready");
                    gate=1; trigger=1; sample; trigger=0;
                    $sformat(path,"sim/results/revision5_bow/gui/n%0d_p%0d_s%0d.txt",note,pressure,speed);
                    f=$fopen(path,"w"); if(!f) $fatal(1,"GUI PCM dump unavailable");
                    stick_count=0;slip_count=0;
                    for(n=0;n<16000;n=n+1) begin
                        sample;
                        $fwrite(f,"%0d %0d\n",$signed(raw_pcm),$signed(body_pcm));
                        if(n>=4000) begin
                            if(raw.r_contact_sticking) stick_count=stick_count+1;
                            else slip_count=slip_count+1;
                        end
                    end
                    $fclose(f);
                    if(stick_count<12 || slip_count<12) $fatal(1,"GUI contact locked");
                    $display("GUI n%0d p%0d s%0d stick=%0d slip=%0d",note,pressure,speed,stick_count,slip_count);
                end
        $display("PASS revision5_bow_gui_tb: 64 GUI-range cases, no X/rail/modal protection");
        $finish;
    end
endmodule
