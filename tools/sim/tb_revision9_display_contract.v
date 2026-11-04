`timescale 1ns/1ps
module tb_revision9_display_contract #(parameter integer BIN_SAMPLES=8);
reg clk=0; always #10 clk=~clk; reg pixel=0; always #7 pixel=~pixel;
reg sys_reset=1,pixel_reset=1,pcm_valid=0,frame_start=0; reg signed [15:0] pcm=0;
reg [27:0] notes=0; reg [3:0] gates=0,instruments=0; reg [63:0] open_notes=0; reg [31:0] bow_speeds=0; reg [95:0] bow_positions=0; reg [3:0] directions=0; reg [31:0] velocities=0,latency=0; reg audio_ready=1; reg [7:0] wave_address=0;
wire signed [15:0] wave_sample,wave_max; wire [15:0] peak,rms; wire [31:0] out_bow_speeds; wire [95:0] out_bow_positions; wire [3:0] out_directions; wire [27:0] out_notes; wire [3:0] out_gates; wire [63:0] out_open_notes; wire [3:0] out_instruments; wire [31:0] out_velocities,out_latency; wire out_audio_ready,capture_valid;
display_observer_cdc #(.BIN_SAMPLES(BIN_SAMPLES)) dut(.i_sys_clk(clk),.i_sys_reset(sys_reset),.i_pcm_valid(pcm_valid),.i_pcm(pcm),.i_notes(notes),.i_gates(gates),.i_instruments(instruments),.i_open_notes(open_notes),.i_bow_speeds(bow_speeds),.i_bow_positions(bow_positions),.i_directions(directions),.i_velocities(velocities),.i_latency_us(latency),.i_audio_ready(audio_ready),.i_pixel_clk(pixel),.i_pixel_reset(pixel_reset),.i_frame_start(frame_start),.i_wave_address(wave_address),.o_wave_sample(wave_sample),.o_wave_max(wave_max),.o_peak(peak),.o_rms(rms),.o_bow_speeds(out_bow_speeds),.o_bow_positions(out_bow_positions),.o_directions(out_directions),.o_notes(out_notes),.o_gates(out_gates),.o_open_notes(out_open_notes),.o_instruments(out_instruments),.o_velocities(out_velocities),.o_latency_us(out_latency),.o_audio_ready(out_audio_ready),.o_capture_valid(capture_valid));
wire signed [15:0] g_wave_sample,g_wave_max; wire [15:0] g_peak,g_rms; wire [31:0] g_out_bow_speeds; wire [95:0] g_out_bow_positions; wire [3:0] g_out_directions; wire [27:0] g_out_notes; wire [3:0] g_out_gates; wire [63:0] g_out_open_notes; wire [3:0] g_out_instruments; wire [31:0] g_out_velocities,g_out_latency; wire g_out_audio_ready,g_capture_valid;
display_observer_gold #(.BIN_SAMPLES(BIN_SAMPLES)) gold(.i_sys_clk(clk),.i_sys_reset(sys_reset),.i_pcm_valid(pcm_valid),.i_pcm(pcm),.i_notes(notes),.i_gates(gates),.i_instruments(instruments),.i_open_notes(open_notes),.i_bow_speeds(bow_speeds),.i_bow_positions(bow_positions),.i_directions(directions),.i_velocities(velocities),.i_latency_us(latency),.i_audio_ready(audio_ready),.i_pixel_clk(pixel),.i_pixel_reset(pixel_reset),.i_frame_start(frame_start),.i_wave_address(wave_address),.o_wave_sample(g_wave_sample),.o_wave_max(g_wave_max),.o_peak(g_peak),.o_rms(g_rms),.o_bow_speeds(g_out_bow_speeds),.o_bow_positions(g_out_bow_positions),.o_directions(g_out_directions),.o_notes(g_out_notes),.o_gates(g_out_gates),.o_open_notes(g_out_open_notes),.o_instruments(g_out_instruments),.o_velocities(g_out_velocities),.o_latency_us(g_out_latency),.o_audio_ready(g_out_audio_ready),.o_capture_valid(g_capture_valid));
always @(negedge pixel) if(!pixel_reset) begin
 if({peak,rms,out_bow_speeds,out_bow_positions,out_directions,out_notes,out_gates,out_open_notes,out_instruments,out_velocities,out_latency,out_audio_ready,capture_valid} !== {g_peak,g_rms,g_out_bow_speeds,g_out_bow_positions,g_out_directions,g_out_notes,g_out_gates,g_out_open_notes,g_out_instruments,g_out_velocities,g_out_latency,g_out_audio_ready,g_capture_valid}) $fatal(1,"FAIL metadata/publication cycle mismatch to baseline");
 if(capture_valid && {wave_sample,wave_max} !== {g_wave_sample,g_wave_max}) $fatal(1,"FAIL waveform baseline mismatch");
end

integer sample_index,bin,pass,lo,hi,v,ep,er,checks=0,reset_stage;
reg [63:0] sum;
reg [31:0] expected_square;
function integer value_at; input integer index,pattern;
begin case(pattern)
 0:value_at=index%2 ? -3000 : 1000;
 1:case(index%4)0:value_at=-32768;1:value_at=32767;2:value_at=0;default:value_at=123;endcase
 default:value_at=0;
endcase end endfunction
task check;input good;input [511:0] msg;begin checks=checks+1;if(good!==1'b1)$fatal(1,"FAIL BIN=%0d %0s",BIN_SAMPLES,msg);end endtask
task pulse_frame;begin @(negedge pixel);frame_start=1;@(negedge pixel);frame_start=0;end endtask
task reset_both;begin @(negedge clk);sys_reset=1;pixel_reset=1;pcm_valid=0;frame_start=0;repeat(5)@(negedge clk);sys_reset=0;pixel_reset=0;repeat(5)@(negedge pixel);check(!capture_valid,"reset hides invalid RAM");end endtask
task start_capture;begin notes=28'h1234567;gates=10;instruments=5;open_notes=64'h123456789abcdef0;bow_speeds=32'h10112233;bow_positions=96'h112233445566778899aabbcc;directions=9;velocities=32'h80402010;latency=33;audio_ready=1;pulse_frame;wait(dut.r_capture_busy);@(negedge clk);notes=0;gates=0;end endtask
task input_sample;input integer value;begin @(negedge clk);pcm=value;pcm_valid=1;@(negedge clk);pcm_valid=0;end endtask
initial begin
 reset_both;
 for(pass=0;pass<3;pass=pass+1)begin
  start_capture;sum=0;ep=0;
  for(sample_index=0;sample_index<256*BIN_SAMPLES;sample_index=sample_index+1)begin
   v=value_at(sample_index,pass);input_sample(v);expected_square=v*v;sum=sum+expected_square;if((v<0?-v:v)>ep)ep=v<0?-v:v;
  end
  check(!dut.r_capture_busy,"exact sample count completes capture");
  wait(dut.r_sqrt_count==0);repeat(5)@(negedge pixel);
  // Metadata does not publish until a pixel frame boundary.
  if(pass==0)check(!capture_valid,"no early publication");
  pulse_frame;check(capture_valid,"frame publishes capture");
  er=$rtoi($sqrt(sum/(256*BIN_SAMPLES)));
  $display("STAT pattern=%0d peak=%0d expected_peak=%0d rms=%0d expected_rms=%0d sum=%0d",pass,peak,ep,rms,er,sum);
  check(peak==ep && rms==er,"independent peak/RMS incl -32768");
  check(out_notes==28'h1234567 && out_gates==10 && out_instruments==5 && out_open_notes==64'h123456789abcdef0,"metadata frozen at capture start");
  check(out_bow_speeds==32'h10112233 && out_bow_positions==96'h112233445566778899aabbcc && out_directions==9 && out_velocities==32'h80402010 && out_latency==33 && out_audio_ready,"all metadata");
  for(bin=0;bin<256;bin=bin+1)begin
   lo=32767;hi=-32768;
   for(sample_index=0;sample_index<BIN_SAMPLES;sample_index=sample_index+1)begin v=value_at(bin*BIN_SAMPLES+sample_index,pass);if(v<lo)lo=v;if(v>hi)hi=v;end
   @(negedge pixel);wave_address=bin;repeat(2)@(negedge pixel);check(wave_sample==lo && wave_max==hi,"all bin extrema");
  end
  reset_both;
 end
 // Interrupt capture at several phases; reset and a fresh capture remain
 // cycle-identical to the pinned baseline. RAM is intentionally not reset.
 for(reset_stage=0;reset_stage<4;reset_stage=reset_stage+1)begin
  start_capture;
  for(sample_index=0;sample_index<(reset_stage==3?256*BIN_SAMPLES:reset_stage==2?255*BIN_SAMPLES:reset_stage+1);sample_index=sample_index+1)input_sample(1234);
  reset_both;
 end
 start_capture;for(sample_index=0;sample_index<256*BIN_SAMPLES;sample_index=sample_index+1)input_sample(1234);
 wait(dut.r_sqrt_count==0);repeat(5)@(negedge pixel);pulse_frame;
 check(capture_valid && peak==1234 && rms==1234,"recovery after reset interruptions");
 $display("PASS display contract BIN_SAMPLES=%0d checks=%0d",BIN_SAMPLES,checks);$finish;
end
initial begin #10000000;$fatal(1,"FAIL display contract watchdog");end
endmodule
