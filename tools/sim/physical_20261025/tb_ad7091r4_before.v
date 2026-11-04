`timescale 1ns/1ps
// Reproduce the frozen pre-fix adapter. This test is intentionally excluded
// from active RTL regression and must compile against the .before.v snapshot.
module tb_ad7091r4_before;
    reg clk=0,reset=1;
    always #10 clk=~clk;
    wire sclk,mosi,miso,cs,convst,reset_adc,busy_n,sample_valid,frame_valid,initialized,fault;
    wire [1:0] sample_channel;
    wire [11:0] sample_value;
    wire [47:0] frame_values;
    integer spi_frames=0,samples=0;
    ad7091r4_sensor_adapter #(.POWER_WAIT_CLKS(100),.REF_SETTLE_CLKS(1000),.SAMPLE_GAP_CLKS(1000)) dut(
        .clk_50m(clk),.reset(reset),.adc_sclk(sclk),.adc_mosi(mosi),.adc_miso(miso),
        .adc_cs_n(cs),.adc_convst_n(convst),.adc_reset_n(reset_adc),.adc_busy_n(busy_n),
        .sample_valid(sample_valid),.sample_channel(sample_channel),.sample_value(sample_value),
        .frame_valid(frame_valid),.frame_values(frame_values),.initialized(initialized),.fault(fault));
    adc_model adc(reset_adc,convst,cs,sclk,mosi,3'd0,miso,busy_n);
    always @(negedge cs) spi_frames=spi_frames+1;
    always @(posedge sample_valid) samples=samples+1;
    initial begin
        #1000;reset=0;
        #1000000;
        if(dut.state!==5'd6 || spi_frames!=1 || samples!=0) $fatal(1,"unexpected before-state; state=%d frames=%d samples=%d",dut.state,spi_frames,samples);
        $display("REPRODUCED BEFORE: second single-cycle SPI start lost during CS high guard; state=WRITE_CFG_WAIT, frames=1, samples=0 after1ms");
        $finish;
    end
endmodule
