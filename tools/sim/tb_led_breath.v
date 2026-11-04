`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_led_breath —— 验证 left_led_status（R45：整条统一呼吸 + 对比式高亮）
//
// 做法：把 sclk/data 当 SPI 从机收，每 32 bit 解出一颗灯：
//       {3'b111, BRI[4:0], B[7:0], G[7:0], R[7:0]}
//       灯序 = 品*4 + 弦，所以 pixel[1:0]=弦、pixel[5:2]=品。
//
// 判据（R46，对应用户要求"整条统一呼吸、弹弦才明显变化、不能太亮"）：
//   1. **静默时 p0..p30 全部相同**（坏灯 p23 除外）—— 这是"不乱"的硬判据
//   2. 静默两个时刻亮度不同 -> 呼吸在动；且单通道 <= 64（不刺眼）
//   3. 弹弦 0：p0 明显亮于 p1（对比式，不是整体抬亮）
//   4. 坏灯 p23 恒为 (0,0,0)
// ---------------------------------------------------------------------------
module tb_led_breath;
    reg clk=1'b0, reset=1'b1;
    reg [3:0]  i_active   = 4'd0;
    reg [3:0]  i_ready    = 4'd0;
    wire sclk, data;

    always #10 clk=~clk;                // 50 MHz

    left_led_status dut(
        .clk(clk),.reset(reset),
        .i_ready(i_ready),.i_multi(4'd0),.i_common(4'd0),.i_fault(4'd0),
        .i_active(i_active),
        .sclk(sclk),.data(data));

    // ---------------- SK9822 从机解码 ----------------
    reg [31:0] sh=32'd0;
    integer bitn=0, idx=0, frame=0;
    reg [4:0] bri_q [0:63];
    reg [7:0] r_q   [0:63];
    reg [7:0] g_q   [0:63];
    reg [7:0] b_q   [0:63];

    integer k;
    initial for (k=0;k<64;k=k+1) begin
        bri_q[k]=5'd0; r_q[k]=8'd0; g_q[k]=8'd0; b_q[k]=8'd0;
    end

    always @(posedge sclk) begin
        sh   = {sh[30:0], data};
        bitn = bitn + 1;
        if (bitn > 32 && ((bitn-32)%32)==0) begin
            idx = (bitn-32)/32 - 1;
            if (idx >= 0 && idx < 64) begin
                bri_q[idx] = sh[28:24];
                b_q[idx]   = sh[23:16];
                g_q[idx]   = sh[15:8];
                r_q[idx]   = sh[7:0];
            end
        end
        if (bitn == 2272) begin
            bitn  = 0;
            frame = frame + 1;
        end
    end

    task show;
        input [127:0] tag;
        input integer p;
        begin
            $display("[%0s] f=%0d p%0d = R%0d G%0d B%0d  (bri=%0d)",
                     tag, frame, p, r_q[p], g_q[p], b_q[p], bri_q[p]);
        end
    endtask

    function integer lum;
        input integer p;
        begin
            lum = r_q[p] + g_q[p] + b_q[p];
        end
    endfunction

    integer errs = 0;
    integer p, ref_r, ref_g, ref_b, bad_cnt;
    integer dr, dg, db;      // 必须用 integer 存差值：reg[7:0]-integer 是无符号，
                             // 负数会变成 4e9 那种天文数字，判据会全部误报
    integer lum_idle, lum12, lum13, lum23, max_ch;

    initial begin
        repeat (20) @(posedge clk);
        reset = 1'b0;

        // ---- 判据 1：静默时 31 颗必须完全一致（坏灯 23 除外）----
        wait (frame == 6);
        ref_r = r_q[0]; ref_g = g_q[0]; ref_b = b_q[0];
        bad_cnt = 0;
        for (p=0; p<31; p=p+1) begin
            // Verilog-2001 没有 continue，用 if 包住
            if (p != 23) begin                    // 23 是物理坏灯，屏蔽为黑
                // 允许 ±8：呼吸每 2.6 ms 走一级，一帧 22.7 ms 内走 ~4 级，
                // 同一帧里靠后的像素本来就更暗一点。真正的"乱"是差几十。
                dr = r_q[p] - ref_r; if (dr < 0) dr = -dr;
                dg = g_q[p] - ref_g; if (dg < 0) dg = -dg;
                db = b_q[p] - ref_b; if (db < 0) db = -db;
                if (dr > 8 || dg > 8 || db > 8) begin
                    if (bad_cnt < 4)
                        $display("  MISMATCH p%0d = R%0d G%0d B%0d  (期望 R%0d G%0d B%0d)",
                                 p, r_q[p], g_q[p], b_q[p], ref_r, ref_g, ref_b);
                    bad_cnt = bad_cnt + 1;
                end
            end
        end
        $display("[idle-uni  ] f=%0d 底色 R%0d G%0d B%0d，31 颗中不一致 %0d 颗",
                 frame, ref_r, ref_g, ref_b, bad_cnt);
        if (bad_cnt != 0) begin
            $display("FAIL 静默时不是整条统一（%0d 颗不一致）", bad_cnt);
            errs = errs + 1;
        end
        if (r_q[0]==0 && g_q[0]==0 && b_q[0]==0) begin
            $display("FAIL 静默时全黑");
            errs = errs + 1;
        end

        // ---- 判据 2：呼吸在动，且不过亮 ----
        lum_idle = lum(0);
        max_ch = r_q[0]; if (g_q[0]>max_ch) max_ch=g_q[0]; if (b_q[0]>max_ch) max_ch=b_q[0];
        wait (frame == 14);
        show("idle-late ", 0);
        if (lum(0) == lum_idle) begin
            $display("FAIL 呼吸没有变化");
            errs = errs + 1;
        end
        if (max_ch > 64) begin
            $display("FAIL 静默底色过亮：单通道 %0d > 64", max_ch);
            errs = errs + 1;
        end

        // ---- 判据 3：弹弦 0 -> 该列亮、其余列压暗（对比明显）----
        i_active = 4'b0001;
        wait (frame == 22);
        show("s0-on    ", 0); show("s0-dim   ", 1);
        if (!(lum(0) > lum(1) * 2)) begin
            $display("FAIL 弹弦对比不足：p0 亮度 %0d，p1 亮度 %0d", lum(0), lum(1));
            errs = errs + 1;
        end

        // ---- 判据 4：坏灯 p23 恒黑 ----
        i_active   = 4'b1000;            // 弦3 发声
        i_ready    = 4'b1000;
        wait (frame == 30);
        show("dead23   ", 22); show("dead23   ", 23);
        lum23 = lum(23);
        if (lum23 != 0) begin
            $display("FAIL 坏灯 p23 未压黑（亮度 %0d）", lum23);
            errs = errs + 1;
        end
        if (lum(22) == 0) begin
            $display("FAIL p22 不该是黑的");
            errs = errs + 1;
        end

        if (errs == 0) $display("PASS R46 unified breath + contrast + dead-pixel (%0d frames)", frame);
        else           $display("FAIL %0d 项未通过", errs);
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("TIMEOUT at frame=%0d", frame);
        $finish;
    end
endmodule
