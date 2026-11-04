`timescale 1ns/1ps
// Core-only accelerated ideal renderer. First two frames retain 1024 clocks
// for identical RAM initialization; subsequent frames use >=96 clocks.
// Current complete core computes in <=82 clocks. Event slots begin >=84.
// The runner maps atomic score controls to the same nominal sample index.
// Output clocks are NOMINAL virtual clocks, not measured UART/DAC latency.
module revision6_accelerated_score_tb;
parameter integer FRAME_CLOCKS=96, PCM_FRAMES=38437;
reg clk=0,reset=1;
integer cycle=0,frame_phase=0,music_sample=0,frames=0,nonzero=0;
integer render_sample=0,render_sim_tick=0;
wire [31:0] current_length=music_sample<2 ? 1024 : FRAME_CLOCKS;
wire sample_tick=!reset && frame_phase==current_length-1;
always #10 clk=~clk;
reg [688:0] controls=0,next_controls;
wire [55:0] notes;
wire [7:0] gates,triggers,stops,directions,wet,damping;
wire [63:0] velocity,event_clock;
wire [127:0] speed;
wire [191:0] position;
wire [31:0] depth,rate,glide,event_sequence;
wire [3:0] auto_expression;
wire event_valid,emergency,bypass;
wire [1:0] tail;
assign {notes,gates,triggers,stops,velocity,speed,position,directions,
 depth,rate,glide,auto_expression,event_valid,event_sequence,event_clock,emergency,bypass,wet,damping,tail}=controls;
wire signed [15:0] pcm;
wire pcm_valid,pcm_first,ready;
wire [31:0] out_sequence,first_sequence,deadlines,clips,body_guards,body_clips,reverb_guards;
wire [63:0] out_clock;
wire [15:0] event_count,max_compute;
wire [7:0] active_mask;
instrument_bank_core core(
 .i_clk(clk),.i_reset(reset),.i_sample_tick(sample_tick),.i_event(event_valid),
 .i_event_sequence(event_sequence),.i_event_clock(event_clock),.i_note_bus(notes),.i_gate_bus(gates),
 .i_trigger_bus(triggers),.i_stop_bus(stops),.i_velocity_bus(velocity),.i_speed_bus(speed),
 .i_position_bus(position),.i_direction_bus(directions),.i_vibrato_depth(depth),.i_vibrato_rate(rate),
 .i_glide_ms(glide),.i_auto_expression(auto_expression),.i_emergency(emergency),.i_fx_bypass(bypass),
 .i_wet(wet),.i_damping(damping),.i_tail(tail),.o_audio_sample(pcm),.o_audio_sample_valid(pcm_valid),
 .o_audio_first_sample(pcm_first),.o_ready(ready),.o_voice_sample_bus(),.o_active_mask(active_mask),
 .o_body_guards(body_guards),.o_body_clips(body_clips),.o_reverb_guard(reverb_guards),
 .o_output_sequence(out_sequence),.o_output_event_clock(out_clock),.o_output_first_sequence(first_sequence),
 .o_output_event_count(event_count),.o_deadline_count(deadlines),.o_max_compute_clocks(max_compute),.o_clip_count(clips));
reg [1023:0] control_path,pcm_path;
integer control_fd,pcm_fd,scan,next_cycle;
reg [63:0] virtual_output_clock;
initial begin
 if(FRAME_CLOCKS<96)$fatal(1,"FAIL accelerated frame budget too short");
 if(!$value$plusargs("CONTROL=%s",control_path))$fatal(1,"FAIL missing CONTROL");
 if(!$value$plusargs("PCM=%s",pcm_path))$fatal(1,"FAIL missing PCM");
 pcm_fd=$fopen(pcm_path,"w");if(!pcm_fd)$fatal(1,"FAIL PCM output");
 repeat(5)@(negedge clk);#2;reset=0;
 forever begin
  @(negedge clk);cycle=cycle+1;
  if(frame_phase==current_length-1)begin frame_phase=0;music_sample=music_sample+1;end
  else frame_phase=frame_phase+1;
 end
end
initial begin
 wait(!reset);#1;
 control_fd=$fopen(control_path,"r");if(!control_fd)$fatal(1,"FAIL control input");
 scan=$fscanf(control_fd,"%d %h\n",next_cycle,next_controls);
 while(scan==2)begin
  while(cycle<next_cycle)begin @(negedge clk);#1;end
  if(cycle!=next_cycle)$fatal(1,"FAIL accelerated control cycle %0d wanted %0d",cycle,next_cycle);
  controls=next_controls;
  scan=$fscanf(control_fd,"%d %h\n",next_cycle,next_controls);
 end
 $fclose(control_fd);
end
always @(posedge clk)if(!reset)begin
 if(sample_tick)begin render_sample=music_sample;render_sim_tick=cycle;end
 #1;
 if(pcm_valid)begin
  if(^pcm===1'bx)$fatal(1,"FAIL unknown PCM");
  virtual_output_clock=render_sample*64'd1024+64'd1023+(cycle-render_sim_tick);
  $fwrite(pcm_fd,"%0d %0d %0d %0d %0d %0d %0d %0d\n",frames,virtual_output_clock,$signed(pcm),
   out_sequence,out_clock,first_sequence,event_count,pcm_first);
  frames=frames+1;if(pcm!=0)nonzero=nonzero+1;
  if(frames==PCM_FRAMES)begin
   if(deadlines!=0 || nonzero<100)$fatal(1,"FAIL accelerated deadline/nonzero");
   $fclose(pcm_fd);
   $display("PASS revision6_accelerated_score_tb: frames=%0d nonzero=%0d frame_clocks=%0d max_compute=%0d deadline=%0d clips=%0d bodyguards=%0d bodyclips=%0d reverbguards=%0d",frames,nonzero,FRAME_CLOCKS,max_compute,deadlines,clips,body_guards,body_clips,reverb_guards);
   $finish;
  end
 end
end
endmodule
