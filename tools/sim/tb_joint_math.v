`timescale 1ns/1ps
module tb_joint_math;
parameter RATE=48828125,POS=96,T60=4000;
reg [31:0] p=0;reg [11:0] length=0;
wire [47:0] expected_loss;wire [23:0] expected_pick;
integer n,k,seed=32'h178951;
ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(2048),.SAMPLE_RATE_MILLIHZ(RATE),.PLUCK_POSITION_Q8(POS),.DECAY_T60_MILLISECONDS(T60)) dut();
assign expected_loss={16'd0,p}*dut.LOSS_PERIOD_SCALE_Q6;
assign expected_pick={12'd0,length}*dut.SAFE_PLUCK_POSITION;
initial begin
 force dut.r_target_length=length;
 force dut.r_note_period_stage1=p;
 for(n=0;n<100000;n=n+1)begin
  case(n%8)
   0:p=0;1:p=1;2:p=32'hffffffff;3:p=32'h80000000;
   4:p=32'h7fffffff;default:p=$random(seed);
  endcase
  length=n%2049;#1;
  if(dut.w_period_loss_product!==expected_loss || dut.w_pick_length_product!==expected_pick)$fatal(1,"constant product p=%h length=%0d",p,length);
 end
 $display("PASS tb_joint_math rate=%0d position=%0d coefficient=%0d cases=100000",RATE,POS,dut.LOSS_PERIOD_SCALE_Q6);$finish;
end
endmodule
