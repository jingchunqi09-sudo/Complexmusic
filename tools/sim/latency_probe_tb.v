`timescale 1ns/1ps
module latency_probe_tb;
    reg clk=0;
    reg reset=1;
    reg event_in=0;
    reg sample_in=0;
    wire gpio_event;
    wire gpio_audio;
    wire valid;
    wire timeout;
    wire overrun;
    wire [31:0] cycles;
    wire [31:0] microseconds;
    integer clock_number=0;
    integer event_clock=0;
    integer errors=0;
    integer timeout_results=0;
    always #10 clk=~clk;
    always @(posedge clk)
    begin
        clock_number = clock_number + 1;
        if (event_in && !dut.r_measurement_pending) event_clock=clock_number;
        #1;
        if (valid && cycles !== clock_number-event_clock)
        begin
            $display("FAIL: latency off-by-one cycles=%0d external=%0d",cycles,clock_number-event_clock);
            errors=errors+1;
        end
        if (valid && timeout)
        begin
            timeout_results=timeout_results+1;
            if(cycles!=200 || microseconds!=4 || gpio_audio)
            begin
                $display("FAIL: timeout must publish current wait without an audio endpoint");
                errors=errors+1;
            end
        end
    end
    latency_probe #(.CLOCK_HZ(50000000),
        .MAX_WAIT_CYCLES(200)) dut (
        .i_clk(clk),
        .i_reset(reset),
        .i_event(event_in),
        .i_audio_first_sample(sample_in),
        .o_gpio_event(gpio_event),
        .o_gpio_audio(gpio_audio),
        .o_measure_valid(valid),
        .o_cycles(cycles),
        .o_microseconds(microseconds),
        .o_timeout(timeout),
        .o_overrun(overrun)
    );
    task pulse_event;
    begin
        @(negedge clk);
        event_in=1;
        @(negedge clk);
        event_in=0;
    end
    endtask
    task pulse_sample;
    begin
        @(negedge clk);
        sample_in=1;
        @(negedge clk);
        sample_in=0;
    end
    endtask
    initial
    begin
        repeat(3) @(negedge clk);
        reset=0;
        pulse_event;
        repeat(99) @(negedge clk);
        pulse_sample;
        if (!valid || cycles != 101 || microseconds != 2)
        begin
            $display("FAIL: cycles/us expected101/2 got %0d/%0d",cycles,microseconds);
            errors=errors+1;
        end
        // 无关 DAC 帧不能重复发布此前测量结果。
        pulse_sample;
        if (valid || gpio_audio)
        begin
            $display("FAIL: stale sample result");
            errors=errors+1;
        end
        @(negedge clk);
        event_in=1;
        sample_in=1;
        @(negedge clk);
        event_in=0;
        sample_in=0;
        if (!valid || cycles != 0)
        begin
            $display("FAIL: same-cycle endpoint");
            errors=errors+1;
        end
        pulse_event;
        pulse_event;
        if (!overrun)
        begin
            $display("FAIL: missing overrun flag");
            errors=errors+1;
        end
        repeat(205) @(negedge clk);
        if (!timeout || dut.r_measurement_pending)
        begin
            $display("FAIL: missing timeout");
            errors=errors+1;
        end
        if (timeout_results!=1)
        begin
            $display("FAIL: missing timeout result publication");
            errors=errors+1;
        end
        $display("LATENCY_RESULT: errors=%0d",errors);
        if (errors == 0)
        begin
            $display("PASS: exact clock and microsecond count");
            $display("PASS: unrelated sample rejected");
            $display("PASS: simultaneous endpoints report zero");
            $display("PASS: event overrun recorded");
            $display("PASS: pending measurement times out");
            $display("PASS: timeout publishes current wait and no audio GPIO");
        end
        $finish;
    end
endmodule
