`timescale 1ns/1ps
// Direct clean_pnr10 twin, arbitrary per-cycle metadata plus full blanking.
module tb_revision9_joint_video;
reg clk=0, reset=1;
always #5 clk=~clk;
reg [10:0] x=0;
reg [9:0] y=0;
reg de=0,hs=0,vs=0;
reg [27:0] notes=0;
reg [63:0] opens=0;
reg [3:0] gates=0,instruments=0,dirs=0;
reg [31:0] speeds=0,velocities=0,latency=0;
reg [95:0] positions=0;
reg signed [15:0] sample=0,maximum=0;
reg [15:0] peak=0,rms=0;
reg capture=0,ready=0;
wire [23:0] rgb[0:1];
wire [1:0] ode,ohs,ovs;
wire [7:0] address[0:1];
`define PORTS(K) .i_clk(clk),.i_reset(reset),.i_x(x),.i_y(y),.i_de(de),.i_hsync(hs),.i_vsync(vs), \
.i_notes(notes),.i_gates(gates),.i_instruments(instruments),.i_open_notes(opens), \
.i_bow_speeds(speeds),.i_bow_positions(positions),.i_directions(dirs), \
.i_wave_max(maximum),.i_peak(peak),.i_rms(rms),.i_velocities(velocities), \
.i_latency_us(latency),.i_ready(ready),.i_capture_valid(capture),.i_wave_sample(sample), \
.o_wave_address(address[K]),.o_red(rgb[K][23:16]),.o_green(rgb[K][15:8]),.o_blue(rgb[K][7:0]), \
.o_de(ode[K]),.o_hsync(ohs[K]),.o_vsync(ovs[K])
instrument_dashboard_gold gold(`PORTS(0));
instrument_dashboard dut(`PORTS(1));
`undef PORTS
integer checks=0,xx,yy,frame,n,seed=32'h39ba2157,shift,bow_position;
reg [31:0] rnd;
reg [13:0] glyph_address=0;
always @(posedge clk) begin
 #1;
 if({rgb[0],ode[0],ohs[0],ovs[0],address[0]} !== {rgb[1],ode[1],ohs[1],ovs[1],address[1]})
  $fatal(1,"video mismatch cycle=%0d x=%0d y=%0d old=%h new=%h",checks,x,y,rgb[0],rgb[1]);
 // Compare the changed predicate before colour composition can mask errors.
 if(gold.w_hit_wave_pcm !== dut.w_hit_wave_pcm)
  $fatal(1,"wave predicate mismatch y=%0d sample=%0d max=%0d shift=%0d",gold.r_ram_y,sample,maximum,gold.r_wave_shift);
 checks=checks+1;
 if(gold.w_glyph_pixel !== dut.w_glyph_pixel)
  $fatal(1,"glyph hit mismatch address=%h",glyph_address);
 if({gold.w_hit_bow_wood,gold.w_hit_bow_contact,gold.w_hit_bow_motion} !==
    {dut.w_hit_bow_wood,dut.w_hit_bow_contact,dut.w_hit_bow_motion})
  $fatal(1,"bow predicate mismatch x=%0d y=%0d",gold.r_ram_x,gold.r_ram_y);
end
task metadata;
 begin
  rnd=$random(seed);notes=rnd;opens={$random(seed),$random(seed)};
  gates=rnd[3:0];instruments=rnd[7:4];dirs=rnd[11:8];ready=rnd[12];capture=rnd[13];
  speeds=$random(seed);velocities=$random(seed);latency=$random(seed);
  positions={$random(seed),$random(seed),$random(seed)};
  peak=$random(seed);rms=$random(seed);sample=$random(seed);maximum=$random(seed);
 end
endtask
initial begin
 repeat(4) @(negedge clk);reset=0;
 force gold.r_selected_character=glyph_address[13:6];
 force dut.r_selected_character=glyph_address[13:6];
 force gold.r_selected_row=glyph_address[5:3];
 force dut.r_selected_row=glyph_address[5:3];
 force gold.r_selected_column=glyph_address[2:0];
 force dut.r_selected_column=glyph_address[2:0];
 for(n=0;n<16384;n=n+1)begin @(negedge clk);glyph_address=n;end
 @(negedge clk);
 release gold.r_selected_character;release dut.r_selected_character;
 release gold.r_selected_row;release dut.r_selected_row;
 release gold.r_selected_column;release dut.r_selected_column;
 reset=1;repeat(4)@(negedge clk);reset=0;
 // Every legal bow position and all 11-bit horizontal coordinates. Full-frame
 // and random-control tests below additionally cover Y and control alignment.
 capture=1;instruments=0;gates=15;
 for(bow_position=0;bow_position<128;bow_position=bow_position+1)begin
  positions={4{bow_position[6:0],17'd0}};
  for(xx=0;xx<2048;xx=xx+1)begin
   @(negedge clk);x=xx;y=112+(xx%4)*72+((xx/4)%54);dirs=xx;
  end
 end
 for(frame=0;frame<2;frame=frame+1)
 for(yy=0;yy<750;yy=yy+1)
 for(xx=0;xx<1650;xx=xx+1) begin
  @(negedge clk);x=xx;y=yy;de=xx<1280 && yy<720;hs=xx>=1390 && xx<1430;vs=yy>=725 && yy<730;
  if(xx%47==0)metadata;
  sample=$random(seed);maximum=$random(seed);
 end
 // Every raw sample value at every reachable scale, with boundary Y values.
 for(shift=2;shift<=10;shift=shift+1) begin
  peak=shift==2 ? 0 : (1<<(shift+5));capture=1;
  for(n=-32768;n<32768;n=n+1) begin
   @(negedge clk);sample=n;maximum=-n-1;
   case(n&7)
    0:y=0;1:y=1023;2:y=459;3:y=460;4:y=560;5:y=561;6:y=664;7:y=665;
   endcase
  end
 end
 // Arbitrary control transitions, full port coordinates, and midstream resets.
 for(n=0;n<30000;n=n+1) begin
  @(negedge clk);metadata;x=$random(seed);y=$random(seed);
  de=rnd[0];hs=rnd[1];vs=rnd[2];reset=n%997==0;
 end
 @(negedge clk);reset=0;repeat(10)@(negedge clk);
 $display("PASS joint dynamic video cycles=%0d full_frames=2",checks);$finish;
end
initial begin #100000000;$fatal(1,"video timeout");end
endmodule
