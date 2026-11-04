`timescale 1ns/1ps
`include "latency_profile.vh"
// AD7091R-4 H6 acquisition only; no UART formatter or performer policy here.
// Protocol: ADI Rev. D pp.5/23/30 and the verified R3 test core. Register reads
// reply in the NEXT SPI frame; conversion CH_ID, not an assumed sequence,
// selects the output lane (the channel mux has one-conversion latency).
//
// ---- R61：压电采样时基提速（延迟优先档，见 src/latency_profile.vh）--------
// 单通道周期 = SPI 帧传输 + 转换 guard(133 clk) + BUSY 握手 + SAMPLE_GAP。
//   R60: 16 bit @1 MHz = 16 us + 2.7 + 0.2 + 21.2 = 约 40 us/通道
//        （SAMPLE_GAP_CLKS=1060；四通道帧率约 8.5 kHz）
//   R61: 16 bit @3.125 MHz = 5.1 us + 2.7 + 0.2 + 4.0 = 约 12.4 us/通道
//        （SAMPLE_GAP_CLKS=200；四通道帧率约 20.2 kHz）
// AD7091R-4 的 SCLK 上限是 50 MHz，3.125 MHz 留了 16 倍余量；
// CS 高电平 8 clk (160 ns) 与 CONVST 低电平 160 ns 都保持原值，只动 SCLK 周期。
// ---------------------------------------------------------------------------
module ad7091r4_spi16 #(
    parameter integer HALF_PERIOD_CLKS = 25,
    parameter integer CS_HIGH_CLKS = 8
) (
    input wire i_clk, input wire i_reset, input wire i_start,
    input wire [15:0] i_tx_word, input wire i_sdo,
    output reg o_cs_n, output reg o_sclk, output reg o_sdi,
    output reg [15:0] o_rx_word, output reg o_done, output reg o_busy
);
    function integer count_width;
        input integer value;
        begin count_width=1; while(value>1) begin value=value>>1; count_width=count_width+1; end end
    endfunction
    localparam integer HALF_W=count_width(HALF_PERIOD_CLKS-1);
    localparam integer CS_W=count_width(CS_HIGH_CLKS-1);
    reg [3:0] bit_count;
    reg [15:0] tx_shift, rx_shift;
    reg [HALF_W-1:0] half_count;
    reg [CS_W-1:0] cs_high_count;
    reg ending;
    // o_done includes CS hold and the inter-frame guard. Thus a caller can
    // launch a single-cycle start after done without silently losing it.
    always @(posedge i_clk) begin
        o_done <= 1'b0;
        if (i_reset) begin
            o_cs_n<=1'b1; o_sclk<=1'b0; o_sdi<=1'b0; o_rx_word<=0;
            o_busy<=1'b0; bit_count<=0; tx_shift<=0; rx_shift<=0;
            half_count<=0; cs_high_count<=0; ending<=1'b0;
        end else if (!o_busy) begin
            o_cs_n<=1'b1; o_sclk<=1'b0;
            if (i_start) begin
                o_busy<=1'b1; o_cs_n<=1'b0; o_sclk<=1'b0;
                tx_shift<={i_tx_word[14:0],1'b0}; rx_shift<=0; bit_count<=0;
                half_count<=0; ending<=1'b0; o_sdi<=i_tx_word[15];
            end
        end else if (o_cs_n) begin
            if (cs_high_count == CS_HIGH_CLKS-1) begin
                o_busy<=1'b0; o_done<=1'b1; cs_high_count<=0;
            end else cs_high_count<=cs_high_count+1'b1;
        end else if (half_count == HALF_PERIOD_CLKS-1) begin
            half_count<=0;
            if (ending) begin
                // Keep CS low another half period after the final SCLK fall.
                o_cs_n<=1'b1; cs_high_count<=0; o_rx_word<=rx_shift;
                o_sdi<=1'b0; ending<=1'b0;
            end else if (!o_sclk) begin
                o_sclk<=1'b1; rx_shift<={rx_shift[14:0],i_sdo};
            end else begin
                o_sclk<=1'b0;
                if (bit_count == 15) ending<=1'b1;
                else begin
                    bit_count<=bit_count+1'b1;
                    tx_shift<={tx_shift[14:0],1'b0}; o_sdi<=tx_shift[15];
                end
            end
        end else half_count<=half_count+1'b1;
    end
endmodule

module ad7091r4_sensor_adapter #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer SAMPLE_GAP_CLKS = 50000,
    parameter integer POWER_WAIT_CLKS = 5000000,
    parameter integer REF_SETTLE_CLKS = 2500000,
    parameter integer RESET_CLKS = CLOCK_HZ/10000,
    parameter integer SPI_HALF_PERIOD_CLKS = `R61_PIEZO_SPI_HALF,
    parameter integer BUSY_TIMEOUT_CLKS = CLOCK_HZ/10000
) (
    input wire clk_50m, input wire reset,
    output wire adc_sclk, output wire adc_mosi, input wire adc_miso,
    output wire adc_cs_n, output reg adc_convst_n, output reg adc_reset_n,
    input wire adc_busy_n,
    output reg sample_valid, output reg [1:0] sample_channel,
    output reg [11:0] sample_value,
    output reg frame_valid, output reg [47:0] frame_values,
    output reg initialized, output reg fault
);
    function integer max_int;
        input integer a,b;
        begin max_int=(a>b)?a:b; end
    endfunction
    function integer count_width;
        input integer value;
        begin count_width=1; while(value>1) begin value=value>>1; count_width=count_width+1; end end
    endfunction
    localparam integer CONV_LOW_CLKS = 8; // 160ns at 50MHz; datasheet 10..500ns.
    localparam integer CONV_WAIT_CLKS = 125; // 2.5us guard, conversion max 600ns.
    localparam integer TIMER_MAX = max_int(max_int(POWER_WAIT_CLKS,REF_SETTLE_CLKS),
        max_int(max_int(SAMPLE_GAP_CLKS,RESET_CLKS),max_int(BUSY_TIMEOUT_CLKS,CONV_WAIT_CLKS)));
    localparam integer TIMER_W=count_width(TIMER_MAX-1);
    localparam ST_POWER=5'd0, ST_RESET=5'd1, ST_RELEASE=5'd2,
        ST_WRITE_CH=5'd3, ST_WRITE_CH_WAIT=5'd4,
        ST_WRITE_CFG=5'd5, ST_WRITE_CFG_WAIT=5'd6,
        ST_READ_CH=5'd7, ST_READ_CH_WAIT=5'd8,
        ST_READ_CFG=5'd9, ST_READ_CFG_WAIT=5'd10,
        ST_FLUSH=5'd11, ST_FLUSH_WAIT=5'd12,
        ST_REF=5'd13, ST_GAP=5'd14, ST_BUSY_IDLE=5'd15,
        ST_CONV_LOW=5'd16, ST_CONV_WAIT=5'd17,
        ST_READ=5'd18, ST_READ_WAIT=5'd19;
    reg [4:0] state;
    reg [TIMER_W-1:0] timer;
    reg [11:0] values [0:3];
    reg [3:0] frame_seen;
    reg spi_start;
    reg [15:0] spi_tx_word;
    wire [15:0] spi_rx_word;
    wire spi_done, spi_busy;
    reg [1:0] busy_sync, miso_sync;
    reg busy_seen, channel_readback_ok;
    reg [3:0] busy_idle_count;
    integer j;
    wire [1:0] result_channel=spi_rx_word[14:13];
    wire [3:0] result_mask=4'b0001 << result_channel;

    // synthesis translate_off
    initial begin
        if (CLOCK_HZ != 50000000 || SAMPLE_GAP_CLKS < 1 || POWER_WAIT_CLKS < 1 ||
            REF_SETTLE_CLKS < 1 || RESET_CLKS < 1 || BUSY_TIMEOUT_CLKS < CONV_WAIT_CLKS ||
            SPI_HALF_PERIOD_CLKS < 4) begin
            $display("FAIL AD7091R-4: invalid timing parameters (50MHz board contract)"); $finish;
        end
    end
    // synthesis translate_on
    always @(posedge clk_50m) begin
        if (reset) begin busy_sync<=2'b11; miso_sync<=0; end
        else begin busy_sync<={busy_sync[0],adc_busy_n}; miso_sync<={miso_sync[0],adc_miso}; end
    end
    ad7091r4_spi16 #(.HALF_PERIOD_CLKS(SPI_HALF_PERIOD_CLKS),.CS_HIGH_CLKS(8)) u_spi (
        .i_clk(clk_50m),.i_reset(reset),.i_start(spi_start),.i_tx_word(spi_tx_word),
        .i_sdo(miso_sync[1]),.o_cs_n(adc_cs_n),.o_sclk(adc_sclk),.o_sdi(adc_mosi),
        .o_rx_word(spi_rx_word),.o_done(spi_done),.o_busy(spi_busy)
    );
    always @(posedge clk_50m) begin
        spi_start<=1'b0; sample_valid<=1'b0; frame_valid<=1'b0;
        if (reset) begin
            state<=ST_POWER; timer<=0; initialized<=0; fault<=0;
            adc_convst_n<=1'b1; adc_reset_n<=1'b0; busy_seen<=0;
            busy_idle_count<=0; channel_readback_ok<=0; frame_seen<=0;
            sample_channel<=0; sample_value<=0; frame_values<=0; spi_tx_word<=0;
            for(j=0;j<4;j=j+1) values[j]<=0;
        end else case(state)
            ST_POWER: begin
                adc_reset_n<=1'b0; initialized<=1'b0; frame_seen<=0;
                if(timer>=POWER_WAIT_CLKS-1) begin timer<=0;state<=ST_RESET;end
                else timer<=timer+1'b1;
            end
            ST_RESET: begin
                if(timer>=RESET_CLKS-1) begin timer<=0;adc_reset_n<=1'b1;state<=ST_RELEASE;end
                else timer<=timer+1'b1;
            end
            ST_RELEASE: begin
                if(timer>=RESET_CLKS-1) begin timer<=0;spi_tx_word<=16'h0c0f;state<=ST_WRITE_CH;end
                else timer<=timer+1'b1;
            end
            ST_WRITE_CH: begin spi_start<=1'b1;state<=ST_WRITE_CH_WAIT;end
            ST_WRITE_CH_WAIT: if(spi_done) begin spi_tx_word<=16'h14b1;state<=ST_WRITE_CFG;end
            ST_WRITE_CFG: begin spi_start<=1'b1;state<=ST_WRITE_CFG_WAIT;end
            ST_WRITE_CFG_WAIT: if(spi_done) begin spi_tx_word<=16'h0800;state<=ST_READ_CH;end
            ST_READ_CH: begin spi_start<=1'b1;state<=ST_READ_CH_WAIT;end
            // 0x0800 requests CHANNEL; this frame does not contain its reply.
            ST_READ_CH_WAIT: if(spi_done) begin spi_tx_word<=16'h1000;state<=ST_READ_CFG;end
            ST_READ_CFG: begin spi_start<=1'b1;state<=ST_READ_CFG_WAIT;end
            ST_READ_CFG_WAIT: if(spi_done) begin
                channel_readback_ok<=(spi_rx_word==16'h000f);
                spi_tx_word<=16'h0000;state<=ST_FLUSH;
            end
            ST_FLUSH: begin spi_start<=1'b1;state<=ST_FLUSH_WAIT;end
            ST_FLUSH_WAIT: if(spi_done) begin
                timer<=0;
                if(channel_readback_ok && spi_rx_word==16'h00b1) state<=ST_REF;
                else begin fault<=1'b1;state<=ST_POWER;end
            end
            ST_REF: begin
                if(timer>=REF_SETTLE_CLKS-1) begin timer<=0;initialized<=1'b1;state<=ST_GAP;end
                else timer<=timer+1'b1;
            end
            ST_GAP: begin
                if(timer>=SAMPLE_GAP_CLKS-1) begin
                    timer<=0;busy_idle_count<=0;busy_seen<=0;state<=ST_BUSY_IDLE;
                end else timer<=timer+1'b1;
            end
            ST_BUSY_IDLE: begin
                // An already-low BUSY cannot certify a newly launched conversion.
                if(busy_sync[1]) busy_idle_count<=busy_idle_count+1'b1;
                else busy_idle_count<=0;
                if(busy_sync[1] && busy_idle_count==7) begin
                    timer<=0;adc_convst_n<=1'b0;state<=ST_CONV_LOW;
                end else if(timer>=BUSY_TIMEOUT_CLKS-1) begin
                    fault<=1'b1;frame_seen<=0;timer<=0;state<=ST_GAP;
                end else timer<=timer+1'b1;
            end
            ST_CONV_LOW: begin
                if(!busy_sync[1]) busy_seen<=1'b1;
                if(timer>=CONV_LOW_CLKS-1) begin
                    timer<=0;adc_convst_n<=1'b1;state<=ST_CONV_WAIT;
                end else timer<=timer+1'b1;
            end
            ST_CONV_WAIT: begin
                if(!busy_sync[1]) busy_seen<=1'b1;
                // Capture BUSY while waiting, including pulses shorter than
                // this guard. Then require both a NEW low and a return high.
                if(timer>=CONV_WAIT_CLKS-1 && busy_sync[1]) begin
                    timer<=0;
                    if(busy_seen) begin spi_tx_word<=16'h0000;state<=ST_READ;end
                    else begin fault<=1'b1;frame_seen<=0;state<=ST_GAP;end
                end else if(timer>=BUSY_TIMEOUT_CLKS-1) begin
                    fault<=1'b1;frame_seen<=0;timer<=0;state<=ST_GAP;
                end else timer<=timer+1'b1;
            end
            ST_READ: begin spi_start<=1'b1;state<=ST_READ_WAIT;end
            ST_READ_WAIT: if(spi_done) begin
                // CH_ID is [15:13]; bit15 must be zero on the four-channel part.
                if(!spi_rx_word[15]) begin
                    values[result_channel]<=spi_rx_word[11:0];
                    sample_channel<=result_channel;sample_value<=spi_rx_word[11:0];sample_valid<=1'b1;
                    if((frame_seen | result_mask)==4'hf) begin
                        for(j=0;j<4;j=j+1)
                            frame_values[j*12 +:12]<=(result_channel==j)?spi_rx_word[11:0]:values[j];
                        frame_valid<=1'b1;frame_seen<=0;
                    end else frame_seen<=frame_seen | result_mask;
                end else begin fault<=1'b1;frame_seen<=0;end
                timer<=0;state<=ST_GAP;
            end
            default: begin state<=ST_POWER;timer<=0;initialized<=0;adc_convst_n<=1'b1;end
        endcase
    end
endmodule
