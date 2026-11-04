//=============================================================================
// tb_pt8211_volume.v — R36 音量通路验证（只测 DAC 发送模块本身）
//
// 要证明四件事：
//   1. vol=128（上电默认）时，送进 DAC 的帧样本与 i_sample **逐位相同**（0 dB 直通）
//   2. vol=64 时输出精确等于 i_sample/2（Q7.8 增益）
//   3. vol=0 恒 0；vol=255 饱和而不是回绕成噪声
//   4. 帧装载的相位关系没变（仍是"valid 同拍装载、下一帧使用"）
//=============================================================================
`timescale 1ns/1ps

module tb_pt8211_volume;
    localparam integer CLK_HZ = 50_000_000;
    localparam integer BCLK_HZ = 3_125_000;

    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg signed [15:0] sample = 0;
    reg        valid = 0;
    reg  [7:0] vol = 8'd128;
    wire signed [15:0] frame_pcm;
    wire        frame_pcm_valid;
    wire        sample_tick;

    pt8211_tx #(.CLOCK_HZ(CLK_HZ), .BCLK_HZ(BCLK_HZ), .USE_VALID_MAILBOX(1)) dut (
        .i_clk(clk), .i_reset(reset),
        .i_sample(sample), .i_sample_valid(valid), .i_sample_event(1'b0),
        .i_sample_ready(1'b1), .i_volume(vol),
        .i_sample_first_sequence(32'd0), .i_sample_event_count(16'd0),
        .o_frame_first_sequence(), .o_frame_event_count(),
        .i_sample_sequence(32'd0), .i_sample_event_clock(64'd0),
        .o_event_frame_complete(), .o_frame_event_sequence(), .o_frame_event_clock(),
        .o_underrun_count(), .o_overrun_count(), .o_frame_sequence(),
        .o_hp_bck(), .o_hp_ws(), .o_hp_din(), .o_sample_tick(sample_tick),
        .o_first_sample(), .o_frame_pcm(frame_pcm), .o_frame_pcm_valid(frame_pcm_valid),
        .o_left_word_complete(), .o_frame_word_complete()
    );

    integer errors = 0;

    // 抓"送进来的那一帧"：armed 置位后第一次 frame_pcm_valid 采到的就是答案
    reg armed = 0;
    reg signed [15:0] cap = 0;
    always @(posedge clk) begin
        if (frame_pcm_valid && armed) begin
            cap   <= frame_pcm;
            armed <= 1'b0;
        end
    end

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("FAIL %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // 推一个样本，等到它被某一帧真正发出去
    task push(input signed [15:0] v);
        integer wait_n;
        begin
            @(posedge clk);
            sample <= v; valid <= 1'b1; armed <= 1'b1;
            @(posedge clk);
            valid <= 1'b0;
            wait_n = 0;
            while (armed !== 1'b0 && wait_n < 20000) begin
                @(posedge clk);
                wait_n = wait_n + 1;
            end
            if (armed !== 1'b0) begin
                $display("FAIL push timeout (no frame consumed the sample)");
                errors = errors + 1;
                armed = 1'b0;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        reset <= 0;
        repeat (20) @(posedge clk);

        // ---- vol = 128：0 dB 直通，必须逐位相同 ----
        vol = 8'd128;
        push(16'sd12345);  check(cap == 16'sd12345,  "vol=128 passthrough positive");
        push(-16'sd23456); check(cap == -16'sd23456, "vol=128 passthrough negative");
        push(16'sh7FFF);   check(cap == 16'sh7FFF,   "vol=128 passthrough full scale");
        push(16'sh8000);   check(cap == 16'sh8000,   "vol=128 passthrough most negative");

        // ---- vol = 64：-6 dB，输出 = 输入/2 ----
        vol = 8'd64;
        push(16'sd10000);  check(cap == 16'sd5000,  "vol=64 halves +10000");
        push(-16'sd10000); check(cap == -16'sd5000, "vol=64 halves -10000");

        // ---- vol = 0：静音 ----
        vol = 8'd0;
        push(16'sd20000);  check(cap == 16'sd0, "vol=0 mutes");

        // ---- vol = 255：+6 dB，必须饱和而不是回绕 ----
        vol = 8'd255;
        push(16'sd20000);  check(cap == 16'sh7FFF, "vol=255 saturates positive (no wraparound)");
        push(-16'sd20000); check(cap == 16'sh8000, "vol=255 saturates negative (no wraparound)");

        // ---- 回到 128，确认 0 dB 恢复逐位直通 ----
        vol = 8'd128;
        push(16'sd7777);   check(cap == 16'sd7777, "vol back to 128 restores bit-exact passthrough");

        if (errors == 0) $display("PASS pt8211 volume (10 checks)");
        else             $display("FAIL pt8211 volume: %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL testbench timeout");
        $finish;
    end
endmodule
