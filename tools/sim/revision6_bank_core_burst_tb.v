`timescale 1ns/1ps
// Direct core ingress, each event is two system clocks apart. Not UART evidence.
module revision6_bank_core_burst_tb;
    parameter integer RATE=48828125;
    reg clk=0,reset=1,tick=0,event_valid=0;
    reg [31:0] event_sequence=0;
    reg [63:0] event_clock=0;
    reg [55:0] notes={7'd73,7'd65,7'd60,7'd68,7'd78,7'd70,7'd63,7'd55};
    reg [63:0] velocity=0;
    reg [127:0] speed=0;
    reg [191:0] position=0;
    reg [7:0] direction=0,triggers=0,stops=0;
    reg [55:0] expected_notes;
    reg [63:0] expected_velocity;
    reg [127:0] expected_speed;
    reg [191:0] expected_position;
    reg [7:0] expected_direction,expected_triggers,expected_stops;
    reg check_model=0;
    reg saturation_boundary=0;
    wire signed [15:0] pcm;
    wire valid,first,ready;
    wire [31:0] output_sequence,first_sequence,deadlines,clips;
    wire [63:0] oldest_clock;
    wire [15:0] event_count,max_compute;
    integer k,cycles,model_checks[0:7];
    reg [31:0] want_first,want_last;
    reg [15:0] want_count;
    reg [63:0] want_clock;
    always #10 clk=~clk;
    instrument_bank_core #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(RATE)) dut(
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_event(event_valid),
        .i_event_sequence(event_sequence),.i_event_clock(event_clock),
        .i_note_bus(notes),.i_gate_bus(8'h0f),.i_trigger_bus(triggers),.i_stop_bus(stops),
        .i_velocity_bus(velocity),.i_speed_bus(speed),.i_position_bus(position),.i_direction_bus(direction),
        .i_vibrato_depth(32'd0),.i_vibrato_rate(32'h30303030),.i_glide_ms(32'd0),.i_auto_expression(4'd0),
        .i_emergency(1'b0),.i_fx_bypass(1'b1),.i_wet(8'd0),.i_damping(8'd128),.i_tail(2'd1),
        .o_audio_sample(pcm),.o_audio_sample_valid(valid),.o_audio_first_sample(first),.o_ready(ready),
        .o_voice_sample_bus(),.o_output_sequence(output_sequence),.o_output_event_clock(oldest_clock),
        .o_output_first_sequence(first_sequence),.o_output_event_count(event_count),
        .o_deadline_count(deadlines),.o_max_compute_clocks(max_compute),.o_clip_count(clips),
        .o_body_guards(),.o_body_clips(),.o_reverb_guard(),.o_active_mask());
    genvar v;
    generate for(v=0;v<8;v=v+1)begin: CHECK_ACTUAL_MODEL
        always @(posedge clk)if(check_model && dut.w_model_tick)begin
            if(dut.r_note[v*7+:7]!==expected_notes[v*7+:7]||
               dut.r_velocity[v*8+:8]!==expected_velocity[v*8+:8]||
               dut.r_speed[v*16+:16]!==expected_speed[v*16+:16]||
               dut.r_position[v*24+:24]!==expected_position[v*24+:24]||
               dut.r_direction[v]!==expected_direction[v])
                $fatal(1,"immutable accepted trigger/control payload changed on actual model tick lane%0d",v);
            if(dut.r_trigger!==expected_triggers||dut.r_stop!==expected_stops)
                $fatal(1,"STOP/trigger order changed on model tick");
            model_checks[v]=model_checks[v]+1;
        end
        if(v<4)begin: V_PORTS
            always @(posedge clk)if(check_model && dut.w_model_tick)begin
                if(dut.PHYSICAL_STRING[v].BOWED.u_string.i_midi_note!==expected_notes[v*7+:7]||
                   dut.PHYSICAL_STRING[v].BOWED.u_string.i_velocity!==expected_velocity[v*8+:8]||
                   dut.PHYSICAL_STRING[v].BOWED.u_string.i_bow_speed!==expected_speed[v*16+:16]||
                   dut.PHYSICAL_STRING[v].BOWED.u_string.i_bow_position!==expected_position[v*24+:24]||
                   dut.PHYSICAL_STRING[v].BOWED.u_string.i_bow_direction!==expected_direction[v]||
                   dut.PHYSICAL_STRING[v].BOWED.u_string.i_trigger!==(expected_triggers[v]&&!expected_stops[v]))
                    $fatal(1,"actual V physical model port payload mismatch lane%0d",v);
            end
        end else begin: U_PORTS
            always @(posedge clk)if(check_model && dut.w_model_tick)begin
                if(dut.PHYSICAL_STRING[v].PLUCKED.u_string.i_midi_note!==expected_notes[v*7+:7]||
                   dut.PHYSICAL_STRING[v].PLUCKED.u_string.i_velocity!==expected_velocity[v*8+:8]||
                   dut.PHYSICAL_STRING[v].PLUCKED.u_string.i_trigger!==(expected_triggers[v]&&!expected_stops[v])||
                   dut.PHYSICAL_STRING[v].PLUCKED.u_string.i_stop!==expected_stops[v])
                    $fatal(1,"actual U physical model port payload mismatch lane%0d",v);
            end
        end
    end endgenerate
    task emit;
        input [31:0] sequence_number;input [63:0] clock_tag;
        input [7:0] trigger_mask,stop_mask;
        begin
            @(negedge clk);event_sequence=sequence_number;event_clock=clock_tag;
            event_valid=1;triggers=trigger_mask;stops=stop_mask;
            @(negedge clk);event_valid=0;triggers=0;stops=0;
        end
    endtask
    task frame;
        begin
            check_model=1;
            @(negedge clk);tick=1;
            if(saturation_boundary)event_valid=1;
            @(negedge clk);tick=0;
            if(saturation_boundary)event_valid=0;
            cycles=0;
            while(!valid)begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>224)$fatal(1,"R9 finite burst frame missed 224clk");
            end
            if(cycles!=224)$fatal(1,"R9 finite burst changed commit clock: %0d",cycles);
            if((^pcm)===1'bx||!first||first_sequence!==want_first||output_sequence!==want_last||
               event_count!==want_count||oldest_clock!==want_clock)
                $fatal(1,"finite burst cause aggregate mismatch: first=%0d last=%0d count=%0d oldest=%0d",first_sequence,output_sequence,event_count,oldest_clock);
            if(deadlines!=0||clips!=0)$fatal(1,"finite burst numerical/deadline guard");
            $display("BURST_COMMIT first=%0d last=%0d count=%0d oldest64=%0d trigger=%02h stop=%02h",first_sequence,output_sequence,event_count,oldest_clock,expected_triggers,expected_stops);
            check_model=0;repeat(4)@(negedge clk);
        end
    endtask
    initial begin
        for(k=0;k<8;k=k+1)model_checks[k]=0;
        repeat(5)@(negedge clk);reset=0;repeat(2200)@(negedge clk);
        if(!ready)$fatal(1,"finite burst initialization");
        expected_notes=notes;
        for(k=0;k<8;k=k+1)begin
            // Earlier lanes are deliberately overwritten by later event buses.
            notes={8{7'd84}};notes[k*7+:7]=expected_notes[k*7+:7];
            velocity={8{8'd255}};speed={8{16'd255}};position=0;direction=8'hff;
            velocity[k*8+:8]=33+k*21;speed[k*16+:16]=5+k*17;
            position[k*24+:24]=24'h400000+k*24'h010000;direction[k]=k%2;
            expected_velocity[k*8+:8]=velocity[k*8+:8];expected_speed[k*16+:16]=speed[k*16+:16];
            expected_position[k*24+:24]=position[k*24+:24];expected_direction[k]=direction[k];
            emit(101+k,64'h1000003e8+k*2,8'd1<<k,0);
        end
        expected_triggers=8'hff;expected_stops=0;
        want_first=101;want_last=108;want_count=8;want_clock=64'h1000003e8;frame;
        for(k=0;k<8;k=k+1)if(model_checks[k]!=1)$fatal(1,"missing physical lane model-tick check %0d",k);
        // A later SELECT is a distinct accepted event and cannot rewrite PLUCK.
        notes={8{7'd84}};velocity={8{8'd255}};speed={8{16'd255}};position=0;direction=8'hff;
        notes[34:28]=69;velocity[39:32]=144;speed[79:64]=78;position[119:96]=24'h500000;direction[4]=0;
        expected_notes=notes;expected_velocity=velocity;expected_speed=speed;
        expected_position=position;expected_direction=direction;
        emit(109,64'h1000007d0,8'h10,0);
        notes[34:28]=71;velocity[39:32]=255;speed[79:64]=255;position[119:96]=0;direction[4]=1;
        emit(110,64'h1000007d2,0,0);
        expected_triggers=8'h10;expected_stops=0;
        want_first=109;want_last=110;want_count=2;want_clock=64'h1000007d0;frame;
        if(dut.r_selected_note[34:28]!=71||
           dut.PHYSICAL_STRING[4].PLUCKED.u_string.r_note_period_stage1!==dut.PHYSICAL_STRING[4].PLUCKED.u_string.r_target_period)
            $fatal(1,"SELECT/PLUCK note lifecycle mismatch");
        // The actual port assertions above prove the committed period uses 69.
        notes[34:28]=73;expected_notes=notes;expected_velocity=velocity;
        expected_speed=speed;expected_position=position;expected_direction=direction;
        emit(111,64'h100000bb8,0,8'h10);emit(112,64'h100000bba,8'h10,0);
        expected_triggers=8'h10;expected_stops=0;
        want_first=111;want_last=112;want_count=2;want_clock=64'h100000bb8;frame;
        if(dut.PHYSICAL_STRING[4].PLUCKED.u_string.r_stopped)$fatal(1,"later trigger did not recover early STOP");
        emit(113,64'h100000fa0,8'h10,8'h10);
        expected_triggers=0;expected_stops=8'h10;
        want_first=113;want_last=113;want_count=1;want_clock=64'h100000fa0;frame;
        if(!dut.PHYSICAL_STRING[4].PLUCKED.u_string.r_stopped||
           dut.PHYSICAL_STRING[4].PLUCKED.u_string.r_excitation_remaining!=0)
            $fatal(1,"same-clock STOP did not win over trigger");
        for(k=0;k<8;k=k+1)if(model_checks[k]!=4)$fatal(1,"model lane assertions missing in a burst/order scenario");
        // Directed state injection, not evidence of 65536 ingress events.
        // Snapshot receives a simultaneous event when the pending counter is
        // already saturated. The aggregate must retain both ffff and oldest.
        @(negedge clk);
        force dut.r_pending_event_count=16'hffff;
        force dut.r_event_pending=1'b1;
        force dut.r_pending_first_sequence=32'd200;
        force dut.r_pending_oldest_clock=64'h100001000;
        saturation_boundary=1;event_sequence=201;event_clock=64'h100001002;
        expected_triggers=0;expected_stops=0;
        want_first=200;want_last=201;want_count=16'hffff;want_clock=64'h100001000;
        frame;
        @(negedge clk);event_valid=0;
        release dut.r_pending_event_count;
        release dut.r_event_pending;
        release dut.r_pending_first_sequence;
        release dut.r_pending_oldest_clock;
        $display("SATURATION_BOUNDARY injected_pending_ffff=1 simultaneous_snapshot_event=1 output_count=%0d oldest64=%0d not_ingress_throughput_evidence=1",event_count,oldest_clock);
        $display("MEASURE direct_ingress_spacing=2clk burst_events=8 checked_physical_lanes=8 checked_model_frames=4 oldest_clock=%0d max_compute=%0d",oldest_clock,max_compute);
        $display("PASS revision6_bank_core_burst_tb: immutable per-event payload, actual 8 model ports, aggregate first/last/count/oldest64, PLUCK then SELECT, STOP order, injected saturation boundary");
        $finish;
    end
endmodule
