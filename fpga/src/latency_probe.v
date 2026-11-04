`include "instrument_constants.vh"

// 从控制事件锁存到对应 PT8211 整帧送达，记录周期数及整微秒数。
// 重叠事件保留第一笔并置 sticky overrun；超时发布实际等待值但不伪造 DAC 脉冲。
// CLOCK_HZ 为整数 MHz 时微秒换算精确；其他时钟下以 o_cycles 为权威读数。
module latency_probe #(
    parameter integer CLOCK_HZ = `INST_CLOCK_HZ,
    parameter integer MAX_WAIT_CYCLES = 250000
) (
    input              i_clk,
    input              i_reset,
    input              i_event,
    input              i_audio_first_sample,
    output reg         o_gpio_event,
    output reg         o_gpio_audio,
    output reg         o_measure_valid,
    output reg [31:0]  o_cycles,
    output reg [31:0]  o_microseconds,
    output reg         o_timeout,
    output reg         o_overrun
);
    localparam integer CYCLES_PER_MICROSECOND =
        (CLOCK_HZ / 1000000 < 1) ? 1 : CLOCK_HZ / 1000000;

    function integer counter_width;
        input integer maximum;
        integer remaining;
        begin
            counter_width = 1;
            remaining = maximum;
            while (remaining > 1)
            begin
                counter_width = counter_width + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction
    localparam integer SUBMICROSECOND_WIDTH = counter_width(CYCLES_PER_MICROSECOND - 1);

    reg        r_measurement_pending;
    reg [31:0] r_elapsed_cycles;        // 尚未完成的测量，不覆盖最近已发布结果。
    reg [31:0] r_elapsed_microseconds;
    reg [SUBMICROSECOND_WIDTH-1:0] r_submicrosecond_cycles; // 一个微秒内剩余周期。
    wire w_microsecond_boundary;
    assign w_microsecond_boundary = (r_submicrosecond_cycles == CYCLES_PER_MICROSECOND - 1);

    always @(posedge i_clk)
    begin
        o_gpio_event    <= 1'b0;
        o_gpio_audio    <= 1'b0;
        o_measure_valid <= 1'b0;
        if (i_reset)
        begin
            r_measurement_pending  <= 1'b0;
            r_elapsed_cycles       <= 32'd0;
            r_elapsed_microseconds <= 32'd0;
            r_submicrosecond_cycles <= 0;
            o_cycles               <= 32'd0;
            o_microseconds         <= 32'd0;
            o_timeout              <= 1'b0;
            o_overrun              <= 1'b0;
        end
        else
        begin
            if (i_event)
            begin
                o_gpio_event <= 1'b1;
                if (r_measurement_pending)
                    o_overrun <= 1'b1;
                else if (i_audio_first_sample)
                begin
                    o_gpio_audio    <= 1'b1;
                    o_measure_valid <= 1'b1;
                    o_cycles        <= 32'd0;
                    o_microseconds  <= 32'd0;
                    o_timeout       <= 1'b0;
                end
                else
                begin
                    r_measurement_pending  <= 1'b1;
                    r_elapsed_cycles       <= 32'd0;
                    r_elapsed_microseconds <= 32'd0;
                    r_submicrosecond_cycles <= 0;
                    o_timeout <= 1'b0;
                end
            end

            if (r_measurement_pending)
            begin
                if (i_audio_first_sample)
                begin
                    o_gpio_audio    <= 1'b1;
                    o_cycles        <= r_elapsed_cycles + 32'd1;
                    o_microseconds  <= r_elapsed_microseconds +
                                       (w_microsecond_boundary ? 32'd1 : 32'd0);
                    o_measure_valid <= 1'b1;
                    r_measurement_pending <= 1'b0;
                end
                else if (r_elapsed_cycles + 32'd1 >= MAX_WAIT_CYCLES)
                begin
                    o_timeout       <= 1'b1;
                    o_cycles        <= r_elapsed_cycles + 32'd1;
                    o_microseconds  <= r_elapsed_microseconds +
                                       (w_microsecond_boundary ? 32'd1 : 32'd0);
                    o_measure_valid <= 1'b1;
                    r_measurement_pending <= 1'b0;
                end
                else
                begin
                    r_elapsed_cycles <= r_elapsed_cycles + 32'd1;
                    if (w_microsecond_boundary)
                    begin
                        r_elapsed_microseconds <= r_elapsed_microseconds + 32'd1;
                        r_submicrosecond_cycles <= 0;
                    end
                    else
                        r_submicrosecond_cycles <= r_submicrosecond_cycles + 1'b1;
                end
            end
        end
    end
endmodule
