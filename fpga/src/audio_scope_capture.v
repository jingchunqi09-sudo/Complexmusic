// 非阻塞示波快照：256个实际送DAC的16位样本，按偶/奇地址存成128×32 RAM。
// request+capture启动新窗；随后request读取pair_index，忙时返回零和busy。
// 采集完成后内容冻结，直到下次capture；UART/显示读取不能反压音频。
module audio_scope_capture (
    input             i_clk,
    input             i_reset,
    input             i_pcm_valid,
    input [15:0]      i_pcm_sample,
    input             i_request,
    input             i_capture,
    input [6:0]       i_pair_index,
    output reg        o_response_valid,
    output reg [31:0] o_sample_pair,
    output reg [31:0] o_info
);
    reg [31:0] r_samples [0:127];       // 偶样本在低16位；奇样本在高16位。
    reg [15:0] r_even_sample;
    reg [7:0] r_write_index;
    reg r_busy;
    reg r_valid;
    reg [15:0] r_sequence;             // 窗编号，自然回绕；valid独立表示是否完成。
    reg [31:0] r_read_data;
    reg r_response_pending;
    reg r_response_has_data;
    reg [31:0] r_response_info;

    always @(posedge i_clk)
    begin
        if (i_pcm_valid && r_busy && r_write_index[0])
            r_samples[r_write_index[7:1]] <= {i_pcm_sample, r_even_sample};
        r_read_data <= r_samples[i_pair_index];
    end

    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            r_even_sample <= 0;
            r_write_index <= 0;
            r_busy <= 0;
            r_valid <= 0;
            r_sequence <= 0;
            r_response_pending <= 0;
            r_response_has_data <= 0;
            r_response_info <= 0;
            o_response_valid <= 0;
            o_sample_pair <= 0;
            o_info <= 0;
        end
        else
        begin
            o_response_valid <= r_response_pending;
            r_response_pending <= i_request;
            if (r_response_pending)
            begin
                o_sample_pair <= r_response_has_data ? r_read_data : 32'd0;
                o_info <= r_response_info;
            end
            if (i_request)
            begin
                r_response_has_data <= r_valid && !r_busy && !i_capture;
                // bits31:16=窗号；bit9=有效，bit8=忙；bits6:0=样本对地址。
                r_response_info <= {r_sequence, 6'd0, r_valid && !i_capture,
                                    r_busy || i_capture, 1'b0, i_pair_index};
            end
            if (i_pcm_valid && r_busy)
            begin
                r_even_sample <= i_pcm_sample;
                r_write_index <= r_write_index + 1'b1;
                if (r_write_index == 8'd255)
                begin
                    r_busy <= 0;
                    r_valid <= 1;
                    r_sequence <= r_sequence + 1'b1;
                end
            end
            // 新capture优先，丢弃尚未完成的旧窗；不会改动音频状态。
            if (i_request && i_capture)
            begin
                r_write_index <= 0;
                r_busy <= 1;
                r_valid <= 0;
            end
        end
    end
endmodule
