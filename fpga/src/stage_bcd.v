//-----------------------------------------------------------------------------
// stage_bcd.v —— 16 位二进制 → 5 位 BCD 的时序转换器（double-dabble）
//
// 每通道 16 个时钟完成，零 DSP、无长组合除法链。dashboard 每帧轮转调用，
// 各数字显示共享一个转换器（8 通道×16 时钟 = 128 时钟/帧，远小于帧长）。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_bcd (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [15:0] value,
    output reg  [19:0] bcd,       // {万,千,百,十,个} 各 4 位
    output reg         done
);
    reg        busy;
    reg [15:0] bin;
    reg [19:0] work;
    reg [4:0]  cnt;

    // 每个 BCD 位 >=5 则 +3（double-dabble 核心）
    wire [19:0] w3 = {
        (work[19:16] >= 5) ? work[19:16] + 4'd3 : work[19:16],
        (work[15:12] >= 5) ? work[15:12] + 4'd3 : work[15:12],
        (work[11:8]  >= 5) ? work[11:8]  + 4'd3 : work[11:8],
        (work[7:4]   >= 5) ? work[7:4]   + 4'd3 : work[7:4],
        (work[3:0]   >= 5) ? work[3:0]   + 4'd3 : work[3:0]
    };

    always @(posedge clk) begin
        if (reset) begin
            busy <= 0; done <= 0; bcd <= 0; bin <= 0; work <= 0; cnt <= 0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                bin <= value; work <= 0; cnt <= 0; busy <= 1;
            end else if (busy) begin
                // {work,bin} 左移 1（先加 3）
                work <= {w3[18:0], bin[15]};
                bin  <= {bin[14:0], 1'b0};
                cnt  <= cnt + 1'b1;
                if (cnt == 5'd15) begin
                    bcd  <= {w3[18:0], bin[15]};
                    done <= 1'b1;
                    busy <= 0;
                end
            end
        end
    end
endmodule

`default_nettype wire
