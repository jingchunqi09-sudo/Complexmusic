`timescale 1ns/1ps
// Actual nominal 50MHz sample spacing. The only expected output-time change
// is eight calculation clocks; complete PCM, raw voices and tags must match.
module revision6_bank_pipeline_twin_tb;
parameter integer RATE=48828125,PCM_FRAMES=40000,EXPECTED_DELTA=8;
reg clk=0,reset=1,tick=0,event_valid=0;
always #10 clk=~clk;
integer cycle=0,phase=0,frame=0,frames=0,nonzero=0,tags=0,fd;
wire [31:0] frame_length=RATE==48000000 ? (frame%3==0 ? 1041 : 1042) : 1024;
reg [55:0] notes={7'd73,7'd65,7'd60,7'd68,7'd78,7'd70,7'd63,7'd55};
reg [7:0] gates=0,triggers=0,stops=0,directions=0;
reg [63:0] velocity=64'hc0c0c0c080808080,event_clock=0;
reg [127:0] speed=128'h00000000000000000030003000300030;
reg [191:0] position={8{24'h800000}};
reg [31:0] depth=0,rate=32'h30303030,glide=0,sequence_number=0;
reg [3:0] auto_expression=0;
reg bypass=1;
reg [7:0] wet=64,damping=128;
reg [1:0] tail=1;
wire signed [15:0] pcm[0:1];
wire [127:0] voices[0:1];
wire [31:0] out_sequence[0:1],first_sequence[0:1],deadlines[0:1],clips[0:1];
wire [31:0] bodyguards[0:1],bodyclips[0:1],roomguards[0:1];
wire [63:0] out_clock[0:1];
wire [15:0] count[0:1],max_compute[0:1];
wire [1:0] valid,ready,first_sample;
`define TWIN_PORTS(N) \
 .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_event(event_valid), \
 .i_event_sequence(sequence_number),.i_event_clock(event_clock),.i_note_bus(notes),.i_gate_bus(gates), \
 .i_trigger_bus(triggers),.i_stop_bus(stops),.i_velocity_bus(velocity),.i_speed_bus(speed), \
 .i_position_bus(position),.i_direction_bus(directions),.i_vibrato_depth(depth),.i_vibrato_rate(rate), \
 .i_glide_ms(glide),.i_auto_expression(auto_expression),.i_emergency(1'b0),.i_fx_bypass(bypass), \
 .i_wet(wet),.i_damping(damping),.i_tail(tail),.o_audio_sample(pcm[N]),.o_audio_sample_valid(valid[N]), \
 .o_audio_first_sample(first_sample[N]),.o_ready(ready[N]),.o_voice_sample_bus(voices[N]),.o_active_mask(), \
 .o_output_sequence(out_sequence[N]),.o_output_event_clock(out_clock[N]), \
 .o_output_first_sequence(first_sequence[N]),.o_output_event_count(count[N]), \
 .o_deadline_count(deadlines[N]),.o_max_compute_clocks(max_compute[N]),.o_clip_count(clips[N]), \
 .o_body_guards(bodyguards[N]),.o_body_clips(bodyclips[N]),.o_reverb_guard(roomguards[N])
instrument_bank_core_pnr3 #(.SAMPLE_RATE_MILLIHZ(RATE)) baseline(`TWIN_PORTS(0));
instrument_bank_core #(.SAMPLE_RATE_MILLIHZ(RATE)) candidate(`TWIN_PORTS(1));
`undef TWIN_PORTS
reg [1:0] pending=0;
reg signed [15:0] saved_pcm[0:1];
reg [127:0] saved_voices[0:1];
reg [31:0] saved_sequence[0:1],saved_first[0:1];
reg [63:0] saved_clock[0:1];
reg [15:0] saved_count[0:1];
reg [1:0] saved_tag;
integer saved_cycle[0:1];
integer voice,member;
reg [1023:0] output_path;
initial begin
 if(!$value$plusargs("PCM=%s",output_path))$fatal(1,"FAIL missing PCM");
 fd=$fopen(output_path,"w");if(!fd)$fatal(1,"FAIL output file");
 repeat(6)@(negedge clk);#1;reset=0;
end
always @(negedge clk)if(!reset)begin
 cycle=cycle+1;tick=0;triggers=0;stops=0;event_valid=0;
 if(phase==frame_length-1)begin phase=0;frame=frame+1;end else phase=phase+1;
 if(phase==frame_length-1)tick=1;
 if(phase==200)begin
  case(frame)
   3:begin gates=15;triggers=255;event_valid=1;end
   200:begin position={24'h200000,24'h600000,24'ha00000,24'he00000,24'hf00000,24'ha00000,24'h600000,24'h100000};
       speed[63:0]=64'h00ff008000300001;directions=5;event_valid=1;end
   4000:begin notes[27:0]={7'd83,7'd74,7'd67,7'd60};glide=32'h15151515;depth=32'h030c183f;rate=32'h00300560;event_valid=1;end
   5000:begin triggers=240;event_valid=1;end
   6000:begin notes[55:28]={7'd79,7'd72,7'd67,7'd74};event_valid=1;end
   8000:begin triggers=240;notes[27:0]={7'd78,7'd70,7'd63,7'd55};directions=10;event_valid=1;end
   10000:begin gates=0;event_valid=1;end
   11000:begin gates=15;triggers=15;auto_expression=15;depth=0;event_valid=1;end
   12000:begin gates=13;stops=2;event_valid=1;end
   14000:begin triggers=240;velocity=64'h606080c080408060;event_valid=1;end
   15000:begin bypass=0;wet=64;damping=128;tail=1;event_valid=1;end
   22000:begin bypass=1;event_valid=1;end
   25000:begin bypass=0;wet=128;damping=255;tail=3;event_valid=1;end
   28000:begin gates=0;stops=255;event_valid=1;end
   30000:begin wet=0;event_valid=1;end
  endcase
  if(event_valid)begin sequence_number=sequence_number+1;event_clock=64'h0000000100000000+cycle;end
 end
end
always @(posedge clk)if(!reset)begin
 #1;
 if(ready[0]!==ready[1])$fatal(1,"FAIL ready identity");
 for(member=0;member<2;member=member+1)if(valid[member])begin
  if(pending[member])$fatal(1,"FAIL member%0d result overwritten",member);
  pending[member]=1;saved_pcm[member]=pcm[member];saved_voices[member]=voices[member];saved_sequence[member]=out_sequence[member];
  saved_clock[member]=out_clock[member];saved_first[member]=first_sequence[member];saved_count[member]=count[member];
  saved_tag[member]=first_sample[member];saved_cycle[member]=cycle;
 end
 if(&pending)begin
  if(saved_cycle[1]-saved_cycle[0]!=EXPECTED_DELTA)$fatal(1,"FAIL expected output delta%0d at frame%0d got%0d",EXPECTED_DELTA,frames,saved_cycle[1]-saved_cycle[0]);
  if(saved_pcm[1]!==saved_pcm[0] || saved_voices[1]!==saved_voices[0])begin
   for(voice=0;voice<8;voice=voice+1)
    $display("TWIN_RAW frame=%0d voice=%0d old=%0d new=%0d",frames,voice,$signed(saved_voices[0][voice*16 +:16]),$signed(saved_voices[1][voice*16 +:16]));
   $fatal(1,"FAIL PCM/raw-voice at frame%0d old%0d new%0d",frames,saved_pcm[0],saved_pcm[1]);
  end
  if(saved_sequence[1]!==saved_sequence[0] || saved_clock[1]!==saved_clock[0] || saved_first[1]!==saved_first[0] ||
     saved_count[1]!==saved_count[0] || saved_tag[1]!==saved_tag[0])$fatal(1,"FAIL complete tag at frame%0d",frames);
  pending=0;if(saved_pcm[1]!=0)nonzero=nonzero+1;if(saved_tag[1])tags=tags+saved_count[1];
  $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",frames,saved_cycle[0],saved_cycle[1],saved_pcm[1],saved_sequence[1],saved_clock[1],saved_first[1],saved_count[1],saved_tag[1]);
  frames=frames+1;
  if(frames==PCM_FRAMES)begin
   if(nonzero<100 || tags!=sequence_number || deadlines[0]!=0 || deadlines[1]!=0 || clips[0]!=0 || clips[1]!=0 ||
      bodyguards[0]!=0 || bodyguards[1]!=0 || bodyclips[0]!=0 || bodyclips[1]!=0 || roomguards[0]!=0 || roomguards[1]!=0)
      $fatal(1,"FAIL numerical/tag completeness");
   if(max_compute[0]!=82-EXPECTED_DELTA || max_compute[1]!=82)$fatal(1,"FAIL compute identity old%0d new%0d",max_compute[0],max_compute[1]);
   $fclose(fd);$display("PASS revision6_bank_pipeline_twin_tb: RATE=%0d frames=%0d nonzero=%0d tags=%0d old_compute=%0d new_compute=82 output_delta_clocks=%0d",RATE,frames,nonzero,tags,max_compute[0],EXPECTED_DELTA);$finish;
  end
 end
end
always @(posedge clk)if(!reset && frame>=3998 && frame<=4008)begin
 if(baseline.w_model_tick)$display("COMMIT old frame%0d neck%0d bridge%0d injection%0d posout%0d retune%0d",frame,
  baseline.PHYSICAL_STRING[1].BOWED.u_string.r_neck_outgoing,baseline.PHYSICAL_STRING[1].BOWED.u_string.r_bridge_outgoing,
  baseline.PHYSICAL_STRING[1].BOWED.u_string.r_bow_injection,baseline.PHYSICAL_STRING[1].BOWED.u_string.w_position_output,
  baseline.PHYSICAL_STRING[1].BOWED.u_string.r_retune_blend);
 if(candidate.w_model_tick)$display("COMMIT new frame%0d neck%0d bridge%0d injection%0d posout%0d retune%0d",frame,
  candidate.PHYSICAL_STRING[1].BOWED.u_string.r_neck_outgoing,candidate.PHYSICAL_STRING[1].BOWED.u_string.r_bridge_outgoing,
  candidate.PHYSICAL_STRING[1].BOWED.u_string.r_bow_injection,candidate.PHYSICAL_STRING[1].BOWED.u_string.w_position_output,
  candidate.PHYSICAL_STRING[1].BOWED.u_string.r_retune_blend);
end
endmodule
