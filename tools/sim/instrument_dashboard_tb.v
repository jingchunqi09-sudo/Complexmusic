`timescale 1ns/1ps
module instrument_dashboard_tb;
    reg clk=0,reset=1;
    wire [10:0] x;
    wire [9:0] y;
    wire de,hs,vs,start;
    wire [7:0] address,r,g,b;
    wire ode,ohs,ovs;
    reg signed [15:0] wave_sample=0;
    reg signed [15:0] wave_max=0;
    reg [15:0] measured_peak=0,measured_rms=0;
    reg signed [15:0] maxima[0:255];
    reg signed [15:0] raw_pcm;
    reg signed [31:0] pcm_square;
    reg [63:0] square_sum=0;
    integer j;
    reg [31:0] latency_us=33;
    reg [63:0] open_notes={8'd69,8'd64,8'd60,8'd67,8'd76,8'd69,8'd62,8'd55};
    reg signed [15:0] samples[0:255];
    integer file_handle,infile,n,code,pixels=0;
    reg [10:0] expected_x[0:5];
    reg [9:0] expected_y[0:5];
    reg [5:0] expected_de=0,expected_hs=0,expected_vs=0;
    integer pixel_stage;
    always #5 clk=~clk;
    video_timing_720p timing(.i_clk(clk),.i_reset(reset),.o_x(x),.o_y(y),.o_de(de),.o_hsync(hs),.o_vsync(vs),.o_frame_start(start));
    instrument_dashboard dut (
        .i_clk(clk),.i_reset(reset),.i_x(x),.i_y(y),.i_de(de),.i_hsync(hs),.i_vsync(vs),
        .i_notes({7'd81,7'd69,7'd60,7'd55}),.i_gates(4'b1001),.i_instruments(4'b0110),
        .i_open_notes(open_notes),
        .i_bow_speeds(32'h40000040),.i_bow_positions({24'h400000,24'd0,24'd0,24'h800000}),.i_directions(4'b1000),
        .i_wave_max(wave_max),.i_peak(measured_peak),.i_rms(measured_rms),
        .i_velocities(32'hc0804060),.i_latency_us(latency_us),.i_ready(1'b1),.i_capture_valid(1'b1),
        .i_wave_sample(wave_sample),.o_wave_address(address),.o_red(r),.o_green(g),.o_blue(b),
        .o_de(ode),.o_hsync(ohs),.o_vsync(ovs));
    always @(posedge clk) begin wave_sample<=samples[address];wave_max<=maxima[address];end
    // RAM alignment, geometry hits, geometry colour, digit priority, text, output.
    // All three video control bits and glyph pixels must have the same delay.
    always @(posedge clk)
    begin
        if(reset)
        begin
            expected_de<=0;expected_hs<=0;expected_vs<=0;
            for(pixel_stage=0;pixel_stage<6;pixel_stage=pixel_stage+1)
            begin expected_x[pixel_stage]<=0;expected_y[pixel_stage]<=0;end
        end
        else
        begin
            expected_de<={expected_de[4:0],de};
            expected_hs<={expected_hs[4:0],hs};
            expected_vs<={expected_vs[4:0],vs};
            expected_x[0]<=x;expected_y[0]<=y;
            for(pixel_stage=1;pixel_stage<6;pixel_stage=pixel_stage+1)
            begin expected_x[pixel_stage]<=expected_x[pixel_stage-1];expected_y[pixel_stage]<=expected_y[pixel_stage-1];end
        end
    end
    initial
    begin
        infile=$fopen("sim/results/violin_a4_prototype_samples.txt","r");
        if(!infile) $fatal(1,"missing real RTL PCM input");
        for(n=0;n<3000;n=n+1) code=$fscanf(infile,"%d\n",raw_pcm);
        for(n=0;n<256;n=n+1)
        begin
            samples[n]=32767;maxima[n]=-32768;
            for(j=0;j<8;j=j+1)
            begin
                code=$fscanf(infile,"%d\n",raw_pcm);
                if(code!=1) $fatal(1,"incomplete real PCM window");
                if(raw_pcm<samples[n]) samples[n]=raw_pcm;
                if(raw_pcm>maxima[n]) maxima[n]=raw_pcm;
                if((raw_pcm<0 ? -raw_pcm : raw_pcm)>measured_peak) measured_peak=raw_pcm<0 ? -raw_pcm : raw_pcm;
                pcm_square=$signed(raw_pcm)*$signed(raw_pcm);
                square_sum=square_sum+{32'd0,pcm_square};
            end
        end
        measured_rms=$rtoi($sqrt(square_sum/2048));
        if(measured_rms>measured_peak) $fatal(1,"RMS exceeds peak");
        $display("DASHBOARD_STATS peak=%0d rms=%0d",measured_peak,measured_rms);
        $fclose(infile);
        file_handle=$fopen("sim/results/dashboard.ppm","w");
        $fwrite(file_handle,"P3\n1280 720\n255\n");
        repeat(3) @(negedge clk);reset=0;
        for(n=0;n<1650*750;n=n+1)
        begin
            @(negedge clk);
            if(ode!==expected_de[5] || ohs!==expected_hs[5] || ovs!==expected_vs[5])
                $fatal(1,"RGB and video control pipeline are not aligned");
            if(ode)
            begin
                if((^{r,g,b})===1'bx) $fatal(1,"unknown RGB");
                if(expected_y[5]>=714 && {r,g,b}!==
                   (expected_x[5]<426 ? 24'hce485c:expected_x[5]<852 ? 24'h5eb66c:24'h548acb))
                    $fatal(1,"colour-bar pixel shifted relative to DE");
                if(expected_y[5]==86 && expected_x[5]==60 && {r,g,b}!==24'hd7e8ee)
                    $fatal(1,"MIDI label glyph shifted relative to geometry");
                if(expected_y[5]==86 && (expected_x[5]==59 || expected_x[5]==62) && {r,g,b}!==24'h101a2b)
                    $fatal(1,"MIDI label paints outside its expected glyph column");
                $fwrite(file_handle,"%0d %0d %0d\n",r,g,b);pixels=pixels+1;
            end
        end
        $fclose(file_handle);
        if(pixels!=1280*720) $fatal(1,"RGB pixel count mismatch");
        if(dut.number_pixel(8,5,-1)) $fatal(1,"digit paints above its bounding box");
        if(dut.r_latency_digits!==20'h00033) $fatal(1,"latency BCD mismatch");
        latency_us=12345;repeat(120) @(negedge clk);
        if(dut.r_latency_digits!==20'h12345) $fatal(1,"five-digit conversion mismatch");
        latency_us=32'hffffffff;repeat(120) @(negedge clk);
        if(dut.r_latency_digits!==20'h99999) $fatal(1,"latency overflow not clamped");
        latency_us=0;repeat(120) @(negedge clk);
        if(dut.r_latency_digits!==0) $fatal(1,"zero latency BCD mismatch");
        // Drive the public timing coordinates; geometry may predecode before
        // the old internal r_x register. Allow the complete pixel pipeline.
        force x=11'd516;force y=10'd134;
        repeat(8) @(negedge clk);
        if({r,g,b}===24'h65bdff) $fatal(1,"default tuning marker should not be at fret five");
        open_notes[7:0]=50;repeat(8) @(negedge clk);
        if({r,g,b}!==24'h65bdff) $fatal(1,"custom tuning does not move fret marker");
        release x;release y;
        $display("PASS instrument_dashboard_tb: real PCM rendered, 921600 known pixels");$finish;
    end
endmodule

