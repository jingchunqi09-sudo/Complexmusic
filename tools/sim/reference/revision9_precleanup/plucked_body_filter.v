// 拨弦琴体的轻量双模态近似；只在弦反馈环外处理辐射声。
// 在Fs=48828.125 Hz时，两模态约440/760 Hz；不是实测尤克里里拟合系数。
// 每模态: v'=(1-1/32)v+k(x-y), y'=y+v'；k=7/2048、5/512。
// 定点状态Q18.8，饱和限制整数回绕；系数用移位加法，不额外占乘法DSP。
module plucked_body_filter (
    input i_clk,
    input i_reset,
    input i_sample_tick,
    input i_trigger,
    input signed [15:0] i_sample,
    output signed [15:0] o_sample
);
    reg signed [25:0] r_low_position, r_low_velocity;
    reg signed [25:0] r_high_position, r_high_velocity;
    wire signed [26:0] w_low_error, w_high_error;
    wire signed [27:0] w_low_velocity, w_high_velocity;
    wire signed [27:0] w_low_position, w_high_position;
    wire signed [27:0] w_output;
    function signed [25:0] bound_state;
        input signed [27:0] value;
        begin
            if (value > 28'sd33554431) bound_state = 26'sh1ffffff;
            else if (value < -28'sd33554432) bound_state = 26'sh2000000;
            else bound_state = value[25:0];
        end
    endfunction
    assign w_low_error = $signed({{3{i_sample[15]}}, i_sample, 8'd0}) - $signed(r_low_position);
    assign w_high_error = $signed({{3{i_sample[15]}}, i_sample, 8'd0}) - $signed(r_high_position);
    assign w_low_velocity = $signed(r_low_velocity) - (r_low_velocity >>> 5) +
        (w_low_error >>> 9) + (w_low_error >>> 10) + (w_low_error >>> 11);
    assign w_high_velocity = $signed(r_high_velocity) - (r_high_velocity >>> 5) +
        (w_high_error >>> 7) + (w_high_error >>> 9);
    assign w_low_position = $signed(r_low_position) + w_low_velocity;
    assign w_high_position = $signed(r_high_position) + w_high_velocity;
    assign w_output = $signed(i_sample) - ($signed(i_sample) >>> 2) +
        (r_low_position >>> 12) + (r_high_position >>> 12);
    assign o_sample = w_output > 32767 ? 16'sh7fff :
        w_output < -32768 ? 16'sh8000 : w_output[15:0];
    always @(posedge i_clk)
    begin
        if (i_reset || (i_sample_tick && i_trigger))
        begin
            r_low_position <= 0;
            r_low_velocity <= 0;
            r_high_position <= 0;
            r_high_velocity <= 0;
        end
        else if (i_sample_tick)
        begin
            r_low_position <= bound_state(w_low_position);
            r_low_velocity <= bound_state(w_low_velocity);
            r_high_position <= bound_state(w_high_position);
            r_high_velocity <= bound_state(w_high_velocity);
        end
    end
endmodule
