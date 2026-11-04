`timescale 1ns/1ps
module display_observer_tb;
    reg sys=0,pixel=0,reset=1,frame_start=0,pcm_valid=0;
    reg signed [15:0] pcm=0;
    reg [27:0] notes=28'h1234567;
    reg [63:0] open_notes=64'h0102030405060708;
    wire [63:0] observed_open_notes;
    reg [7:0] address=0;
    wire signed [15:0] wave_sample;
    wire [27:0] observed_notes;
    wire [3:0] gates,instruments;
    wire [31:0] velocities,latency;
    wire ready,valid;
    integer n;
    always #10 sys=~sys;
    always #7 pixel=~pixel;
    display_observer_cdc #(.BIN_SAMPLES(1)) dut (
        .i_sys_clk(sys),.i_sys_reset(reset),.i_pcm_valid(pcm_valid),.i_pcm(pcm),
        .i_notes(notes),.i_gates(4'b1010),.i_instruments(4'b0101),.i_velocities(32'h80402010),
        .i_open_notes(open_notes),.o_open_notes(observed_open_notes),
        .i_bow_speeds(32'h40302010),.i_bow_positions(96'd0),.i_directions(4'b0101),
        .i_latency_us(32'd33),.i_audio_ready(1'b1),
        .i_pixel_clk(pixel),.i_pixel_reset(reset),.i_frame_start(frame_start),.i_wave_address(address),
        .o_wave_sample(wave_sample),.o_notes(observed_notes),.o_gates(gates),.o_instruments(instruments),
        .o_velocities(velocities),.o_latency_us(latency),.o_audio_ready(ready),.o_capture_valid(valid),
        .o_wave_max(),.o_peak(),.o_rms(),.o_bow_speeds(),.o_bow_positions(),.o_directions());
    task video_frame;
        begin
            @(negedge pixel);frame_start=1;
            @(negedge pixel);frame_start=0;
            repeat(6) @(negedge sys);
        end
    endtask
    task capture;
        input integer bias;
        begin
            for(n=0;n<256;n=n+1)
            begin
                @(negedge sys);pcm=n-128+bias;pcm_valid=1;
                @(negedge sys);pcm_valid=0;
            end
            repeat(30) @(negedge pixel);
        end
    endtask
    initial
    begin
        repeat(5) @(negedge sys);reset=0;
        video_frame;
        if(valid) $fatal(1,"uncaptured RAM marked valid");
        capture(0);
        if(valid) $fatal(1,"capture changed visible window before blank");
        video_frame;
        if(!valid || observed_notes!==28'h1234567 || latency!=33 || !ready)
            $fatal(1,"bundled metadata handshake failed");
        // The next capture writes the other bank, frozen bank remains complete.
        for(n=0;n<256;n=n+1)
        begin
            @(negedge pixel);address=n;repeat(2) @(negedge pixel);
            if($signed(wave_sample)!=n-128) $fatal(1,"frozen wave sample mismatch");
        end
        notes=28'h7654321;open_notes=64'hffeeddccbbaa9988;capture(1000);
        if(observed_notes!==28'h1234567) $fatal(1,"metadata tore inside frame");
        address=0;repeat(3) @(negedge pixel);
        if(wave_sample!=-128) $fatal(1,"back bank overwrote front");
        video_frame;
        if(observed_notes!==28'h1234567) $fatal(1,"snapshot must reflect capture-start state");
        if(observed_open_notes!==64'h0102030405060708) $fatal(1,"custom tuning tore inside frozen snapshot");
        address=255;repeat(3) @(negedge pixel);
        if(wave_sample!=1127) $fatal(1,"bank exchange failed");
        $display("PASS display_observer_tb: two unrelated clocks, all samples, frozen banks, bundled controls");
        $finish;
    end
endmodule
