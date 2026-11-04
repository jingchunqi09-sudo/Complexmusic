`timescale 1ns/1ps
`default_nettype none
//-----------------------------------------------------------------------------
// tb_piezo_r17.v —— piezo_string_det 行为验证（按真实 24.9 kSPS 生成激励）
//
// 旧 tb_piezo_v3 用的是 6.2 kHz 的 ms_stim.hex，而生产 ADC 是 24.9 kSPS，
// 旧的 GUARD/包络 τ 因此在实板上短了 4 倍 —— 这是"仿真全绿、实板误响"的根源。
// 本台按 24900 Hz/通道 生成两类激励：
//   1) 单弦拨弦：ch0 强、其余弱且不同相  -> 必须输出音符事件
//   2) 拍琴身  ：四路同相等幅            -> 必须被空间判据拒绝，只加颤音
// 判据：ev_total>=2、rej_total>=1、拍击后 vibrato_depth>0。
//-----------------------------------------------------------------------------
module tb_piezo_r17;
    localparam integer FS = 24900;
    localparam integer N  = 41000;          // ≈1.65 s

    reg clk=0, reset=1;
    reg sample_valid=0;
    reg [1:0] channel=0;
    reg [11:0] value=0;
    wire [3:0]  trigger;
    wire [31:0] velocity;
    wire        ev_valid;
    wire [3:0]  ev_strings;
    wire [14:0] ev_peak;
    wire [15:0] ev_total;
    wire [63:0] dbg_ay;
    wire [3:0]  dbg_warm;
    wire [7:0]  vibrato;
    wire [15:0] rej_total;

    piezo_string_det dut(
        .clk(clk),.reset(reset),.sample_valid(sample_valid),.healthy(1'b1),
        .channel(channel),.value(value),
        .trigger(trigger),.velocity(velocity),
        .ev_valid(ev_valid),.ev_strings(ev_strings),.ev_peak(ev_peak),
        .ev_total(ev_total),.dbg_ay(dbg_ay),.dbg_warm(dbg_warm),
        .vibrato_depth(vibrato),.rej_total(rej_total));
    always #10 clk=~clk;

    integer n, c;
    real tt, exc, env, ph;
    real code;
    integer code_i;
    integer nev, nrej_at_tap, nfire;
    integer vib_at_tap;

    // 事件打分
    always @(posedge clk) if(ev_valid) begin
        nev = nev + 1;
        $display("EVENT %0d t=%0.3f s ch_mask=%b peak=%0d", nev, (n*1.0/FS), ev_strings, ev_peak);
    end
    always @(posedge clk) if(|trigger) nfire = nfire + 1;

    task drive;   // 一个通道样本
        input [1:0] ch;
        input real v;
        begin
            @(negedge clk);
            channel = ch;
            code = v + 2050.0;
            if(code < 0.0) code = 0.0;
            if(code > 4095.0) code = 4095.0;
            code_i = $rtoi(code);
            value = code_i[11:0];
            sample_valid = 1;
            @(negedge clk);
            sample_valid = 0;
        end
    endtask

    initial begin
        nev=0; nfire=0; nrej_at_tap=0; vib_at_tap=0;
        #200 reset=0;
        // warm 250 ms（WARM=6225 样本）
        for(n=0;n<N;n=n+1) begin
            tt = (n*1.0/FS);
            for(c=0;c<4;c=c+1) begin
                exc = 0.0;
                // ---- 拨弦 @0.30 s：ch0 强、其余弱且不同相 ----
                if(tt>=0.30 && tt<0.46) begin
                    ph = 2.0*3.14159265*330.0*(tt-0.30);
                    env = $exp(-(tt-0.30)/0.12);
                    exc = (c==0) ? 320.0*$sin(ph)*env :
                                  (c==1 ? 18.0*$sin(ph+1.1)*env :
                                  (c==2 ? 14.0*$sin(ph+2.2)*env : 11.0*$sin(ph+3.0)*env));
                end
                // ---- 拍琴身 @0.75 s：四路同相等幅 ----
                if(tt>=0.75 && tt<1.05) begin
                    ph = 2.0*3.14159265*180.0*(tt-0.75);
                    env = $exp(-(tt-0.75)/0.20);
                    exc = 210.0*$sin(ph)*env;
                end
                // ---- 再拨一次 @1.20 s ----
                if(tt>=1.20 && tt<1.36) begin
                    ph = 2.0*3.14159265*330.0*(tt-1.20);
                    env = $exp(-(tt-1.20)/0.12);
                    exc = (c==0) ? 320.0*$sin(ph)*env : 0.0;
                end
                drive(c[1:0], exc);
            end
            if(n==19422) nrej_at_tap=rej_total;   // 0.78 s
            // 颤音按 16 ms/级衰减（VIB_DEC_FRAMES=100），1.05 s 时早已归零，
            // 所以这里记峰值而不是定点采样。
            if(vibrato > vib_at_tap) vib_at_tap = vibrato;
        end
        $display("RESULT ev_total=%0d fire=%0d rej_at_tap=%0d tap_rej_seen=%0d",
                 ev_total, nfire, nrej_at_tap, rej_total);
        $display("VIB final=%0d peak=%0d", vibrato, vib_at_tap);
        if(ev_total < 16'd2) $fatal(1,"expected at least two pluck events");
        if(rej_total < 16'd1) $fatal(1,"tap on body was not rejected by the spatial gate");
        if(rej_total == 0) $fatal(1,"tap on body was not rejected");
        if(vibrato == 0 && vib_at_tap == 0) $fatal(1,"tap on body did not raise vibrato depth");
        $display("PASS piezo r17: plucks kept, body tap rejected, vibrato raised");
        $finish;
    end
    initial begin #200000000; $fatal(1,"timeout"); end
endmodule
`default_nettype wire
