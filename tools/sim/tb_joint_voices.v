`timescale 1ns/1ps
module tb_joint_voices;
parameter D=1024,RATE=48828125,SHARE=1,PREP=24,OPTIONS=1,PROFILE=2,FINE=1,EXTERNAL=0,POS=96,SAMPLES=12000;
reg clk=0,reset=1,tick=0,prepare=0,trigger=0,stop=0,gate=0,direction=0;
reg [6:0] note=0; reg [7:0] velocity=0;
reg signed [15:0] speed=0; reg [23:0] position=0;
reg [31:0] period=0; reg [15:0] step=0;
wire [15:0] ua,ub,va,vb; wire ur,us,vr,vs; wire [31:0] ga,gb;
integer frame=0,k,checks=0,seed=32'h16a7339,nonzero=0,maxage=0,maxremaining=0;
reg [1:0] commit_phases=0;
always #10 clk=~clk;
`define UP .DELAY_LINE_LENGTH(D),.SAMPLE_RATE_MILLIHZ(RATE),.SHARE_POLARIZATION_MULTIPLIERS(SHARE),.ENABLE_PICK_COMB(OPTIONS),.ENABLE_DUAL_POLARIZATION(OPTIONS),.ENABLE_PHYSICAL_EXCITATION(OPTIONS),.EXTENDED_DECAY(OPTIONS),.ENABLE_EXTERNAL_PITCH(EXTERNAL),.PLUCK_POSITION_Q8(POS)
`define UI(A,R,G) .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(velocity),.i_external_period_q16(period),.i_external_excitation_step(step),.o_audio_sample(A),.o_ready(R),.o_guard_count(G)
ukulele_waveguide_voice_gold #(`UP) ug(`UI(ua,ur,ga));
ukulele_waveguide_voice #(`UP) ud(`UI(ub,us,gb));
`define VP .DELAY_LINE_LENGTH(D),.SAMPLE_RATE_MILLIHZ(RATE),.SHARE_INTERPOLATION_MULTIPLIER(SHARE),.SEPARATE_CONTROL_PREPARE(1),.ENABLE_FINE_PITCH(FINE),.BOW_CONTROL_PROFILE(PROFILE)
`define VI(A,R) .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_prepare_tick(prepare),.i_trigger(trigger),.i_stop(stop),.i_gate(gate),.i_midi_note(note),.i_velocity(velocity),.i_bow_speed(speed),.i_bow_position(position),.i_bow_direction(direction),.i_period_q16(period),.o_audio_sample(A),.o_ready(R)
violin_waveguide_voice_gold #(`VP) vg(`VI(va,vr));
violin_waveguide_voice #(`VP) vd(`VI(vb,vs));
`undef UP
`undef UI
`undef VP
`undef VI
task memories;
begin
 for(k=0;k<D;k=k+1) begin
  if(ug.r_delay_line[k]!==ud.r_delay_line[k] || ug.r_secondary_delay_line[k]!==ud.r_secondary_delay_line[k]) $fatal(1,"U RAM %0d",k);
 end
 for(k=0;k<D/2;k=k+1) if(ug.r_pick_history[k]!==ud.r_pick_history[k]) $fatal(1,"pick RAM %0d",k);
 for(k=0;k<vg.BRIDGE_MEMORY_DEPTH;k=k+1) if(vg.r_bridge_delay_line[k]!==vd.r_bridge_delay_line[k]) $fatal(1,"bridge RAM %0d",k);
 for(k=0;k<vg.NECK_MEMORY_DEPTH;k=k+1) if(vg.r_neck_delay_line[k]!==vd.r_neck_delay_line[k]) $fatal(1,"neck RAM %0d",k);
end
endtask
always @(posedge clk) begin
 // Pre-edge comparisons include every write enable/address/data and every
 // control/precompute register. Thus RAM transaction equality is checked
 // at its commit edge, including initialization and reset interactions.
 if(!reset && $time>100) begin
  // GENERATED_MONITORS
 end
 #1;
 if(!reset && tick && ur && vr) begin
  if({ua,va,ga,ur,vr}!=={ub,vb,gb,us,vs} || (^ub)===1'bx || (^vb)===1'bx) $fatal(1,"PCM/ready/guard frame=%0d",frame);
  if(ud.r_delay_index>=D || ud.r_secondary_delay_index>=D || ud.r_excitation_age>D || ud.r_excitation_remaining>=D || ud.r_secondary_excitation_remaining>=D || ud.r_pick_index>=D/2 || ud.r_pick_length>D/2) $fatal(1,"U bounds");
  if(vd.r_bridge_index>=vd.BRIDGE_MEMORY_DEPTH || vd.r_neck_index>=vd.NECK_MEMORY_DEPTH || vd.r_samples_since_trigger>vd.NECK_MEMORY_DEPTH) $fatal(1,"V bounds");
  if(ud.r_excitation_age>maxage)maxage=ud.r_excitation_age;
  if(ud.r_excitation_remaining>maxremaining)maxremaining=ud.r_excitation_remaining;
  checks=checks+1;if(ub!=0 || vb!=0)nonzero=nonzero+1;
  commit_phases[ud.r_multiply_secondary]=1'b1;
 end
end
initial begin
 repeat(5)@(negedge clk);reset=0;
 wait(ur && us && vr && vs);repeat(40)@(negedge clk);
 for(frame=0;frame<SAMPLES;frame=frame+1)begin
  @(negedge clk);
  // Complete a maximum-length fill before dynamic retune/retrigger tests.
  trigger=frame==0 || (frame>D+8 && (frame%31==0 || frame%127==1));
  stop=frame>D+8 && (frame%227==0 || frame%997==7);
  note=frame<=D+8 ? 0 : (frame/31)%128;
  velocity=frame<=D+8 ? 255 : $random(seed); gate=1;
  speed=$random(seed);position=$random(seed);direction=frame%2;
  step=$random(seed);
  case(frame%8)
   0:period=0;1:period=32'hffffffff;2:period=32'h00080000;
   3:period=(D+1)<<16;4:period=32'h0000ffff;default:period=$random(seed);
  endcase
  if(frame<=D+8)period=(D+1)<<16;
  prepare=1;@(negedge clk);prepare=0;
  // The one prepare cycle above counts toward the U stability interval.
  // Exactly PREP clocks from control change to tick assertion; alternate
  // commit phase naturally because the total frame length is now odd.
  repeat(PREP-1)@(negedge clk);tick=1;@(negedge clk);tick=0;
  // After a commit, vary velocity/trigger before settling for next tick:
  // specifically exercises the two-stage onset dependency across cycles.
  repeat(3)begin velocity=$random(seed);trigger=~trigger;@(negedge clk);end
  trigger=0;repeat(12)@(negedge clk);
  if(frame%1000==999)memories;
 end
 memories;
 if(SHARE && commit_phases!=2'b11)$fatal(1,"missing multiplier phase coverage");
 // Internal MIDI period clamps to D before subtracting one filter sample;
 // external pitch reaches the inclusive D length and D-1 remaining bound.
 if(checks!=SAMPLES || nonzero<100 || maxage!=(EXTERNAL ? D : (D==8 ? 8 : D-1)) || maxremaining!=(EXTERNAL ? D-1 : (D==8 ? 7 : D-2))) $fatal(1,"coverage checks=%0d nonzero=%0d age=%0d remaining=%0d D=%0d",checks,nonzero,maxage,maxremaining,D);
 $display("PASS tb_joint_voices D=%0d RATE=%0d checks=%0d nonzero=%0d maxage=%0d remaining=%0d",D,RATE,checks,nonzero,maxage,maxremaining);$finish;
end
initial begin #200000000;$fatal(1,"timeout");end
endmodule
