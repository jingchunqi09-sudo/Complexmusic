`timescale 1ns/1ps
// Physical UART in/out, emergency reinitialization and persistent 64-bit diagnostics.
module revision6_safety_diag_tb;
parameter integer EXTERNAL=0;
reg clk=0,bck=0,reset_n=0,rx=1;
wire tx,pa;
integer errors=0,k,j,trigger_count=0,completed=0,scan_triggers,saved_sequence;
reg [7:0] packet[0:19],received[0:11];
reg [15:0] crc;
reg [7:0] data_byte,checksum;
integer rx_index=0,diag_count=0;
reg [31:0] first[0:11],second[0:11];
reg [11:0] seen=0;
reg [63:0] saved_clock;
reg [55:0] expected_notes;
always #10 clk=~clk;
always #325.520833 bck=~bck;
tang_mega_60k_top #(.ENABLE_HDMI(0),.USE_EXTERNAL_AUDIO_CLOCK(EXTERNAL)) dut (
.clk_50m(clk),.audio_bck_in(bck),.reset_n(reset_n),.uart_rx(rx),.uart_tx(tx),.pa_en(pa),
.adc0_miso(1'b0),.adc1_miso(1'b0),.adc2_miso(1'b0),
.adc0_sck(),.adc0_mosi(),.adc0_cs_n(),.adc1_sck(),.adc1_mosi(),.adc1_cs_n(),
.adc2_sck(),.adc2_mosi(),.adc2_cs_n(),.hp_bck(),.hp_ws(),.hp_din(),
.latency_event_gpio(),.latency_audio_gpio(),
.hdmi_data_p(),.hdmi_data_n(),.hdmi_clock_p(),.hdmi_clock_n(),.hdmi_tx_enable());
task check;
input condition;input [767:0] message;
begin
if(!condition)begin errors=errors+1;$display("FAIL: %0s",message);end
end
endtask
function [15:0] crc_byte;
input [15:0] c;input [7:0] d;reg [15:0] v;integer q;
begin
v=c^{d,8'd0};for(q=0;q<8;q=q+1)v=v[15] ? (v<<1)^16'h1021 : v<<1;crc_byte=v;
end
endfunction
task byte_out;
input [7:0] value;integer q;
begin
@(negedge clk);rx=0;repeat(434)@(negedge clk);
for(q=0;q<8;q=q+1)begin rx=value[q];repeat(434)@(negedge clk);end
rx=1;repeat(434)@(negedge clk);
end
endtask
task send_packet;
begin
crc=16'hffff;for(k=0;k<18;k=k+1)crc=crc_byte(crc,packet[k]);
packet[18]=crc[7:0];packet[19]=crc[15:8];
for(k=0;k<20;k=k+1)byte_out(packet[k]);
end
endtask
task prepare;
input [7:0] op,voice,source;input [31:0] epoch;input [15:0] seq;
input [7:0] note,value,pressure,flags;
begin
packet[0]=8'ha6;packet[1]=1;packet[2]=op;packet[3]=voice;packet[4]=source;
packet[5]=epoch[7:0];packet[6]=epoch[15:8];packet[7]=epoch[23:16];packet[8]=epoch[31:24];
packet[9]=seq[7:0];packet[10]=seq[15:8];packet[11]=note;packet[12]=value;
packet[13]=pressure;packet[14]=64;packet[15]=flags;packet[16]=0;packet[17]=0;
end
endtask
task action;
input [7:0] op,voice,source;input [31:0] epoch;input [15:0] seq;
input [7:0] note,value,pressure,flags;
begin prepare(op,voice,source,epoch,seq,note,value,pressure,flags);send_packet;end
endtask
task query;
input [7:0] index;
begin
byte_out(8'ha5);byte_out(8'h24);byte_out(index);byte_out(0);byte_out(0);byte_out(0);byte_out(8'h24^index);
repeat(200000)@(negedge clk);
check(seen[index],"real UART diagnostic response received");
end
endtask
always @(negedge clk)
begin
if(reset_n && dut.w_bank_triggers!=0)trigger_count=trigger_count+1;
if(reset_n && dut.w_event_word_complete)completed=completed+1;
end
// Decode actual TX pin; preserve every byte and verify the on-wire checksum.
initial
begin
wait(reset_n);
forever
begin
@(negedge tx);#4340;check(!tx,"UART response start bit");
for(j=0;j<8;j=j+1)begin #8680;data_byte[j]=tx;end
#8680;check(tx,"UART response stop bit");
if(rx_index!=0 || data_byte==8'hd5)
begin
received[rx_index]=data_byte;rx_index=rx_index+1;
if(rx_index==12)
begin
checksum=0;for(j=1;j<11;j=j+1)checksum=checksum^received[j];
check(checksum==received[11],"D5 status XOR exactly matches wire bytes");
if(received[1]==4)
begin
check(received[2][3:0]<=11,"diagnostic index in range");
seen[received[2][3:0]]=1;
first[received[2][3:0]]={received[6],received[5],received[4],received[3]};
second[received[2][3:0]]={received[10],received[9],received[8],received[7]};
diag_count=diag_count+1;
end
rx_index=0;
end
end
end
end
initial
begin
repeat(10)@(negedge clk);reset_n=1;wait(dut.w_audio_ready);repeat(4000)@(negedge clk);
// Exercise a nonzero high word without simulating 86 seconds; this is a width test.
force dut.u_router.r_clock=64'h00000001ffff0000;
@(negedge clk);release dut.u_router.r_clock;
action(1,0,2,1,0,127,0,0,0);action(1,4,3,2,0,127,0,0,0);
prepare(10,0,2,1,1,127,200,128,0);packet[16]=3;send_packet;
action(3,0,2,1,2,69,100,192,3);action(4,4,3,2,1,60,255,0,0);
repeat(100000)@(negedge clk);
check(dut.w_frame_pcm!=0,"eight-bank audio active before emergency");
action(9,0,1,3,0,127,0,0,0);
check(pa && !dut.w_audio_ready,"emergency mutes amplifier during state reinitialization");
check(dut.w_bank_gates==0,"emergency releases both physical banks");
saved_sequence=dut.w_bank_sequence;
wait(dut.w_audio_ready);repeat(5000)@(negedge clk);
check(dut.r_last_tag_last==saved_sequence && dut.r_last_tag_count==1,"emergency completes its own tagged zero frame");
check(dut.w_frame_pcm==0,"emergency clears all string, body and wet state");
action(4,4,3,2,2,60,255,0,0);action(1,0,4,2,0,127,0,0,0);
check(dut.w_bank_sequence==saved_sequence,"delayed action and unseen old CLAIM cannot restart after emergency");
check(dut.w_frame_pcm==0,"rejected delayed transactions preserve silence");
action(1,0,4,4,0,127,0,0,0);action(3,0,4,4,1,69,64,192,1);
scan_triggers=trigger_count;
prepare(11,0,4,4,2,127,0,0,0);
// S0 fret1; S1 frets1+5 => highest5; S2 open; S3 fret12.
packet[11]=8'h01;packet[12]=8'h10;packet[13]=8'h01;packet[14]=0;packet[15]=0;packet[16]=8'h80;packet[17]=15;
send_packet;
expected_notes={7'd88,7'd69,7'd67,7'd56};
check(dut.w_bank_notes[27:0]==expected_notes[27:0],"48-state scan maps all four strings to open plus highest fret");
check(trigger_count==scan_triggers && dut.w_bank_gates[0],"left scan preserves bow contact without new trigger");
check(dut.w_scan_anomalies==1,"multiple frets counted once per ambiguous string");
repeat(5000)@(negedge clk);saved_sequence=dut.r_last_tag_last;saved_clock=dut.r_last_tag_clock;
check(saved_clock[63:32]!=0,"frame diagnostic retains full 64-bit acceptance time");
query(5);query(6);query(10);query(11);query(8);
check(first[5]==saved_sequence && second[5]==saved_sequence,"diag5 retains tagged first/last across untagged frames");
check(first[6]==saved_clock[31:0] && second[6]==1,"diag6 retains oldest time and count");
check({second[10],first[10]}==saved_clock,"diag10 losslessly returns 64-bit acceptance time");
check({second[11],first[11]}==saved_clock,"diag11 latest accepted trace time matches scan");
check(first[8]==1,"diag8 returns scan anomaly count");
check(dut.w_core_deadlines==0,"diagnostic UART traffic never blocks audio producer");
$display("SAFETY_DIAG_RESULT: external=%0d errors=%0d diagnostics=%0d completed=%0d clock=%h",EXTERNAL,errors,diag_count,completed,saved_clock);
if(errors)$fatal(1,"safety and diagnostic regression");$finish;
end
initial begin #150000000;$fatal(1,"safety diagnostic watchdog");end
endmodule
