`timescale 1ns/1ps
// 用较快波特率检查命令/寄存器边界；整机 TB 另测实际 50 MHz / 115200 配置。
module uart_config_tb;
    reg clock = 0;
    reg reset = 1;
    reg uart_rx = 1;
    reg sample_tick = 0;
    wire [63:0] active_open_notes;
    wire [27:0] note_bus;
    wire [3:0] gate_bus;
    wire [3:0] pluck_bus;
    wire [3:0] stop_bus;
    wire [3:0] instrument_bus;
    wire [3:0] direction_bus;
    wire [31:0] velocity_bus;
    wire [31:0] bow_speed_bus;
    wire [95:0] bow_position_bus;
    wire event_pulse;
    wire frame_error;
    wire scope_request, scope_capture;
    wire [6:0] scope_index;
    integer scope_requests=0;
    wire tuning_write;
    wire tuning_commit;
    wire [2:0] tuning_address;
    wire [7:0] tuning_note;
    wire spi_write;
    wire [1:0] spi_adapter;
    wire [2:0] spi_field;
    wire [15:0] spi_value;
    wire [2:0] spi_enable;
    wire [2:0] spi_cpol;
    wire [2:0] spi_cpha;
    wire [47:0] spi_dividers;
    wire [17:0] spi_commands_width;
    wire [17:0] spi_responses_width;
    wire [95:0] spi_commands;
    reg tuning_commit_pending = 0;
    integer event_count = 0;
    integer pluck_count = 0; // 逐周期观察脉冲，避免帧结束时已经清零而漏检。
    integer stop_count = 0;
    reg [3:0] stopped_strings = 0; // 逐周期累计显式停止对应的物理弦。
    integer error_count = 0;
    integer previous_event_count;
    always #500 clock = ~clock;
    uart_event_bridge #(.CLOCK_HZ(1000000),
        .BAUD_RATE(100000),
        .BOW_TIMEOUT_MS(5)) bridge (
        .i_clk(clock),
        .i_reset(reset),
        .i_uart_rx(uart_rx),
        .i_open_notes(active_open_notes),
        .o_note_bus(note_bus),
        .o_gate_bus(gate_bus),
        .o_pluck_pulse_bus(pluck_bus),
        .o_stop_pulse_bus(stop_bus),
        .o_velocity_bus(velocity_bus),
        .o_bow_speed_bus(bow_speed_bus),
        .o_bow_position_bus(bow_position_bus),
        .o_direction_bus(direction_bus),
        .o_instrument_select_bus(instrument_bus),
        .o_event_pulse(event_pulse),
        .o_frame_error(frame_error),
        .o_tuning_write(tuning_write),
        .o_tuning_address(tuning_address),
        .o_tuning_note(tuning_note),
        .o_tuning_commit(tuning_commit),
        .o_spi_profile_write(spi_write),
        .o_spi_adapter(spi_adapter),
        .o_spi_field(spi_field),
        .o_spi_value(spi_value),
        .o_status_request(),
        .o_sensor_snapshot_request(),
        .o_scope_request(scope_request),
        .o_scope_capture(scope_capture),
        .o_scope_index(scope_index),
        .o_sensor_snapshot_adapter()
    );
    instrument_config_bank tuning (
        .i_clk(clock),
        .i_reset(reset),
        .i_write_valid(tuning_write),
        .i_write_addr(tuning_address),
        .i_write_data(tuning_note),
        .i_commit(tuning_commit_pending && sample_tick),
        .o_active_open_notes(active_open_notes),
        .o_commit_ack()
    );
    spi_profile_bank profiles (
        .i_clk(clock),
        .i_reset(reset),
        .i_write_valid(spi_write),
        .i_adapter(spi_adapter),
        .i_field(spi_field),
        .i_data(spi_value),
        .o_enable(spi_enable),
        .o_cpol(spi_cpol),
        .o_cpha(spi_cpha),
        .o_clock_dividers(spi_dividers),
        .o_command_widths(spi_commands_width),
        .o_response_widths(spi_responses_width),
        .o_command_words(spi_commands)
    );
    always @(posedge clock)
    begin
        if (reset) tuning_commit_pending <= 0;
        else if (tuning_commit) tuning_commit_pending <= 1;
        else if (sample_tick) tuning_commit_pending <= 0;
    end
    always @(posedge event_pulse) event_count = event_count + 1;
    always @(posedge clock) if(scope_request) scope_requests=scope_requests+1;
    always @(posedge clock)
    begin
        if (!reset && (|pluck_bus))
            pluck_count = pluck_count + 1;
        if (!reset && (|stop_bus))
        begin
            stop_count = stop_count + 1;
            stopped_strings = stopped_strings | stop_bus;
        end
    end
    task check;
    input condition;
    input [767:0] description;
    begin
        if (condition) $display("PASS: %0s", description);
        else
        begin
            $display("FAIL: %0s", description);
            error_count=error_count+1;
        end
    end
    endtask
    task send_byte;
    input [7:0] data;
    integer bit_number;
    begin
        @(negedge clock);
        uart_rx=0;
        repeat(10) @(negedge clock);
        for(bit_number=0;bit_number<8;bit_number=bit_number+1)
        begin
            uart_rx=data[bit_number];
            repeat(10) @(negedge clock);
        end
        uart_rx=1;
        repeat(10) @(negedge clock);
    end
    endtask
    task send_frame;
    input [7:0] kind;
    input [7:0] index;
    input [7:0] note;
    input [7:0] value;
    input [7:0] expression;
    input [7:0] checksum_error;
    begin
        send_byte(8'hA5);
        send_byte(kind);
        send_byte(index);
        send_byte(note);
        send_byte(value);
        send_byte(expression);
        send_byte(kind^index^note^value^expression^checksum_error);
        repeat(4) @(negedge clock);
    end
    endtask
    task send_bad_stop_byte;
    input [7:0] data;
    integer bit_number;
    begin
        @(negedge clock);
        uart_rx=0;
        repeat(10) @(negedge clock);
        for(bit_number=0;bit_number<8;bit_number=bit_number+1)
        begin
            uart_rx=data[bit_number];
            repeat(10) @(negedge clock);
        end
        uart_rx=0;
        repeat(10) @(negedge clock);
        uart_rx=1;
        repeat(20) @(negedge clock);
    end
    endtask
    task commit_at_frame;
    begin
        @(negedge clock);
        sample_tick=1;
        @(negedge clock);
        sample_tick=0;
        @(negedge clock);
    end
    endtask
    task reset_all;
    begin
        @(negedge clock);
        reset=1;
        repeat(4) @(negedge clock);
        reset=0;
        event_count=0;
        pluck_count=0;
        stop_count=0;
        stopped_strings=0;
        repeat(4) @(negedge clock);
    end
    endtask
    initial
    begin
        reset_all;
        check(note_bus == {7'd69,7'd69,7'd60,7'd55}, "reset notes follow each string's default violin/ukulele mode");
        check(spi_enable == 0, "all SPI adapters remain disabled until configured");
        send_frame(8'h01,0,60,200,0,1);
        check(frame_error && event_count==0, "bad checksum does not emit a musical event");
        reset_all;
        send_frame(8'hEE,0,60,200,0,0);
        check(frame_error && event_count==0, "unknown frame type does not emit a musical event");
        reset_all;
        send_byte(8'hA5);
        send_byte(8'h01);
        repeat(51000) @(negedge clock);
        check(frame_error && event_count==0, "partial UART frame times out without a musical event");
        send_frame(8'h01,1,60,200,0,0);
        check(event_count==1 && note_bus[13:7]==60, "parser resynchronizes after the partial-frame timeout");
        reset_all;
        send_byte(8'hA5);
        send_bad_stop_byte(8'h01);
        check(frame_error && event_count==0, "invalid stop bit discards the partial command");
        send_frame(8'h01,1,61,200,0,0);
        check(event_count==1 && note_bus[13:7]==61, "valid frame recovers after an invalid stop bit");
        reset_all;
        send_frame(8'h05,0,58,0,0,0);
        send_frame(8'h05,4,43,0,0,0);
        check(active_open_notes[7:0]==55 && active_open_notes[39:32]==67,
        "two tuning writes remain in shadow registers");
        send_frame(8'h06,0,0,0,0,0);
        check(active_open_notes[7:0]==55 && active_open_notes[39:32]==67,
        "UART commit request waits for the audio frame boundary");
        commit_at_frame;
        check(active_open_notes[7:0]==58 && active_open_notes[39:32]==43,
        "both instrument tuning changes become active atomically");
        check(event_count==0, "tuning configuration writes do not masquerade as musical events");
        send_frame(8'h04,0,127,0,0,0);
        check(note_bus[6:0]==55 && !instrument_bus[0], "repeated TIMBRE preserves pitch after tuning commit; FRET uses the new table");
        send_frame(8'h07,0,12,0,0,0);
        check(note_bus[6:0]==70, "fret 12 adds an octave to the shared left-hand tuning");
        send_frame(8'h01,0,127,100,0,0);
        check(note_bus[6:0]==70, "pluck note=127 preserves the latest fret-selected note");
        send_frame(8'h02,0,127,64,8'hC0,0);
        check(note_bus[6:0]==70 && gate_bus[0] && bow_speed_bus[7:0]==64,
        "bow note=127 preserves pitch and updates speed/gate");
        check(bow_position_bus[23:0]==24'h800000 && direction_bus[0],
        "bow position maps seven bits to Q0.24 independently of direction");
        send_frame(8'h04,0,127,1,0,0);
        check(note_bus[6:0]==43 && instrument_bus[0], "ukulele mode selects its separate active custom tuning");
        send_frame(8'h07,0,12,0,0,0);
        check(note_bus[6:0]==55, "same fret number uses the selected instrument tuning");
        previous_event_count=event_count;
        send_frame(8'h08,0,72,0,0,0);
        check(note_bus[6:0]==72 && pluck_bus==0 && event_count==previous_event_count+1,
        "NOTE_SET changes absolute pitch without retriggering a pluck");
        previous_event_count=event_count;
        send_frame(8'h10,2,2,8'hCD,8'hAB,0);
        send_frame(8'h10,2,1,3,0,0);
        send_frame(8'h10,2,0,1,0,0);
        send_frame(8'h10,2,3,8'h18,8'h20,0);
        send_frame(8'h10,2,4,8'hEF,8'hBE,0);
        send_frame(8'h10,2,5,8'h5A,8'hC3,0);
        check(spi_dividers[47:32]==16'hABCD, "SPI UART profile preserves both bytes of a 16-bit divider");
        check(spi_cpol[2] && spi_cpha[2] && spi_enable[2], "SPI UART profile selects mode 3 and enables adapter 2");
        check(spi_commands_width[17:12]==24 && spi_responses_width[17:12]==32,
        "SPI UART profile independently sets command and receive widths");
        check(spi_commands[95:64]==32'hC35ABEEF, "SPI command high/low writes reconstruct the 32-bit command");
        check(event_count==previous_event_count, "SPI configuration frames do not emit musical events");
        check(!frame_error, "all supported valid configuration frames remain error-free");
        send_frame(8'h10,2,3,0,0,0);
        check(spi_commands_width[17:12]==1 && spi_responses_width[17:12]==1,
        "zero command/response widths consistently clamp to one bit");
        reset_all;
        send_frame(8'h02,0,69,64,64,0);
        repeat(3000) @(negedge clock);
        send_frame(8'h02,0,127,80,64,0);
        repeat(3000) @(negedge clock);
        check(gate_bus[0] && bow_speed_bus[7:0]==80,
        "periodic BOW refresh keeps sustained violin gate alive");
        repeat(2500) @(negedge clock);
        check(!gate_bus[0] && bow_speed_bus[7:0]==0,
        "missing BOW refresh releases gate and clears speed at watchdog timeout");
        check(stop_count==0,
              "BOW watchdog releases motion without emitting a ukulele stop command");

        reset_all;
        send_frame(8'h01,1,60,200,0,0);
        previous_event_count=event_count;
        send_frame(8'h03,1,0,0,0,0);
        check(stop_count==1 && stopped_strings==4'b0010 && event_count==previous_event_count+1,
              "explicit STOP emits exactly one stop pulse for the addressed string");
        check(pluck_count==1 && velocity_bus[15:8]==200 && !gate_bus[1],
              "STOP neither retriggers pluck nor alters the stored velocity");
        repeat(10) @(negedge clock);
        check(stop_count==1 && stop_bus==0,
              "STOP returns to zero and cannot repeat without another command");
        previous_event_count=event_count;
        send_frame(8'h03,4,0,0,0,0);
        check(frame_error && stop_count==1 && event_count==previous_event_count,
              "unsupported STOP string cannot emit a stop pulse or event");

        // 压力独立于弓运动；在原 BOW 到期前调整压力也不能推迟停弓。
        reset_all;
        send_frame(8'h02,0,69,64,8'hC0,0);
        previous_event_count=event_count;
        send_frame(8'h09,0,255,192,255,0);
        check(velocity_bus[7:0]==192 && event_count==previous_event_count+1,
              "PRESSURE accepts full 8-bit pressure and ignores reserved fields");
        check(note_bus[6:0]==69 && gate_bus[0] && bow_speed_bus[7:0]==64 &&
              direction_bus[0] && bow_position_bus[23:0]==24'h800000 && pluck_bus==0 && pluck_count==0,
              "PRESSURE does not change pitch, gate, motion or pluck state");
        send_frame(8'h09,0,0,0,0,0);
        check(velocity_bus[7:0]==0 && gate_bus[0] && pluck_bus==0 && pluck_count==0,
              "zero PRESSURE is valid without releasing the motion gate");

        reset_all;
        send_frame(8'h02,0,69,64,64,0);
        repeat(3000) @(negedge clock);
        send_frame(8'h09,0,0,160,0,0);
        check(gate_bus[0] && velocity_bus[7:0]==160,
              "PRESSURE updates while a bow gate remains active");
        repeat(1600) @(negedge clock);
        check(!gate_bus[0] && bow_speed_bus[7:0]==0,
              "PRESSURE never refreshes the BOW watchdog");
        reset_all;
        send_frame(8'h09,4,0,160,0,0);
        check(frame_error && event_count==0 && velocity_bus==32'h80808080,
              "PRESSURE rejects unsupported strings without changing controls");

        reset_all;
        send_frame(8'h08,0,127,0,0,0);
        check(frame_error && event_count==0, "NOTE_SET rejects reserved MIDI 127");
        reset_all;
        send_frame(8'h22,0,0,1,0,0);
        check(scope_requests==1 && scope_capture && scope_index==0 && event_count==0,
              "scope capture is a diagnostic request, never a musical trigger");
        send_frame(8'h22,127,0,0,0,0);
        check(scope_requests==2 && !scope_capture && scope_index==127,
              "scope supports every pair address including 127");
        send_frame(8'h22,128,0,0,0,0);
        check(scope_requests==2 && frame_error,
              "scope rejects out-of-range address without a response request");
        reset_all;
        send_frame(8'h02,0,72,64,64,0);
        send_frame(8'h04,0,0,0,0,0);
        check(note_bus[6:0]==72 && gate_bus[0] && pluck_count==0,
              "repeated TIMBRE preserves held pitch and motion");
        send_frame(8'h04,0,0,1,0,0);
        check(note_bus[6:0]==67 && instrument_bus[0],
              "actual timbre change selects ukulele high-G open string");
        send_frame(8'h01,0,76,160,0,0);
        send_frame(8'h04,0,0,1,0,0);
        check(note_bus[6:0]==76 && pluck_count==1,
              "repeated plucked TIMBRE does not reset pitch or retrigger");
        $display("UART_CONFIG_RESULT: errors=%0d",error_count);
        $finish;
    end
    initial
    begin
        #100000000;
        $display("FAIL: UART configuration watchdog expired");
        $finish;
    end
endmodule
