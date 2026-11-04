`timescale 1ns/1ps
// Real 50 MHz / 115200 UART, actual eight string cores and decoded DAC pins.
module revision6_atomic_top_tb;
    parameter integer EXTERNAL=0;
    reg clk=0,bck=0,reset_n=0,rx=1;
    wire obck,ws,din,pa,event_gpio,audio_gpio;
    integer frames=0,nonzero=0,accepted=0,completed=0,errors=0;
    integer bits=0,bi,k,voice_index,cycles=0,min_latency=2147483647,max_latency=0;
    reg aligned=0,previous_ws=0;
    reg [15:0] shift=0,left=0;
    reg [7:0] packet[0:19];
    reg [15:0] crc;
    reg [31:0] pending_sequence=0;
    reg [31:0] prior_bank_sequence=0,prior_stale=0;
    integer accepted_at[0:255];
    always #10 clk=~clk;
    always #325.520833 bck=~bck;
    tang_mega_60k_top #(.ENABLE_HDMI(0),.USE_EXTERNAL_AUDIO_CLOCK(EXTERNAL)) dut (
        .clk_50m(clk),.audio_bck_in(bck),.reset_n(reset_n),.uart_rx(rx),.uart_tx(),
        .hp_bck(obck),.hp_ws(ws),.hp_din(din),.pa_en(pa),
        .adc0_miso(1'b0),.adc1_miso(1'b0),.adc2_miso(1'b0),
        .latency_event_gpio(event_gpio),.latency_audio_gpio(audio_gpio),
        .adc0_sck(),.adc0_mosi(),.adc0_cs_n(),.adc1_sck(),.adc1_mosi(),.adc1_cs_n(),
        .adc2_sck(),.adc2_mosi(),.adc2_cs_n(),
        .hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable());
    task check;
        input condition;
        input [767:0] message;
        begin
            if(!condition)
            begin
                errors=errors+1;$display("FAIL: %0s",message);
            end
        end
    endtask
    function [15:0] crc_byte;
        input [15:0] c;
        input [7:0] d;
        reg [15:0] v;
        integer j;
        begin
            v=c^{d,8'd0};
            for(j=0;j<8;j=j+1) v=v[15] ? (v<<1)^16'h1021 : v<<1;
            crc_byte=v;
        end
    endfunction
    task byte_out;
        input [7:0] value;
        integer j;
        begin
            @(negedge clk);rx=0;repeat(434)@(negedge clk);
            for(j=0;j<8;j=j+1)
            begin
                rx=value[j];repeat(434)@(negedge clk);
            end
            rx=1;repeat(434)@(negedge clk);
        end
    endtask
    task action;
        input [7:0] op,voice,source;
        input [31:0] epoch;
        input [15:0] seq;
        input [7:0] note,value,pressure,flags;
        begin
            packet[0]=8'ha6;packet[1]=1;packet[2]=op;packet[3]=voice;packet[4]=source;
            packet[5]=epoch[7:0];packet[6]=epoch[15:8];packet[7]=epoch[23:16];packet[8]=epoch[31:24];
            packet[9]=seq[7:0];packet[10]=seq[15:8];packet[11]=note;packet[12]=value;
            packet[13]=pressure;packet[14]=64;packet[15]=flags;packet[16]=0;packet[17]=0;
            crc=16'hffff;
            for(k=0;k<18;k=k+1)crc=crc_byte(crc,packet[k]);
            packet[18]=crc[7:0];packet[19]=crc[15:8];
            for(k=0;k<20;k=k+1)byte_out(packet[k]);
            repeat((seq*73)%1041)@(negedge clk);
        end
    endtask
    always @(negedge clk)
    begin
        cycles=cycles+1;
        if(reset_n && dut.w_bank_event)
        begin
            accepted=accepted+1;pending_sequence=dut.w_bank_sequence;
            accepted_at[dut.w_bank_sequence]=cycles;
        end
        if(reset_n && dut.w_event_word_complete)
        begin
            completed=completed+1;
            check(dut.w_frame_event_sequence==pending_sequence,"complete-frame event sequence matches accepted transaction");
            check(dut.w_frame_first_sequence==pending_sequence && dut.w_frame_event_count==1,
                "nominal UART commit preserves first/last sequence and event count");
            bi=cycles-accepted_at[pending_sequence];
            if(bi<min_latency)min_latency=bi;
            if(bi>max_latency)max_latency=bi;
            check(bi>0 && bi<=5000,"accepted transaction to full tagged stereo frame <=100us");
        end
    end
    always @(posedge obck)
    begin
        if(!reset_n)
        begin
            aligned=0;bits=0;previous_ws=0;
        end
        else
        begin
            if(!aligned && ws && !previous_ws)
            begin
                aligned=1;bits=0;
            end
            if(aligned)
            begin
                check(ws===(bits<16),"PT8211 slot alignment");
                shift={shift[14:0],din};
                if(bits==15)left=shift;
                if(bits==31)
                begin
                    frames=frames+1;
                    check(left===shift,"atomic identical left/right PCM");
                    check(shift===dut.w_frame_pcm,"DAC pins equal frame mailbox PCM");
                    if(shift!=0)nonzero=nonzero+1;
                end
                bits=(bits+1)%32;
            end
            previous_ws=ws;
        end
    end
    initial
    begin
        repeat(10)@(negedge clk);reset_n=1;wait(dut.w_audio_ready);
        repeat(4000)@(negedge clk);
        action(1,0,2,100,0,127,0,0,0);
        action(1,4,3,101,0,127,0,0,0);
        for(voice_index=0;voice_index<4;voice_index=voice_index+1)
        begin
            action(8,voice_index,2,100,voice_index*2+1,127,0,0,0);
            action(3,voice_index,2,100,voice_index*2+2,55+voice_index*7,64,192,3);
        end
        for(voice_index=0;voice_index<4;voice_index=voice_index+1)action(4,4+voice_index,3,101,voice_index+1,60+voice_index*3,192,0,0);
        repeat(50000)@(negedge clk);
        check(dut.w_bank_gates[3:0]==15,"four violin gates independently active alongside ukulele bank");
        check(dut.u_audio_core.o_clip_count==0,"normal eight-core PCM has no mixer clipping");
        action(1,0,1,102,0,127,0,0,0);
        action(3,2,2,100,9,78,128,192,3); // delayed prior owner rejected
        check(dut.w_bank_gates[3:0]==0,"old score cannot restart after human CLAIM");
        action(3,2,1,102,1,69,64,192,3);
        prior_stale=dut.w_stale;prior_bank_sequence=dut.w_bank_sequence;
        // Claims never previously received must still respect this bank's
        // accepted epoch102, including equal epochs from another source.
        action(1,0,2,101,0,127,0,0,0);
        action(1,0,4,101,0,127,0,0,0);
        action(1,0,4,102,0,127,0,0,0);
        check(dut.w_stale==prior_stale+3 && dut.w_bank_sequence==prior_bank_sequence,
            "real UART unseen old/equal CLAIMs are stale without accepted output events");
        check(dut.u_router.r_owner[0]==1 && dut.u_router.r_epoch[0]==102 &&
            dut.w_bank_gates[2] && dut.w_bank_notes[14 +:7]==69,
            "delayed CLAIMs preserve human bank owner, contact and note");
        action(7,0,2,100,10,127,0,0,0); // old STOP rejected
        check(dut.w_bank_gates[2],"old score STOP cannot stop the new human owner");
        action(5,4,3,101,5,71,0,0,0);
        action(6,4,3,101,6,127,0,0,0);
        repeat(5000)@(negedge clk);
        check(accepted==completed,"every nominal accepted UART transaction has one complete tagged frame");
        check(accepted==18 && completed==18 && dut.w_stale==5,
            "18 accepted/completed transactions and five stale UART packets are accounted separately");
        check(nonzero>100 && frames>500,"real model PCM reaches the physical serial pins");
        check(dut.w_audio_underruns==0 && dut.w_audio_overruns==0 && dut.w_core_deadlines==0,
            "nominal output/compute deadlines have no missing or duplicate frames");
        // Withhold three production results: mailbox must zero fill, then recover.
        force dut.w_audio_sample_valid=0;
        repeat(3500)@(negedge clk);
        check(dut.w_audio_underruns>=2,"missing results are counted");
        check(dut.w_frame_pcm==0,"missed deadline sends zero rather than stale bow PCM");
        release dut.w_audio_sample_valid;
        repeat(5000)@(negedge clk);
        check(dut.w_frame_pcm!=0,"mailbox resumes fresh model PCM after missing-result fault");
        $display("ATOMIC_TOP_RESULT: external=%0d errors=%0d accepted=%0d completed=%0d frames=%0d nonzero=%0d latency_min=%0d latency_max=%0d missing=%0d orphan_requests=%0d",EXTERNAL,errors,accepted,completed,frames,nonzero,min_latency,max_latency,dut.w_audio_underruns,dut.w_audio_overruns);
        if(errors)$fatal(1,"atomic top regression");
        $finish;
    end
    initial
    begin
        #100000000;$fatal(1,"atomic top watchdog");
    end
endmodule
