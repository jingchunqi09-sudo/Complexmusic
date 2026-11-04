`timescale 1ns/1ps
module tb_audio_mapping_20261018;
reg signed [15:0] speed=0;
reg direction=0,gate=1,stop=0;
reg [7:0] pressure=128;
integer s,d,p,mag,base,weak,expected1,expected2,checks=0;
violin_waveguide_voice #(.BOW_CONTROL_PROFILE(1),.ENABLE_BOW_LIFECYCLE(0),.ENABLE_FULL_SPEED_RANGE(1)) old_profile(
 .i_clk(1'b0),.i_reset(1'b1),.i_prepare_tick(1'b0),.i_period_q16(32'd0),.i_sample_tick(1'b0),.i_trigger(1'b0),
 .i_stop(stop),.i_gate(gate),.i_midi_note(7'd69),.i_velocity(pressure),.i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(24'd0));
violin_waveguide_voice #(.BOW_CONTROL_PROFILE(2),.ENABLE_BOW_LIFECYCLE(0),.ENABLE_FULL_SPEED_RANGE(1)) new_profile(
 .i_clk(1'b0),.i_reset(1'b1),.i_prepare_tick(1'b0),.i_period_q16(32'd0),.i_sample_tick(1'b0),.i_trigger(1'b0),
 .i_stop(stop),.i_gate(gate),.i_midi_note(7'd69),.i_velocity(pressure),.i_bow_speed(speed),.i_bow_direction(direction),.i_bow_position(24'd0));
initial begin
 for(d=0;d<2;d=d+1)for(s=-32768;s<=32767;s=s+1)begin
  speed=s;direction=d;mag=s<0?-s:s;if(mag>255)mag=255;
  base=mag<=48?mag*16:768+(mag-48)*5;
  weak=mag>0&&mag<16?32+14*mag:base;
  expected1=(s<0)^d?-base:base;expected2=(s<0)^d?-weak:weak;
  #1;
  if($signed(old_profile.w_bow_target_velocity)!==expected1||$signed(new_profile.w_bow_target_velocity)!==expected2)
   $fatal(1,"speed/direction mapping %0d %0d",s,d);
  checks=checks+1;
 end
 for(p=0;p<3;p=p+1)begin
  gate=p!=0;stop=p==1;pressure=p==2?0:128;#1;
  if(old_profile.w_bow_target_velocity!==0||new_profile.w_bow_target_velocity!==0)$fatal(1,"contact zero");
 end
 $display("PASS exhaustive 16-bit speed x direction %0d plus gate/STOP/zero pressure",checks);$finish;
end
endmodule
