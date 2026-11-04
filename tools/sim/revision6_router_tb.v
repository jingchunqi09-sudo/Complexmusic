`timescale 1ns/1ps
module revision6_router_tb;
    reg clk=0,reset=1,frame_tick=0,byte_valid=0;
    reg [7:0] byte_data=0;
    reg legacy_event=0;
    reg [7:0] legacy_type=0,legacy_index=0;
    reg [27:0] legacy_note={7'd76,7'd69,7'd62,7'd55};
    reg [3:0] legacy_gate=0,legacy_pluck=0,legacy_stop=0,legacy_instrument=0;
    reg [31:0] legacy_velocity=32'h80808080,legacy_speed=0;
    reg [95:0] legacy_position=0;
    wire [55:0] notes,serial_notes;
    wire [7:0] gates,triggers,stops,serial_gates,serial_triggers,serial_stops;
    wire [31:0] rejected,stale,crc_errors,superseded,serial_rejected,serial_stale,serial_crc;
    wire event_valid,serial_event;
    wire emergency;
    wire [31:0] scan_anomalies;
    integer emergency_count=0;
    reg scan_atomic_check=0;
    reg [55:0] scan_before,scan_after;
    reg [7:0] packet [0:19];
    reg [15:0] crc;
    reg uart_rx=1;
    wire rx_valid;
    wire [7:0] rx_byte,a5_type,a5_index;
    wire [27:0] a5_note;
    wire [3:0] a5_gate,a5_pluck,a5_stop,a5_direction,a5_instrument;
    wire [31:0] a5_velocity,a5_speed;
    wire [95:0] a5_position;
    wire a5_event,a5_error;
    integer k,n,prior_rejected,prior_stale,prior_crc,prior_trigger,prior_stop;
    integer trigger_count[0:7],stop_count[0:7];
    integer serial_event_count=0,a5_event_count=0,a5_error_count=0;
    integer prior_serial,prior_a5,prior_a5_error;
    localparam BIT_CLOCKS=50000000/115200;
    always #10 clk=~clk;
    always @(posedge clk)if(!reset)begin
        for(n=0;n<8;n=n+1)begin
            if(triggers[n])trigger_count[n]=trigger_count[n]+1;
            if(stops[n])stop_count[n]=stop_count[n]+1;
        end
        if(serial_event)serial_event_count=serial_event_count+1;
        if(a5_event)a5_event_count=a5_event_count+1;
        if(a5_error)a5_error_count=a5_error_count+1;
        if(emergency)emergency_count=emergency_count+1;
        if(scan_atomic_check && notes!==scan_before && notes!==scan_after)
            $fatal(1,"LEFT_SCAN exposed a partial four-string update");
    end
    performance_bank_router #(.CLOCK_HZ(50000000),.BOW_TIMEOUT_MS(1)) dut(
        .i_clk(clk),.i_reset(reset),.i_frame_tick(frame_tick),.i_open_notes(64'h45403c434c453e37),.i_byte_valid(byte_valid),.i_byte(byte_data),
        .i_legacy_event(legacy_event),.i_legacy_type(legacy_type),.i_legacy_index(legacy_index),
        .i_legacy_note(legacy_note),.i_legacy_gate(legacy_gate),.i_legacy_pluck(legacy_pluck),
        .i_legacy_stop(legacy_stop),.i_legacy_velocity(legacy_velocity),.i_legacy_speed(legacy_speed),
        .i_legacy_position(legacy_position),.i_legacy_direction(4'd0),.i_legacy_instrument(legacy_instrument),
        .o_note_bus(notes),.o_gate_bus(gates),.o_trigger_bus(triggers),.o_stop_bus(stops),
        .o_velocity_bus(),.o_speed_bus(),.o_position_bus(),.o_direction_bus(),.o_vibrato_depth(),
        .o_vibrato_rate(),.o_glide_ms(),.o_auto_expression(),.o_event(event_valid),
        .o_event_sequence(),.o_event_clock(),.o_emergency(emergency),.o_wet(),.o_damping(),.o_tail(),
        .o_fx_bypass(),.o_view_instrument(),.o_rejected(rejected),.o_stale(stale),.o_superseded(superseded),.o_crc_errors(crc_errors),
        .o_trace_valid(),.o_trace_disposition(),.o_trace_source(),.o_trace_epoch(),.o_trace_session_sequence(),
        .o_trace_opcode(),.o_trace_voice(),.o_trace_clock(),.o_scan_anomalies(scan_anomalies));
    uart_event_bridge #(.CLOCK_HZ(50000000),.BAUD_RATE(115200),.BOW_TIMEOUT_MS(1000),.DEFAULT_INSTRUMENTS(0)) bridge(
        .i_clk(clk),.i_reset(reset),.i_uart_rx(uart_rx),.i_open_notes(64'h45403c434c453e37),
        .o_rx_byte_valid(rx_valid),.o_rx_byte_data(rx_byte),.o_legacy_type(a5_type),.o_legacy_index(a5_index),
        .o_note_bus(a5_note),.o_gate_bus(a5_gate),.o_pluck_pulse_bus(a5_pluck),.o_stop_pulse_bus(a5_stop),
        .o_velocity_bus(a5_velocity),.o_bow_speed_bus(a5_speed),.o_bow_position_bus(a5_position),
        .o_direction_bus(a5_direction),.o_instrument_select_bus(a5_instrument),.o_event_pulse(a5_event),
        .o_frame_error(a5_error),.o_tuning_write(),.o_tuning_address(),.o_tuning_note(),.o_tuning_commit(),
        .o_spi_profile_write(),.o_spi_adapter(),.o_spi_field(),.o_spi_value(),.o_status_request(),
        .o_sensor_snapshot_request(),.o_scope_request(),.o_scope_capture(),.o_scope_index(),.o_sensor_snapshot_adapter(),
        .o_diag_index(),.o_diag_request());
    performance_bank_router #(.CLOCK_HZ(50000000),.BOW_TIMEOUT_MS(1000)) serial(
        .i_clk(clk),.i_reset(reset),.i_frame_tick(frame_tick),.i_open_notes(64'h45403c434c453e37),.i_byte_valid(rx_valid),.i_byte(rx_byte),
        .i_legacy_event(a5_event),.i_legacy_type(a5_type),.i_legacy_index(a5_index),.i_legacy_note(a5_note),
        .i_legacy_gate(a5_gate),.i_legacy_pluck(a5_pluck),.i_legacy_stop(a5_stop),
        .i_legacy_velocity(a5_velocity),.i_legacy_speed(a5_speed),.i_legacy_position(a5_position),
        .i_legacy_direction(a5_direction),.i_legacy_instrument(a5_instrument),
        .o_note_bus(serial_notes),.o_gate_bus(serial_gates),.o_trigger_bus(serial_triggers),.o_stop_bus(serial_stops),
        .o_velocity_bus(),.o_speed_bus(),.o_position_bus(),.o_direction_bus(),.o_vibrato_depth(),
        .o_vibrato_rate(),.o_glide_ms(),.o_auto_expression(),.o_event(serial_event),
        .o_event_sequence(),.o_event_clock(),.o_emergency(),.o_wet(),.o_damping(),.o_tail(),.o_fx_bypass(),
        .o_rejected(serial_rejected),.o_stale(serial_stale),.o_superseded(),.o_view_instrument(),.o_crc_errors(serial_crc),
        .o_trace_valid(),.o_trace_disposition(),.o_trace_source(),.o_trace_epoch(),.o_trace_session_sequence(),
        .o_trace_opcode(),.o_trace_voice(),.o_trace_clock(),.o_scan_anomalies());
    function [15:0] crc_update;
        input [15:0] c;input [7:0] b;
        reg [15:0] v;integer j;
        begin
            v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=v[15]?(v<<1)^16'h1021:v<<1;
            crc_update=v;
        end
    endfunction
    task build;
        input [7:0] op,voice,source;
        input [31:0] epoch;input [15:0] sequence_number;
        input [7:0] note,value,pressure,flags;
        integer j;
        begin
            packet[0]=8'ha6;packet[1]=1;packet[2]=op;packet[3]=voice;packet[4]=source;
            packet[5]=epoch[7:0];packet[6]=epoch[15:8];packet[7]=epoch[23:16];packet[8]=epoch[31:24];
            packet[9]=sequence_number[7:0];packet[10]=sequence_number[15:8];packet[11]=note;
            packet[12]=value;packet[13]=pressure;packet[14]=64;packet[15]=flags;packet[16]=0;packet[17]=0;
            crc=16'hffff;for(j=0;j<18;j=j+1)crc=crc_update(crc,packet[j]);
            packet[18]=crc[7:0];packet[19]=crc[15:8];
        end
    endtask
    task send;
        integer j;
        begin
            for(j=0;j<20;j=j+1)begin
                @(negedge clk);byte_data=packet[j];byte_valid=1;
                @(negedge clk);byte_valid=0;
            end
            repeat(3)@(negedge clk);
        end
    endtask
    task build_scan;
        input [7:0] voice,source;input [31:0] epoch;input [15:0] seq;
        input [47:0] mask;input [7:0] validity;
        integer j;
        begin
            build(11,voice,source,epoch,seq,0,0,0,0);
            for(j=0;j<6;j=j+1)packet[11+j]=mask[j*8+:8];
            packet[17]=validity;
            crc=16'hffff;for(j=0;j<18;j=j+1)crc=crc_update(crc,packet[j]);
            packet[18]=crc[7:0];packet[19]=crc[15:8];
        end
    endtask
    task action;
        input [7:0] op,voice,source;input [31:0] epoch;input [15:0] seq;
        input [7:0] note,value,pressure,flags;
        begin build(op,voice,source,epoch,seq,note,value,pressure,flags);send;end
    endtask
    task boundary;
        begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;end
    endtask
    task a5_manual;
        input [7:0] kind,index;
        begin
            @(negedge clk);legacy_type=kind;legacy_index=index;legacy_event=1;
            @(negedge clk);legacy_event=0;repeat(3)@(negedge clk);
        end
    endtask
    task uart_byte;
        input [7:0] value;integer j;
        begin
            @(negedge clk);uart_rx=0;repeat(BIT_CLOCKS)@(negedge clk);
            for(j=0;j<8;j=j+1)begin uart_rx=value[j];repeat(BIT_CLOCKS)@(negedge clk);end
            uart_rx=1;repeat(BIT_CLOCKS)@(negedge clk);
        end
    endtask
    task uart_packet;
        integer j;
        begin for(j=0;j<20;j=j+1)uart_byte(packet[j]);repeat(BIT_CLOCKS)@(negedge clk);end
    endtask
    task uart_a5;
        input [7:0] kind,index,note,value,expression;
        begin
            uart_byte(8'ha5);uart_byte(kind);uart_byte(index);uart_byte(note);
            uart_byte(value);uart_byte(expression);uart_byte(kind^index^note^value^expression);
            repeat(BIT_CLOCKS)@(negedge clk);
        end
    endtask
    initial begin
        for(k=0;k<8;k=k+1)begin trigger_count[k]=0;stop_count[k]=0;end
        repeat(5)@(negedge clk);reset=0;repeat(5)@(negedge clk);
        action(1,0,2,1,0,127,0,0,0);
        action(3,0,2,1,1,69,48,128,1);
        if(!gates[0]||notes[6:0]!=69||trigger_count[0]!=1)$fatal(1,"initial score bow");
        prior_trigger=trigger_count[0];action(3,0,2,1,2,69,0,128,1);
        if(!gates[0]||trigger_count[0]!=prior_trigger)$fatal(1,"contact speed-zero retriggered");
        prior_rejected=rejected;action(3,0,2,1,3,69,48,128,3);
        if(rejected!=prior_rejected+1||trigger_count[0]!=prior_trigger)$fatal(1,"continuous update erased same-frame trigger admission");
        boundary;action(3,0,2,1,4,69,48,128,3);
        if(trigger_count[0]!=prior_trigger+1)$fatal(1,"new frame did not allow trigger");
        prior_stale=stale;action(3,0,2,1,4,70,48,128,1);
        if(stale!=prior_stale+1||notes[6:0]!=69)$fatal(1,"duplicate sequence admitted");
        prior_crc=crc_errors;build(5,0,2,1,5,72,0,0,0);packet[19]=packet[19]^1;send;
        if(crc_errors!=prior_crc+1||notes[6:0]!=69)$fatal(1,"bad CRC changed state");
        action(1,4,3,1,0,127,0,0,0);boundary;
        action(4,4,3,1,1,60,200,0,0);
        prior_trigger=trigger_count[4];prior_rejected=rejected;action(4,4,3,1,2,64,200,0,0);
        if(rejected!=prior_rejected+1||trigger_count[4]!=prior_trigger||notes[34:28]!=60)$fatal(1,"two same-frame plucks not rejected");
        prior_stop=stop_count[4];action(2,4,3,1,3,127,0,0,0);
        if(stop_count[4]!=prior_stop||!gates[0])$fatal(1,"U release damped tail or cleared V bank");
        action(1,4,3,2,0,127,0,0,0);action(6,4,3,2,1,127,0,0,0);
        if(stop_count[4]!=prior_stop+1||!gates[0])$fatal(1,"selective U STOP/cross-bank isolation");
        // Score pressure heartbeats cannot transfer the bank to A5 legacy.
        legacy_velocity[7:0]=200;a5_manual(9,0);
        prior_stale=stale;action(5,0,2,1,5,71,0,0,0);
        if(stale!=prior_stale||notes[6:0]!=71)$fatal(1,"pressure stole score bank");
        boundary;action(3,1,2,1,6,62,48,128,1);
        if(gates[1:0]!=2'b11)$fatal(1,"second score voice not active");
        // A5 effective performer action cancels the entire score V bank.
        legacy_note[6:0]=72;a5_manual(8,0);
        if(gates[3:0]!=0)$fatal(1,"human takeover left another score bow active");
        prior_stale=stale;prior_stop=stop_count[0];action(6,0,2,1,7,127,0,0,0);
        if(stale!=prior_stale+1||stop_count[0]!=prior_stop)$fatal(1,"old score STOP acted on human owner");
        prior_stale=stale;action(1,0,2,1,0,127,0,0,0);
        if(stale!=prior_stale+1)$fatal(1,"delayed old CLAIM reclaimed bank");
        // Equal epoch from another source is stale even after legacy takeover.
        prior_stale=stale;action(1,0,1,1,65534,127,0,0,0);
        if(stale!=prior_stale+1||dut.r_owner[0]!=0)$fatal(1,"cross-source equal epoch reclaimed after A5 takeover");
        action(1,0,1,2,65534,127,0,0,0);action(5,0,1,2,0,74,0,0,0);
        if(notes[6:0]!=74)$fatal(1,"sequence half-range wrap rejected");
        prior_stale=stale;action(5,0,1,2,32768,75,0,0,0);
        if(stale!=prior_stale+1||notes[6:0]!=74)$fatal(1,"ambiguous half-range sequence accepted");
        prior_rejected=rejected;action(5,0,1,2,1,127,0,0,0);
        if(rejected!=prior_rejected+1)$fatal(1,"SELECT_NEXT KEEP accepted");
        prior_rejected=rejected;action(1,1,1,2,0,127,0,0,0);
        if(rejected!=prior_rejected+1)$fatal(1,"invalid CLAIM bank address accepted");
        action(1,0,1,32'hffffffff,0,127,0,0,0);
        prior_stale=stale;action(1,0,1,0,0,127,0,0,0);
        action(1,0,1,1,0,127,0,0,0);
        if(stale!=prior_stale+2)$fatal(1,"exhausted epoch wrapped without reset");
        boundary;action(3,0,1,32'hffffffff,1,69,48,128,1);
        if(!gates[0])$fatal(1,"timeout setup failed");
        repeat(50020)@(negedge clk);
        if(gates[0]||stop_count[0]!=prior_stop+1)$fatal(1,"bow timeout did not release");
        // Fresh safety session is owner-independent and newer than both banks.
        reset=1;repeat(5)@(negedge clk);reset=0;repeat(5)@(negedge clk);
        action(1,0,2,1,0,127,0,0,0);boundary;action(3,0,2,1,1,69,48,128,1);
        action(1,4,3,7,0,127,0,0,0);boundary;action(4,4,3,7,1,60,200,0,0);
        prior_stale=stale;prior_trigger=emergency_count;
        action(9,0,2,99,0,127,0,0,0);
        action(9,0,1,2,0,127,0,0,0);
        if(stale!=prior_stale+2||!gates[0]||emergency_count!=prior_trigger)$fatal(1,"unsafe source or cross-bank stale emergency admitted");
        action(9,0,1,8,0,127,0,0,0);
        if(gates!=0||emergency_count!=prior_trigger+1||dut.r_owner[0]!=0||dut.r_owner[1]!=0)$fatal(1,"fresh ownerless ALL_STOP failed");
        prior_stale=stale;action(9,0,1,8,1,127,0,0,0);action(6,4,3,7,2,127,0,0,0);
        if(stale!=prior_stale+2||emergency_count!=prior_trigger+1)$fatal(1,"duplicate emergency/old score acted after safety epoch");
        action(9,0,4,9,0,127,0,0,0);
        if(emergency_count!=prior_trigger+2)$fatal(1,"fresh sensor safety session rejected without owner");
        prior_stale=stale;action(1,4,2,8,0,127,0,0,0);
        if(stale!=prior_stale+1||dut.r_owner[1]!=0)$fatal(1,"unseen source delayed CLAIM rearmed after safety epoch");
        action(1,4,2,10,0,127,0,0,0);
        if(dut.r_owner[1]!=2)$fatal(1,"fresh CLAIM failed after safety epoch");
        // One valid frame updates all four notes together, with no trigger/STOP.
        action(1,0,4,10,0,127,0,0,0);
        prior_trigger=trigger_count[0]+trigger_count[1]+trigger_count[2]+trigger_count[3];
        scan_before=notes;scan_after=notes;scan_after[27:0]={7'd88,7'd70,7'd67,7'd55};scan_atomic_check=1;
        build_scan(0,4,10,1,(48'd2048<<36)|(48'd1<<24)|(48'd17<<12),15);send;scan_atomic_check=0;
        if(notes!==scan_after||scan_anomalies!=1||trigger_count[0]+trigger_count[1]+trigger_count[2]+trigger_count[3]!=prior_trigger)
            $fatal(1,"highest-fret/open atomic LEFT_SCAN or no-trigger contract");
        scan_before=notes;scan_after=notes;scan_after[27:0]={7'd88,7'd81,7'd74,7'd67};scan_atomic_check=1;
        build_scan(0,4,10,2,48'hffffffffffff,15);send;scan_atomic_check=0;
        if(notes!==scan_after||scan_anomalies!=5)$fatal(1,"full high-bit payload scan/multi anomaly count");
        prior_rejected=rejected;scan_before=notes;
        build_scan(0,4,10,3,0,7);send;
        if(notes!==scan_before||rejected!=prior_rejected+1||scan_anomalies!=5)$fatal(1,"partial-validity scan committed");
        prior_stale=stale;build_scan(0,4,10,2,0,15);send;
        if(notes!==scan_before||stale!=prior_stale+1)$fatal(1,"stale scan committed");
        prior_rejected=rejected;build_scan(0,2,10,4,0,15);send;
        if(notes!==scan_before||rejected!=prior_rejected+1)$fatal(1,"non-sensor scan admitted");
        build_scan(0,4,10,4,0,15);send;
        if(notes[27:0]!=={7'd76,7'd69,7'd62,7'd55})$fatal(1,"all-open scan failed");
        boundary;action(3,0,4,10,5,55,48,128,1);
        prior_trigger=trigger_count[0];build_scan(0,4,10,6,48'd1,15);send;
        if(!gates[0]||trigger_count[0]!=prior_trigger||notes[6:0]!=56)$fatal(1,"left scan restarted continuous bow");
        scan_before=notes;action(1,4,4,11,0,127,0,0,0);
        build_scan(4,4,11,1,(48'd2<<36)|(48'd4<<24)|(48'd8<<12)|48'd16,15);send;
        if(notes[27:0]!==scan_before[27:0]||notes[55:28]!=={7'd71,7'd67,7'd64,7'd72})$fatal(1,"U tuning scan or bank isolation");
        prior_stale=stale;prior_trigger=emergency_count;action(9,0,1,10,0,127,0,0,0);
        if(stale!=prior_stale+1||emergency_count!=prior_trigger)$fatal(1,"unused but globally older emergency admitted after other bank CLAIM");
        // Legacy effective plucks obey the same per-voice/frame admission.
        boundary;legacy_instrument[0]=1;legacy_pluck=1;
        prior_trigger=trigger_count[4];a5_manual(7,0);
        if(trigger_count[4]!=prior_trigger+1)$fatal(1,"first A5 synthetic pluck rejected");
        prior_rejected=rejected;a5_manual(7,0);
        if(trigger_count[4]!=prior_trigger+1||rejected!=prior_rejected+1)$fatal(1,"second same-frame A5 synthetic pluck admitted");
        boundary;a5_manual(7,0);legacy_pluck=0;
        if(trigger_count[4]!=prior_trigger+2)$fatal(1,"A5 synthetic pluck failed after frame boundary");
        // Actual 50MHz/115200 UART. A5 payload A6 and A6 payload A5 both occur.
        prior_a5=a5_event_count;prior_a5_error=a5_error_count;
        uart_a5(2,0,69,8'ha6,64);
        if(a5_event_count!=prior_a5+1||a5_error_count!=prior_a5_error||!serial_gates[0])$fatal(1,"real A5 UART bow rejected");
        prior_serial=serial_event_count;build(1,4,3,9,0,127,0,0,0);uart_packet;
        if(serial_event_count!=prior_serial+1||serial_crc!=0)$fatal(1,"A5 payload A6 swallowed next A6 CLAIM");
        prior_serial=serial_event_count;prior_a5=a5_event_count;
        build(4,4,3,9,1,60,8'ha5,0,0);uart_packet;
        if(serial_event_count!=prior_serial+1||a5_event_count!=prior_a5||serial_notes[34:28]!=60||serial_crc!=0)
            $fatal(1,"A6 payload A5 leaked into legacy parser");
        prior_a5=a5_event_count;uart_a5(3,0,127,0,0);
        if(a5_event_count!=prior_a5+1||serial_gates[0]||serial_notes[34:28]!=60)$fatal(1,"legacy STOP/A6 bank coexistence");
        $display("MEASURE rejected=%0d stale=%0d crc=%0d superseded=%0d scan_anomalies=%0d emergency_events=%0d serial_events=%0d A5_events=%0d",rejected,stale,crc_errors,superseded,scan_anomalies,emergency_count,serial_event_count,a5_event_count);
        $display("PASS revision6_router_tb: CRC, sequences, epoch, bank isolation/takeover, pressure, bounded A5/A6 triggers, contact, U release, timeout, atomic48 scan, fresh global emergency and delayed CLAIM, real UART A5/A6");
        $finish;
    end
endmodule
