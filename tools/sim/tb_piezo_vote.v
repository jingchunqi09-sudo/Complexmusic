`timescale 1ns/1ps
// 压电选弦投票的单元验证。DIV_BITS 缩到 6（真实 16）以缩短仿真，
// 逻辑与时间常数无关：VOTE_WIN 条"窗"数不变。
//
// 场景全部来自用户反馈"拉到几个不同的弦"与实测串扰比：
//   一弦主/次 1.33、四弦 1.56、二弦 4.8、三弦 20.0
module tb_piezo_vote;
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
        // R53：thr/freeze 端口已随 R52 的控制面一起删除
        .pick(pick), .pick_eff(pick_eff), .enabled(enabled)
    );

    task set_ay(input integer a0, input integer a1,
                input integer a2, input integer a3);
        begin
            ay = {a3[15:0], a2[15:0], a1[15:0], a0[15:0]};
        end
    endtask

    task wait_win(input integer n);
        integer i;
        begin
            for (i = 0; i < n * WIN_CLK + WIN_CLK; i = i + 1) @(posedge clk);
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk); bow_start = 1'b1;
            @(negedge clk); bow_start = 1'b0;
        end
    endtask

    integer fails = 0;
    task chk(input [8*48-1:0] name, input [3:0] got, input [3:0] exp);
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

        // 1. 静默：没有压电信号 -> 回退四弦（保命，不许静音）
        chk("silence pick_eff", pick_eff, 4'b1111);

        // 2. 单弦稳定（弦2=300，其余 20）：起音沿立即锁定
        set_ay(20, 20, 300, 20);
        pulse_start;
        wait_win(1);
        chk("single start pick", pick, 4'b0100);
        wait_win(6);
        chk("single hold pick", pick, 4'b0100);

        // 3. 邻弦串扰 75%（弦1=225 = 弦2 的 75%，一弦最坏情况）
        set_ay(20, 225, 300, 20);
        wait_win(10);
        chk("crosstalk75 pick", pick, 4'b0100);

        // 4. 三根同时过线（R23 的 mask 会全放进来；投票必须仍只有一根）
        set_ay(280, 225, 300, 210);
        wait_win(10);
        chk("three-hot pick", pick, 4'b0100);

        // 5. argmax 两窗一抖（弦2 与弦0 交替 300/290）：票数上不去，
        //    pick 必须保持上一根，不能跟着跳
        set_ay(300, 20, 290, 20);  wait_win(3);
        set_ay(290, 20, 300, 20);  wait_win(3);
        set_ay(300, 20, 290, 20);  wait_win(3);
        set_ay(290, 20, 300, 20);  wait_win(3);
        chk("jitter hold pick", pick, 4'b0100);

        // 6. 真实换弦（弦0 明确最强）：VOTE_WIN 窗后必须跟随
        set_ay(400, 20, 100, 20);
        wait_win(9);
        chk("switch to s0", pick, 4'b0001);

        // 7. 单窗尖峰（弦3 一窗 500 然后回落）：不许锁弦3
        set_ay(400, 20, 100, 500);
        wait_win(1);
        set_ay(400, 20, 100, 20);
        wait_win(9);
        chk("spike reject", pick, 4'b0001);

        // 8. 静默后仍保持上一次（不是清零）
        set_ay(0, 0, 0, 0);
        wait_win(10);
        chk("quiet hold pick", pick, 4'b0001);

        // 9. 弦3 稳定最强 -> 跟随
        set_ay(20, 20, 20, 400);
        wait_win(9);
        chk("switch to s3", pick, 4'b1000);

        if (fails == 0)
            $display("PASS piezo_string_vote all scenarios");
        else
            $display("FAIL piezo_string_vote fails=%0d", fails);
        $finish;
    end
endmodule
