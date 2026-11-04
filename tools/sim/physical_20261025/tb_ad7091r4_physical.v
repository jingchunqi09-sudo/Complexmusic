`timescale 1ns/1ps
// Pin-level protocol regression. Expected values come from the independently
// decoded reference ADC model, not from DUT internals or a forced sample bus.
module tb_ad7091r4_physical;
    parameter integer CASE=0;
    reg clk=0,reset=1;
    always #10 clk=~clk;
    reg [2:0] adc_fault=0;
    wire sclk,mosi,miso,cs,convst,reset_adc,busy_n;
    wire sample_valid,frame_valid,initialized,fault;
    wire [1:0] sample_channel;
    wire [11:0] sample_value;
    wire [47:0] frame_values;
    localparam integer SLOW_DEFAULTS=(CASE==6);
    ad7091r4_sensor_adapter #(
        .POWER_WAIT_CLKS(SLOW_DEFAULTS?5000000:100),
        .REF_SETTLE_CLKS(SLOW_DEFAULTS?2500000:1000),
        .RESET_CLKS(SLOW_DEFAULTS?5000:32),
        .SAMPLE_GAP_CLKS(SLOW_DEFAULTS?50000:1000)
    ) dut(
        .clk_50m(clk),.reset(reset),.adc_sclk(sclk),.adc_mosi(mosi),.adc_miso(miso),
        .adc_cs_n(cs),.adc_convst_n(convst),.adc_reset_n(reset_adc),.adc_busy_n(busy_n),
        .sample_valid(sample_valid),.sample_channel(sample_channel),.sample_value(sample_value),
        .frame_valid(frame_valid),.frame_values(frame_values),.initialized(initialized),.fault(fault));
    adc_model adc(reset_adc,convst,cs,sclk,mosi,adc_fault,miso,busy_n);
    integer samples=0,frames=0;
    reg [3:0] sample_mask=0;
    reg old_sample=0,old_frame=0;
    time cs_high_at=0,config_at=0,last_sample_at=0;
    time max_sample_period=0;
    reg [15:0] command=0;
    integer command_bits=0;
    always @(negedge cs) begin
        if(cs_high_at!=0 && $time-cs_high_at<160) $fatal(1,"CS guard under160ns");
        command=0; command_bits=0;
    end
    always @(posedge sclk) if(!cs) begin
        command={command[14:0],mosi}; command_bits=command_bits+1;
    end
    always @(posedge cs) begin
        cs_high_at=$time;
        if(command_bits==16 && command==16'h14b1) config_at=$time;
    end
    always @(negedge convst) if(CASE==6) begin
        if($time<100000000) $fatal(1,"default power wait under100ms");
        if(config_at==0 || $time-config_at<50000000) $fatal(1,"default VREF wait under50ms");
    end
    always @(negedge clk) begin
        if(!reset) begin
            if(old_sample && sample_valid) $fatal(1,"sample strobe wider than one clock");
            if(old_frame && frame_valid) $fatal(1,"frame strobe wider than one clock");
            if(sample_valid) begin
                if(!initialized) $fatal(1,"sample while not initialized");
                case(sample_channel)
                    0:if(sample_value!==2048) $fatal(1,"VIN0 wrong or routed incorrectly %h",sample_value);
                    1:if(sample_value!==2200) $fatal(1,"VIN1 wrong or routed incorrectly %h",sample_value);
                    2:if(sample_value!==1500) $fatal(1,"VIN2 wrong or routed incorrectly %h",sample_value);
                    3:if(sample_value!==3000) $fatal(1,"VIN3 wrong or routed incorrectly %h",sample_value);
                endcase
                sample_mask=sample_mask | (1<<sample_channel);
                samples=samples+1;
                if(last_sample_at!=0 && $time-last_sample_at>max_sample_period) max_sample_period=$time-last_sample_at;
                last_sample_at=$time;
            end
            if(frame_valid) begin
                if(frame_values!=={12'd3000,12'd1500,12'd2200,12'd2048}) $fatal(1,"non-coherent four-channel frame %h",frame_values);
                if(sample_mask!=15) $fatal(1,"frame before all four IDs observed");
                frames=frames+1;sample_mask=0;
            end
            old_sample=sample_valid;old_frame=frame_valid;
        end
    end
    initial begin
        if(CASE==1) adc_fault=1;
        if(CASE==2) adc_fault=2;
        if(CASE==3) adc_fault=3;
        if(CASE==4) adc_fault=5;
        #1000;reset=0;
        if(CASE>=1 && CASE<=4) begin
            #500000;
            if(samples!=0 || frames!=0 || !fault) $fatal(1,"fault case accepted invalid sample or failed to report CASE=%d samples=%d frames=%d fault=%b",CASE,samples,frames,fault);
            if(CASE==2 && adc.total!=0) $fatal(1,"conversion began while BUSY was already low");
            adc_fault=0;
        end
        if(CASE==5) begin
            wait(frames>=1);
            // A missing BUSY pulse still advances the hardware sequencer.
            // Recovery must route the next returned ID, not wait forever for
            // the old expected index.
            adc_fault=1;
            #300000;
            adc_fault=0;
        end
        wait(frames>=3);
        if((CASE==0 || CASE==6) && fault) $fatal(1,"fault during normal capture");
        if(CASE>=1 && CASE<=5 && !fault) $fatal(1,"fault history lost after recovery");
        $display("PASS AD7091R4 CASE=%0d samples=%0d coherent_frames=%0d max_inter_sample_ns=%0t fault_history=%b",CASE,samples,frames,max_sample_period,fault);
        $finish;
    end
    initial begin
        if(CASE==6) #180000000; else #4000000;
        $fatal(1,"ADC timeout CASE=%0d state=%0d samples=%0d frames=%0d",CASE,dut.state,samples,frames);
    end
endmodule
