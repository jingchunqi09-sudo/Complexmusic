`timescale 1ns/1ps
module tb_revision9_parser_timeout;
reg clk=0; always #5 clk=~clk;
reg reset=1, frame_tick=0, byte_valid=0;
reg [7:0] byte_data=0;
reg [63:0] open_notes=0;
reg legacy_event=0; reg [7:0] legacy_type=0, legacy_index=0;
reg [27:0] legacy_note=0; reg [3:0] legacy_gate=0, legacy_pluck=0, legacy_stop=0;
reg [31:0] legacy_velocity=0, legacy_speed=0; reg [95:0] legacy_position=0;
reg [3:0] legacy_direction=0, legacy_instrument=0;
wire [3:0] view_instrument; wire [55:0] note_bus; wire [7:0] gate_bus,trigger_bus,stop_bus;
wire [63:0] velocity_bus; wire [127:0] speed_bus; wire [191:0] position_bus; wire [7:0] direction_bus;
wire [31:0] vibrato_depth,vibrato_rate,glide_ms; wire [3:0] auto_expression;
wire event_pulse; wire [31:0] event_sequence; wire [63:0] event_clock; wire emergency;
wire [7:0] wet,damping; wire [1:0] tail; wire fx_bypass; wire [31:0] rejected,stale,superseded,crc_errors;
wire trace_valid; wire [2:0] trace_disposition; wire [7:0] trace_source; wire [31:0] trace_epoch;
wire [15:0] trace_seq; wire [7:0] trace_opcode; wire [2:0] trace_voice; wire [63:0] trace_clock; wire [31:0] scan_anomalies;
performance_bank_router #(.CLOCK_HZ(1000),.BOW_TIMEOUT_MS(1000)) dut(
 .i_clk(clk),.i_reset(reset),.i_frame_tick(frame_tick),.i_open_notes(open_notes),.i_byte_valid(byte_valid),.i_byte(byte_data),
 .i_legacy_event(legacy_event),.i_legacy_type(legacy_type),.i_legacy_index(legacy_index),.i_legacy_note(legacy_note),.i_legacy_gate(legacy_gate),
 .i_legacy_pluck(legacy_pluck),.i_legacy_stop(legacy_stop),.i_legacy_velocity(legacy_velocity),.i_legacy_speed(legacy_speed),
 .i_legacy_position(legacy_position),.i_legacy_direction(legacy_direction),.i_legacy_instrument(legacy_instrument),
 .o_view_instrument(view_instrument),.o_note_bus(note_bus),.o_gate_bus(gate_bus),.o_trigger_bus(trigger_bus),.o_stop_bus(stop_bus),
 .o_velocity_bus(velocity_bus),.o_speed_bus(speed_bus),.o_position_bus(position_bus),.o_direction_bus(direction_bus),
 .o_vibrato_depth(vibrato_depth),.o_vibrato_rate(vibrato_rate),.o_glide_ms(glide_ms),.o_auto_expression(auto_expression),
 .o_event(event_pulse),.o_event_sequence(event_sequence),.o_event_clock(event_clock),.o_emergency(emergency),.o_wet(wet),.o_damping(damping),.o_tail(tail),.o_fx_bypass(fx_bypass),
 .o_rejected(rejected),.o_stale(stale),.o_superseded(superseded),.o_crc_errors(crc_errors),.o_trace_valid(trace_valid),.o_trace_disposition(trace_disposition),
 .o_trace_source(trace_source),.o_trace_epoch(trace_epoch),.o_trace_session_sequence(trace_seq),.o_trace_opcode(trace_opcode),.o_trace_voice(trace_voice),.o_trace_clock(trace_clock),.o_scan_anomalies(scan_anomalies));

reg [7:0] packet[0:19]; reg [15:0] crc;
integer k,n,mode,checks=0,cases=0,j;
function [15:0] crc_byte; input [15:0] c; input [7:0] d; reg [15:0] v; integer b;
begin v=c^{d,8'd0}; for(b=0;b<8;b=b+1) v=v[15]?(v<<1)^16'h1021:v<<1; crc_byte=v; end endfunction
task check; input condition; input [1023:0] msg;
begin checks=checks+1; if(condition!==1'b1) $fatal(1,"FAIL case=%0d state=%0d mode=%0d %0s",cases,n,mode,msg); end endtask
task reset_dut; begin @(negedge clk);reset=1;byte_valid=0;repeat(3)@(negedge clk);reset=0;end endtask
task send_byte; input [7:0] b;
begin @(negedge clk);byte_data=b;byte_valid=1;@(posedge clk);#1;byte_valid=0;end endtask
task make_packet; input [31:0] ep; integer a;
begin
 packet[0]=8'ha6;packet[1]=1;packet[2]=1;packet[3]=0;packet[4]=1;
 packet[5]=ep[7:0];packet[6]=ep[15:8];packet[7]=ep[23:16];packet[8]=ep[31:24];
 packet[9]=0;packet[10]=0;packet[11]=127;packet[12]=0;packet[13]=0;packet[14]=64;packet[15]=0;packet[16]=0;packet[17]=0;
 crc=16'hffff;for(a=0;a<18;a=a+1)crc=crc_byte(crc,packet[a]);packet[18]=crc[7:0];packet[19]=crc[15:8];
end endtask
// Wait for the *pre-edge* timeout predicate; no hierarchical forcing.
task at_age; input integer age;
begin while(dut.r_frame_age<age)begin @(posedge clk);#1;end @(negedge clk);end endtask
task edge_byte; input integer valid; input [7:0] b;
begin byte_valid=valid;byte_data=b;@(posedge clk);#1;byte_valid=0;end endtask
task accepted_claim; input [31:0] ep;
begin check(event_pulse && trace_valid && trace_disposition==1,"CLAIM accepted on last CRC edge");check(dut.r_owner[0]==1 && dut.r_epoch[0]==ep,"owner and epoch");check(dut.r_count==0,"closed packet");end endtask
task recover; input integer header_present; integer a;
begin make_packet(900);for(a=header_present;a<20;a=a+1)send_byte(packet[a]);accepted_claim(900);end endtask
initial begin
 // All 19 partial A6 states x no byte / payload / correct next byte (CRC
 // when state19) / A6 / A5. Old transaction never changes ownership/epoch.
 for(n=1;n<=19;n=n+1)for(mode=0;mode<5;mode=mode+1)begin
  cases=cases+1;reset_dut;make_packet(100);for(j=0;j<n;j=j+1)send_byte(packet[j]);
  at_age(50);edge_byte(mode!=0,mode==3?8'ha6:mode==4?8'ha5:mode==2?packet[n]:8'h55);
  check(crc_errors==1,"timeout counted once");check(!event_pulse && !trace_valid && event_sequence==0,"expired byte cannot publish");
  check(dut.r_owner[0]==0 && dut.r_epoch[0]==0 && dut.r_global_epoch==0 && dut.r_latest_epoch[0]==0 && dut.r_sequence_valid==0,"no stale ownership/watermark mutation");
  if(mode==3)begin
   check(dut.r_count==1 && dut.r_legacy_skip==0 && dut.r_crc==crc_byte(16'hffff,8'ha6),"independent A6 seed");recover(1);
  end else if(mode==4)begin
   check(dut.r_count==0 && dut.r_legacy_skip==6,"fresh A5 skip");for(j=0;j<6;j=j+1)send_byte(j==2?8'ha6:8'h44);check(dut.r_legacy_skip==0,"six bytes skipped");recover(0);
  end else begin
   check(dut.r_count==0 && dut.r_legacy_skip==0,"old transaction discarded");repeat(55)@(negedge clk);check(crc_errors==1,"idle timeout not repeated");recover(0);
  end
  check(crc_errors==1,"recovery CRC independent");
 end
 // Last legal pre-cutoff cycle for every partial state; deadline unchanged.
 for(n=1;n<=19;n=n+1)begin
  cases=cases+1;reset_dut;make_packet(100);for(j=0;j<n;j=j+1)send_byte(packet[j]);at_age(49);edge_byte(1,packet[n]);
  check(crc_errors==0,"pre-cutoff byte accepted");if(n==19)accepted_claim(100);else check(dut.r_count==n+1,"pre-cutoff progress");
 end
 // All six legacy skip positions and A6/A5/payload/no-byte collisions.
 for(n=1;n<=6;n=n+1)for(mode=0;mode<4;mode=mode+1)begin
  cases=cases+1;reset_dut;send_byte(8'ha5);for(j=6;j>n;j=j-1)send_byte(8'h33);
  at_age(50);edge_byte(mode!=0,mode==2?8'ha6:mode==3?8'ha5:8'h44);
  check(crc_errors==1 && !event_pulse,"A5 timeout only once/no event");
  if(mode==2)begin check(dut.r_count==1 && dut.r_legacy_skip==0,"A5 timeout to A6");recover(1);end
  else if(mode==3)begin check(dut.r_legacy_skip==6,"A5 timeout to A5");for(j=0;j<6;j=j+1)send_byte(8'h66);recover(0);end
  else begin check(dut.r_count==0 && dut.r_legacy_skip==0,"A5 timeout cleared");recover(0);end
 end
 // A header one cycle after timeout is handled by the normal idle parser.
 cases=cases+1;reset_dut;send_byte(8'ha6);at_age(50);edge_byte(0,0);send_byte(8'ha6);recover(1);
 check(crc_errors==1,"post-cutoff recovery");
 // Reset wins even with a timeout/header collision.
 cases=cases+1;reset_dut;send_byte(8'ha6);at_age(50);reset=1;edge_byte(1,8'ha6);check(dut.r_count==0 && crc_errors==0,"reset priority");
 $display("PASS A6 timeout directed cases=%0d checks=%0d",cases,checks);$finish;
end
initial begin #10000000;$fatal(1,"FAIL test watchdog");end
endmodule
