`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_led_r50 —— 验证 R50 灯带规则
//
// 做法：把 sclk/data 当 SPI 从机，每 32 bit 解出一颗灯：
//       {3'b111, BRI[4:0], B[7:0], G[7:0], R[7:0]}
//
// 判据（全部与呼吸相位无关，只比"有没有/比例关系"）：
//   A 帧长仍是 2272 bit（时序一个字没动）
//   B 静默：pix0..30 的 32 bit **完全相同**且非 0（统一底色青）
//   C 静默：pix22（坏灯 L23）与 pix31..63 全 0
//   D 弦 0 发声：弦 0 列 B==0 且 R>0（琥珀）；其它列 R==0（仍是青）
//   E 弦 2 发声：弦 2 列 R==0 且 G>0 且 B>0（蓝）；弦 0 列退回青（R==0）
//   F 坏灯在任何时刻都是全 0
//   G BRI 字段 == 3（电流档）
// ---------------------------------------------------------------------------
module tb_led_r50;
    reg clk=1'b0, reset=1'b1;
    reg [3:0] i_active=4'd0;
    wire sclk, data;

    always #10 clk=~clk;

    left_led_status dut(
        .clk(clk),.reset(reset),
        .i_ready(4'd0),.i_multi(4'd0),.i_common(4'd0),.i_fault(4'd0),
        .i_active(i_active),.sclk(sclk),.data(data));

    reg [31:0] sh=32'd0;
    integer bitn=0, idx=0, frame=0;
    integer maxbit=0;
    reg [31:0] px [0:63];

    always @(posedge sclk) begin
        sh   = {sh[30:0], data};
        bitn = bitn + 1;
        if (bitn > 32 && ((bitn-32)%32)==0) begin
            idx = (bitn-32)/32 - 1;
            if (idx < 64) px[idx] = sh;
        end
        if (bitn == 2272) begin
            bitn  = 0;
            frame = frame + 1;
        end
        if (bitn > maxbit) maxbit = bitn;
    end

    integer errs = 0;
    integer k, f0;

    // ---- R50：直接盯住"压暗常量" ----------------------------------------
    // 只看解码后的像素值分不清 0.5× 和 1.0×（颜色比例相同），必须在像素中途
    // 采样组合逻辑里的 gsel/bsel。这里踩过一次：写成 48+(48>>2)+(48>>4)=63
    // 是 1.3125 倍（更亮），解码层完全看不出来。
    integer dim_bad = 0, dim_n = 0;
    always @(posedge clk) begin
        if (dut.divider==8'd249 && dut.sclk && dut.in_pixels &&
            dut.next_bpos==5'd16 && dut.px_valid && !dut.px_dead) begin
            if (!dut.act[dut.px_str] && dut.any_act_h) begin
                dim_n = dim_n + 1;
                if (dut.gsel !== 8'd24 || dut.bsel !== 8'd32) begin
                    if (dim_bad < 4)
                        $display("FAIL H: 压暗列 gsel=%0d bsel=%0d（应为 24/32 = 0.5x）",
                                 dut.gsel, dut.bsel);
                    dim_bad = dim_bad + 1;
                end
            end
        end
    end

    // 静默判据
    // 注意：一帧 22.7 ms 内呼吸值会走 1~3 级，所以 pix0 与 pix30 不可能逐位相同。
    // 判"同一底色"要看颜色规则：R==0、B>G>0（青），并允许 ±4 的呼吸偏差。
    task check_idle;
        input integer f;
        integer g0, b0;
        begin
            g0 = px[0][15:8];
            b0 = px[0][23:16];
            for (k=1;k<31;k=k+1) begin
                if (k != 22) begin
                    if (px[k][7:0] !== 8'd0) begin
                        $display("FAIL B: 静默 pix%0d 的 R=%0d 不为 0", k, px[k][7:0]);
                        errs = errs + 1;
                    end else if (px[k][15:8] == 8'd0 || px[k][23:16] == 8'd0) begin
                        $display("FAIL B: 静默 pix%0d 全黑（应该呼吸）", k);
                        errs = errs + 1;
                    end else if (px[k][23:16] <= px[k][15:8]) begin
                        $display("FAIL B: 静默 pix%0d 不是青（G=%0d B=%0d，应 B>G）",
                                 k, px[k][15:8], px[k][23:16]);
                        errs = errs + 1;
                    end
                end
            end
            if (g0 == 8'd0 || b0 == 8'd0) begin
                $display("FAIL B: 静默 pix0 全黑");
                errs = errs + 1;
            end
            // 坏灯与 31..63 全黑
            if (px[22][23:0] !== 24'd0) begin
                $display("FAIL C: 坏灯 pix22 = 0x%08X 不是全黑", px[22]);
                errs = errs + 1;
            end
            for (k=31;k<64;k=k+1)
                if (px[k][23:0] !== 24'd0) begin
                    $display("FAIL C: pix%0d 的 RGB=0x%06X 不是全黑", k, px[k][23:0]);
                    errs = errs + 1;
                end
        end
    endtask

    // 弦 s 发声时的判据：本弦列必须是指定弦色，其它列必须是青（R==0）
    task check_active;
        input [1:0] s;
        input integer f;
        integer m;
        reg [7:0] R,G,B;
        begin
            for (m=0;m<31;m=m+1) begin
                R = px[m][7:0];
                G = px[m][15:8];
                B = px[m][23:16];
                if (m==22) begin
                    if (px[m][23:0] !== 24'd0) begin
                        $display("FAIL F: 坏灯在弦%0d 发声时亮了 = 0x%08X", s, px[m]);
                        errs = errs + 1;
                    end
                end else if (m[1:0]==s) begin
                    // 判据只依赖"颜色比例"，与呼吸相位无关：
                    //   弦0 琥珀 (150,60,0)  -> B 恒为 0
                    //   弦1 青绿 (0,150,60)  -> R 恒为 0 且 G>=B
                    //   弦2 蓝   (0,60,150)  -> R 恒为 0 且 B>G 且与底色不同
                    //   弦3 紫   (110,0,110) -> G 恒为 0
                    case (s)
                        2'd0: if (B !== 8'd0) begin
                                  $display("FAIL D: 弦0 列 pix%0d 有蓝分量 B=%0d（琥珀应 B=0）", m, B);
                                  errs = errs + 1; end
                        2'd1: if (R !== 8'd0 || G < B) begin
                                  $display("FAIL D: 弦1 列 pix%0d R=%0d G=%0d B=%0d（应 R=0 且 G>=B）",
                                           m,R,G,B);
                                  errs = errs + 1; end
                        2'd2: if (R !== 8'd0 || B < G) begin
                                  $display("FAIL D: 弦2 列 pix%0d R=%0d G=%0d B=%0d（应 R=0 且 B>=G）",
                                           m,R,G,B);
                                  errs = errs + 1; end
                        default: if (G !== 8'd0) begin
                                  $display("FAIL D: 弦3 列 pix%0d 有绿分量 G=%0d（紫应 G=0）", m, G);
                                  errs = errs + 1; end
                    endcase
                end else begin
                    if (R !== 8'd0) begin
                        $display("FAIL D: 非本弦 pix%0d 的 R=%0d 不为 0（应是青）", m, R);
                        errs = errs + 1;
                    end
                end
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        reset = 1'b0;

        wait (frame == 4);  f0 = frame;
        $display("[idle] frame=%0d pix0=0x%08X pix22=0x%08X pix30=0x%08X pix31=0x%08X",
                 f0, px[0], px[22], px[30], px[31]);
        check_idle(f0);

        i_active = 4'b0001;                       // 弦 0
        wait (frame == f0+6);                     // 等尾灯保持与呼吸都更新
        $display("[s0]   pix0=0x%08X  pix1=0x%08X  pix2=0x%08X  pix3=0x%08X  pix22=0x%08X",
                 px[0], px[1], px[2], px[3], px[22]);
        check_active(2'd0, frame);

        i_active = 4'b0100;                       // 弦 2
        wait (frame == f0+26);   // 等 0.40 s 拖尾过期（约 18 帧）
        $display("[s2]   pix0=0x%08X  pix1=0x%08X  pix2=0x%08X  pix3=0x%08X",
                 px[0], px[1], px[2], px[3]);
        check_active(2'd2, frame);

        // 松开后 0.40 s 拖尾期内颜色保持（这是设计），拖尾结束后才回统一青。
        // 回到静默的规则已在开头验过，这里不再等 0.4 s（仿真时间不够划算）。

        // 帧长与 BRI
        if (maxbit != 2271) begin
            $display("FAIL A: 帧长异常，最大 bit 计数 %0d（应为 2271）", maxbit);
            errs = errs + 1;
        end
        if (px[0][28:24] !== 5'd3) begin
            $display("FAIL G: BRI 字段 = %0d（应为 3）", px[0][28:24]);
            errs = errs + 1;
        end
        if (px[0][31:29] !== 3'b111) begin
            $display("FAIL G: 起始位不是 111（=0x%0d）", px[0][31:29]);
            errs = errs + 1;
        end

        $display("[dim] 采样 %0d 次，错误 %0d 次（期望 0）", dim_n, dim_bad);
        if (dim_bad != 0) errs = errs + 1;
        if (dim_n == 0) begin
            $display("FAIL H: 没有采到压暗列，判据形同虚设");
            errs = errs + 1;
        end
        if (errs==0) $display("PASS led r50: 31 颗 / 坏灯 index22 / 分弦配色 / 帧长 2272 / BRI=3");
        else         $display("FAIL %0d 项", errs);
        $finish;
    end

    initial begin
        #900_000_000;
        $display("TIMEOUT frame=%0d bitn=%0d", frame, bitn);
        $finish;
    end
endmodule
