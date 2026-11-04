`timescale 1ns/1ps
//=============================================================================
// rec_stream.v — 录音码流打包与发送（56 字节/帧）
//
// 环形缓冲 512 字节（1 块 BSRAM，占 R17 剩余 20 块中的 5%）。
// 12.2 KB/s 码率下 512 字节 = 42 ms 抖动吸收能力，远大于一帧发送时间
// （56+7 字节 @ 230400 ≈ 2.7 ms）。
//
// 只在本模块被"授权"（allow=1，即链路无其它发送者）时才填发送缓冲，
// 因此不会与命令应答抢 buffer。缓冲满时丢弃新样本并累加 drop 计数，
// 而不是覆盖旧样本——覆盖会造成解码器 predictor 漂移。
//=============================================================================
module rec_stream (
    input  wire        clk,
    input  wire        reset,
    input  wire        allow,           // 链路空闲，可发送
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    output reg  [7:0]  drop_count,
    // 发送缓冲写口
    output reg         tx_wr_en,
    output reg  [5:0]  tx_wr_addr,
    output reg  [7:0]  tx_wr_data,
    output reg         tx_send,
    input  wire        tx_busy,
    input  wire        tx_done
);
    localparam [2:0] R_IDLE = 3'd0, R_PRIME = 3'd1, R_FILL = 3'd2,
                     R_SEND = 3'd3, R_WAIT = 3'd4;
    localparam integer FRAME_BYTES = 56;

    reg [7:0] mem [0:511];
    reg [8:0] r_wp, r_rp;
    reg [9:0] r_count;
    reg [2:0] r_state;
    reg [6:0] r_i;
    reg [7:0] r_q;

    wire [8:0] rd_ptr_next = r_rp + 9'd1;

    // R38 修复（这是录音回传唯一的真功能 bug）：
    //   r_q <= mem[r_rp] 是**同步读**，比 r_rp 落后一拍。原来 R_FILL 里
    //   tx_wr_data <= r_q 与 r_rp <= r_rp+1 同拍执行，于是：
    //     字节0 = mem[0]（对）
    //     字节1 = mem[0]（**重复**，因为 r_q 这一拍才变成 mem[1]）
    //     字节2 = mem[1] …整体错一格，mem[55] 永远发不出去
    //   ESP32 侧 LADPCM 是按顺序解半字节的，首字节重复 = 多插 2 个假样本，
    //   之后每个样本都偏移 2 个位置，瞬态会被抹平、波形失真。
    //   修法：读地址在 R_FILL 期间预取 r_rp+1，让 r_q 始终领先发送一拍。
    //   9 位自然回绕，正好等同环形缓冲的下一个元素，不增加任何存储。
    wire [8:0] rd_addr = (r_state == R_FILL) ? rd_ptr_next : r_rp;

    // 写口
    always @(posedge clk) begin
        if (byte_valid) begin
            if (r_count < 10'd512) mem[r_wp] <= byte_data;
        end
    end

    // 读口（独立 → Simple Dual Port BSRAM）
    // 采样当前读指针：R_PRIME 之后一拍 r_q = mem[r_rp]，正好是首字节
    always @(posedge clk) begin
        r_q <= mem[rd_addr];
    end

    always @(posedge clk) begin
        if (reset) begin
            r_wp       <= 9'd0;
            r_rp       <= 9'd0;
            r_count    <= 10'd0;
            r_state    <= R_IDLE;
            r_i        <= 7'd0;
            drop_count <= 8'd0;
            tx_wr_en   <= 1'b0;
            tx_wr_addr <= 6'd0;
            tx_wr_data <= 8'd0;
            tx_send    <= 1'b0;
        end else begin
            tx_wr_en <= 1'b0;
            tx_send  <= 1'b0;

            // 缓冲计数
            if (byte_valid && r_count < 10'd512) begin
                r_wp    <= r_wp + 9'd1;
                r_count <= r_count + 10'd1;
            end else if (byte_valid) begin
                if (drop_count != 8'hFF) drop_count <= drop_count + 8'd1;
            end

            case (r_state)
                R_IDLE: begin
                    if (allow && !tx_busy && r_count >= FRAME_BYTES) begin
                        r_i     <= 7'd0;
                        r_state <= R_PRIME;
                    end
                end
                // 空转一拍：r_q 追上 r_rp
                R_PRIME: r_state <= R_FILL;
                R_FILL: begin
                    tx_wr_en   <= 1'b1;
                    tx_wr_addr <= r_i[5:0];
                    tx_wr_data <= r_q;
                    r_rp       <= r_rp + 9'd1;
                    if (r_count != 10'd0) r_count <= r_count - 10'd1;
                    if (r_i >= FRAME_BYTES - 1) r_state <= R_SEND;
                    else                        r_i     <= r_i + 7'd1;
                end
                R_SEND: begin
                    tx_send <= 1'b1;
                    r_state <= R_WAIT;
                end
                R_WAIT: begin
                    if (tx_done) r_state <= R_IDLE;
                end
                default: r_state <= R_IDLE;
            endcase
        end
    end
endmodule
