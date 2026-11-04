`timescale 1ns/1ps
module display_envelope_tb;
    reg sys=0,pixel=0,reset=1,frame_start=0,pcm_valid=0;
    reg signed [15:0] pcm=0;
    reg [7:0] address=0;
    wire signed [15:0] lo,hi;
    wire [15:0] peak,rms;
    wire valid;
    integer n;
    always #10 sys=~sys;
    always #7 pixel=~pixel;
    display_observer_cdc dut (
        .i_sys_clk(sys),.i_sys_reset(reset),.i_pcm_valid(pcm_valid),.i_pcm(pcm),
        .i_notes(28'd0),.i_gates(4'd0),.i_instruments(4'd0),.i_open_notes(64'd0),
        .i_velocities(32'd0),.i_latency_us(32'd0),.i_audio_ready(1'b1),
        .i_bow_speeds(32'd0),.i_bow_positions(96'd0),.i_directions(4'd0),
        .i_pixel_clk(pixel),.i_pixel_reset(reset),.i_frame_start(frame_start),
        .i_wave_address(address),.o_wave_sample(lo),.o_wave_max(hi),.o_peak(peak),.o_rms(rms),.o_capture_valid(valid),
        .o_bow_speeds(),.o_bow_positions(),.o_directions(),.o_notes(),.o_gates(),.o_open_notes(),
        .o_instruments(),.o_velocities(),.o_latency_us(),.o_audio_ready());
    task frame;
        begin
            @(negedge pixel);frame_start=1;
            @(negedge pixel);frame_start=0;
            repeat(6) @(negedge sys);
        end
    endtask
    task capture;
        input integer silent;
        begin
            for(n=0;n<2048;n=n+1)
            begin
                @(negedge sys);pcm=silent ? 0 : n%2 ? -3000 : 1000;pcm_valid=1;
                @(negedge sys);pcm_valid=0;
            end
            repeat(32) @(negedge sys);
        end
    endtask
    initial
    begin
        repeat(5) @(negedge sys);reset=0;
        frame;capture(0);frame;
        if(!valid || peak!=3000 || rms!=2236) $fatal(1,"raw PCM peak/RMS incorrect");
        for(n=0;n<256;n=n+1)
        begin
            address=n;repeat(3) @(negedge pixel);
            if(lo!=-3000 || hi!=1000) $fatal(1,"bin extrema lost");
        end
        capture(1);frame;
        if(peak!=0 || rms!=0) $fatal(1,"silence is not zero");
        $display("PASS display_envelope_tb: 2048 PCM samples, all extrema, exact RMS and silence");$finish;
    end
endmodule
