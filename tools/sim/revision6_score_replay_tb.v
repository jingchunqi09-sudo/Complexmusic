`timescale 1ns/1ps
// B records the complete public core input on the clock where the core consumes it.
// A1 replays that file in a fresh simulation; A0 uses independently generated
// atomic score-time controls. PCM comparison is performed by the Python runner.
module revision6_score_replay_tb;
parameter integer MODE=0, END_CYCLE=40000000;
reg clk=0, reset=1, uart_rx=1;
integer cycle=0, frames=0, nonzero=0, trace_count=0;
always #10 clk=~clk;
wire sample_tick=!reset && cycle[9:0]==10'd1023;
wire rx_valid, legacy_event;
wire [7:0] rx_byte, legacy_type, legacy_index;
wire [27:0] legacy_note;
wire [3:0] legacy_gate, legacy_pluck, legacy_stop, legacy_direction, legacy_instrument;
wire [31:0] legacy_velocity, legacy_speed;
wire [95:0] legacy_position;
wire [55:0] b_note;
wire [7:0] b_gate,b_trigger,b_stop,b_direction,b_wet,b_damping;
wire [63:0] b_velocity;
wire [127:0] b_speed;
wire [191:0] b_position;
wire [31:0] b_depth,b_rate,b_glide,b_sequence;
wire [63:0] b_clock;
wire [3:0] b_auto;
wire b_event,b_emergency,b_bypass;
wire [1:0] b_tail;
wire [31:0] rejected,stale,superseded,crc_errors;
wire trace_valid;
wire [2:0] disposition,trace_voice;
wire [7:0] trace_source,trace_opcode;
wire [31:0] trace_epoch;
wire [63:0] trace_clock;
wire [15:0] trace_sequence;
uart_event_bridge #(.CLOCK_HZ(50000000),.BAUD_RATE(115200),.BOW_TIMEOUT_MS(1000),.DEFAULT_INSTRUMENTS(0)) bridge(
 .i_clk(clk),.i_reset(reset),.i_uart_rx(uart_rx),.i_open_notes(64'h45403c434c453e37),
 .o_rx_byte_valid(rx_valid),.o_rx_byte_data(rx_byte),.o_legacy_type(legacy_type),.o_legacy_index(legacy_index),
 .o_note_bus(legacy_note),.o_gate_bus(legacy_gate),.o_pluck_pulse_bus(legacy_pluck),.o_stop_pulse_bus(legacy_stop),
 .o_velocity_bus(legacy_velocity),.o_bow_speed_bus(legacy_speed),.o_bow_position_bus(legacy_position),
 .o_direction_bus(legacy_direction),.o_instrument_select_bus(legacy_instrument),.o_event_pulse(legacy_event),
 .o_frame_error(),.o_tuning_write(),.o_tuning_address(),.o_tuning_note(),.o_tuning_commit(),
 .o_spi_profile_write(),.o_spi_adapter(),.o_spi_field(),.o_spi_value(),.o_status_request(),
 .o_sensor_snapshot_request(),.o_scope_request(),.o_scope_capture(),.o_scope_index(),.o_sensor_snapshot_adapter(),
 .o_diag_request(),.o_diag_index());
performance_bank_router router(
 .i_clk(clk),.i_reset(reset),.i_frame_tick(sample_tick),.i_open_notes(64'h45403c434c453e37),
 .i_byte_valid(rx_valid),.i_byte(rx_byte),
 .i_legacy_event(legacy_event),.i_legacy_type(legacy_type),.i_legacy_index(legacy_index),.i_legacy_note(legacy_note),
 .i_legacy_gate(legacy_gate),.i_legacy_pluck(legacy_pluck),.i_legacy_stop(legacy_stop),
 .i_legacy_velocity(legacy_velocity),.i_legacy_speed(legacy_speed),.i_legacy_position(legacy_position),
 .i_legacy_direction(legacy_direction),.i_legacy_instrument(legacy_instrument),.o_view_instrument(),
 .o_note_bus(b_note),.o_gate_bus(b_gate),.o_trigger_bus(b_trigger),.o_stop_bus(b_stop),
 .o_velocity_bus(b_velocity),.o_speed_bus(b_speed),.o_position_bus(b_position),.o_direction_bus(b_direction),
 .o_vibrato_depth(b_depth),.o_vibrato_rate(b_rate),.o_glide_ms(b_glide),.o_auto_expression(b_auto),
 .o_event(b_event),.o_event_sequence(b_sequence),.o_event_clock(b_clock),.o_emergency(b_emergency),
 .o_wet(b_wet),.o_damping(b_damping),.o_tail(b_tail),.o_fx_bypass(b_bypass),
 .o_rejected(rejected),.o_stale(stale),.o_superseded(superseded),.o_crc_errors(crc_errors),
 .o_trace_valid(trace_valid),.o_trace_disposition(disposition),.o_trace_source(trace_source),
 .o_trace_epoch(trace_epoch),.o_trace_session_sequence(trace_sequence),.o_trace_opcode(trace_opcode),
 .o_trace_voice(trace_voice),.o_trace_clock(trace_clock),.o_scan_anomalies());
wire [688:0] b_bundle={b_note,b_gate,b_trigger,b_stop,b_velocity,b_speed,b_position,b_direction,
 b_depth,b_rate,b_glide,b_auto,b_event,b_sequence,b_clock,b_emergency,b_bypass,b_wet,b_damping,b_tail};
reg [688:0] replay_bundle=0, previous_bundle;
wire [688:0] chosen=MODE==0 ? b_bundle : replay_bundle;
wire [55:0] note_bus;
wire [7:0] gate_bus,trigger_bus,stop_bus,direction_bus,wet,damping;
wire [63:0] velocity_bus;
wire [127:0] speed_bus;
wire [191:0] position_bus;
wire [31:0] depth,rate,glide,event_sequence;
wire [63:0] event_clock;
wire [3:0] auto_expression;
wire event_valid,emergency,bypass;
wire [1:0] tail;
assign {note_bus,gate_bus,trigger_bus,stop_bus,velocity_bus,speed_bus,position_bus,direction_bus,
 depth,rate,glide,auto_expression,event_valid,event_sequence,event_clock,emergency,bypass,wet,damping,tail}=chosen;
wire signed [15:0] pcm;
wire pcm_valid,pcm_first,ready;
wire [31:0] out_sequence,first_sequence,deadline,clip_count;
wire [63:0] out_clock;
wire [15:0] event_count,max_compute;
instrument_bank_core core(
 .i_clk(clk),.i_reset(reset),.i_sample_tick(sample_tick),.i_event(event_valid),
 .i_event_sequence(event_sequence),.i_event_clock(event_clock),.i_note_bus(note_bus),.i_gate_bus(gate_bus),
 .i_trigger_bus(trigger_bus),.i_stop_bus(stop_bus),.i_velocity_bus(velocity_bus),.i_speed_bus(speed_bus),
 .i_position_bus(position_bus),.i_direction_bus(direction_bus),.i_vibrato_depth(depth),.i_vibrato_rate(rate),
 .i_glide_ms(glide),.i_auto_expression(auto_expression),.i_emergency(emergency),.i_fx_bypass(bypass),
 .i_wet(wet),.i_damping(damping),.i_tail(tail),.o_audio_sample(pcm),.o_audio_sample_valid(pcm_valid),
 .o_audio_first_sample(pcm_first),.o_ready(ready),.o_voice_sample_bus(),.o_active_mask(),
 .o_body_guards(),.o_body_clips(),.o_reverb_guard(),.o_output_sequence(out_sequence),
 .o_output_event_clock(out_clock),.o_output_first_sequence(first_sequence),.o_output_event_count(event_count),
 .o_deadline_count(deadline),.o_max_compute_clocks(max_compute),.o_clip_count(clip_count));
reg [1023:0] case_path,control_path,pcm_path,trace_path,tx_path,schedule_path;
integer control_fd,pcm_fd,trace_fd,tx_fd,schedule_fd,scan,next_cycle,j,k;
reg [159:0] packet;
task uart_byte;
 input [7:0] value;
 integer bit_index;
 begin
  uart_rx=0;repeat(434)begin @(negedge clk);#1;end
  for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
   uart_rx=value[bit_index];repeat(434)begin @(negedge clk);#1;end
  end
  uart_rx=1;repeat(434)begin @(negedge clk);#1;end
 end
endtask
initial begin
 if(!$value$plusargs("CASE=%s",case_path))$fatal(1,"FAIL missing CASE");
 if(!$value$plusargs("PCM=%s",pcm_path))$fatal(1,"FAIL missing PCM");
 if(!$value$plusargs("CONTROL=%s",control_path))$fatal(1,"FAIL missing CONTROL");
 pcm_fd=$fopen(pcm_path,"w");if(!pcm_fd)$fatal(1,"FAIL PCM output");
 if(MODE==0)begin
  if(!$value$plusargs("TRACE=%s",trace_path))$fatal(1,"FAIL missing TRACE");
  if(!$value$plusargs("TX=%s",tx_path))$fatal(1,"FAIL missing TX");
  trace_fd=$fopen(trace_path,"w");tx_fd=$fopen(tx_path,"w");
  control_fd=$fopen(control_path,"w");
 end
 repeat(5)@(negedge clk);#2;reset=0;
 forever begin @(negedge clk);cycle=cycle+1;end
end
initial begin
 wait(!reset);#1;
 if(MODE==0)begin
  if(!$value$plusargs("SCHEDULE=%s",schedule_path))$fatal(1,"FAIL missing SCHEDULE");
  schedule_fd=$fopen(schedule_path,"r");if(!schedule_fd)$fatal(1,"FAIL schedule input");
  scan=$fscanf(schedule_fd,"%d %h\n",next_cycle,packet);
  while(scan==2)begin
   while(cycle<next_cycle)begin @(negedge clk);#1;end
   $fwrite(tx_fd,"%0d %h\n",cycle,packet);
   for(j=0;j<20;j=j+1)uart_byte(packet[159-j*8 -:8]);
   scan=$fscanf(schedule_fd,"%d %h\n",next_cycle,packet);
  end
  $fclose(schedule_fd);
 end else begin
  control_fd=$fopen(control_path,"r");if(!control_fd)$fatal(1,"FAIL replay input");
  scan=$fscanf(control_fd,"%d %h\n",next_cycle,previous_bundle);
  while(scan==2)begin
   while(cycle<next_cycle)begin @(negedge clk);#1;end
   if(cycle!=next_cycle)$fatal(1,"FAIL replay clock %0d wanted %0d",cycle,next_cycle);
   replay_bundle=previous_bundle;
   scan=$fscanf(control_fd,"%d %h\n",next_cycle,previous_bundle);
  end
  $fclose(control_fd);
 end
end
always @(posedge clk)if(!reset)begin
 if(MODE==0 && (cycle==0 || b_bundle!==previous_bundle))begin
  $fwrite(control_fd,"%0d %h\n",cycle,b_bundle);previous_bundle=b_bundle;
 end
 #1;
 if(MODE==0 && trace_valid)begin
  trace_count=trace_count+1;
  $fwrite(trace_fd,"%0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,disposition,
   trace_source,trace_epoch,trace_sequence,trace_opcode,trace_voice,trace_clock);
 end
 if(pcm_valid)begin
  if(^pcm===1'bx)$fatal(1,"FAIL unknown PCM");
  $fwrite(pcm_fd,"%0d %0d %0d %0d %0d %0d %0d %0d\n",frames,cycle,$signed(pcm),
   out_sequence,out_clock,first_sequence,event_count,pcm_first);
  frames=frames+1;if(pcm!=0)nonzero=nonzero+1;
 end
 if(cycle>=END_CYCLE)begin
  if(deadline!=0 || frames<1000 || nonzero<100)$fatal(1,"FAIL score frames/nonzero/deadline");
  if(MODE==0 && (rejected || stale || crc_errors))$fatal(1,"FAIL admission errors");
  $fclose(pcm_fd);
  if(MODE==0)begin $fclose(control_fd);$fclose(trace_fd);$fclose(tx_fd);end
  $display("PASS revision6_score_replay_tb: mode=%0d frames=%0d nonzero=%0d traces=%0d deadline=%0d max_compute=%0d clips=%0d",MODE,frames,nonzero,trace_count,deadline,max_compute,clip_count);
  $finish;
 end
end
endmodule
