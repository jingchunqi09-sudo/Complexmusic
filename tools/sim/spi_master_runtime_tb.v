`timescale 1ns/1ps
// 四个独立从机检查全部 CPOL/CPHA 组合，32 位命令 + 32 位响应覆盖 64 位边界。
// 请求分频 2 应夹到 4：10 ns 系统周期下，SCK 半周期 40 ns。
// 从机在输出边沿后 12 / 13 ns 改变 MISO，模拟外部 ADC 的 tCO。
module spi_runtime_mode_case #(
    parameter integer MODE=0
) (
    input clock,
    input reset,
    input request,
    output done,
    output reg passed=0
);
    localparam integer CPOL=MODE/2;
    localparam integer CPHA=MODE%2;
    localparam integer ADC_CLOCK_TO_OUTPUT_NS=12+CPHA;
    localparam [31:0] COMMAND_WORD=32'hC35AA596;
    localparam [31:0] RESPONSE_WORD=32'hA53CC35A ^ MODE;
    wire serial_clock;
    wire chip_select_n;
    wire serial_transmit;
    wire busy;
    wire [31:0] received_word;
    reg requested_cpol=CPOL!=0;
    reg requested_cpha=CPHA!=0;
    reg [15:0] requested_divider=16'd2;
    reg [5:0] requested_command_bits=6'd32;
    reg [5:0] requested_response_bits=6'd32;
    reg [31:0] requested_command=COMMAND_WORD;
    reg serial_receive=0;
    reg [63:0] slave_stream;
    reg [31:0] captured_command=0;
    integer transmit_bit_index=0;
    integer sampled_bit_count=0;
    time transaction_start_time;
    time serial_edge_timestamp;
    time previous_serial_edge_timestamp;
    integer checked_half_periods=0;
    integer half_period_errors=0;
    spi_master_runtime dut (
        .i_clk(clock),
        .i_reset(reset),
        .i_req(request),
        .i_cpol(requested_cpol),
        .i_cpha(requested_cpha),
        .i_clk_div(requested_divider),
        .i_cmd_bits(requested_command_bits),
        .i_rx_bits(requested_response_bits),
        .i_cmd(requested_command),
        .i_miso(serial_receive),
        .o_mosi(serial_transmit),
        .o_sck(serial_clock),
        .o_cs_n(chip_select_n),
        .o_busy(busy),
        .o_done(done),
        .o_rx_data(received_word)
    );
    // 事务已开始后故意修改所有配置；完整命令/响应仍必须保持锁存的 profile。
    initial
    begin
        wait(busy);
        @(negedge clock);
        requested_cpol=!requested_cpol;
        requested_cpha=!requested_cpha;
        requested_divider=16'd65535;
        requested_command_bits=6'd1;
        requested_response_bits=6'd1;
        requested_command=~COMMAND_WORD;
    end
    always @(negedge chip_select_n)
    begin
        transaction_start_time=$time;
        slave_stream={32'd0,RESPONSE_WORD};
        captured_command=0;
        transmit_bit_index=0;
        sampled_bit_count=0;
        previous_serial_edge_timestamp=transaction_start_time;
        checked_half_periods=0;
        half_period_errors=0;
        serial_receive <= #(ADC_CLOCK_TO_OUTPUT_NS) slave_stream[63];
    end
    // 只观察引脚边沿；CS 拉低时设置空闲极性的变化不计作数据边沿。
    always @(serial_clock)
    begin
        serial_edge_timestamp=$time;
        #1;
        if (!chip_select_n && $time > transaction_start_time+1)
        begin
            if(serial_edge_timestamp-previous_serial_edge_timestamp!=40)
            begin
                half_period_errors=half_period_errors+1;
                $display("FAIL: SPI mode %0d half period=%0d ns, expected clamp to 40 ns",
                MODE,serial_edge_timestamp-previous_serial_edge_timestamp);
            end
            previous_serial_edge_timestamp=serial_edge_timestamp;
            checked_half_periods=checked_half_periods+1;
            if ((CPHA==0 && serial_clock!=CPOL) ||
            (CPHA==1 && serial_clock==CPOL))
            begin
                if(sampled_bit_count<32)
                captured_command={captured_command[30:0],serial_transmit};
                sampled_bit_count=sampled_bit_count+1;
            end
            else
            begin
                if(CPHA==0) transmit_bit_index=transmit_bit_index+1;
                if(transmit_bit_index<64)
                // 上方观察器等待的 1 ns 已包含在总 tCO 中。
                serial_receive <= #(ADC_CLOCK_TO_OUTPUT_NS-1)
                slave_stream[63-transmit_bit_index];
                if(CPHA==1) transmit_bit_index=transmit_bit_index+1;
            end
        end
    end
    always @(posedge done)
    begin
        #1;
        passed=(received_word===RESPONSE_WORD && captured_command===COMMAND_WORD &&
        !busy && half_period_errors==0 && checked_half_periods>=127);
        if(passed)
        begin
            $display("PASS: SPI mode %0d divider=2 clamps to 4, SCK half period=40 ns",MODE);
            $display("PASS: SPI mode %0d, 32-bit command/reply with ADC tCO=%0d ns and synchronized MISO",
            MODE,ADC_CLOCK_TO_OUTPUT_NS);
            $display("PASS: SPI mode %0d profile mutations while busy do not alter the current transaction",MODE);
        end
        else $display("FAIL: SPI mode %0d command=%h reply=%h expected=%h",MODE,captured_command,received_word,RESPONSE_WORD);
    end
endmodule
module spi_master_runtime_tb;
    reg clock=0;
    reg reset=1;
    reg request=0;
    wire [3:0] done;
    wire [3:0] passed;
    spi_runtime_mode_case #(.MODE(0)) case0(clock,reset,request,done[0],passed[0]);
    spi_runtime_mode_case #(.MODE(1)) case1(clock,reset,request,done[1],passed[1]);
    spi_runtime_mode_case #(.MODE(2)) case2(clock,reset,request,done[2],passed[2]);
    spi_runtime_mode_case #(.MODE(3)) case3(clock,reset,request,done[3],passed[3]);
    always #5 clock=~clock;
    initial
    begin
        repeat(4) @(negedge clock);
        reset=0;
        repeat(3) @(negedge clock);
        request=1;
        @(negedge clock);
        request=0;
        // CPHA=1 在最终采样后一个系统周期发布；各模式 DONE 不必重合。
        // passed 锁存成功结果，避免依赖各路完成脉冲同周期。
        wait(&passed);
        #2;
        $display("SPI_MASTER_RESULT: errors=%0d",passed==4'b1111 ? 0 : 1);
        $finish;
    end
    initial
    begin
        #10000;
        $display("FAIL: SPI runtime watchdog expired");
        $finish;
    end
endmodule
