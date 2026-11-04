`timescale 1ns/1ps

module tb_r9_v31_p1_boundaries;
    reg clk = 0, reset = 1, byte_valid = 0;
    reg [7:0] byte_data = 0;
    reg legacy_event = 0;
    reg [7:0] legacy_type = 0, legacy_index = 0;
    reg [27:0] legacy_note = 0;
    reg [3:0] legacy_gate = 0, legacy_pluck = 0, legacy_stop = 0, legacy_instrument = 0;
    reg [31:0] legacy_velocity = 0, legacy_speed = 0;
    reg [95:0] legacy_position = 0;
    wire [7:0] gates, stops;
    integer stop_seen = 0;
    integer j;
    reg [7:0] valid_bow [0:19];
    reg [7:0] bad_bow [0:19];

    always #5 clk = ~clk;
    always @(posedge clk) if (!reset && stops[0]) stop_seen = stop_seen + 1;

    performance_bank_router #(.CLOCK_HZ(100000), .BOW_TIMEOUT_MS(1)) router(
        .i_clk(clk), .i_reset(reset), .i_frame_tick(1'b0), .i_open_notes(64'd0),
        .i_byte_valid(byte_valid), .i_byte(byte_data),
        .i_legacy_event(legacy_event), .i_legacy_type(legacy_type), .i_legacy_index(legacy_index),
        .i_legacy_note(legacy_note), .i_legacy_gate(legacy_gate), .i_legacy_pluck(legacy_pluck),
        .i_legacy_stop(legacy_stop), .i_legacy_velocity(legacy_velocity), .i_legacy_speed(legacy_speed),
        .i_legacy_position(legacy_position), .i_legacy_direction(4'd0), .i_legacy_instrument(legacy_instrument),
        .o_view_instrument(), .o_note_bus(), .o_gate_bus(gates), .o_trigger_bus(), .o_stop_bus(stops),
        .o_velocity_bus(), .o_speed_bus(), .o_position_bus(), .o_direction_bus(),
        .o_vibrato_depth(), .o_vibrato_rate(), .o_glide_ms(), .o_auto_expression(),
        .o_event(), .o_event_sequence(), .o_event_clock(), .o_emergency(), .o_wet(), .o_damping(),
        .o_tail(), .o_fx_bypass(), .o_rejected(), .o_stale(), .o_superseded(), .o_crc_errors(),
        .o_trace_valid(), .o_trace_disposition(), .o_trace_source(), .o_trace_epoch(),
        .o_trace_session_sequence(), .o_trace_opcode(), .o_trace_voice(), .o_trace_clock(),
        .o_scan_anomalies());

    reg bridge_reset = 1, bridge_rx = 1;
    wire bridge_valid, bridge_frame_error;
    wire [7:0] bridge_data;
    uart_event_bridge #(.CLOCK_HZ(1000), .BAUD_RATE(100), .BOW_TIMEOUT_MS(1000)) bridge(
        .i_clk(clk), .i_reset(bridge_reset), .i_uart_rx(bridge_rx), .i_open_notes(64'd0),
        .o_rx_byte_valid(bridge_valid), .o_rx_byte_data(bridge_data), .o_legacy_type(), .o_legacy_index(),
        .o_note_bus(), .o_gate_bus(), .o_pluck_pulse_bus(), .o_stop_pulse_bus(), .o_velocity_bus(),
        .o_bow_speed_bus(), .o_bow_position_bus(), .o_direction_bus(), .o_instrument_select_bus(),
        .o_event_pulse(), .o_frame_error(bridge_frame_error), .o_tuning_write(), .o_tuning_address(),
        .o_tuning_note(), .o_tuning_commit(), .o_spi_profile_write(), .o_spi_adapter(), .o_spi_field(),
        .o_spi_value(), .o_status_request(), .o_diag_request(), .o_diag_index(),
        .o_sensor_snapshot_request(), .o_scope_request(), .o_scope_capture(), .o_scope_index(),
        .o_sensor_snapshot_adapter());

    task send_frame;
        input integer bad;
        begin
            for (j = 0; j < 20; j = j + 1) begin
                if (j == 19) router.r_bow_age[0] = 98;
                @(negedge clk); byte_data = bad ? bad_bow[j] : valid_bow[j]; byte_valid = 1;
                @(negedge clk); byte_valid = 0;
            end
        end
    endtask

    initial begin
        valid_bow[0]=8'ha6; valid_bow[1]=8'h01; valid_bow[2]=8'h03; valid_bow[3]=8'h00;
        valid_bow[4]=8'h01; valid_bow[5]=8'h64; valid_bow[6]=8'h00; valid_bow[7]=8'h00;
        valid_bow[8]=8'h00; valid_bow[9]=8'h00; valid_bow[10]=8'h00; valid_bow[11]=8'h3c;
        valid_bow[12]=8'h32; valid_bow[13]=8'h64; valid_bow[14]=8'h40; valid_bow[15]=8'h01;
        valid_bow[16]=8'h00; valid_bow[17]=8'h00; valid_bow[18]=8'h08; valid_bow[19]=8'hc0;
        for (j = 0; j < 20; j = j + 1) bad_bow[j] = valid_bow[j];
        bad_bow[18]=0; bad_bow[19]=0;

        repeat (4) @(negedge clk); reset=0; bridge_reset=0; repeat (3) @(negedge clk);
        // Put the violin voice one cycle before watchdog expiry. The final BOW
        // byte is accepted on that expiry cycle; it must remove only that
        // watchdog STOP, leaving gate high and no STOP pulse.
        router.o_gate_bus = 8'h01;
        router.r_bow_age[0] = 0;
        router.r_owner[0] = 1; router.r_epoch[0] = 100; router.r_sequence_valid[0] = 0;
        send_frame(0);
        repeat (2) @(posedge clk);
        if (!gates[0] || stop_seen != 0) begin
            $fatal(1, "accepted BOW did not win watchdog STOP arbitration");
        end

        router.o_gate_bus = 8'h01;
        router.r_bow_age[0] = 0;
        send_frame(1);
        @(posedge clk);
        if (stop_seen == 0) begin
            $display("DEBUG bad gates=%h stops=%h rejected=%0d stale=%0d crc=%0d age=%0d count=%0d", gates, stops, router.o_rejected, router.o_stale, router.o_crc_errors, router.r_bow_age[0], router.r_count);
            $fatal(1, "CRC-invalid BOW incorrectly cleared watchdog STOP");
        end

        // Component boundary: timeout edge with A6 must seed bridge skip.
        force bridge.r_parser_state = 3'd2;
        force bridge.r_partial_frame_age = 32'd50;
        force bridge.w_received_valid = 1'b1;
        force bridge.w_received_byte = 8'ha6;
        force bridge.w_received_frame_error = 1'b0;
        @(posedge clk); #1;
        release bridge.r_parser_state; release bridge.r_partial_frame_age;
        release bridge.w_received_valid; release bridge.w_received_byte; release bridge.w_received_frame_error;
        if (bridge.r_a6_skip != 19) $fatal(1, "bridge timeout A6 did not seed r_a6_skip=19");
        $display("PASS tb_r9_v31_p1_boundaries: watchdog/BOW arbitration, CRC rejection, bridge timeout A6 skip");
        $finish;
    end
endmodule
