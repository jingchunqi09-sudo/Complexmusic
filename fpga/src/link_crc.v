`timescale 1ns/1ps
//=============================================================================
// link_crc.v — CRC16-CCITT-FALSE 与 CRC8 的组合/时序计算单元
//
// CRC16: poly 0x1021, init 0xFFFF, 不反射, 无最终 XOR。
//        按字节顺序：crc = crc ^ {data, 8'h00} 后逐位左移。与 ESP32 侧
//        Python/C 参考实现逐位一致（见 04_DOCS/协议规格_v1.md）。
// CRC8 : poly 0x07, init 0x00，用于将来更短的动作帧（本版未启用）。
//
// 一个字节 8 次迭代为纯组合逻辑，50 MHz 下约 4 ns，可单拍完成。
//=============================================================================
module link_crc (
    input  wire        clk,
    input  wire        reset,
    input  wire        step,        // 单拍：把 data 并入 crc16
    input  wire        init,        // 单拍：重置为 0xFFFF
    input  wire [7:0]  data,
    output wire [15:0] crc16,
    output wire [15:0] crc16_next
);
    function [15:0] crc16_byte;
        input [15:0] c_in;
        input [7:0]  d;
        integer i;
        reg [15:0] c;
        begin
            c = c_in ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_byte = c;
        end
    endfunction

    reg [15:0] r_crc;
    assign crc16 = r_crc;
    assign crc16_next = crc16_byte(r_crc, data);

    always @(posedge clk) begin
        if (reset || init) r_crc <= 16'hFFFF;
        else if (step)      r_crc <= crc16_next;
    end
endmodule
