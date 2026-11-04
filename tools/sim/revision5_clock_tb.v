`timescale 1ns/1ps
module revision5_clock_tb;
    reg clk=0, bck=0, reset=1, ready=0;
    reg valid=0, tagged=0, drop_result=0;
    reg signed [15:0] pcm=0;
    wire obck,ws,din,tick,frame_valid,left_done,frame_done,event_done;
    wire signed [15:0] frame_pcm;
    wire [31:0] under,over,sequence;
    integer errors=0,produced=0,loaded=0,events=0,age=0;
    integer countdown=0,completed=0,bit_number;
    reg [15:0] left_word,right_word;
    time last_load=0, first_load=0;
    reg nominal=1;
    integer reset_epoch=0, receive_epoch=0;
    always @(posedge reset) reset_epoch=reset_epoch+1;
    always #10 clk=~clk;
    always #325.520833 bck=~bck;
    pt8211_external_tx dut (
        .i_clk(clk),.i_reset(reset),.i_bck(bck),.i_sample(pcm),
        .i_sample_valid(valid),.i_sample_event(tagged),.i_sample_ready(ready),
        .o_hp_bck(obck),.o_hp_ws(ws),.o_hp_din(din),.o_sample_tick(tick),
        .o_frame_pcm(frame_pcm),.o_frame_pcm_valid(frame_valid),
        .o_left_word_complete(left_done),.o_frame_word_complete(frame_done),
        .o_event_frame_complete(event_done),.o_underrun_count(under),
        .o_overrun_count(over),.o_frame_sequence(sequence));
    task check;
        input condition;
        input [511:0] message;
        begin
            if (!condition) begin errors=errors+1; $display("FAIL: %0s",message); end
        end
    endtask
    // Producer mimics the bounded model/mixer completion, with tag in the same
    // transaction; changing a source while the right word sends must not tear.
    always @(negedge clk)
    begin
        valid=0;
        if(reset) begin countdown=0;produced=0;tagged=0;pcm=0; end
        else if(tick) countdown=18;
        else if(countdown>1) countdown=countdown-1;
        else if(countdown==1)
        begin
            countdown=0;
            if(!drop_result)
            begin
                produced=produced+1; pcm=16'h4100+produced;
                tagged=(produced%7==0); valid=1;
            end
        end
    end
    always @(negedge clk)
    begin
        if(!reset && frame_valid && frame_pcm!=0)
        begin
            loaded=loaded+1;
            check(frame_pcm==(16'h4100+loaded),"monotonic PCM frame, no duplicates or skips");
            if(last_load!=0 && nominal)
                check($time-last_load>=20820 && $time-last_load<=20850,"one model frame per 48kHz output boundary");
            last_load=$time;
        end
        if(!reset && event_done) events=events+1;
        if(!reset && frame_done) completed=completed+1;
    end
    initial forever
    begin
        @(posedge ws);
        receive_epoch=reset_epoch;
        left_word=0;right_word=0;
        for(bit_number=0;bit_number<16;bit_number=bit_number+1)
        begin @(posedge obck);left_word={left_word[14:0],din}; end
        for(bit_number=0;bit_number<16;bit_number=bit_number+1)
        begin @(posedge obck);right_word={right_word[14:0],din}; end
        if(!reset && receive_epoch==reset_epoch)
            check(left_word===right_word,"both physical PT8211 words contain one atomic PCM");
    end
    always @(ws or din)
        if(!reset && dut.r_audio_release[2])
            check(bck==0,"DIN/WS change only while BCK is low");
    initial
    begin
        #137 reset=0;
        // Intentionally wait across startup requests to prove readiness recovery.
        #72000 ready=1;
        wait(loaded>=500);
        #1000;
        check(under==0 && over==0,"continuous nominal output without underrun/overrun");
        check(events==loaded/7 || events+1==loaded/7,"event completion tags follow complete stereo frames");
        $display("CLOCK_NOMINAL: frames=%0d produced=%0d events=%0d underruns=%0d overruns=%0d",loaded,produced,events,under,over);
        nominal=0;drop_result=1;
        #70000;
        check(under>0,"missing producer results counted and zero filled");
        drop_result=0;
        #70000;
        check(frame_pcm!=0,"producer resumes after missing-result fault");
        // Different reset phase; discard partial serial frame and restart tags.
        reset=1; ready=0; #2137;
        loaded=0;events=0;last_load=0; reset=0;ready=1;nominal=1;
        wait(loaded>=100);
        #1000;
        check(under==0 && over==0,"reset restores empty handshake and fault counters");
        $display("PASS revision5_clock_tb: errors=%0d frames=%0d",errors,loaded);
        if(errors) $fatal(1,"external clock CDC regression failed");
        $finish;
    end
    initial begin #30000000; $fatal(1,"external clock watchdog"); end
endmodule
