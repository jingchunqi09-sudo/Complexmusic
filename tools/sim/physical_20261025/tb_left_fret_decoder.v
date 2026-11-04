`timescale 1ns/1ps
module tb_left_fret_decoder;
    reg clk=0; always #10 clk=~clk;
    reg reset=1;
    reg [191:0] snapshot=0;
    reg snapshot_valid=0;
    reg [1:0] snapshot_string=0;
    wire [19:0] fret_bus;
    wire [3:0] valid_mask;
    wire [1:0] updated_string;
    wire update_valid,multi_key;
    integer frame,s,c,updates=0;
    reg [19:0] before_bus;
    left_hand_fret_decoder dut(
        .clk_50m(clk),.reset(reset),.snapshot(snapshot),
        .snapshot_valid(snapshot_valid),.snapshot_string(snapshot_string),
        .fret_bus(fret_bus),.valid_mask(valid_mask),
        .updated_string(updated_string),.update_valid(update_valid),.multi_key(multi_key)
    );
    function [11:0] quiet;
        input integer string_no;
        input integer channel_no;
        begin quiet=500+string_no*700+channel_no*7;end
    endfunction
    task send;
        input integer string_no;
        input [15:0] mask;
        input integer amplitude;
        integer channel_no,latency;
        reg signed [31:0] v;
        begin
            @(negedge clk);
            for(channel_no=0;channel_no<16;channel_no=channel_no+1) begin
                v=quiet(string_no,channel_no)+(mask[channel_no] ? amplitude : 0);
                snapshot[channel_no*12 +:12]=v[11:0];
            end
            snapshot_string=string_no; snapshot_valid=1;
            @(negedge clk);snapshot_valid=0;latency=0;
            while(!update_valid && latency<60) begin @(posedge clk);#1;latency=latency+1;end
            if(!update_valid || updated_string!==string_no[1:0] || latency!=49)
                $fatal(1,"decoder completion/tag/latency failed s=%0d clocks=%0d",string_no,latency);
            updates=updates+1;
            @(negedge clk);
        end
    endtask
    task expect_fret;
        input integer string_no;
        input integer expected;
        begin
            if(fret_bus[string_no*5 +:5]!==expected[4:0])
                $fatal(1,"fret mismatch string=%0d expected=%0d actual=%0d",string_no,expected,fret_bus[string_no*5 +:5]);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);reset=0;
        // The four electrical baselines differ by 700 LSB. Sharing one set
        // would produce phantom keys even though every string is untouched.
        for(frame=0;frame<16;frame=frame+1) begin
            for(s=0;s<4;s=s+1) begin
                send(s,0,0);
                if(frame<15 && valid_mask[s]) $fatal(1,"calibration became valid too early");
                if(fret_bus!==0) $fatal(1,"startup generated a false fret");
            end
        end
        if(valid_mask!==4'hf) $fatal(1,"four strings did not independently calibrate");
        send(0,16'h8000,200);expect_fret(0,0);
        send(0,16'h8000,200);expect_fret(0,16);
        for(s=1;s<4;s=s+1) expect_fret(s,0);
        send(1,16'h0004,250);expect_fret(1,0);
        send(1,16'h0004,250);expect_fret(1,3);expect_fret(0,16);
        send(2,16'h0100,-300);send(2,16'h0100,-300);expect_fret(2,9);
        send(3,16'h4002,300);send(3,16'h4002,300);
        expect_fret(3,15);
        if(!multi_key) $fatal(1,"multiple held frets not reported");
        // Held keys stay active inside the hysteresis band.
        send(0,16'h8000,80);send(0,16'h8000,80);expect_fret(0,16);
        send(0,16'h8000,64);expect_fret(0,16);
        send(0,16'h8000,64);expect_fret(0,0);
        send(0,16'h8000,80);send(0,16'h8000,80);expect_fret(0,0);
        send(0,16'h8000,96);send(0,16'h8000,96);expect_fret(0,16);
        // Release and a one-frame spike cannot replace a stable fingering.
        send(1,0,0);expect_fret(1,3);send(1,0,0);expect_fret(1,0);
        send(1,16'h0400,500);expect_fret(1,0);
        send(1,0,0);send(1,0,0);expect_fret(1,0);
        // Other strings retain their own states throughout the sequence.
        expect_fret(2,9);expect_fret(3,15);
        @(negedge clk);reset=1;repeat(3) @(negedge clk);reset=0;
        if(valid_mask!==0 || fret_bus!==0) $fatal(1,"reset left stale string states");
        send(2,0,0);
        if(valid_mask!==0 || fret_bus!==0) $fatal(1,"old baseline exposed after reset");
        $display("PASS left fret decoder: %0d snapshots; four baselines,16th fret,negative touch,debounce,hysteresis,highest-fret priority,reset",updates);
        $finish;
    end
    initial begin #5000000;$fatal(1,"timeout");end
endmodule
