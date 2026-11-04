`timescale 1ns/1ps
module video_timing_tb;
    reg clk=0,reset=1;
    wire [10:0] x;
    wire [9:0] y;
    wire de,hs,vs,start;
    integer active_count=0,hs_count=0,vs_count=0,frames=0,n;
    always #5 clk=~clk;
    video_timing_720p dut(.i_clk(clk),.i_reset(reset),.o_x(x),.o_y(y),.o_de(de),.o_hsync(hs),.o_vsync(vs),.o_frame_start(start));
    initial
    begin
        repeat(3) @(negedge clk);reset=0;
        for(n=0;n<1650*750;n=n+1)
        begin
            if(de)active_count=active_count+1;
            if(hs)hs_count=hs_count+1;
            if(vs)vs_count=vs_count+1;
            if(start)frames=frames+1;
            if(x>=1650 || y>=750) $fatal(1,"coordinate out of bounds");
            @(negedge clk);
        end
        if(active_count!=1280*720 || hs_count!=40*750 || vs_count!=5*1650 || frames!=1 || x!=0 || y!=0)
            $fatal(1,"720p frame totals/sync mismatch");
        $display("PASS video_timing_tb: complete frame and sync widths");$finish;
    end
endmodule
