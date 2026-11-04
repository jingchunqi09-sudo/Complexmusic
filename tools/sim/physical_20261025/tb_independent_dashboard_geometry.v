`timescale 1ns/1ps
// Independent, cycle-exact checker. Both instances use the unmodified vendor
// primitive model. All 11-bit X / 10-bit Y port values include blanking.
module tb_independent_dashboard_geometry;
GSR GSR(.GSRI(1'b1));
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
integer cycles=0,predicate_checks=0,xx,yy,frame,n,marker,dx,rr;
integer seed=32'h72f1839d;
reg [31:0] rnd;
reg [5:0] expected_de=0,expected_hs=0,expected_vs=0;
reg [3:0] saw_string=0,saw_fret=0,saw_marker=0,saw_velocity=0;
reg [3:0] saw_wood=0,saw_contact=0,saw_motion=0;
reg saw_row_digit=0,saw_latency_digit=0;
task check_geometry;
 begin
  if({gold.w_hit_string,gold.w_hit_fret,gold.w_hit_marker,gold.w_hit_velocity,
      gold.w_hit_bow_wood,gold.w_hit_bow_contact,gold.w_hit_bow_motion,
      gold.w_hit_header,gold.w_hit_wave,gold.w_hit_wave_grid,gold.w_hit_wave_pcm,
      gold.w_hit_bars,gold.w_bar_band,gold.w_number_valid,gold.w_number_latency} !==
     {dut.w_hit_string,dut.w_hit_fret,dut.w_hit_marker,dut.w_hit_velocity,
      dut.w_hit_bow_wood,dut.w_hit_bow_contact,dut.w_hit_bow_motion,
      dut.w_hit_header,dut.w_hit_wave,dut.w_hit_wave_grid,dut.w_hit_wave_pcm,
      dut.w_hit_bars,dut.w_bar_band,dut.w_number_valid,dut.w_number_latency})
   $fatal(1,"geometry mismatch cycle=%0d phase=%0d x=%0d y=%0d old_marker=%b new_marker=%b old_bow=%b/%b/%b new_bow=%b/%b/%b",
     cycles,frame,gold.r_ram_x,gold.r_ram_y,gold.w_hit_marker,dut.w_hit_marker,
     gold.w_hit_bow_wood,gold.w_hit_bow_contact,gold.w_hit_bow_motion,
     dut.w_hit_bow_wood,dut.w_hit_bow_contact,dut.w_hit_bow_motion);
  if({gold.w_number,gold.w_number_x,gold.w_number_y} !==
     {dut.w_number,dut.w_number_x,dut.w_number_y})
   $fatal(1,"digit selection mismatch cycle=%0d x=%0d y=%0d old=%h/%0d/%0d new=%h/%0d/%0d",
     cycles,gold.r_ram_x,gold.r_ram_y,gold.w_number,gold.w_number_x,gold.w_number_y,
     dut.w_number,dut.w_number_x,dut.w_number_y);
  saw_string=saw_string|gold.w_hit_string;
  saw_fret=saw_fret|gold.w_hit_fret;
  saw_marker=saw_marker|gold.w_hit_marker;
  saw_velocity=saw_velocity|gold.w_hit_velocity;
  saw_wood=saw_wood|gold.w_hit_bow_wood;
  saw_contact=saw_contact|gold.w_hit_bow_contact;
  saw_motion=saw_motion|gold.w_hit_bow_motion;
  saw_row_digit=saw_row_digit|(gold.w_number_valid&&!gold.w_number_latency);
  saw_latency_digit=saw_latency_digit|(gold.w_number_valid&&gold.w_number_latency);
  predicate_checks=predicate_checks+1;
 end
endtask
always @(posedge clk)begin
 if(reset)begin expected_de<=0;expected_hs<=0;expected_vs<=0;end
 else begin
  expected_de<={expected_de[4:0],de};
  expected_hs<={expected_hs[4:0],hs};
  expected_vs<={expected_vs[4:0],vs};
 end
 #1;
 if({rgb[0],ode[0],ohs[0],ovs[0],address[0]} !== {rgb[1],ode[1],ohs[1],ovs[1],address[1]})
  $fatal(1,"public mismatch cycle=%0d phase=%0d x=%0d y=%0d old=%h new=%h",cycles,frame,x,y,rgb[0],rgb[1]);
 if({ode[0],ohs[0],ovs[0]} !== {expected_de[5],expected_hs[5],expected_vs[5]} ||
    {ode[1],ohs[1],ovs[1]} !== {expected_de[5],expected_hs[5],expected_vs[5]})
  $fatal(1,"independent six-register timing mismatch cycle=%0d",cycles);
 check_geometry;
 cycles=cycles+1;
end
task metadata;
 begin
  rnd=$random(seed);notes=$random(seed);opens={$random(seed),$random(seed)};
  gates=rnd[3:0];instruments=rnd[7:4];dirs=rnd[11:8];ready=rnd[12];capture=rnd[13];
  speeds=$random(seed);velocities=$random(seed);latency=$random(seed);
  positions={$random(seed),$random(seed),$random(seed)};
  peak=$random(seed);rms=$random(seed);sample=$random(seed);maximum=$random(seed);
 end
endtask
initial begin
 frame=0;
 repeat(4)@(negedge clk);reset=0;
 capture=1;ready=1;gates=15;instruments=0;dirs=5;
 speeds=32'hff804001;velocities=32'hff804020;
 notes={7'd72,7'd69,7'd65,7'd60};opens={8{8'd60}};
 positions={7'd127,17'd0,7'd64,17'd0,7'd1,17'd0,7'd0,17'd0};
 latency=99999;peak=32767;rms=12345;sample=-12345;maximum=23456;
 // First pass: all coordinates with meaningful stable metadata and every row.
 // Second pass: arbitrary full-width metadata on every pixel clock.
 for(frame=0;frame<2;frame=frame+1)
 for(yy=0;yy<1024;yy=yy+1)
 for(xx=0;xx<2048;xx=xx+1)begin
  @(negedge clk);x=xx;y=yy;
  de=xx<1280&&yy<720;hs=xx>=1390&&xx<1430;vs=yy>=725&&yy<730;
  if(frame==1)metadata;
 end
 // Probe marker arithmetic outside the reachable fret-valid subset. Deposit
 // both old/new array words after their normal write, then sample predicates
 // before the next write. This is an interface/cone check, not a physical note.
 frame=2;capture=1;instruments=0;reset=0;
 for(marker=0;marker<2048;marker=marker+1)
 for(dx=-1;dx<=13;dx=dx+1)begin
  @(negedge clk);x=marker+dx;y=134+(marker%4)*72;
  gold.r_ram_x=x;dut.r_ram_x=x;gold.r_ram_y=y;dut.r_ram_y=y;
  gold.r_marker_valid=15;dut.r_marker_valid=15;
  gold.r_marker_x[0]=marker;dut.r_marker_x[0]=marker;
  gold.r_marker_x[1]=marker;dut.r_marker_x[1]=marker;
  gold.r_marker_x[2]=marker;dut.r_marker_x[2]=marker;
  gold.r_marker_x[3]=marker;dut.r_marker_x[3]=marker;
  #1;check_geometry;
 end
 frame=3;
 for(n=0;n<30000;n=n+1)begin
  @(negedge clk);metadata;x=$random(seed);y=$random(seed);
  de=rnd[0];hs=rnd[1];vs=rnd[2];reset=n%997==0;
 end
 @(negedge clk);reset=0;repeat(10)@(negedge clk);
 if({saw_string,saw_fret,saw_marker,saw_velocity,saw_wood,saw_contact,saw_motion}!==28'hfffffff ||
    !saw_row_digit || !saw_latency_digit)
  $fatal(1,"coverage missing string=%h fret=%h marker=%h velocity=%h wood=%h contact=%h motion=%h rowdigit=%b latencydigit=%b",
    saw_string,saw_fret,saw_marker,saw_velocity,saw_wood,saw_contact,saw_motion,saw_row_digit,saw_latency_digit);
 $display("PASS independent_dashboard_geometry cycles=%0d predicate_checks=%0d full_coordinates=%0d marker_probes=%0d metadata_random_cycles=%0d seed=%h",
   cycles,predicate_checks,2*2048*1024,2048*15,2048*1024+30000,32'h72f1839d);
 $finish;
end
initial begin #100000000;$fatal(1,"video timeout");end
endmodule
