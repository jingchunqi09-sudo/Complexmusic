`timescale 1ns/1ps
module hdmi_audio_independence_tb;
    reg clk=0,reset_n=0,rx=1;
    wire bck0,ws0,din0,bck1,ws1,din1;
    wire pa0,pa1;
    reg initialized_seen=0;
    integer n,pcm_frames=0,nonzero_frames=0;
    always #10 clk=~clk;
    tang_mega_60k_top #(.ENABLE_HDMI(0)) reference_audio (
        .clk_50m(clk),.audio_bck_in(1'b0),.reset_n(reset_n),.uart_rx(rx),.hp_bck(bck0),.hp_ws(ws0),.hp_din(din0),.pa_en(pa0),
        .adc0_miso(1'b0),.adc1_miso(1'b0),.adc2_miso(1'b0),
        .uart_tx(),.adc0_sck(),.adc0_mosi(),.adc0_cs_n(),.adc1_sck(),.adc1_mosi(),.adc1_cs_n(),
        .adc2_sck(),.adc2_mosi(),.adc2_cs_n(),.latency_event_gpio(),.latency_audio_gpio(),
        .hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable());
    tang_mega_60k_top #(.ENABLE_HDMI(1)) with_video (
        .clk_50m(clk),.audio_bck_in(1'b0),.reset_n(reset_n),.uart_rx(rx),.hp_bck(bck1),.hp_ws(ws1),.hp_din(din1),.pa_en(pa1),
        .adc0_miso(1'b0),.adc1_miso(1'b0),.adc2_miso(1'b0),
        .uart_tx(),.adc0_sck(),.adc0_mosi(),.adc0_cs_n(),.adc1_sck(),.adc1_mosi(),.adc1_cs_n(),
        .adc2_sck(),.adc2_mosi(),.adc2_cs_n(),.latency_event_gpio(),.latency_audio_gpio(),
        .hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable());
    always @(posedge clk)
        initialized_seen<=reset_n && !reference_audio.w_reset && reference_audio.w_audio_ready;
    always @(negedge clk)
        if(reset_n && {bck0,ws0,din0,pa0}!=={bck1,ws1,din1,pa1})
            $fatal(1,"video altered PT8211 bitstream or timing");
    always @(negedge clk)
        if(reset_n && !reference_audio.w_reset && reference_audio.w_audio_ready)
        begin
            if(reference_audio.w_audio_sample_valid!==with_video.w_audio_sample_valid ||
               reference_audio.w_frame_pcm_valid!==with_video.w_frame_pcm_valid ||
               reference_audio.w_frame_pcm!==with_video.w_frame_pcm)
                $fatal(1,"video altered complete PCM frame cadence/content");
            // PA_EN is registered: allow its one-clock transition from cold
            // initialization, then require uninterrupted ordinary operation.
            if(initialized_seen && (pa0 || pa1)) $fatal(1,"amplifier muted during initialized ordinary audio calculation");
            if(reference_audio.w_frame_pcm_valid)
            begin
                pcm_frames=pcm_frames+1;
                if(reference_audio.w_frame_pcm!=0) nonzero_frames=nonzero_frames+1;
            end
        end
    task send_byte;
        input [7:0] data;
        integer bit_number;
        begin
            rx=0;repeat(434) @(negedge clk);
            for(bit_number=0;bit_number<8;bit_number=bit_number+1)
            begin
            rx=data[bit_number];repeat(434) @(negedge clk);
            end
            rx=1;repeat(434) @(negedge clk);
        end
    endtask
    task command;
        input [7:0] kind,index,note,value,expression;
        begin
            send_byte(8'ha5);send_byte(kind);send_byte(index);send_byte(note);
            send_byte(value);send_byte(expression);send_byte(kind^index^note^value^expression);
        end
    endtask
    initial
    begin
        repeat(8) @(negedge clk);reset_n=1;
        repeat(2000) @(negedge clk);
        command(4,0,0,1,0);command(1,0,67,192,0);
        command(4,1,0,0,0);command(2,1,69,64,32);
        command(2,1,69,96,160);command(9,1,0,224,0);
        repeat(5000000) @(negedge clk);
        if(!with_video.VIDEO.u_display.w_capture_valid)
            $fatal(1,"joint run did not complete real-PCM video capture");
        command(3,0,0,0,0);command(2,1,127,0,32);
        repeat(20000) @(negedge clk);
        if(pcm_frames<1000 || nonzero_frames<100) $fatal(1,"audio isolation test did not produce real nonzero PCM");
        if(reference_audio.w_core_deadlines!=0 || with_video.w_core_deadlines!=0 ||
           reference_audio.w_audio_underruns!=0 || with_video.w_audio_underruns!=0)
            $fatal(1,"integrated audio deadline/underrun guard fired");
        $display("PASS hdmi_audio_independence_tb: PT8211 cycle-for-cycle equal, PCM=%0d nonzero=%0d, PA stays enabled, deadlines=0",pcm_frames,nonzero_frames);
        $finish;
    end
endmodule

