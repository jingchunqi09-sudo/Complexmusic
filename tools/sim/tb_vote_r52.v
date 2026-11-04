`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// tb_vote_r52b —— 这次实板回归的守门测试
//
// 实板现象（R52，2026-11-03）：
//   "弹完以后会乱响好几次，小提琴一拉就会识别四根弦，而且声音特别大"
//
// 根因：R52 加了 `QUIET_WIN=76` 把 pick 在静默 100 ms 后清零。而
//   assign pick_eff = (pick_r != 0) ? pick_r : (enabled_w ? arg_onehot : FALLBACK_MASK);
// 清零后只要 enabled_w=0（静默期、以及起音最初几毫秒包络还没过门限），
// pick_eff 就回退成 FALLBACK_MASK = 1111 -> 四弦齐鸣、声音特别大。
//
// 本测试台守三条（任何一条挂掉就说明又退回去了）：
//   A 锁到弦2 之后静默 200 窗，pick 必须**仍然是弦2**（不许被清零）
//   B 同一时刻 pick_eff 也必须是弦2 one-hot，**绝不能是 1111**
//   C 静默期 pick_eff 在整个 200 窗里一次都不许出现 1111
// ---------------------------------------------------------------------------
module tb_vote_r52b;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg [63:0] ay = 64'd0;
    reg bow_start = 0;
    wire [3:0] pick, pick_eff;
    wire enabled;

    localparam integer DIV_BITS = 6;
    localparam integer WIN_CLK  = 1 << DIV_BITS;

    piezo_string_vote #(
        .SELECT_MIN(16'd32), .DIV_BITS(DIV_BITS), .VOTE_WIN(6),
        .FALLBACK_MASK(4'b1111), .START_VOTE(2)
    ) dut (
        .clk(clk), .reset(reset), .ay(ay), .bow_start(bow_start),
        .pick(pick), .pick_eff(pick_eff), .enabled(enabled)
    );

    integer fails = 0;
    integer k;
    integer fallback_cnt = 0;

    task set_ay(input integer a0, input integer a1,
                input integer a2, input integer a3);
        begin
            ay = {a3[15:0], a2[15:0], a1[15:0], a0[15:0]};
        end
    endtask

    task wait_win(input integer n);
        begin
            for (k = 0; k < n; k = k + 1) repeat (WIN_CLK) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    task pulse_start;
        begin
            @(posedge clk); bow_start = 1;
            @(posedge clk); bow_start = 0;
        end
    endtask

    // 逐拍守三条不变量（评审建议：单弦/不回落/多弦 gate）
    //   pick != 0 时 pick_eff 必须恰好 one-hot（popcount==1），绝不许 1111
    //   复位释放后 pick 一旦非 0，此后不许再变回 0（"pick 常驻"不变量）
    function integer pop4(input [3:0] v);
        begin
            pop4 = v[0] + v[1] + v[2] + v[3];
        end
    endfunction

    integer multi_cnt = 0;
    reg     locked_seen = 1'b0;

    always @(posedge clk) begin
        if (!reset) begin
            if (pick != 4'd0) locked_seen <= 1'b1;
            if ((pick != 4'd0) && (pick_eff === 4'b1111))
                fallback_cnt = fallback_cnt + 1;
            // 一旦锁定过，pick_eff 就不许再出现"多弦同时"（四弦齐鸣/四倍音量来源）。
            // 注意：**复位后、第一次锁定前** pick=0 且 enabled_w=0 时 pick_eff 会等于
            // FALLBACK_MASK(1111)，这是 R51 就有的"保命"设计（压电完全没信号时
            // 至少四弦都能响），不是本版引入的，所以判据从"锁定后"开始算。
            if (locked_seen && (pop4(pick_eff) > 1))
                multi_cnt = multi_cnt + 1;
        end
    end

    task chk(input [8*44-1:0] name, input [3:0] got, input [3:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s got=%b exp=%b", name, got, exp);
                fails = fails + 1;
            end else
                $display("  ok  %0s = %b", name, got);
        end
    endtask

    initial begin
        reset = 1;
        set_ay(0, 0, 0, 0);
        wait_win(2);
        reset = 0;
        wait_win(2);

        // 锁到弦2
        set_ay(20, 20, 300, 20);
        pulse_start;
        wait_win(8);
        chk("lock s2", pick, 4'b0100);

        // ---- A / B / C：静默 200 窗（≈262 ms，远超原来 100 ms 的清零门槛）----
        set_ay(0, 0, 0, 0);
        wait_win(100);
        chk("A pick held at 100 win", pick, 4'b0100);
        chk("B pick_eff at 100 win", pick_eff, 4'b0100);
        wait_win(100);
        chk("A pick held at 200 win", pick, 4'b0100);
        chk("B pick_eff at 200 win", pick_eff, 4'b0100);

        if (fallback_cnt != 0) begin
            $display("FAIL C: 静默期出现 %0d 拍 pick_eff=1111（四弦齐鸣）", fallback_cnt);
            fails = fails + 1;
        end else
            $display("  ok  C no fallback-to-4-strings during silence");

        if (multi_cnt != 0) begin
            $display("FAIL D: 有 %0d 拍 pick_eff 是多弦（四倍音量来源）", multi_cnt);
            fails = fails + 1;
        end else
            $display("  ok  D pick_eff never multi-string");

        // 再起音，pick 必须能跟随到弦3（不能因为长期静默锁死）
        set_ay(20, 20, 20, 400);
        pulse_start;
        wait_win(9);
        chk("re-attack follow s3", pick, 4'b1000);
        chk("re-attack pick_eff s3", pick_eff, 4'b1000);

        if (!locked_seen) begin
            $display("FAIL: 全程没有锁定过，判据形同虚设");
            fails = fails + 1;
        end
        if (fails == 0)
            $display("PASS vote r52b: pick 常驻 / 不回落四弦 / 无多弦 / 再起音能跟随");
        else
            $display("FAIL vote r52b fails=%0d", fails);
        $finish;
    end
endmodule
