`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_paw_recovery —— 验证 R47 对 paw3395_driver 的两处修复
//
// 修复 1：S_ERROR 自动重试（原来没有任何出口，SPI 抖一次就永久死机）
// 修复 2：运行期自检容错（连续 3 次才判错）+ 每轮清零 check_failed
//         （原来 check_failed 只在初始化时清，一次抖动会被永久保留）
//
// 做法：写一个 PAW3395 SPI 从机模型（mode 3：从机下降沿出、主机上升沿采），
//       在指定轮次让 CPI 寄存器(0x48)返回错值，观察 ready / debug_error 的变化。
//
// 判据：
//   A. 正常初始化后 ready=1
//   B. 注入 1 次错 -> ready 仍为 1（单次抖动只丢一个采样，不再整机死）
//   C. 连续注入到第 3 次 -> 进 S_ERROR，debug_error=3，ready=0
//   D. 等 RETRY_CYCLES 后自动重初始化，ready 回到 1（无需按键复位）
// ---------------------------------------------------------------------------
module tb_paw_recovery;

    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    wire paw_nreset, paw_ncs, paw_sclk, paw_mosi;
    wire signed [15:0] dx, dy;
    wire paw_ready, paw_err, paw_valid;
    wire [3:0] debug_error;
    reg  paw_miso = 1'b0;

    // ---- 参数缩小，让仿真快 ----
    paw3395_driver #(
        .CPI(3200),
        .RESET_CYCLES(5), .POWER_WAIT_CYCLES(5), .WAIT_5MS_CYCLES(5),
        .WAIT_1MS_CYCLES(20),
        .SPI_CLK_DIV(2), .SPI_SRAD_CYCLES(2),
        .RETRY_CYCLES(200),
        .CHECK_FAIL_MAX(3)
    ) dut (
        .clk_50m(clk), .reset_n(reset_n), .paw_miso(paw_miso), .paw_motion(1'b1),
        .paw_nreset(paw_nreset), .paw_ncs(paw_ncs), .paw_sclk(paw_sclk), .paw_mosi(paw_mosi),
        .delta_x(dx), .delta_y(dy), .motion_valid(), .ready(paw_ready), .init_error(paw_err),
        .debug_product_id(), .debug_inverse_id(), .debug_motion(), .debug_squal(),
        .debug_cpi_x(), .debug_cpi_y(), .debug_error(debug_error),
        .sample_valid(paw_valid));

    // ---------------- 故障注入 ----------------
    // 每轮运行期自检开始时消耗一个 inject_left；本轮的 CPI 读全部返回错值。
    integer inject_left = 0;
    reg     inject_active = 1'b0;

    always @(posedge clk) begin
        // S_MOTION_CMD=18，count==1 表示刚进入（下一拍开始计时）
        if (dut.state == 5'd18 && dut.count == 5'd1) begin
            if (inject_left > 0) begin
                inject_active <= 1'b1;
                inject_left   <= inject_left - 1;
            end else begin
                inject_active <= 1'b0;
            end
        end
        if (dut.state == 5'd14) inject_active <= 1'b0;   // S_READY
        if (dut.state == 5'd22) inject_active <= 1'b0;   // S_ERROR：停止注入，否则重试也会被注入
    end

    // ---------------- SPI 从机模型 ----------------
    reg [7:0] addr_shift;
    reg [7:0] addr_lat;
    reg [2:0] abit, dbit;
    reg       phase_addr;

    // 简化寄存器文件：必须支持**写**，否则 0x40(AWAKE) 的
    // "读-改-写-再读验证"流程会失败（debug_error=5）。
    reg [7:0] regs [0:255];
    reg [7:0] wshift;
    reg [2:0] wbit;
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) regs[i] = 8'h00;
        regs[8'h00] = 8'h51;      // Product_ID
        regs[8'h5F] = 8'hAE;      // Inverse_ID
        regs[8'h48] = 8'h3F;      // CPI_X low  (CPI_SETTING = 3200/50-1 = 0x3F)
        regs[8'h49] = 8'h00;      // CPI_X high
        regs[8'h4A] = 8'h3F;      // CPI_Y low
        regs[8'h4B] = 8'h00;      // CPI_Y high
        regs[8'h6C] = 8'h80;      // Motion：bit7=1 有新数据
        regs[8'h02] = 8'h80;
        regs[8'h03] = 8'h01;
        regs[8'h05] = 8'h01;
        regs[8'h07] = 8'h40;      // SQUAL
    end

    function [7:0] reg_read(input [7:0] a);
        begin
            // 注入：运行期自检读的是 Product_ID(0x00) 与 Inverse_ID(0x5F)，
            // 这里让它们返回错值（模拟 MISO 抖动）。
            if (inject_active && (a == 8'h00 || a == 8'h5F)) reg_read = 8'h00;
            else reg_read = regs[a];
        end
    endfunction

    always @(negedge paw_ncs) begin
        phase_addr <= 1'b1;
        abit       <= 3'd7;
        dbit       <= 3'd7;
        wbit       <= 3'd7;
        addr_shift <= 8'd0;
        wshift     <= 8'd0;
    end

    // 地址阶段：主机上升沿驱动 MOSI，从机在这里采
    // 数据阶段（写操作）：同样在上升沿采 DATA，结束时写进 regs
    always @(posedge paw_sclk) if (!paw_ncs) begin
        if (phase_addr) begin
            if (abit == 3'd0) begin
                addr_lat   <= {addr_shift[7:1], paw_mosi};
                phase_addr <= 1'b0;
            end else begin
                addr_shift[abit] <= paw_mosi;
                abit <= abit - 3'd1;
            end
        end else if (addr_lat[7]) begin          // 写操作
            wshift[wbit] <= paw_mosi;
            if (wbit == 3'd0) begin
                // 真实 PAW3395 上这些是**只读**的，写无效；但初始化表里会写它们
                // （第 90 条写 0x5F、第 54 条写 0x6C）。模型必须照芯片行为忽略，
                // 否则自检读到被覆盖的值（实测 Inverse_ID 0xAE -> 0x1E）会误判。
                //   0x00 Product_ID / 0x5F Inverse_ID / 0x6C Motion
                //   0x02..0x07 Motion、Delta_X/Y、SQUAL
                if ((addr_lat & 8'h7F) != 8'h00 &&
                    (addr_lat & 8'h7F) != 8'h5F &&
                    (addr_lat & 8'h7F) != 8'h6C &&
                    !((addr_lat & 8'h7F) >= 8'h02 && (addr_lat & 8'h7F) <= 8'h07))
                    regs[addr_lat & 8'h7F] <= {wshift[7:1], paw_mosi};
            end else wbit <= wbit - 3'd1;
        end
    end

    // Verilog-2001 不允许对函数返回值直接位选，先落到线网
    reg [7:0] cur_rdata;
    always @(*) cur_rdata = reg_read(addr_lat);

    // 数据阶段：从机在下降沿改变 MISO
    always @(negedge paw_sclk) if (!paw_ncs && !phase_addr) begin
        paw_miso <= cur_rdata[dbit];
        if (dbit != 3'd0) dbit <= dbit - 3'd1;
    end

    // 探针：打印每次自检读回的值
    always @(posedge clk) begin
        if (dut.spi_done && dut.state == 5'd25)
            $display("[CK] ph=%0d idx=%0d addr=%02X rdata=%02X inj=%0d streak=%0d cf=%0d",
                     dut.check_phase, dut.check_index, dut.spi_addr, dut.spi_rdata,
                     inject_active, dut.fail_streak, dut.check_failed);
    end

    // ---------------- 主检查流程 ----------------
    integer errs = 0;
    integer guard;
    integer retry_seen = 0;

    // ---- R49：sample_valid 间隔监测 ----------------------------------------
    // bow_motion_tracker 的 WATCHDOG_MS=8：连续 400000 拍没有采样就 gate<=0。
    // 只要最大间隔 < 400000 拍，下游就永远不会认为"弓没了"，也就不会重新起音。
    integer gap = 0, max_gap = 0;
    reg     gap_run = 1'b0;
    always @(posedge clk) begin
        if (gap_run) begin
            if (paw_valid) begin
                if (gap > max_gap) max_gap = gap;
                gap <= 0;
            end else begin
                gap <= gap + 1;
            end
        end
    end

    // 等 ready 拉高，超时则返回 0
    task wait_ready;
        input integer max_cycles;
        output integer ok;
        begin
            ok = 0;
            for (guard = 0; guard < max_cycles; guard = guard + 1) begin
                @(posedge clk);
                if (paw_ready) begin ok = 1; guard = max_cycles; end
            end
        end
    endtask

    initial begin
        // ---- 判据 A：正常初始化 ----
        repeat (5) @(posedge clk);
        reset_n = 1'b1;
        wait_ready(200000, guard);
        if (guard == 0) begin
            $display("FAIL A: 初始化未完成，ready 一直是 0（debug_error=%0d）", debug_error);
            $finish;
        end
        $display("[A] 初始化完成 ready=1  @%0t", $time);

        // 从这里开始统计采样间隔（初始化阶段有几百 ms 的间隔，不算）
        gap = 0; max_gap = 0; gap_run = 1'b1;

        // ---- 判据 B：注入 1 次错，ready 应保持 ----
        inject_left = 1;
        repeat (60) @(posedge clk);      // 覆盖至少一个自检周期(20拍)+SPI
        if (!paw_ready) begin
            $display("FAIL B: 单次 SPI 错误就把 ready 拉低了（应容错）");
            errs = errs + 1;
        end else begin
            $display("[B] 注入 1 次错，ready 仍为 1（单次容错生效）");
        end

        // ---- 判据 C：连续注入到第 3 次，进运行期软恢复 ----
        // 注意：判据 B 之后等了 60 拍，期间有正常检查会把 fail_streak 清零，
        // 所以这里必须**连续注入 3 次**才能触发判错。
        //
        // R49 契约变更：运行期判错后**不再** ready=0 / init_error=1 / 整机重来。
        //   前端是 .ready(paw_ready && !paw_error)，两个信号任意一个掉一拍，
        //   bow_motion_tracker 就 gate<=0，恢复后整音重新起音 —— 那就是"混响感"。
        //   新契约：ready 与 init_error 全程保持"正常"，只等 2 ms 重读两个 ID。
        inject_left = 3;
        retry_seen  = 0;
        for (guard = 0; guard < 400000; guard = guard + 1) begin
            @(posedge clk);
            if (debug_error == 4'd4) begin
                retry_seen = 1;
                guard = 400000;
            end
        end
        if (!retry_seen) begin
            $display("FAIL C: 连续 3 次错误后没有进入软恢复（debug_error 未到 4）");
            errs = errs + 1;
        end else begin
            $display("[C] 连续 3 次错 -> 进软恢复 debug_error=4");
        end

        // ---- 判据 C2：软恢复期间 ready / init_error 必须保持"正常" ----
        // 这是 R49 的核心。这里在软恢复窗口内连采 2000 拍，两个信号都不许掉。
        begin : c2
            integer k;
            integer bad;
            bad = 0;
            for (k = 0; k < 2000; k = k + 1) begin
                @(posedge clk);
                if (!paw_ready || paw_err) bad = bad + 1;
            end
            if (bad != 0) begin
                $display("FAIL C2: 软恢复期间 ready/init_error 掉了 %0d 拍（下游会重新起音）", bad);
                errs = errs + 1;
            end else begin
                $display("[C2] 软恢复期间 ready=1 / init_error=0，下游无感");
            end
        end

        // ---- 判据 D：恢复后必须能继续出采样 ----
        retry_seen = 0;
        for (guard = 0; guard < 400000; guard = guard + 1) begin
            @(posedge clk);
            if (paw_valid) begin
                retry_seen = 1;
                guard = 400000;
            end
        end
        if (!retry_seen) begin
            $display("FAIL D: 软恢复之后再也出不了 sample_valid");
            errs = errs + 1;
        end else begin
            $display("[D] 软恢复后 sample_valid 恢复");
        end

        // ---- 判据 E：整段测试里 sample_valid 的最大间隔必须 < 8 ms 看门狗 ----
        // bow_motion_tracker 的 WATCHDOG_MS=8，超时就把 gate 拉 0、speed 清零。
        // 只要间隔 < 8 ms（50 MHz 下 400000 拍），下游永远不会看到"弓没了"。
        $display("[E] sample_valid 最大间隔 = %0d 拍 (%.2f ms)，看门狗 400000 拍 (8.00 ms)",
                 max_gap, max_gap * 0.00002);
        if (max_gap >= 400000) begin
            $display("FAIL E: 间隔 >= 8 ms，bow_motion_tracker 会关弓并重新起音");
            errs = errs + 1;
        end

        if (errs == 0) $display("PASS paw recovery: 单次容错 + 连续3次软恢复 + 全程不惊动发声");
        else           $display("FAIL %0d 项", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT state=%0d ready=%0d err=%0d", dut.state, paw_ready, debug_error);
        $finish;
    end
endmodule
