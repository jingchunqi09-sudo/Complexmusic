`timescale 1ns/1ps
// Independent ADC128S102 mode-3 serial model: DOUT launches 27 ns after
// falling edges, DIN is latched on rising edges, previous ADD selects data.
module left_adc128_model #(parameter CHIP=0)(
    input cs_n,input sclk,input din,input [3:0] excitation,output reg dout=0
);
    integer bit_no=0,previous_channel=0;
    reg [7:0] command=0;
    reg [15:0] word_value;
    integer str;
    time last_fall=0,last_cs_high=0;
    function integer string_no;
        input [3:0] mask;
        begin
            case(mask)1:string_no=0;2:string_no=1;4:string_no=2;8:string_no=3;
                default:string_no=-1;
            endcase
        end
    endfunction
    always @(negedge cs_n) begin
        if(!sclk) $fatal(1,"CS asserted with SCLK low");
        if(last_cs_high!=0 && $time-last_cs_high<60) $fatal(1,"CS high gap too short");
        str=string_no(excitation);
        if(str<0) $fatal(1,"ADC conversion without one-hot excitation");
        word_value=12'h120+str*256+(previous_channel+CHIP*8)*11;
        bit_no=0;command=0;
    end
    always @(negedge sclk) if(!cs_n) begin
        last_fall=$time;
        dout <= #27 word_value[15-bit_no];
    end
    always @(posedge sclk) if(!cs_n) begin
        if($time-last_fall!=60) $fatal(1,"SPI half-period changed");
        if(bit_no<8) command={command[6:0],din};
        bit_no=bit_no+1;
    end
    always @(posedge cs_n) begin
        if(bit_no!=0) begin
            if(bit_no!=16) $fatal(1,"not sixteen rising edges per transfer");
            if($time-last_fall<120) $fatal(1,"CS deasserted before full final hold");
            previous_channel=command[5:3];
        end
        last_cs_high=$time;
    end
endmodule

module tb_left_scanner #(
    parameter integer EXC_SLOT_TICKS=1200,
    parameter integer SETTLE_TICKS=200,
    parameter integer TARGET_SNAPSHOTS=12,
    parameter integer TIMEOUT_NS=2000000
);
    reg clk=0;always #10 clk=~clk;
    reg reset=1;
    wire sclk,din,cs1,cs2,out1,out2;
    wire [3:0] tx,excitation;
    wire [191:0] snapshot;
    wire snapshot_valid;
    wire [1:0] snapshot_string;
    integer snapshots=0,channel_no,expected;
    integer cycle_count=0,last_snapshot_cycle=-1;
    integer transfers=0,burst_start_cycle=-1;
    reg previous_cs=1;
    integer last_string_cycle [0:3];
    reg [3:0] seen_string=0;
    integer last_string=3;
    reg [3:0] last_exc=0;
    left_hand_sensor_adapter #(.EXC_SLOT_TICKS(EXC_SLOT_TICKS),.SETTLE_TICKS(SETTLE_TICKS)) dut(
        .clk_50m(clk),.reset(reset),.adc_sclk(sclk),.adc_din(din),
        .adc1_cs_n(cs1),.adc1_out(out1),.adc2_cs_n(cs2),.adc2_out(out2),
        .fpga_tx1(tx[0]),.fpga_tx2(tx[1]),.fpga_tx3(tx[2]),.fpga_tx4(tx[3]),
        .snapshot(snapshot),.snapshot_valid(snapshot_valid),
        .snapshot_string(snapshot_string),.excitation(excitation)
    );
    left_adc128_model #(.CHIP(0)) adc1(cs1,sclk,din,excitation,out1);
    left_adc128_model #(.CHIP(1)) adc2(cs2,sclk,din,excitation,out2);
    always @(posedge clk) begin
        #1;
        cycle_count=cycle_count+1;
        if(!reset) begin
            if(!cs1 && previous_cs) begin
                if(transfers%9==0) burst_start_cycle=cycle_count;
                transfers=transfers+1;
            end
            previous_cs=cs1;
            if(tx!==excitation || cs1!==cs2) $fatal(1,"paired ADC/drive interface mismatch");
            if(excitation!=0 && (excitation & (excitation-1))!=0) $fatal(1,"overlapping excitation");
            if(excitation!=0 && last_exc!=0 && excitation!=last_exc) $fatal(1,"missing break-before-make gap");
            last_exc=excitation;
            if(snapshot_valid) begin
                // Nine 16-clock frames: 9*(32+1)*DIV cycles plus
                // eight inter-frame DIV-cycle CS-high gaps = 915 cycles.
                if(cycle_count-burst_start_cycle!=915)
                    $fatal(1,"nine-frame burst=%0d cycles, expected=915",cycle_count-burst_start_cycle);
                if(last_snapshot_cycle>=0 && cycle_count-last_snapshot_cycle!=EXC_SLOT_TICKS)
                    $fatal(1,"snapshot interval=%0d, expected=%0d",cycle_count-last_snapshot_cycle,EXC_SLOT_TICKS);
                if(seen_string[snapshot_string] &&
                   cycle_count-last_string_cycle[snapshot_string]!=(4*EXC_SLOT_TICKS))
                    $fatal(1,"same-string interval=%0d, expected=%0d",
                        cycle_count-last_string_cycle[snapshot_string],4*EXC_SLOT_TICKS);
                seen_string[snapshot_string]=1'b1;
                last_string_cycle[snapshot_string]=cycle_count;
                last_snapshot_cycle=cycle_count;
                if(snapshot_string!==((last_string+1)%4)) $fatal(1,"string sequence/tag failed");
                last_string=snapshot_string;
                for(channel_no=0;channel_no<16;channel_no=channel_no+1) begin
                    expected=12'h120+snapshot_string*256+channel_no*11;
                    if(snapshot[channel_no*12 +:12]!==expected[11:0])
                        $fatal(1,"snapshot mismatch string=%0d channel=%0d expected=%h actual=%h",snapshot_string,channel_no,expected[11:0],snapshot[channel_no*12 +:12]);
                end
                snapshots=snapshots+1;
                if(snapshots==TARGET_SNAPSHOTS) begin
                    $display("PASS left scanner: %0d coherent snapshots, interval=%0d cycles, same-string=%0d cycles, 27ns DOUT/mode3/break-before-make checks (EXC_SLOT_TICKS=%0d SETTLE_TICKS=%0d)",
                        TARGET_SNAPSHOTS,EXC_SLOT_TICKS,4*EXC_SLOT_TICKS,EXC_SLOT_TICKS,SETTLE_TICKS);
                    $finish;
                end
            end
        end
    end
    initial begin repeat(4) @(negedge clk);reset=0;end
    initial begin #(TIMEOUT_NS);$fatal(1,"timeout");end
endmodule
