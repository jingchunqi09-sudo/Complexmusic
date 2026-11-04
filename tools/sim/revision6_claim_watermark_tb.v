`timescale 1ns/1ps
// Independent regression for the production per-bank epoch watermark.
module revision6_claim_watermark_tb;
    reg clk=0, reset=1, frame_tick=0, byte_valid=0;
    reg [7:0] byte_data=0;
    reg legacy_event=0;
    reg [7:0] legacy_type=0, legacy_index=0;
    reg [3:0] legacy_gate=0, legacy_pluck=0, legacy_stop=0;
    wire [7:0] gates, stops;
    wire [55:0] notes;
    wire [31:0] stale, rejected;
    wire trace_valid;
    wire [2:0] disposition;
    wire [7:0] trace_source;
    wire [31:0] trace_epoch;
    reg [7:0] packet [0:19];
    reg [15:0] crc;
    integer j;
    always #10 clk=~clk;
    performance_bank_router #(.BOW_TIMEOUT_MS(0)) dut (
        .i_clk(clk), .i_reset(reset), .i_frame_tick(frame_tick),
        .i_open_notes(64'h45403c434c453e37),
        .i_byte_valid(byte_valid), .i_byte(byte_data),
        .i_legacy_event(legacy_event), .i_legacy_type(legacy_type),
        .i_legacy_index(legacy_index), .i_legacy_note({7'd76,7'd69,7'd62,7'd55}),
        .i_legacy_gate(legacy_gate), .i_legacy_pluck(legacy_pluck),
        .i_legacy_stop(legacy_stop), .i_legacy_velocity(32'h80808080),
        .i_legacy_speed(32'h30303030), .i_legacy_position(96'd0),
        .i_legacy_direction(4'd0), .i_legacy_instrument(4'd0),
        .o_note_bus(notes), .o_gate_bus(gates), .o_stop_bus(stops),
        .o_stale(stale), .o_rejected(rejected), .o_trace_valid(trace_valid),
        .o_trace_disposition(disposition), .o_trace_source(trace_source),
        .o_trace_epoch(trace_epoch), .o_view_instrument(), .o_trigger_bus(),
        .o_velocity_bus(), .o_speed_bus(), .o_position_bus(), .o_direction_bus(),
        .o_vibrato_depth(), .o_vibrato_rate(), .o_glide_ms(), .o_auto_expression(),
        .o_event(), .o_event_sequence(), .o_event_clock(), .o_emergency(),
        .o_wet(), .o_damping(), .o_tail(), .o_fx_bypass(), .o_superseded(),
        .o_crc_errors(), .o_trace_session_sequence(), .o_trace_opcode(),
        .o_trace_voice(), .o_trace_clock(), .o_scan_anomalies()
    );
    function [15:0] crc_update;
        input [15:0] c;
        input [7:0] b;
        reg [15:0] v;
        integer k;
        begin
            v=c^{b,8'd0};
            for(k=0;k<8;k=k+1) v=v[15]?(v<<1)^16'h1021:v<<1;
            crc_update=v;
        end
    endfunction
    task action;
        input [7:0] op, voice, source;
        input [31:0] epoch;
        input [15:0] seq;
        input [7:0] note, flags;
        begin
            packet[0]=8'ha6; packet[1]=1; packet[2]=op;
            packet[3]=voice; packet[4]=source;
            packet[5]=epoch[7:0]; packet[6]=epoch[15:8];
            packet[7]=epoch[23:16]; packet[8]=epoch[31:24];
            packet[9]=seq[7:0]; packet[10]=seq[15:8]; packet[11]=note;
            packet[12]=48; packet[13]=128; packet[14]=64;
            packet[15]=flags; packet[16]=0; packet[17]=0;
            crc=16'hffff;
            for(j=0;j<18;j=j+1) crc=crc_update(crc,packet[j]);
            packet[18]=crc[7:0]; packet[19]=crc[15:8];
            for(j=0;j<20;j=j+1)
            begin
                @(negedge clk); byte_valid=1; byte_data=packet[j];
                @(negedge clk); byte_valid=0;
            end
            $display("OBS op=%0d voice=%0d source=%0d epoch=%0d disposition=%0d ownerV=%0d epochV=%0d ownerU=%0d epochU=%0d stale=%0d rejected=%0d gate=%02x noteV0=%0d global=%0d safety=%0d",
                op,voice,source,epoch,disposition,dut.r_owner[0],dut.r_epoch[0],
                dut.r_owner[1],dut.r_epoch[1],stale,rejected,gates,notes[6:0],
                dut.r_global_epoch,dut.r_safety_epoch);
            repeat(3) @(negedge clk);
        end
    endtask
    task fresh_frame;
        begin
            @(negedge clk); frame_tick=1;
            @(negedge clk); frame_tick=0;
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); reset=1;
            repeat(4) @(negedge clk);
            reset=0;
            repeat(4) @(negedge clk);
        end
    endtask
    initial
    begin
        repeat(5) @(negedge clk); reset=0;
        repeat(4) @(negedge clk);
        $display("SCENARIO reject delayed unseen score/sensor CLAIM after human takeover");
        action(1,0,2,50,0,127,0);
        action(3,0,2,50,1,69,1);
        action(1,0,1,100,0,127,0); fresh_frame;
        action(3,0,1,100,1,72,1); fresh_frame;
        action(1,0,2,51,0,127,0);
        if(dut.r_owner[0]!=1 || dut.r_epoch[0]!=100 || stale!=1 ||
           disposition!=3 || !gates[0] || notes[6:0]!=72)
            $fatal(1,"Delayed unseen score CLAIM stole new human owner");
        action(3,0,2,51,1,62,1);
        if(stale!=2 || !gates[0] || notes[6:0]!=72)
            $fatal(1,"Action for rejected old CLAIM altered human note");
        action(1,0,4,99,0,127,0);
        if(stale!=3 || dut.r_owner[0]!=1 || dut.r_epoch[0]!=100 || !gates[0])
            $fatal(1,"Unseen sensor old CLAIM altered human owner");
        $display("SCENARIO equal bank epoch across sources is stale");
        action(1,0,4,100,0,127,0);
        action(1,0,2,100,0,127,0);
        if(stale!=5 || dut.r_owner[0]!=1 || dut.r_epoch[0]!=100 || !gates[0])
            $fatal(1,"Equal epoch across source displaced owner");
        $display("SCENARIO truly fresh sensor101 takeover and RELEASE retain watermark");
        action(1,0,4,101,0,127,0); fresh_frame;
        if(stale!=5 || disposition!=1 || dut.r_owner[0]!=4 ||
           dut.r_epoch[0]!=101 || gates[0])
            $fatal(1,"Fresh sensor101 takeover rejected or bow not released");
        action(3,0,4,101,1,74,1);
        action(2,0,4,101,2,127,0);
        if(dut.r_owner[0]!=0 || dut.r_epoch[0]!=101 || gates[0])
            $fatal(1,"RELEASE did not retain watermark");
        action(1,0,1,100,0,127,0);
        action(1,0,2,99,0,127,0);
        if(stale!=7 || dut.r_owner[0]!=0 || dut.r_epoch[0]!=101)
            $fatal(1,"Old CLAIM accepted after RELEASE");
        action(1,0,1,102,0,127,0);
        if(disposition!=1 || dut.r_owner[0]!=1 || dut.r_epoch[0]!=102)
            $fatal(1,"Fresh CLAIM102 after RELEASE rejected");
        $display("SCENARIO V102 and U51 retain independent ordinary CLAIM watermark");
        action(1,4,3,51,0,127,0);
        if(disposition!=1 || dut.r_owner[0]!=1 || dut.r_owner[1]!=3 ||
           dut.r_epoch[0]!=102 || dut.r_epoch[1]!=51 || stale!=7)
            $fatal(1,"Bank-independent fresh U51 refused after V102");
        // Also test the precise V100/U51 example on a clean state.
        reset_dut;
        action(1,0,1,100,0,127,0);
        action(1,4,3,51,0,127,0);
        if(disposition!=1 || dut.r_owner[0]!=1 || dut.r_owner[1]!=3 || stale!=0)
            $fatal(1,"Bank-independent U51 refused after V100");
        $display("SCENARIO legacy takeover retains A6 epoch watermark");
        fresh_frame;
        action(3,0,1,100,1,72,1);
        @(negedge clk); legacy_type=8; legacy_event=1;
        @(negedge clk); legacy_event=0;
        if(dut.r_owner[0]!=0 || dut.r_epoch[0]!=100 || gates[0])
            $fatal(1,"Legacy takeover erased epoch watermark");
        action(1,0,4,99,0,127,0);
        action(1,0,2,100,0,127,0);
        if(stale!=2 || dut.r_owner[0]!=0 || dut.r_epoch[0]!=100)
            $fatal(1,"Old/equal A6 CLAIM took bank after legacy takeover");
        action(1,0,2,101,0,127,0);
        if(disposition!=1 || dut.r_owner[0]!=2 || dut.r_epoch[0]!=101)
            $fatal(1,"Fresh A6 CLAIM rejected after legacy takeover");
        $display("SCENARIO existing global emergency safety remains intact");
        action(9,0,1,102,0,127,0);
        action(1,4,4,101,0,127,0);
        if(stale!=3 || dut.r_owner[0]!=0 || dut.r_owner[1]!=0 ||
           dut.r_safety_epoch!=102 || dut.r_global_epoch!=102)
            $fatal(1,"Safety watermark bypassed by old other-bank CLAIM");
        action(1,4,4,103,0,127,0);
        if(disposition!=1 || dut.r_owner[1]!=4 || dut.r_epoch[1]!=103)
            $fatal(1,"Fresh other-bank CLAIM after safety rejected");
        $display("PASS revision6_claim_watermark_tb: unseen old/equal CLAIM, fresh101 takeover, RELEASE/legacy watermark, independent banks, global safety");
        $finish;
    end
endmodule
