//-----------------------------------------------------------------------------
// piezo_wave_bank.v —— 四通道压电包络的显示波形缓存（R7）
//
// 每通道独立降采样：每 16 个样本取窗口峰值写 1 点（≈387 点/秒 @6.2kHz），
// 256 点环形 RAM ≈ 0.66 s 历史。峰值保持而非平均，保证起振尖峰在屏幕上可见。
// 读地址 rd_addr=0 为最旧点，255 为最新点（滚动显示，最新在右）。
// 资源：4×256×16bit = 16Kbit，一块 BSRAM 即可，不需要 DDR3。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module piezo_wave_bank (
    input  wire        wr_clk,        // 50 MHz 样本域
    input  wire        rd_clk,        // 视频像素时钟域
    input  wire        reset,
    input  wire        sample_valid,
    input  wire [1:0]  channel,
    input  wire [15:0] ay,            // 当前样本通道的 |y| 包络
    input  wire [7:0]  rd_addr,       // 显示列（0 最旧 … 255 最新）
    output reg  [15:0] rd_data0,
    output reg  [15:0] rd_data1,
    output reg  [15:0] rd_data2,
    output reg  [15:0] rd_data3
);

    // 双口 RAM：写侧样本域、读侧视频域（Gowin DPB 推断）
    reg [15:0] mem0 [0:255];
    reg [15:0] mem1 [0:255];
    reg [15:0] mem2 [0:255];
    reg [15:0] mem3 [0:255];

    reg [7:0]  wr_ptr [0:3];
    reg [3:0]  decim  [0:3];
    reg [15:0] peak   [0:3];

    // 读地址用各通道写指针的同步副本（视频域）计算滚动偏移
    reg [7:0]  wr_ptr_v [0:3];
    always @(posedge rd_clk) begin
        wr_ptr_v[0] <= wr_ptr[0];
        wr_ptr_v[1] <= wr_ptr[1];
        wr_ptr_v[2] <= wr_ptr[2];
        wr_ptr_v[3] <= wr_ptr[3];
    end

    wire [7:0] ra0 = wr_ptr_v[0] + rd_addr;
    wire [7:0] ra1 = wr_ptr_v[1] + rd_addr;
    wire [7:0] ra2 = wr_ptr_v[2] + rd_addr;
    wire [7:0] ra3 = wr_ptr_v[3] + rd_addr;

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            mem0[i] = 0; mem1[i] = 0; mem2[i] = 0; mem3[i] = 0;
        end
        for (i = 0; i < 4; i = i + 1) begin
            wr_ptr[i] = 0; decim[i] = 0; peak[i] = 0;
        end
    end

    // 读侧（视频时钟）
    always @(posedge rd_clk) begin
        rd_data0 <= mem0[ra0];
        rd_data1 <= mem1[ra1];
        rd_data2 <= mem2[ra2];
        rd_data3 <= mem3[ra3];
    end

    // 写侧（样本时钟）
    always @(posedge wr_clk) begin
        if (reset) begin
            for (i = 0; i < 4; i = i + 1) begin
                wr_ptr[i] <= 0; decim[i] <= 0; peak[i] <= 0;
            end
        end else if (sample_valid) begin
            if (ay > peak[channel]) peak[channel] <= ay;
            if (decim[channel] == 4'd15) begin
                decim[channel] <= 0;
                peak[channel]  <= 0;
                case (channel)
                    2'd0: mem0[wr_ptr[0]] <= (ay > peak[0]) ? ay : peak[0];
                    2'd1: mem1[wr_ptr[1]] <= (ay > peak[1]) ? ay : peak[1];
                    2'd2: mem2[wr_ptr[2]] <= (ay > peak[2]) ? ay : peak[2];
                    2'd3: mem3[wr_ptr[3]] <= (ay > peak[3]) ? ay : peak[3];
                endcase
                wr_ptr[channel] <= wr_ptr[channel] + 1'b1;
            end else begin
                decim[channel] <= decim[channel] + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
