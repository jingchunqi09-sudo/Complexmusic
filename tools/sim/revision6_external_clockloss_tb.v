`timescale 1ns/1ps
// True 50MHz, 115200 UART and independent 1.536MHz BCK, including loss phases.
module revision6_external_clockloss_tb;
    reg clk=0,bck=0,clock_running=1,reset_n=0,rx=1;
    wire tx,pa,hp_bck,hp_ws,hp_din;
    integer errors=0,case_index=0,slot_index,level_index;
    integer slots[0:4];
    integer produced=0,published_id=0,produced_before_resume=0,consumed_id=0;
    reg [15:0] produced_pcm[0:8191];
    time produced_time[0:8191];
    time publication_time=0,resumed_at=0,paused_at=0;
    reg recover=0,require_mute=0,zero_complete=0,fresh_consumed=0,fresh_complete=0;
    integer recovered_frames=0,total_frames=0,nonzero_frames=0;
    reg [15:0] first_fresh_pcm=0;
    reg aligned=0,previous_ws=0;
    integer bit_index=0;
    reg [15:0] serial_shift=0,left_word=0;
    integer diag_count=0,rx_index=0,diag_before=0,k,j;
    reg [7:0] received[0:11],data_byte,checksum;
    reg [31:0] diag_under=0,diag_over=0;
    reg diag_ready=0;
    integer saved_produced=0;
    always #10 clk=~clk;
    always #325.520833 if(clock_running)bck=~bck;
    tang_mega_60k_top #(.ENABLE_HDMI(0),.USE_EXTERNAL_AUDIO_CLOCK(1),.DEFAULT_INSTRUMENTS(0)) dut(
        .clk_50m(clk),.audio_bck_in(bck),.reset_n(reset_n),.uart_rx(rx),.uart_tx(tx),.pa_en(pa),
        .adc0_miso(1'b0),.adc1_miso(1'b0),.adc2_miso(1'b0),
        .adc0_sck(),.adc0_mosi(),.adc0_cs_n(),.adc1_sck(),.adc1_mosi(),.adc1_cs_n(),
        .adc2_sck(),.adc2_mosi(),.adc2_cs_n(),.hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),
        .latency_event_gpio(),.latency_audio_gpio(),
        .hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable());
    task check;
        input condition;input [767:0] message;
        begin if(!condition)begin errors=errors+1;if(errors<=30)$display("FAIL: case=%0d time=%0t %0s",case_index,$time,message);end end
    endtask
    task byte_out;
        input [7:0] value;integer q;
        begin
            @(negedge clk);rx=0;repeat(434)@(negedge clk);
            for(q=0;q<8;q=q+1)begin rx=value[q];repeat(434)@(negedge clk);end
            rx=1;repeat(434)@(negedge clk);
        end
    endtask
    task a5;
        input [7:0] kind,index,note,value,expression;
        begin
            byte_out(8'ha5);byte_out(kind);byte_out(index);byte_out(note);byte_out(value);byte_out(expression);
            byte_out(kind^index^note^value^expression);
        end
    endtask
    task diagnostic;
        input expected_ready;
        begin
            diag_before=diag_count;a5(8'h24,2,0,0,0);
            repeat(100000)@(negedge clk);
            check(diag_count==diag_before+1,"real UART diag2 still responds with BCK paused");
            check(diag_under==dut.w_audio_underruns && diag_over==dut.w_audio_overruns,"D5 under/over bytes match digital counters");
            check(diag_ready===expected_ready,"D5 flag bit4 accurately reports qualified audio ready");
        end
    endtask
    // The active router requires an A6 owner claim before bow events. Legacy
    // A5 BOW no longer establishes the source used by this recovery test.
    function [15:0] crc16;
        input [15:0] c;input [7:0] d;
        reg [15:0] v;integer bit_n;
        begin v=c^{d,8'd0};for(bit_n=0;bit_n<8;bit_n=bit_n+1)
            v=v[15]?(v<<1)^16'h1021:v<<1;crc16=v;end
    endfunction
    task a6_bow;
        input [7:0] opcode;input [15:0] sequence;
        reg [7:0] packet[0:19];reg [15:0] crc;integer q;
        begin
            for(q=0;q<20;q=q+1)packet[q]=0;
            packet[0]=8'ha6;packet[1]=1;packet[2]=opcode;packet[3]=0;packet[4]=2;
            packet[5]=100;packet[9]=sequence[7:0];packet[10]=sequence[15:8];
            packet[11]=69;packet[12]=64;packet[13]=128;packet[14]=64;packet[15]=1;
            crc=16'hffff;for(q=0;q<18;q=q+1)crc=crc16(crc,packet[q]);
            packet[18]=crc[7:0];packet[19]=crc[15:8];
            for(q=0;q<20;q=q+1)byte_out(packet[q]);
        end
    endtask
    // Observe real core publications and mailbox acceptance; never force PCM.
    always @(posedge clk)if(reset_n)begin
        if(dut.w_audio_sample_valid)begin
            produced=produced+1;
            if(produced>=8192)$fatal(1,"clockloss production recorder capacity");
            produced_pcm[produced]=dut.w_audio_sample;produced_time[produced]=$time;
        end
        if(!dut.EXTERNAL_AUDIO.u_external_tx.i_reset && dut.w_audio_sample_valid &&
           dut.EXTERNAL_AUDIO.u_external_tx.r_requested &&
           dut.EXTERNAL_AUDIO.u_external_tx.r_request_sync[2]==dut.EXTERNAL_AUDIO.u_external_tx.r_request_seen)begin
            published_id=produced;publication_time=$time;
        end
    end
    always @(negedge clk)if(reset_n)begin
        if(require_mute)check(pa===1'b1,"PA must remain muted throughout loss and pre-zero recovery");
        if(recover && dut.r_external_audio_qualified && !zero_complete)
            check(0,"qualification occurred before complete receiver zero stereo");
    end
    always @(negedge bck)begin
        if(recover && !fresh_consumed && !dut.EXTERNAL_AUDIO.u_external_tx.i_reset &&
           !dut.EXTERNAL_AUDIO.u_external_tx.w_audio_reset && dut.EXTERNAL_AUDIO.u_external_tx.r_next_bit==0 &&
           dut.EXTERNAL_AUDIO.u_external_tx.r_response_sync[2]!=dut.EXTERNAL_AUDIO.u_external_tx.r_ack_toggle)begin
            consumed_id=published_id;first_fresh_pcm=dut.EXTERNAL_AUDIO.u_external_tx.r_pcm_hold;
            check(zero_complete,"first live mailbox load follows the complete zero stereo frame");
            check(consumed_id>produced_before_resume && produced_time[consumed_id]>=resumed_at && publication_time>=resumed_at,
                  "first resumed PCM is from fresh production, never pre-loss mailbox replay");
            check(first_fresh_pcm===produced_pcm[consumed_id],"first fresh wire word equals observed core production PCM");
            fresh_consumed=1;
        end
    end
    always @(posedge hp_bck)begin
        if(reset_n)begin
            if(!aligned && hp_ws && !previous_ws)begin aligned=1;bit_index=0;end
            if(aligned)begin
                check(hp_ws===(bit_index<16),"receiver WS must keep exact stereo slot boundaries");
                serial_shift={serial_shift[14:0],hp_din};
                if(bit_index==15)left_word=serial_shift;
                if(bit_index==31)begin
                    total_frames=total_frames+1;check(left_word===serial_shift,"receiver left/right PCM are atomic");
                    if(serial_shift!=0)nonzero_frames=nonzero_frames+1;
                    if(recover)begin
                        recovered_frames=recovered_frames+1;
                        if(recovered_frames==1)begin
                            check(left_word===16'd0 && serial_shift===16'd0,"first complete resumed stereo must be zero");
                            zero_complete=1;require_mute=0;
                        end
                        if(recovered_frames==2)begin
                            check(fresh_consumed && serial_shift===first_fresh_pcm,"second resumed stereo carries first fresh production");
                            fresh_complete=1;
                        end
                    end
                end
                bit_index=(bit_index+1)%32;
            end
            previous_ws=hp_ws;
        end
    end
    // Actual 115200 TX decoder; D5 kind4 carries under/over for diagnostic index2.
    initial begin
        wait(reset_n);
        forever begin
            @(negedge tx);#4340;check(!tx,"D5 UART start bit");
            for(j=0;j<8;j=j+1)begin #8680;data_byte[j]=tx;end
            #8680;check(tx,"D5 UART stop bit");
            if(rx_index!=0 || data_byte==8'hd5)begin
                received[rx_index]=data_byte;rx_index=rx_index+1;
                if(rx_index==12)begin
                    checksum=0;for(j=1;j<11;j=j+1)checksum=checksum^received[j];
                    check(checksum==received[11],"D5 checksum verified on physical TX wire");
                    if(received[1]==4 && received[2][3:0]==2)begin
                        diag_under={received[6],received[5],received[4],received[3]};
                        diag_over={received[10],received[9],received[8],received[7]};
                        diag_ready=received[2][4];diag_count=diag_count+1;
                    end
                    rx_index=0;
                end
            end
        end
    end
    task pause_and_resume;
        input integer slot,high_level;
        integer found,wait_cycles;
        begin
            found=0;
            while(!found)begin
                @(negedge bck);#1;
                if(dut.EXTERNAL_AUDIO.u_external_tx.r_next_bit==((slot+1)%32))found=1;
            end
            if(high_level)begin @(posedge bck);#1;end
            clock_running=0;paused_at=$time;
            check(bck===high_level[0],"BCK stopped at requested low/high level");
            repeat(51000)@(negedge clk);
            check(pa && dut.w_audio_clock_lost && !dut.r_external_audio_qualified,"loss mutes PA within1.02ms and dequalifies");
            require_mute=1;saved_produced=produced;
            repeat(51000)@(negedge clk);
            check(produced==saved_produced,"no production requests while actual external clock is absent");
            check(dut.w_bank_gates[0] && dut.u_audio_core.PHYSICAL_STRING[0].BOWED.u_string.r_active,
                  "clock loss preserves source state and owner instead of acting as ALL_STOP");
            diagnostic(1'b0);
            check(dut.w_audio_underruns==0 && dut.w_audio_overruns==0,"physical clock loss is not counted as producer under/over");
            check($time-paused_at>=2000000,"BCK pause lasts at least2ms");
            produced_before_resume=produced;resumed_at=$time;
            aligned=0;previous_ws=0;bit_index=0;serial_shift=0;left_word=0;
            recovered_frames=0;zero_complete=0;fresh_consumed=0;fresh_complete=0;recover=1;clock_running=1;
            wait_cycles=0;
            while(!fresh_complete || pa)begin
                @(negedge clk);wait_cycles=wait_cycles+1;
                if(wait_cycles>7500)$fatal(1,"clockloss normal recovery exceeds150us");
            end
            check(dut.w_audio_underruns==0 && dut.w_audio_overruns==0,"normal fresh recovery introduces no under/over");
            check(consumed_id>produced_before_resume,"fresh production identity strictly advances after resume");
            check(dut.w_audio_status_ready,"qualified audio ready restores after complete fresh frame");
            $display("CLOCKLOSS_CASE slot=%0d high=%0d pause_ns=%0d first_fresh_id=%0d pcm=%0d zero_complete=1 under=%0d over=%0d",
                slot,high_level,resumed_at-paused_at,consumed_id,$signed(first_fresh_pcm),dut.w_audio_underruns,dut.w_audio_overruns);
            recover=0;repeat(6000)@(negedge clk);case_index=case_index+1;
        end
    endtask
    initial begin
        slots[0]=0;slots[1]=7;slots[2]=15;slots[3]=23;slots[4]=31;
        repeat(12)@(negedge clk);reset_n=1;wait(dut.w_audio_ready);repeat(5000)@(negedge clk);
        a6_bow(1,0);a6_bow(3,1);repeat(100000)@(negedge clk);
        check(nonzero_frames>10 && !pa,"live bowed PCM is established before first clock loss");
        for(slot_index=0;slot_index<5;slot_index=slot_index+1)
            for(level_index=0;level_index<2;level_index=level_index+1)pause_and_resume(slots[slot_index],level_index);
        check(diag_count==10,"all ten stopped-clock diagnostic queries completed");
        diagnostic(1'b1);
        check(diag_count==11,"restored ready flag verified on real UART D5 wire");
        check(dut.w_core_deadlines==0 && dut.w_core_clips==0,"clock loss does not corrupt core timing/numerics");
        $display("CLOCKLOSS_RESULT errors=%0d cases=%0d diagnostics=%0d actual_productions=%0d stereo_frames=%0d nonzero=%0d",errors,case_index,diag_count,produced,total_frames,nonzero_frames);
        if(errors)$fatal(1,"external clockloss assertions failed");
        $display("PASS revision6_external_clockloss_tb: phase/level clock loss, persistent mute, complete zero recovery, fresh production identity and real UART diag");$finish;
    end
    initial begin #100000000;$fatal(1,"external clockloss watchdog");end
endmodule
