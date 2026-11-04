`timescale 1ns/1ps
module spi_scan_scheduler_tb;
    reg clock=0;
    reg reset=1;
    reg [2:0] enable=0;
    reg [2:0] busy=0;
    reg [2:0] done=0;
    reg [31:0] received0=0;
    reg [31:0] received1=0;
    reg [31:0] received2=0;
    wire [2:0] requests;
    wire frame_valid;
    wire [1:0] frame_channel;
    wire [31:0] frame_data;
    integer error_count=0;
    integer result_count=0;
    reg [2:0] result_seen=0;
    spi_scan_scheduler dut (
        .i_clk(clock),
        .i_reset(reset),
        .i_enable(enable),
        .i_busy0(busy[0]),
        .i_done0(done[0]),
        .i_rx0(received0),
        .i_busy1(busy[1]),
        .i_done1(done[1]),
        .i_rx1(received1),
        .i_busy2(busy[2]),
        .i_done2(done[2]),
        .i_rx2(received2),
        .o_req0(requests[0]),
        .o_req1(requests[1]),
        .o_req2(requests[2]),
        .o_frame_valid(frame_valid),
        .o_frame_channel(frame_channel),
        .o_frame_data(frame_data)
    );
    always #5 clock=~clock;
    task check;
    input condition;
    input [767:0] description;
    begin
        if(condition) $display("PASS: %0s",description);
        else
        begin
            $display("FAIL: %0s",description);
            error_count=error_count+1;
        end
    end
    endtask
    always @(negedge clock) if(!reset && frame_valid)
    begin
        result_count=result_count+1;
        if(result_seen[frame_channel])
        begin
            $display("FAIL: adapter result duplicated");
            error_count=error_count+1;
        end
        result_seen[frame_channel]=1;
        case(frame_channel)
            0: check(frame_data==32'h01234567,"adapter 0 mailbox retained its complete word");
            1: check(frame_data==32'h89ABCDEF,"adapter 1 mailbox retained its complete word");
            2: check(frame_data==32'h2468ACE0,"adapter 2 mailbox retained its complete word");
            default:
            begin
                $display("FAIL: invalid adapter index");
                error_count=error_count+1;
            end
        endcase
    end
    initial
    begin
        repeat(4) @(negedge clock);
        reset=0;
        repeat(3) @(negedge clock);
        check(requests==0,"disabled adapters do not start speculative transactions");
        enable=3'b111;
        @(negedge clock);
        check(requests==3'b111,"all three idle adapters start in parallel");
        busy=3'b111;
        repeat(3) @(negedge clock);
        check(requests==0,"pending busy transfers are not repeatedly requested");
        received0=32'h01234567;
        received1=32'h89ABCDEF;
        received2=32'h2468ACE0;
        done=3'b111;
        enable=0;
        @(negedge clock);
        done=0;
        busy=0;
        received0=0;
        received1=0;
        received2=0;
        repeat(8) @(negedge clock);
        check(result_count==3 && result_seen==3'b111,
        "simultaneous DONE pulses drain all three mailboxes exactly once");
        result_count=0;
        result_seen=0;
        busy=3'b001;
        enable=3'b111;
        @(negedge clock);
        check(requests==3'b110,"one permanently busy adapter does not block the other two");
        busy=3'b111;
        enable=0;
        received1=32'h89ABCDEF;
        received2=32'h2468ACE0;
        done=3'b100;
        @(negedge clock);
        done=0;
        repeat(5) @(negedge clock);
        check(result_count==1 && result_seen==3'b100,"fast adapter 2 completes while adapter 1 remains busy");
        done=3'b010;
        @(negedge clock);
        done=0;
        repeat(5) @(negedge clock);
        check(result_count==2 && result_seen==3'b110,"later adapter 1 result is retained and delivered");
        $display("SPI_SCHEDULER_RESULT: errors=%0d",error_count);
        $finish;
    end
    initial
    begin
        #10000;
        $display("FAIL: SPI scheduler watchdog expired");
        $finish;
    end
endmodule
