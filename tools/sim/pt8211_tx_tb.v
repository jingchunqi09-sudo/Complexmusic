`timescale 1ns/1ps

// Decode the external pins exactly as a 16-bit PT8211 receiver does.
module pt8211_tx_tb;
    localparam integer SYSTEM_CLOCK_PERIOD_NS = 20;
    reg system_clock = 1'b0;
    reg reset = 1'b1;
    reg signed [15:0] mono_sample = 16'hA5C3;
    wire bit_clock;
    wire word_select;
    wire serial_data;
    wire next_sample_tick;
    wire first_sample_marker;
    wire left_word_complete;
    wire frame_word_complete;
    integer error_count = 0;
    integer measured_period_ns;
    integer first_edge_time;
    integer second_edge_time;
    reg [15:0] decoded_word;

    always #(SYSTEM_CLOCK_PERIOD_NS/2) system_clock = ~system_clock;
    pt8211_tx dut (
        .i_clk(system_clock), .i_reset(reset), .i_sample(mono_sample),
        .o_hp_bck(bit_clock), .o_hp_ws(word_select), .o_hp_din(serial_data),
        .o_sample_tick(next_sample_tick), .o_first_sample(first_sample_marker),
        .o_left_word_complete(left_word_complete),
        .o_frame_word_complete(frame_word_complete)
    );

    task check;
        input condition;
        input [511:0] description;
        begin
            if (condition) $display("PASS: %0s", description);
            else begin
                $display("FAIL: %0s", description);
                error_count = error_count + 1;
            end
        end
    endtask

    task receive_word;
        output [15:0] received;
        integer bit_number;
        begin
            received = 16'd0;
            for (bit_number = 0; bit_number < 16; bit_number = bit_number + 1) begin
                @(posedge bit_clock);
                received = {received[14:0], serial_data};
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge system_clock);
        reset = 1'b0;

        @(posedge bit_clock); first_edge_time = $time;
        @(posedge bit_clock); second_edge_time = $time;
        measured_period_ns = second_edge_time - first_edge_time;
        check(measured_period_ns == 640, "BCK = 1.5625 MHz, 32 system clocks per period");

        @(posedge word_select); first_edge_time = $time;
        @(posedge word_select); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 20480,
              "stereo frame = 32 BCK periods, sample rate = 48828.125 Hz");
        receive_word(decoded_word);
        check(decoded_word == 16'hA5C3, "LEFT word is MSB-first 0xA5C3 without an I2S delay bit");

        // Change the source during a frame. The RIGHT slot must still carry
        // the word captured at the LEFT start, not the new source word.
        @(negedge system_clock); mono_sample = 16'h3C5A;
        @(negedge word_select);
        receive_word(decoded_word);
        check(decoded_word == 16'hA5C3, "RIGHT slot uses the atomically held frame word");
        @(posedge word_select);
        receive_word(decoded_word);
        check(decoded_word == 16'h3C5A, "next frame captures the new mono sample");

        @(posedge next_sample_tick); first_edge_time = $time;
        @(negedge next_sample_tick); second_edge_time = $time;
        check(second_edge_time - first_edge_time == SYSTEM_CLOCK_PERIOD_NS,
              "sample_tick is one system clock wide");
        @(posedge word_select); second_edge_time = $time;
        // Active transmitter requests the following frame at this frame's
        // capture edge; the next capture is a complete 32-BCK frame later.
        check(second_edge_time - first_edge_time == 20480,
              "sample request leads next frame word capture by 1024 system clocks");

        @(posedge first_sample_marker); first_edge_time = $time;
        check(bit_clock == 1'b1 && word_select == 1'b1,
              "first_sample marker coincides with LEFT MSB sampling edge");
        @(negedge first_sample_marker); second_edge_time = $time;
        check(second_edge_time - first_edge_time == SYSTEM_CLOCK_PERIOD_NS,
              "first_sample marker is one system clock wide");
        @(posedge first_sample_marker); first_edge_time = $time;
        @(posedge first_sample_marker); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 20480,
              "one first_sample marker per complete stereo frame");

        @(posedge first_sample_marker); first_edge_time = $time;
        @(posedge left_word_complete); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 9600,
              "complete LEFT word marker follows its MSB by 15 BCK periods");
        check(bit_clock == 1'b1 && word_select == 1'b1,
              "complete LEFT word marker coincides with LSB sampling edge");
        @(negedge left_word_complete); first_edge_time = $time;
        check(first_edge_time - second_edge_time == SYSTEM_CLOCK_PERIOD_NS,
              "complete LEFT word marker is one system clock wide");

        @(posedge left_word_complete); first_edge_time = $time;
        @(posedge frame_word_complete); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 10240,
              "complete stereo frame follows LEFT LSB by 16 BCK periods");
        check(bit_clock == 1'b1 && word_select == 1'b0,
              "complete stereo frame marker coincides with RIGHT LSB sampling edge");
        @(negedge frame_word_complete); first_edge_time = $time;
        check(first_edge_time - second_edge_time == SYSTEM_CLOCK_PERIOD_NS,
              "complete stereo frame marker is one system clock wide");
        @(posedge frame_word_complete); first_edge_time = $time;
        @(posedge frame_word_complete); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 20480,
              "one complete stereo frame marker per 32 BCK periods");

        @(posedge next_sample_tick); first_edge_time = $time;
        @(posedge next_sample_tick); second_edge_time = $time;
        check(second_edge_time - first_edge_time == 20480,
              "one sample request per complete stereo frame");
        $display("PT8211_RESULT: errors=%0d", error_count);
        if(error_count)$fatal(1,"PT8211 assertions failed");
        $finish;
    end

    // With an active receiver, DIN and WS must not change while BCK is high.
    always @(serial_data or word_select) begin
        if (!reset && bit_clock !== 1'b0) begin
            $display("FAIL: data/word-select changed outside the BCK falling edge");
            error_count = error_count + 1;
        end
    end

    initial begin
        #1000000;
        $display("FAIL: PT8211 simulation watchdog expired");
        $finish;
    end
endmodule
