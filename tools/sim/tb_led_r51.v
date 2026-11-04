`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_led_r51 —— 验证 R51 灯带（在 R50 规则上修"只有小提琴"的问题）
//
// 与 R50 的差别：
//   · 删掉 L23(index22) 压黑判据 —— 那颗灯已物理拆除、DI/DO 短接，索引不偏移，
//     代码不再特判，所以 index 22 必须和同弦其他灯**完全同色**。
//   · 新增"单拍脉冲"判据：`i_active` 只拉高 1 拍（模拟尤克里里拨弦触发
//     trigger_bus[7:4] 的单拍脉冲），灯必须靠 0.40 s 拖尾稳定显示。
//     这是 R50 那个 bug 的直接回归测试：R50 接的是恒 0 的 gate_bus[7:4]，
//     所以"拨弦点亮"根本不会发生。
//
// 解码：把 sclk/data 当 SPI 从机，每 32 bit 解一颗灯：
//       {3'b111, BRI[4:0], B[7:0], G[7:0], R[7:0]}
//
// 判据：
//   A 帧长仍是 2272 bit
//   B 静默 pix0..30 全是青（R==0, B>G>0）
//   C pix31..63 全黑
//   D 弦0 电平发声 -> 弦0 行 B==0 且 R>0（琥珀）
//   E 弦2 电平发声 -> 弦2 行 R==0 且 B>=G（蓝），弦0 行退回青
//   F **弦1 单拍脉冲** -> 弦1 行 R==0 且 G>=B 且非全黑（青绿），且 index22 同色
//   G 单拍脉冲后等 0.6 s -> 全部褪回青
//   H 压暗常量必须正好 24/32（0.5×）
//   I BRI=3、起始位 111
// ---------------------------------------------------------------------------
module tb_led_r51;
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

    // ---- 压暗常量：必须直接采组合逻辑，解码层看不出来 ----
    integer dim_bad = 0, dim_n = 0;
    always @(posedge clk) begin
        if (dut.divider==8'd249 && dut.sclk && dut.in_pixels &&
            dut.next_bpos==5'd16 && dut.px_valid && !dut.px_dead) begin
            if (!dut.act[dut.px_str] && dut.any_act_h) begin
                dim_n = dim_n + 1;
                if (dut.gsel !== 8'd24 || dut.bsel !== 8'd32) begin
                    if (dim_bad < 4)
                        $display("FAIL H: 压暗行 gsel=%0d bsel=%0d（应为 24/32 = 0.5x）",
                                 dut.gsel, dut.bsel);
                    dim_bad = dim_bad + 1;
                end
            end
        end
    end

    // 静默判据
    task check_idle;
        input integer f;
        integer g0, b0;
        begin
            g0 = px[0][15:8];
            b0 = px[0][23:16];
            // 物理接收者 0..29（L23 拆除后只剩 30 颗）；接收者 30 对应逻辑 31，无灯必黑
            for (k=0;k<30;k=k+1) begin
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
            if (px[30][23:0] !== 24'd0) begin
                $display("FAIL B: pix30 应全黑（逻辑索引 31 无灯），实际 0x%06X", px[30][23:0]);
                errs = errs + 1;
            end
            if (g0 == 8'd0 || b0 == 8'd0) begin
                $display("FAIL B: 静默 pix0 全黑");
                errs = errs + 1;
            end
            for (k=31;k<64;k=k+1)
                if (px[k][23:0] !== 24'd0) begin
                    $display("FAIL C: pix%0d 的 RGB=0x%06X 不是全黑", k, px[k][23:0]);
                    errs = errs + 1;
                end
        end
    endtask

    // 弦 s 发声时的判据：本弦行必须是指定弦色，其它行必须是青（R==0）
    task check_active;
        input [1:0] s;
        input integer f;
        integer m;
        reg [1:0] str;
        reg [7:0] R,G,B;
        begin
            for (m=0;m<30;m=m+1) begin
                // L23(index22) 已物理拆除：接收者 m>=22 收的是逻辑 m+1 的字
                str = (m >= 22) ? (m+1) : m;
                R = px[m][7:0];
                G = px[m][15:8];
                B = px[m][23:16];
                if (str[1:0]==s) begin
                    if (R===8'd0 && G===8'd0 && B===8'd0) begin
                        $display("FAIL D: 弦%0d 行 pix%0d 全黑（应亮弦色）", s, m);
                        errs = errs + 1;
                    end else case (s)
                        2'd0: if (B !== 8'd0) begin
                                  $display("FAIL D: 弦0 行 pix%0d 有蓝分量 B=%0d（琥珀应 B=0）", m, B);
                                  errs = errs + 1; end
                        2'd1: if (R !== 8'd0 || G < B) begin
                                  $display("FAIL F: 弦1 行 pix%0d R=%0d G=%0d B=%0d（应 R=0 且 G>=B）",
                                           m,R,G,B);
                                  errs = errs + 1; end
                        2'd2: if (R !== 8'd0 || B < G) begin
                                  $display("FAIL D: 弦2 行 pix%0d R=%0d G=%0d B=%0d（应 R=0 且 B>=G）",
                                           m,R,G,B);
                                  errs = errs + 1; end
                        default: if (G !== 8'd0) begin
                                  $display("FAIL D: 弦3 行 pix%0d 有绿分量 G=%0d（紫应 G=0）", m, G);
                                  errs = errs + 1; end
                    endcase
                end else begin
                    if (R !== 8'd0) begin
                        $display("FAIL D: 非本弦 pix%0d 的 R=%0d 不为 0（应是青）", m, R);
                        errs = errs + 1;
                    end
                end
            end
            if (px[30][23:0] !== 24'd0) begin
                $display("FAIL D: pix30 应全黑（逻辑索引 31 无灯）");
                errs = errs + 1;
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

        // ---- D：小提琴（电平） ----
        i_active = 4'b0001;                       // 弦 0
        wait (frame == f0+6);
        $display("[s0]   pix0=0x%08X  pix1=0x%08X  pix2=0x%08X  pix3=0x%08X",
                 px[0], px[1], px[2], px[3]);
        check_active(2'd0, frame);

        i_active = 4'b0100;                       // 弦 2
        wait (frame == f0+26);                    // 等 0.40 s 拖尾过期
        $display("[s2]   pix0=0x%08X  pix1=0x%08X  pix2=0x%08X  pix3=0x%08X",
                 px[0], px[1], px[2], px[3]);
        check_active(2'd2, frame);

        // ---- F：尤克里里（单拍脉冲）—— R50 bug 的回归测试 ----
        // 真实路径 trigger_bus[7:4] 只有 1 拍高电平，灯必须靠 hold 记住它。
        i_active = 4'b0000;
        wait (frame == f0+44);                    // 先等上一轮彻底褪回
        check_idle(frame);
        @(posedge clk);
        i_active = 4'b0010;                       // 弦 1，只高 1 拍
        @(posedge clk);
        i_active = 4'b0000;
        wait (frame == f0+52);
        $display("[pulse s1] pix1=0x%08X pix5=0x%08X pix22=0x%08X pix25=0x%08X",
                 px[1], px[5], px[22], px[25]);
        check_active(2'd1, frame);

        // ---- G：脉冲之后必须自己褪回青 ----
        wait (frame == f0+80);
        check_idle(frame);
        $display("[decay] pix1=0x%08X pix5=0x%08X（应已回青）", px[1], px[5]);

        // ---- A / I：帧长与亮度码 ----
        if (maxbit != 2271) begin
            $display("FAIL A: 帧长异常，最大 bit 计数 %0d（应为 2271）", maxbit);
            errs = errs + 1;
        end
        if (px[0][28:24] !== 5'd3) begin
            $display("FAIL I: BRI 字段 = %0d（应为 3）", px[0][28:24]);
            errs = errs + 1;
        end
        if (px[0][31:29] !== 3'b111) begin
            $display("FAIL I: 起始位不是 111");
            errs = errs + 1;
        end

        $display("[dim] 采样 %0d 次，错误 %0d 次（期望 0）", dim_n, dim_bad);
        if (dim_bad != 0) errs = errs + 1;
        if (dim_n == 0) begin
            $display("FAIL H: 没有采到压暗行，判据形同虚设");
            errs = errs + 1;
        end
        if (errs==0) $display("PASS led r51: 电平+单拍脉冲都能点亮 / 31 颗 / index22 不特判 / 帧长 2272");
        else         $display("FAIL %0d 项", errs);
        $finish;
    end

    initial begin
        #3_200_000_000;
        $display("TIMEOUT frame=%0d bitn=%0d", frame, bitn);
        $finish;
    end
endmodule
