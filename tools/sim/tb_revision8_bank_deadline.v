`timescale 1ns/1ps
// New R8 deadline contract: real eight-string bank, no dummy voice models.
// Fault injection only suppresses a completed downstream valid handshake.
module tb_revision8_bank_deadline;
    parameter integer RATE = 48828125;
    reg clk=0, reset=1, tick=0, event_valid=0, emergency=0;
    reg [31:0] event_sequence=0;
    reg [63:0] event_clock=0;
    reg [7:0] triggers=0, gates=0;
    wire signed [15:0] pcm;
    wire valid, first, ready;
    wire [31:0] deadlines, sequence_out, first_sequence;
    wire [63:0] clock_out;
    wire [15:0] max_compute, event_count;
    integer cycles, normal_latency, k, cases=0;
    reg [31:0] expected_deadlines=0;
    always #10 clk = !clk;
    instrument_bank_core #(.SAMPLE_RATE_MILLIHZ(RATE)) dut (
        .i_clk(clk), .i_reset(reset), .i_sample_tick(tick), .i_event(event_valid),
        .i_event_sequence(event_sequence), .i_event_clock(event_clock),
        .i_note_bus({7'd73,7'd65,7'd60,7'd68,7'd78,7'd70,7'd63,7'd55}),
        .i_gate_bus(gates), .i_trigger_bus(triggers), .i_stop_bus(8'd0),
        .i_velocity_bus(64'h6060606080808080), .i_speed_bus(128'h00000000000000000030003000300030),
        .i_position_bus({8{24'h800000}}), .i_direction_bus(8'd0),
        .i_vibrato_depth(32'd0), .i_vibrato_rate(32'h30303030), .i_glide_ms(32'd0), .i_auto_expression(4'd0),
        .i_emergency(emergency), .i_fx_bypass(1'b1), .i_wet(8'd0), .i_damping(8'd128), .i_tail(2'd1),
        .o_audio_sample(pcm), .o_audio_sample_valid(valid), .o_audio_first_sample(first), .o_ready(ready),
        .o_output_sequence(sequence_out), .o_output_event_clock(clock_out),
        .o_output_first_sequence(first_sequence), .o_output_event_count(event_count),
        .o_deadline_count(deadlines), .o_max_compute_clocks(max_compute),
        .o_voice_sample_bus(), .o_active_mask(), .o_body_guards(), .o_body_clips(), .o_reverb_guard(), .o_clip_count()
    );

    task launch;
        begin
            @(negedge clk);
            if (!ready || dut.r_phase != 0) $fatal(1,"FAIL bank not ready before launch");
            event_sequence=event_sequence+1;
            event_clock=64'h100000000+event_sequence;
            event_valid=1;
            triggers=8'hff;
            tick=1;
            @(negedge clk);
            tick=0;
            triggers=0;
            event_valid=0;
            cycles=0;
        end
    endtask

    task wait_valid;
        begin
            while (!valid && cycles<770)
            begin
                @(negedge clk);
                cycles=cycles+1;
            end
            if (!valid || cycles>768 || (^pcm)===1'bx)
                $fatal(1,"FAIL bank bounded valid cycles=%0d pcm=%h",cycles,pcm);
            if (deadlines!==expected_deadlines)
                $fatal(1,"FAIL deadline counter got=%0d expected=%0d",deadlines,expected_deadlines);
        end
    endtask

    task check_tag;
        begin
            if (!first || sequence_out!==event_sequence || first_sequence!==event_sequence ||
                event_count!=1 || clock_out!==event_clock)
                $fatal(1,"FAIL normal/recovery tag first=%0d last=%0d count=%0d",first_sequence,sequence_out,event_count);
        end
    endtask

    task check_fault_tag;
        begin
            if (first || sequence_out!==event_sequence || first_sequence!==event_sequence ||
                event_count!=1 || clock_out!==event_clock)
                $fatal(1,"FAIL timeout lacks failed-frame metadata first=%0d last=%0d count=%0d clock=%0d",
                       first_sequence,sequence_out,event_count,clock_out);
        end
    endtask

    task wait_reinitialized;
        integer n;
        begin
            n=0;
            while (!ready && n<10000)
            begin
                @(negedge clk);
                n=n+1;
                if (valid || first) $fatal(1,"FAIL stale completion during timeout reset recovery");
            end
            if (!ready) $fatal(1,"FAIL timeout reset failed to reinitialize within 10000clk");
        end
    endtask

    task inject_late_completion;
        begin
            // Completion after a timed-out/reset transaction cannot leak into
            // an idle frame, even if a downstream handshake glitches late.
            force dut.w_body_valid=1'b1;
            force dut.w_fx_valid=1'b1;
            @(negedge clk);
            if (valid || first || pcm!==0 || dut.w_fx_tick)
                $fatal(1,"FAIL late downstream valid leaked into idle output");
            release dut.w_body_valid;
            release dut.w_fx_valid;
            idle_clean(4);
        end
    endtask

    task recover_without_event;
        begin
            // No new event arrives after the failed frame: retained cause
            // tags must not be replayed as if that failed event succeeded.
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;cycles=0;
            wait_valid;
            if (first || event_count!=0 || cycles!=normal_latency)
                $fatal(1,"FAIL no-event recovery replayed failed cause count=%0d",event_count);
            idle_clean(20);
        end
    endtask

    task idle_clean;
        input integer duration;
        integer n;
        begin
            for (n=0;n<duration;n=n+1)
            begin
                @(negedge clk);
                if (valid || first) $fatal(1,"FAIL stale/duplicate completion while idle");
            end
        end
    endtask

    initial
    begin
        repeat(5) @(negedge clk);
        reset=0;
        repeat(2200) @(negedge clk);
        gates=8'h0f;
        launch;
        wait_valid;
        check_tag;
        normal_latency=cycles;
        if (normal_latency!=224)
            $fatal(1,"FAIL R9 normal commit must remain at clock 224: %0d",normal_latency);
        idle_clean(20);
        cases=cases+1;

        // Unexpected extra sample edge while busy records one fault without
        // restarting the current frame or emitting an extra PCM/tag.
        launch;
        repeat(60) @(negedge clk);
        cycles=60;
        tick=1;
        @(negedge clk);
        cycles=cycles+1;
        tick=0;
        expected_deadlines=expected_deadlines+1;
        wait_valid;
        check_tag;
        if (cycles!=normal_latency) $fatal(1,"FAIL busy tick restarted audio computation");
        idle_clean(20);
        cases=cases+1;

        // Lost body completion reaches the real counter deadline; no forced
        // phase jump or shortened timeout bypasses the actual wait path.
        launch;
        force dut.w_body_valid=1'b0;
        expected_deadlines=expected_deadlines+1;
        wait_valid;
        if (cycles!=767 || pcm!==0 || first)
            $fatal(1,"FAIL body-stall deadline did not zero-fill at 767: %0d",cycles);
        check_fault_tag;
        release dut.w_body_valid;
        idle_clean(2);
        inject_late_completion;
        wait_reinitialized;
        recover_without_event;
        cases=cases+1;
        launch;
        wait_valid;
        check_tag;
        if (cycles!=normal_latency) $fatal(1,"FAIL recovery after body stall");
        idle_clean(20);
        cases=cases+1;

        launch;
        force dut.w_fx_valid=1'b0;
        expected_deadlines=expected_deadlines+1;
        wait_valid;
        if (cycles!=767 || pcm!==0 || first) $fatal(1,"FAIL FX-stall zero fill");
        check_fault_tag;
        release dut.w_fx_valid;
        idle_clean(2);
        inject_late_completion;
        wait_reinitialized;
        recover_without_event;
        cases=cases+1;
        launch;
        wait_valid;
        check_tag;
        idle_clean(20);
        cases=cases+1;

        // Completion on the exact last permitted edge wins over timeout.
        // Drive a marked PCM result to detect accidental zero-fill priority.
        launch;
        force dut.w_body_valid=1'b0;
        repeat(766) @(negedge clk);
        cycles=766;
        force dut.w_fx_sample=16'sd3210;
        force dut.w_fx_valid=1'b1;
        wait_valid;
        if (cycles!=767 || pcm!==16'sd3210) $fatal(1,"FAIL final-edge completion lost to timeout");
        check_tag;
        release dut.w_fx_valid;
        release dut.w_fx_sample;
        release dut.w_body_valid;
        idle_clean(20);
        cases=cases+1;

        // Reset-based emergency at expression, string, body and FX stages.
        for (k=0;k<5;k=k+1)
        begin
            launch;
            repeat(10+k*33) @(negedge clk);
            emergency=1;
            gates=0;
            @(negedge clk);
            emergency=0;
            if (valid || first || pcm!==0 || dut.r_phase!=0)
                $fatal(1,"FAIL emergency did not abort immediately stage=%0d",k);
            idle_clean(2200);
            if (!ready) $fatal(1,"FAIL emergency memory reinitialization stage=%0d",k);
            // Emergency is itself a retained event; consume and check it.
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;cycles=0;
            wait_valid;
            check_tag;
            idle_clean(20);
            gates=8'h0f;
            launch;
            wait_valid;
            check_tag;
            idle_clean(20);
            cases=cases+1;
        end
        if (cases!=12 || max_compute>768 || deadlines!=3)
            $fatal(1,"FAIL coverage/contract cases=%0d max=%0d deadline=%0d",cases,max_compute,deadlines);
        $display("PASS tb_revision8_bank_deadline RATE=%0d cases=12 normal_latency=%0d hard_timeout=767 busy_tick_faults=1 stall_timeouts=2 emergency_stages=5 recovery_tags=complete timeout_tags=complete late_valid_dropped=2 no_event_recoveries=2 final_edge_wins=1",RATE,normal_latency);
        $finish;
    end
    initial
    begin
        #2000000;
        $fatal(1,"FAIL bank deadline test global timeout");
    end
endmodule
