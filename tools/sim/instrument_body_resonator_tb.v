`timescale 1ns/1ps
module instrument_body_resonator_tb;
    reg clk = 0;
    reg reset = 1;
    reg sample_tick = 0;
    reg trigger = 0;
    reg bypass = 0;
    reg instrument = 0;
    reg signed [15:0] sample = 0;
    wire signed [15:0] result;
    wire [15:0] guards, clips;
    integer n, preset, file_handle, sample_value;
    integer tail_peak, initial_peak, absolute_value;
    real phase;

    always #5 clk = ~clk;
    instrument_body_resonator dut (
        .i_clk(clk), .i_reset(reset), .i_sample_tick(sample_tick),
        .i_trigger(trigger), .i_bypass(bypass), .i_instrument(instrument),
        .i_sample(sample), .o_sample(result),
        .o_guard_count(guards), .o_clip_count(clips)
    );

    task tick;
        input integer value;
        begin
            @(negedge clk);
            sample = value;
            repeat (5) @(negedge clk); // Minimum documented shadow settling.
            sample_tick = 1;
            @(negedge clk);
            sample_tick = 0;
            if (^result === 1'bx)
            begin
                $display("FAIL body output unknown");
                $finish;
            end
        end
    endtask

    task reset_filter;
        begin
            reset = 1;
            sample_tick = 0;
            trigger = 0;
            bypass = 0;
            sample = 0;
            repeat (3) @(negedge clk);
            reset = 0;
            repeat (6) @(negedge clk);
        end
    endtask

    initial
    begin
        for (preset = 0; preset < 2; preset = preset + 1)
        begin
            instrument = preset;
            reset_filter;
            file_handle = preset == 0 ? $fopen("sim/results/body_violin_impulse.txt", "w") :
                                       $fopen("sim/results/body_ukulele_impulse.txt", "w");
            initial_peak = 0;
            tail_peak = 0;
            for (n = 0; n < 16384; n = n + 1)
            begin
                tick(n == 0 ? 20000 : 0);
                $fdisplay(file_handle, "%0d", result);
                absolute_value = result < 0 ? -result : result;
                if (n < 256 && absolute_value > initial_peak) initial_peak = absolute_value;
                if (n > 12000 && absolute_value > tail_peak) tail_peak = absolute_value;
            end
            $fclose(file_handle);
            if (initial_peak < 5000 || tail_peak > 8 || guards != 0 || clips != 0)
            begin
                $display("FAIL body impulse preset=%0d initial=%0d tail=%0d guard=%0d clip=%0d",
                         preset, initial_peak, tail_peak, guards, clips);
                $finish;
            end

            reset_filter;
            for (n = 0; n < 24000; n = n + 1) tick(16000);
            if (result > 8 || result < -8 || guards != 0 || clips != 0)
            begin
                $display("FAIL body DC preset=%0d result=%0d guard=%0d clip=%0d",
                         preset, result, guards, clips);
                $finish;
            end

            // Positive and negative near-full-scale broadband inputs must
            // remain bounded and must not engage the internal state guard.
            reset_filter;
            for (n = 0; n < 12000; n = n + 1) tick(n % 2 ? 32767 : -32768);
            if (guards != 0)
            begin
                $display("FAIL body full-scale alternating input guard=%0d", guards);
                $finish;
            end

            // A sustained note at the lowest body resonance exercises
            // internal resonant gain rather than merely Nyquist alternation.
            reset_filter;
            phase = 0.0;
            for (n = 0; n < 16000; n = n + 1)
            begin
                sample_value = $rtoi(28000.0 * $sin(phase));
                phase = phase + 6.283185307179586 * (preset == 0 ? 271.8 : 364.0) / 48828.125;
                tick(sample_value);
            end
            if (guards != 0)
            begin
                $display("FAIL body resonant input guard=%0d", guards);
                $finish;
            end

            bypass = 1;
            for (n = 0; n < 1000; n = n + 1)
            begin
                sample_value = (n * 7919) % 65536 - 32768;
                tick(sample_value);
                if (result !== sample_value[15:0])
                begin
                    $display("FAIL body bypass not bit-exact");
                    $finish;
                end
            end
            bypass = 0;
            trigger = 1;
            tick(30000);
            trigger = 0;
            if (result != 0)
            begin
                $display("FAIL body trigger did not clear output");
                $finish;
            end
            tick(0);
            if (result != 0)
            begin
                $display("FAIL body trigger retained modal energy");
                $finish;
            end
        end

        // Fault injection proves guard/clip counters and saturation operate.
        reset_filter;
        for (n = 0; n < 6; n = n + 1)
        begin
            dut.r_position_q8[n] = 30'sd536870000;
            dut.r_velocity_q8[n] = 30'sd536870000;
        end
        tick(0);
        if (guards != 1 || clips != 1 || result != 32767)
        begin
            $display("FAIL body guard injection guards=%0d clips=%0d output=%0d", guards, clips, result);
            $finish;
        end
        if (dut.r_position_q8[0] != 30'sd536870911)
        begin
            $display("FAIL body state did not saturate");
            $finish;
        end
        $display("PASS instrument_body_resonator_tb impulse/DC/full-scale/resonance/bypass/trigger/guard");
        $finish;
    end
endmodule
