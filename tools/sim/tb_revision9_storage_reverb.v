`timescale 1ns/1ps
module tb_revision9_storage_reverb;
parameter RATE=48828125;
localparam C0=(64'd1559*RATE+24000000)/48000000;
localparam C1=(64'd1613*RATE+24000000)/48000000;
localparam C2=(64'd1699*RATE+24000000)/48000000;
localparam C3=(64'd1783*RATE+24000000)/48000000;
localparam A0=(64'd149*RATE+24000000)/48000000;
localparam A1=(64'd211*RATE+24000000)/48000000;
localparam A2=(64'd263*RATE+24000000)/48000000;
localparam TAIL_FRAMES=RATE==96000000 ? 5000 : (64'd255*RATE+99999)/100000;
reg clk=0,reset=1,clear=0,tick=0,bypass=0;
always #10 clk=~clk;
reg signed [15:0] sample=0;
reg [7:0] wet=255,damping=192;
reg [1:0] tail=3;
wire signed [15:0] pcm[0:1];
wire [1:0] valid,ready;
wire [31:0] guard[0:1];
`define PORTS(K) .i_clk(clk),.i_reset(reset),.i_clear(clear),.i_sample_tick(tick),.i_sample(sample), \
.i_bypass(bypass),.i_wet(wet),.i_damping(damping),.i_tail(tail),.o_sample(pcm[K]), \
.o_sample_valid(valid[K]),.o_ready(ready[K]),.o_guard_count(guard[K])
small_room_reverb_gold #(.SAMPLE_RATE_MILLIHZ(RATE)) gold(`PORTS(0));
small_room_reverb #(.SAMPLE_RATE_MILLIHZ(RATE)) dut(`PORTS(1));
`undef PORTS
integer n,j,k,seed=32'h981342ab,outputs=0,ap_writes=0,ram_checks=0,cycles=0;
integer prev_bank,prev_address;
reg check_write,prev_ready=0;
reg [23:0] prev_data;
task compare_ram;
begin
 for(k=0;k<A0;k=k+1)if(gold.r_ap0[k] !== {dut.r_ap_high[k],dut.r_ap_low[k]})$fatal(1,"AP0 RAM mismatch address=%0d",k);
 for(k=0;k<A1;k=k+1)if(gold.r_ap1[k] !== {dut.r_ap_high[A0+k],dut.r_ap_low[A0+k]})$fatal(1,"AP1 RAM mismatch address=%0d",k);
 for(k=0;k<A2;k=k+1)if(gold.r_ap2[k] !== {dut.r_ap_high[A0+A1+k],dut.r_ap_low[A0+A1+k]})$fatal(1,"AP2 RAM mismatch address=%0d",k);
 for(k=0;k<C0;k=k+1)if(gold.r_comb0[k] !== dut.r_comb0[k])$fatal(1,"comb0 mismatch");
 for(k=0;k<C1;k=k+1)if(gold.r_comb1[k] !== dut.r_comb1[k])$fatal(1,"comb1 mismatch");
 for(k=0;k<C2;k=k+1)if(gold.r_comb2[k] !== dut.r_comb2[k])$fatal(1,"comb2 mismatch");
 for(k=0;k<C3;k=k+1)if(gold.r_comb3[k] !== dut.r_comb3[k])$fatal(1,"comb3 mismatch");
 ram_checks=ram_checks+1;
end
endtask
always @(posedge clk)begin
 check_write=!gold.r_initializing && gold.r_state==11;
 prev_bank=gold.r_ap_bank;
 case(prev_bank)
  0:prev_address=gold.r_a0;
  1:prev_address=A0+gold.r_a1;
  2:prev_address=A0+A1+gold.r_a2;
 endcase
 prev_data=gold.state_value(gold.w_ap_write_value);
 if(check_write && (dut.w_ap_address!==prev_address || dut.w_ap_write_data!==prev_data))
  $fatal(1,"AP write transaction mismatch");
 #1;
 if({pcm[0],valid[0],ready[0],guard[0]} !== {pcm[1],valid[1],ready[1],guard[1]})$fatal(1,"PCM/valid/ready/guard mismatch cycle=%0d",cycles);
 if({gold.r_state,gold.r_initializing,gold.r_clear_index,gold.r_bank,gold.r_ap_bank,
     gold.r_a0,gold.r_a1,gold.r_a2,gold.r_ap_x,gold.r_ap_y,gold.r_ap_selected,
     gold.r_mult_a,gold.r_mult_b,gold.r_product,gold.r_lp0,gold.r_lp1,gold.r_lp2,gold.r_lp3} !==
    {dut.r_state,dut.r_initializing,dut.r_clear_index,dut.r_bank,dut.r_ap_bank,
     dut.r_a0,dut.r_a1,dut.r_a2,dut.r_ap_x,dut.r_ap_y,dut.r_ap_selected,
     dut.r_mult_a,dut.r_mult_b,dut.r_product,dut.r_lp0,dut.r_lp1,dut.r_lp2,dut.r_lp3})$fatal(1,"key state mismatch");
 if(gold.r_ap_delay !== dut.r_ap_delay)$fatal(1,"AP synchronous read mismatch");
 if(check_write)begin
  if({dut.r_ap_high[prev_address],dut.r_ap_low[prev_address]} !== prev_data)$fatal(1,"AP committed RAM mismatch");
  ap_writes=ap_writes+1;
 end
 if(ready[0] && !prev_ready)compare_ram;
 prev_ready=ready[0];
 if(valid[0])begin outputs=outputs+1;if(outputs%1024==0)compare_ram;end
 cycles=cycles+1;
end
task wait_ready;
begin while(!ready[0])@(negedge clk);end
endtask
task frame;
input integer noise;
begin
 tick=1;@(negedge clk);tick=0;
 repeat(43)begin
  if(noise!=0)begin sample=$random(seed);wet=$random(seed);tail=$random(seed);damping=$random(seed);bypass=$random(seed);end
  @(negedge clk);
 end
end
endtask
initial begin
 // Deliberately dirty memories: correctness cannot rely on power-up zero.
 for(k=0;k<A0+A1+A2;k=k+1)begin dut.r_ap_low[k]=16'h5ac3;dut.r_ap_high[k]=8'h96;end
 for(k=0;k<A0;k=k+1)gold.r_ap0[k]=24'h965ac3;
 for(k=0;k<A1;k=k+1)gold.r_ap1[k]=24'h965ac3;
 for(k=0;k<A2;k=k+1)gold.r_ap2[k]=24'h965ac3;
 repeat(4)@(negedge clk);reset=0;wait_ready;
 // Exercise signed reconstruction at RAM limits without relying on the
 // acoustic loop to happen to reach saturation or a one-Q8-unit value.
 for(k=0;k<A0+A1+A2;k=k+1)begin
  case(k%4)
   0:prev_data=24'h800000;1:prev_data=24'h7fffff;
   2:prev_data=24'hffffff;3:prev_data=24'h000010;
  endcase
  dut.r_ap_low[k]=prev_data[15:0];dut.r_ap_high[k]=prev_data[23:16];
  if(k<A0)gold.r_ap0[k]=prev_data;
  else if(k<A0+A1)gold.r_ap1[k-A0]=prev_data;
  else gold.r_ap2[k-A0-A1]=prev_data;
 end
 for(n=0;n<16;n=n+1)frame(0);
 // Abort every compute stage and restart clear while clear is in progress.
 for(n=0;n<42;n=n+1)begin
  sample=16'h7fff;tick=1;@(negedge clk);tick=0;repeat(n)@(negedge clk);
  clear=1;tick=1;@(negedge clk);clear=0;tick=0;repeat(13)@(negedge clk);
  clear=1;@(negedge clk);clear=0;wait_ready;
 end
 for(n=0;n<3000;n=n+1)begin
  case(n%4)0:sample=16'h8000;1:sample=16'h7fff;2:sample=-1;3:sample=$random(seed);endcase
  wet=n;damping=n>>2;tail=n;bypass=n%7==0;frame(1);
 end
 // Establish the longest configured tail, then stop excitation for >=2.55 s.
 wet=255;damping=192;tail=3;bypass=0;
 for(n=0;n<1000;n=n+1)begin sample=$random(seed);frame(0);end
 sample=0;
 for(n=0;n<TAIL_FRAMES;n=n+1)frame(0);
 compare_ram;
 if($test$plusargs("INJECT_ERROR"))begin
  $display("INJECTED_ERROR AP RAM");dut.r_ap_low[0]=~dut.r_ap_low[0];compare_ram;
 end
 if(outputs<TAIL_FRAMES || ap_writes<3*TAIL_FRAMES || ram_checks<40)$fatal(1,"coverage missing");
 $display("PASS tb_revision9_storage_reverb RATE=%0d outputs=%0d tail_frames=%0d ap_writes=%0d ram_checks=%0d",RATE,outputs,TAIL_FRAMES,ap_writes,ram_checks);$finish;
end
initial begin #600000000;$fatal(1,"timeout");end
endmodule
