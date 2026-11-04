`timescale 1ns/1ps
// Raw-level scanner adapted from Downloads/LeftHand_LATEST/工程/rtl/
// left_hand_peripheral_test.v (2026-10-27): 5 ms slots, 100 us settle,
// carrier HALF=544. ADC128S102 pin timing follows TI SNAS298G and the
// project's tested mode-3 scanner. This module does not demodulate I/Q.
module left_hand_sensor_adapter #(
    parameter integer CLK_HZ = 50000000,
    parameter integer ADC_HALF_DIV = 3,
    parameter integer EXC_SLOT_TICKS = CLK_HZ/200,
    parameter integer SETTLE_TICKS = CLK_HZ/10000,
    parameter integer CARRIER_HALF = 544
) (
    input wire clk_50m, input wire reset,
    output wire adc_sclk, output wire adc_din,
    output wire adc1_cs_n, input wire adc1_out,
    output wire adc2_cs_n, input wire adc2_out,
    output wire fpga_tx1, output wire fpga_tx2,
    output wire fpga_tx3, output wire fpga_tx4,
    output reg [191:0] snapshot,
    output reg snapshot_valid,
    output reg [1:0] snapshot_string,
    output reg slot_valid,
    output reg [1:0] slot_string,
    output reg [15:0] slot_sample_count,
    output wire [3:0] excitation
);
    function integer count_width;
        input integer maximum;
        integer value;
        begin
            count_width = 1; value = maximum;
            while (value > 1) begin
                value = value >> 1; count_width = count_width + 1;
            end
        end
    endfunction
    localparam integer SLOT_WIDTH = count_width(EXC_SLOT_TICKS-1);
    localparam integer DIV_WIDTH = count_width(ADC_HALF_DIV-1);
    localparam integer CAR_WIDTH = count_width(CARRIER_HALF-1);
    // First scan: one prime + eight data transfers = 305*DIV clocks
    // (915 at DIV=3). Later scans retain the ADC command pipeline and
    // take eight*(32*DIV + DIV hold + DIV gap) = 816 clocks at DIV=3.
    localparam integer BURST_TICKS = 305*ADC_HALF_DIV;
    localparam integer REPEAT_SCAN_TICKS = 272*ADC_HALF_DIV;
    localparam integer LAST_START_TICK = EXC_SLOT_TICKS-BURST_TICKS-2;
    localparam integer LAST_REPEAT_TICK = EXC_SLOT_TICKS-REPEAT_SCAN_TICKS-2;
    localparam A_IDLE=2'd0, A_XFER=2'd1, A_HOLD=2'd2, A_GAP=2'd3;
    reg [1:0] adc_state;
    reg [DIV_WIDTH-1:0] adc_div;
    reg adc_sclk_r, adc_cs_r, adc_din_r;
    reg [3:0] adc_bit;
    reg [2:0] cmd_channel, result_channel;
    reg pipeline_valid;
    reg [11:0] shift1, shift2;
    reg [11:0] sample [0:15];
    reg slot_started;
    reg [15:0] scan_count;
    reg [SLOT_WIDTH-1:0] exc_count;
    reg [1:0] exc_string, scan_string;
    reg [3:0] exc_drive;
    reg [CAR_WIDTH-1:0] car_count;
    reg carrier;
    wire [7:0] control_word = {2'b00,cmd_channel,3'b000};
    wire [3:0] carrier_drive = exc_drive & {4{carrier}};
    assign adc_sclk = adc_sclk_r;
    assign adc_din = adc_din_r;
    assign adc1_cs_n = adc_cs_r;
    assign adc2_cs_n = adc_cs_r;
    assign {fpga_tx4,fpga_tx3,fpga_tx2,fpga_tx1} = carrier_drive;
    // excitation identifies the selected slot even during a carrier LOW.
    assign excitation = exc_drive;

    // Free-running carrier: fc = CLK_HZ/(2*CARRIER_HALF). No phase lock to
    // a channel sample is claimed. Raw level depends on carrier phase and
    // analog settling; threshold calibration must use this exact profile.
    // Every complete scan is published, not only the slot's final scan.
    // A downstream aggregator can count/compare all approximately 300 scans
    // per default 5 ms slot. This raw level is not a peak envelope.
    always @(posedge clk_50m) begin
        if (reset) begin car_count <= 0; carrier <= 0; end
        else if (car_count == CARRIER_HALF-1) begin
            car_count <= 0; carrier <= ~carrier;
        end else car_count <= car_count + 1'b1;
    end

    // Exactly three low-drive cycles at each slot boundary; inactive strings
    // remain strong zero. No internal clocks or combinational decoder drive.
    always @(posedge clk_50m) begin
        if (reset) begin
            exc_count <= 0; exc_string <= 0; exc_drive <= 0;
        end else if (exc_count == EXC_SLOT_TICKS-1) begin
            exc_count <= 0; exc_string <= exc_string + 1'b1; exc_drive <= 0;
        end else begin
            exc_count <= exc_count + 1'b1;
            if (exc_count == 2) exc_drive <= 4'b0001 << exc_string;
        end
    end

    // Mode 3: idle HIGH, 16 rising edges, DIV=3 gives 60 ns half-cycle.
    // DOUT is captured on rising edges, 60 ns after the ADC launch falling
    // edge (27 ns max tDACC). HOLD and CS-HIGH GAP each last 60 ns.
    // Every started burst fits entirely within the current excitation slot.
    always @(posedge clk_50m) begin
        if (reset) begin
            adc_state <= A_IDLE; adc_div <= 0;
            adc_sclk_r <= 1; adc_cs_r <= 1; adc_din_r <= 0;
            adc_bit <= 0; cmd_channel <= 0; result_channel <= 0;
            pipeline_valid <= 0; shift1 <= 0; shift2 <= 0;
            snapshot <= 0; snapshot_valid <= 0; snapshot_string <= 0;
            slot_started <= 0; scan_count <= 0; scan_string <= 0;
            slot_valid <= 0; slot_string <= 0; slot_sample_count <= 0;
        end else begin
            snapshot_valid <= 0;
            slot_valid <= 0;
            if (exc_count == 0) begin slot_started <= 0; scan_count <= 0; end
            if (exc_count == EXC_SLOT_TICKS-1) begin
                slot_string <= exc_string;
                slot_sample_count <= scan_count;
                slot_valid <= 1;
            end
            case (adc_state)
                A_IDLE: begin
                    adc_sclk_r <= 1; adc_cs_r <= 1; adc_din_r <= 0;
                    if (!slot_started && exc_count >= SETTLE_TICKS && exc_count <= LAST_START_TICK) begin
                        adc_state <= A_XFER; adc_cs_r <= 0; adc_div <= 0;
                        adc_bit <= 0; cmd_channel <= 0; result_channel <= 0;
                        pipeline_valid <= 0; shift1 <= 0; shift2 <= 0;
                        scan_string <= exc_string;
                        slot_started <= 1;
                    end
                end
                A_XFER: begin
                    if (adc_div == ADC_HALF_DIV-1) begin
                        adc_div <= 0;
                        if (adc_sclk_r) begin
                            adc_sclk_r <= 0;
                            adc_din_r <= (adc_bit < 8) ? control_word[7-adc_bit] : 1'b0;
                        end else begin
                            if (adc_bit >= 4) begin
                                shift1 <= {shift1[10:0],adc1_out};
                                shift2 <= {shift2[10:0],adc2_out};
                            end
                            adc_sclk_r <= 1;
                            if (adc_bit == 15) adc_state <= A_HOLD;
                            else adc_bit <= adc_bit + 1'b1;
                        end
                    end else adc_div <= adc_div + 1'b1;
                end
                A_HOLD: begin
                    if (adc_div == ADC_HALF_DIV-1) begin
                        adc_div <= 0; adc_cs_r <= 1; adc_din_r <= 0;
                        if (pipeline_valid) begin
                            sample[result_channel] <= shift1;
                            sample[{1'b1,result_channel}] <= shift2;
                        end
                        if (pipeline_valid && result_channel == 7) begin
                            // Last channels come from this transfer, avoiding
                            // stale NBA values for channels 7 and 15.
                            snapshot <= {shift2,sample[14],sample[13],sample[12],
                                sample[11],sample[10],sample[9],sample[8],shift1,
                                sample[6],sample[5],sample[4],sample[3],sample[2],sample[1],sample[0]};
                            snapshot_string <= scan_string;
                            snapshot_valid <= 1;
                            if (scan_count != 16'hffff) scan_count <= scan_count + 1'b1;
                            // Command 0 was just sent while receiving ch7.
                            // Retain that pipeline through the next full GAP.
                            // No new scan is started unless all eight transfers
                            // can finish before the excitation rotates.
                            if (exc_count <= LAST_REPEAT_TICK) begin
                                result_channel <= cmd_channel;
                                cmd_channel <= cmd_channel + 1'b1;
                                adc_state <= A_GAP;
                            end else adc_state <= A_IDLE;
                        end else begin
                            result_channel <= cmd_channel;
                            cmd_channel <= cmd_channel + 1'b1;
                            pipeline_valid <= 1; adc_state <= A_GAP;
                        end
                    end else adc_div <= adc_div + 1'b1;
                end
                A_GAP: begin
                    if (adc_div == ADC_HALF_DIV-1) begin
                        adc_div <= 0; adc_cs_r <= 0; adc_state <= A_XFER;
                        adc_bit <= 0; shift1 <= 0; shift2 <= 0;
                    end else adc_div <= adc_div + 1'b1;
                end
                default: adc_state <= A_IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if (ADC_HALF_DIV < 1 || CARRIER_HALF < 1 || SETTLE_TICKS < 4 ||
            LAST_START_TICK < SETTLE_TICKS) begin
            $fatal(1,"left raw scanner: invalid divider/carrier/settle/slot parameters");
        end
    end
    always @(posedge clk_50m) begin
        if (!reset && exc_count == EXC_SLOT_TICKS-1 && adc_state != A_IDLE)
            $fatal(1,"left raw scanner: conversion crossed slot boundary");
        if (!reset && adc_state != A_IDLE && scan_string != exc_string)
            $fatal(1,"left raw scanner: conversion string changed");
    end
    // synthesis translate_on
endmodule
