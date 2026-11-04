`timescale 1ns/1ps
// Pixel-for-pixel regression against the SHA-pinned, frozen R5 renderer.
// The reference module is generated from build/frozen_r5_20261004 by the runner.
module revision6_dashboard_tb;
    reg clk=0, reset=1;
    reg [10:0] x=0;
    reg [9:0] y=0;
    reg de=0,hs=0,vs=0;
    reg [27:0] notes={7'd81,7'd69,7'd60,7'd55};
    reg [3:0] gates=4'b1001,instruments=4'b0110,directions=4'b1000;
    reg [63:0] open_notes={8'd69,8'd64,8'd60,8'd67,8'd76,8'd69,8'd62,8'd55};
    reg [31:0] speeds=32'h40000040,velocities=32'hc0804060,latency_us=12345;
    reg [95:0] positions={24'h400000,24'd0,24'd0,24'h800000};
    reg [15:0] peak=8192,rms=4096;
    reg ready=1,capture_valid=1;
    reg signed [15:0] wave_min=0,wave_max=0;
    reg signed [15:0] minima[0:255],maxima[0:255];
    wire [7:0] address,ref_address,r,g,b,ref_r,ref_g,ref_b;
    wire ode,ohs,ovs,ref_de,ref_hs,ref_vs;
    reg [5:0] expected_de=0,expected_hs=0,expected_vs=0;
    reg [10:0] expected_x[0:5];
    reg [9:0] expected_y[0:5];
    reg check_enable=0;
    integer i,j,px,py,profile,compared=0,visible=0,probes=0;
    always #5 clk=~clk;
    instrument_dashboard dut (
        .i_clk(clk),.i_reset(reset),.i_x(x),.i_y(y),.i_de(de),.i_hsync(hs),.i_vsync(vs),
        .i_notes(notes),.i_gates(gates),.i_instruments(instruments),.i_open_notes(open_notes),
        .i_bow_speeds(speeds),.i_bow_positions(positions),.i_directions(directions),
        .i_wave_max(wave_max),.i_peak(peak),.i_rms(rms),.i_velocities(velocities),
        .i_latency_us(latency_us),.i_ready(ready),.i_capture_valid(capture_valid),.i_wave_sample(wave_min),
        .o_wave_address(address),.o_red(r),.o_green(g),.o_blue(b),.o_de(ode),.o_hsync(ohs),.o_vsync(ovs));
    instrument_dashboard_r5 reference (
        .i_clk(clk),.i_reset(reset),.i_x(x),.i_y(y),.i_de(de),.i_hsync(hs),.i_vsync(vs),
        .i_notes(notes),.i_gates(gates),.i_instruments(instruments),.i_open_notes(open_notes),
        .i_bow_speeds(speeds),.i_bow_positions(positions),.i_directions(directions),
        .i_wave_max(wave_max),.i_peak(peak),.i_rms(rms),.i_velocities(velocities),
        .i_latency_us(latency_us),.i_ready(ready),.i_capture_valid(capture_valid),.i_wave_sample(wave_min),
        .o_wave_address(ref_address),.o_red(ref_r),.o_green(ref_g),.o_blue(ref_b),
        .o_de(ref_de),.o_hsync(ref_hs),.o_vsync(ref_vs));
    always @(posedge clk)
    begin
        wave_min<=minima[address];wave_max<=maxima[address];
        if(reset)
        begin
            expected_de<=0;expected_hs<=0;expected_vs<=0;
            for(j=0;j<6;j=j+1) begin expected_x[j]<=0;expected_y[j]<=0;end
        end
        else
        begin
            expected_de<={expected_de[4:0],de};expected_hs<={expected_hs[4:0],hs};
            expected_vs<={expected_vs[4:0],vs};expected_x[0]<=x;expected_y[0]<=y;
            for(j=1;j<6;j=j+1)
            begin expected_x[j]<=expected_x[j-1];expected_y[j]<=expected_y[j-1];end
        end
    end
    always @(negedge clk)
        if(check_enable)
        begin
            if(address!==ref_address) $fatal(1,"wave RAM address changed");
            if({ode,ohs,ovs}!=={expected_de[5],expected_hs[5],expected_vs[5]})
                $fatal(1,"DE/HS/VS no longer have six pixel clocks of latency");
            if({ode,ohs,ovs,r,g,b}!=={ref_de,ref_hs,ref_vs,ref_r,ref_g,ref_b})
                $fatal(1,"R5/R6 pixel mismatch profile=%0d x=%0d y=%0d R6=%h R5=%h",
                    profile,expected_x[5],expected_y[5],{r,g,b},{ref_r,ref_g,ref_b});
            if(!ode && {r,g,b}!==24'd0) $fatal(1,"RGB is not black during blanking");
            compared=compared+1;
            if(ode) visible=visible+1;
        end
    task drive;
        input [10:0] nx;
        input [9:0] ny;
        input nd,nh,nv;
        begin @(negedge clk);x=nx;y=ny;de=nd;hs=nh;vs=nv;end
    endtask
    task probe;
        input [10:0] nx;
        input [9:0] ny;
        input [23:0] colour;
        begin
            repeat(8) drive(nx,ny,1'b1,1'b0,1'b0);
            #1;
            if({r,g,b}!==colour)
                $fatal(1,"boundary pixel x=%0d y=%0d expected=%h got=%h",nx,ny,colour,{r,g,b});
            probes=probes+1;
        end
    endtask
    initial
    begin
        for(i=0;i<256;i=i+1)
        begin minima[i]=-((i*17)%8192);maxima[i]=(i*31)%8192;end
        repeat(3) @(negedge clk);reset=0;
        repeat(180) drive(0,740,0,0,0);
        check_enable=1;
        for(profile=0;profile<2;profile=profile+1)
        begin
            if(profile==1)
            begin
                // Out-of-range fret, zero-speed contact, opposite bow direction,
                // 0/max velocity, saturated latency and rail warning labels.
                notes={7'd88,7'd69,7'd61,7'd54};gates=4'b0110;instruments=0;
                directions=4'b0101;speeds=32'h004000ff;positions={24'hfe0000,24'h800000,24'h100000,24'd0};
                velocities=32'hff008001;latency_us=32'hffffffff;peak=32768;rms=12345;ready=0;
                for(i=0;i<256;i=i+1)
                begin minima[i]=-32768+i*73;maxima[i]=32767-i*53;end
                // Metadata is a frame-frozen observer snapshot. Settle in blank.
                check_enable=0;repeat(180) drive(0,740,0,0,0);check_enable=1;
            end
            for(py=0;py<750;py=py+1)
                for(px=0;px<1650;px=px+1)
                    drive(px,py,px<1280 && py<720,px>=1390 && px<1430,py>=725 && py<730);
            repeat(8) drive(0,740,0,0,0);
            $display("FRAME profile=%0d compared=%0d visible=%0d",profile,compared,visible);
        end
        // Public-coordinate checks are independent of the frozen reference.
        check_enable=0;
        notes={7'd81,7'd69,7'd60,7'd55};gates=4'b1001;instruments=4'b0110;
        directions=4'b1000;speeds=32'h40000040;positions={24'h400000,24'd0,24'd0,24'h800000};
        velocities=32'hc0804060;latency_us=12345;peak=8192;rms=4096;ready=1;
        repeat(180) drive(0,740,0,0,0);check_enable=1;
        probe(425,714,24'hce485c);probe(426,714,24'h5eb66c);
        probe(851,714,24'h5eb66c);probe(852,714,24'h548acb);
        probe(1279,719,24'h548acb);
        probe(60,86,24'hd7e8ee);probe(59,86,24'h101a2b);probe(62,86,24'h101a2b);
        probe(152,128,24'h39485e);probe(154,128,24'h101a2b);
        probe(156,134,24'h65bdff);probe(168,134,24'h101a2b);
        // Bow contact/wood overlap must preserve the wood foot priority.
        probe(951,155,24'hfff3c4);probe(951,156,24'hbe8e61);
        probe(1100,134,24'h6fcabf);probe(1148,134,24'h101a2b);
        // Independent sync edges and reset flush, including active-video reset.
        for(i=0;i<32;i=i+1) drive(i*41,i*23, i[0], i[1], i[2]);
        check_enable=0;@(negedge clk);reset=1;
        repeat(3) @(negedge clk);
        if({ode,ohs,ovs,r,g,b}!==0) $fatal(1,"reset did not blank output");
        reset=0;repeat(180) drive(0,740,0,0,0);check_enable=1;
        repeat(32) drive(1279,719,1,1,1);
        $display("PASS revision6_dashboard_tb: compared=%0d visible=%0d probes=%0d latency=6",compared,visible,probes);
        $finish;
    end
endmodule
