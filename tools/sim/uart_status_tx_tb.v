`timescale 1ns/1ps
// 独立按 TX 引脚重建 8N1 包，检查两个邮箱竞争、合并标记及采样快照旁路。
module uart_status_tx_tb;
    reg clock = 0;
    reg reset = 1;
    reg publish = 0;
    reg [31:0] latency_cycles = 0;
    reg [31:0] latency_us = 0;
    reg sensor_valid = 0;
    reg [1:0] sensor_adapter = 0;
    reg [31:0] sensor_word = 0;
    reg snapshot_request = 0;
    reg [1:0] snapshot_adapter = 0;
    reg scope_valid = 0;
    wire serial_transmit;
    integer errors = 0;
    integer packet_count = 0;
    integer byte_number;
    reg [7:0] received_byte;
    reg [7:0] received_checksum;
    reg [95:0] received_packet;
    reg [95:0] packets [0:15];

    always #5 clock = ~clock;
    uart_status_tx #(.CLOCK_HZ(1000000), .BAUD_RATE(100000)) dut
    (
        .i_clk(clock),
        .i_reset(reset),
        .i_publish(publish),
        .i_latency_cycles(latency_cycles),
        .i_latency_microseconds(latency_us),
        .i_timeout(1'b0),
        .i_overrun(1'b0),
        .i_frame_error(1'b0),
        .i_audio_ready(1'b1),
        .i_sensor_frame_valid(sensor_valid),
        .i_sensor_adapter(sensor_adapter),
        .i_sensor_word(sensor_word),
        .i_snapshot_request(snapshot_request),
        .i_snapshot_adapter(snapshot_adapter),
        .i_scope_valid(scope_valid),
        .i_scope_pair(32'h7fff8000),
        .i_scope_info(32'h0003027f),
        .o_uart_tx(serial_transmit)
    );
    task check;
        input condition;
        input [767:0] description;
        begin
            if (condition)
                $display("PASS: %0s", description);
            else
            begin
                $display("FAIL: %0s", description);
                errors = errors + 1;
            end
        end
    endtask
    task receive_byte;
        output [7:0] byte_value;
        integer bit_number;
        begin
            @(negedge serial_transmit);
            #50;
            if (serial_transmit !== 1'b0)
            begin
                $display("FAIL: malformed TX start bit");
                errors = errors + 1;
            end
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1)
            begin
                #100;
                byte_value[bit_number] = serial_transmit;
            end
            #100;
            if (serial_transmit !== 1'b1)
            begin
                $display("FAIL: malformed TX stop bit");
                errors = errors + 1;
            end
        end
    endtask
    // 被测 TX 不提供 ready/valid 给此监听器，数据来源仅为真实串行引脚。
    initial
    begin
        wait (!reset);
        forever
        begin
            received_packet = 96'd0;
            received_checksum = 8'd0;
            for (byte_number = 0; byte_number < 12; byte_number = byte_number + 1)
            begin
                receive_byte(received_byte);
                received_packet[byte_number*8 +: 8] = received_byte;
                if (byte_number > 0 && byte_number < 11)
                    received_checksum = received_checksum ^ received_byte;
            end
            check(received_packet[7:0] == 8'hD5 &&
                  received_packet[95:88] == received_checksum,
                  "complete 12-byte status packet has valid header and XOR");
            packets[packet_count] = received_packet;
            packet_count = packet_count + 1;
        end
    end
    initial
    begin
        repeat (4) @(negedge clock);
        reset = 0;
        @(negedge clock);
        // 两生产者同时来：两个 kind 都必须留下；采样也同周期旁路。
        publish = 1;
        latency_cycles = 32'd100;
        latency_us = 32'd2;
        sensor_valid = 1;
        sensor_adapter = 2;
        sensor_word = 32'h11223344;
        snapshot_request = 1;
        snapshot_adapter = 2;
        @(negedge clock);
        // 正好在旧延迟邮箱取出周期提供下一值，不算旧值被覆盖。
        latency_cycles = 32'd200;
        latency_us = 32'd4;
        sensor_valid = 0;
        snapshot_request = 0;
        @(negedge clock);
        publish = 0;
        wait (packet_count == 3);
        check(packets[0][15:8] == 1 && packets[0][55:24] == 100,
              "first latency is immutable after serialization starts");
        check(packets[1][15:8] == 2 && packets[1][55:24] == 32'h11223344 &&
              packets[1][87:56] == 1 && packets[1][22:21] == 2,
              "simultaneous snapshot retains newest sensor word, count and adapter");
        check(packets[2][15:8] == 1 && packets[2][55:24] == 200 && !packets[2][19],
              "publish on mailbox drain preserves next value without false coalescing");

        @(negedge clock);
        publish = 1;
        latency_cycles = 32'd300;
        @(negedge clock);
        publish = 0;
        repeat (4) @(negedge clock);
        // 发送期间对同类邮箱更新；保持两类彼此独立，最新值应有合并标志。
        publish = 1;
        latency_cycles = 32'd400;
        sensor_valid = 1;
        sensor_adapter = 1;
        sensor_word = 32'h55667788;
        snapshot_request = 1;
        snapshot_adapter = 1;
        @(negedge clock);
        latency_cycles = 32'd500;
        sensor_word = 32'hAABBCCDD;
        @(negedge clock);
        publish = 0;
        sensor_valid = 0;
        snapshot_request = 0;
        wait (packet_count == 6);
        check(packets[3][15:8] == 1 && packets[3][55:24] == 300 && !packets[3][19],
              "updates never tear an in-flight latency packet");
        check(packets[4][15:8] == 2 && packets[4][55:24] == 32'hAABBCCDD &&
              packets[4][87:56] == 2 && packets[4][19],
              "snapshot replacements report latest coherent sample and coalescing");
        check(packets[5][15:8] == 1 && packets[5][55:24] == 500 && packets[5][19],
              "latency replacements report latest value and coalescing independently");
        @(negedge clock);
        snapshot_adapter = 3;
        snapshot_request = 1;
        @(negedge clock);
        snapshot_request = 0;
        repeat (1500) @(negedge clock);
        check(packet_count == 6, "invalid snapshot adapter cannot queue a packet");
        @(negedge clock); scope_valid=1;
        @(negedge clock); scope_valid=0;
        wait(packet_count==7);
        check(packets[6][15:8]==3 && packets[6][55:24]==32'h7fff8000 &&
              packets[6][87:56]==32'h0003027f,
              "PCM pair and capture metadata survive serialized kind03 packet");
        $display("UART_STATUS_RESULT: errors=%0d", errors);
        $finish;
    end
    initial
    begin
        #200000;
        $display("FAIL: UART status watchdog expired");
        $finish;
    end
endmodule
