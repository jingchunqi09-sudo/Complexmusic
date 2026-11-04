`timescale 1ns/1ps
module audio_scope_capture_tb;
    reg clk=0, reset=1, pcm_valid=0, request=0, capture=0;
    reg [15:0] pcm=0;
    reg [6:0] index=0;
    wire valid;
    wire [31:0] pair_data, info;
    integer count;
    always #5 clk=~clk;
    audio_scope_capture dut (
        .i_clk(clk), .i_reset(reset), .i_pcm_valid(pcm_valid), .i_pcm_sample(pcm),
        .i_request(request), .i_capture(capture), .i_pair_index(index),
        .o_response_valid(valid), .o_sample_pair(pair_data), .o_info(info)
    );
    task read_pair;
        input [6:0] address;
        input start;
        begin
            @(negedge clk); index=address; capture=start; request=1;
            @(negedge clk); request=0; capture=0;
            @(negedge clk);
            if (!valid) $fatal(1,"scope response missing");
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); reset=0;
        read_pair(0,0);
        if(info[9:8] != 0 || pair_data != 0) $fatal(1,"uninitialized RAM exposed");
        read_pair(0,1);
        if(!info[8] || info[9]) $fatal(1,"capture response not busy");
        for(count=0; count<256; count=count+1) begin
            @(negedge clk); pcm_valid=1; pcm=count-128;
        end
        @(negedge clk); pcm_valid=0;
        for(count=0; count<128; count=count+1) begin
            read_pair(count,0);
            if(!info[9] || info[8] || info[31:16]!=1 || info[6:0]!=count)
                $fatal(1,"capture metadata mismatch");
            if($signed(pair_data[15:0])!=2*count-128 || $signed(pair_data[31:16])!=2*count-127)
                $fatal(1,"sample ordering/sign mismatch");
        end
        // Later PCM must never tear a frozen display/export window.
        pcm_valid=1; pcm=30000;
        repeat(300) @(negedge clk); pcm_valid=0;
        read_pair(0,0);
        if(pair_data!=32'hff81ff80) $fatal(1,"frozen capture overwritten");
        read_pair(0,1);
        repeat(10) @(negedge clk);
        read_pair(0,1);
        if(!info[8] || info[9]) $fatal(1,"restart did not invalidate old window");
        $display("SCOPE_RESULT: errors=0");
        $finish;
    end
endmodule
