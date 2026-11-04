`timescale 1ns/1ps
// Direct controller contract tests. ADC/PAW serial protocol tests are separate;
// this bench drives coherent sensor samples, with no force of DUT internals.
module tb_performer_controls;
    reg clk=0;
    always #10 clk=!clk;
    reg reset=1;
    reg b_valid=0,b_ready=0;
    reg [7:0] b_motion=0;
    reg signed [15:0] dx=0,dy=0;
    wire b_gate,b_direction,b_lifted,b_bounce;
    wire [7:0] b_speed;
    wire signed [23:0] b_position;
    bow_motion_tracker u_bow(.clk(clk),.reset(reset),.sample_valid(b_valid),
        .ready(b_ready),.motion(b_motion),.dx(dx),.dy(dy),.gate(b_gate),
        .direction(b_direction),.lifted(b_lifted),.speed(b_speed),
        .bounce(b_bounce),.position(b_position));
    reg [19:0] fret=0;
    reg [3:0] left_valid=0;
    wire [55:0] notes;
    wire [3:0] bowed;
    performer_pitch_map u_pitch(.clk(clk),.reset(reset),.fret_bus(fret),
        // R25：定弦端口。不接会是高阻 z，导致 open_eff 变 x、note 全未知，
        // 所以显式给 R24 的默认定弦（与 link_regs.v 上电值一致）。
        .open_notes({7'd69, 7'd64, 7'd60, 7'd67, 7'd76, 7'd69, 7'd62, 7'd55}),
        .valid_mask(left_valid),.note_bus(notes),.bowed_strings(bowed));
    reg p_valid=0,p_healthy=0;
    reg [1:0] p_channel=0;
    reg [11:0] p_value=0;
    wire [3:0] p_trigger;
    wire [31:0] p_velocity;
    piezo_onset_bank u_piezo(.clk(clk),.reset(reset),.sample_valid(p_valid),
        .healthy(p_healthy),.channel(p_channel),.value(p_value),
        .trigger(p_trigger),.velocity(p_velocity));
    integer checks=0;
    integer triggers[0:3];
    integer lane,frame,f,n,old_count;
    integer v_open[0:3];
    integer u_open[0:3];
    reg [6:0] hold_note;
    always @(negedge clk) begin
        for(n=0;n<4;n=n+1) if(p_trigger[n]) triggers[n]=triggers[n]+1;
    end
    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1'b1)begin
                $display("FAIL performer controls at %0t: %0s",$time,message);
                $finish;
            end
        end
    endtask
    task bow_sample;
        input [7:0] motion;
        input signed [15:0] x,y;
        begin
            @(negedge clk);b_valid=1;b_motion=motion;dx=x;dy=y;
            @(posedge clk);#1;
            @(negedge clk);b_valid=0;
        end
    endtask
    task finger;
        input integer index,value;
        begin
            @(negedge clk);fret[index*5 +:5]=value;
            @(posedge clk);#1;
        end
    endtask
    task wait_ms;
        input integer milliseconds;
        begin repeat(milliseconds*50000)@(posedge clk);#1;end
    endtask
    task piezo_sample;
        input integer index,value;
        begin
            @(negedge clk);p_valid=1;p_channel=index;p_value=value;
            @(posedge clk);#1;
            @(negedge clk);p_valid=0;
            @(posedge clk);#1;
        end
    endtask
    function integer dc_of;
        input integer lane;
        begin
            case(lane)
                0: dc_of=2051;
                1: dc_of=2050;
                2: dc_of=2050;
                default: dc_of=1882;
            endcase
        end
    endfunction
    initial begin
        for(lane=0;lane<4;lane=lane+1)triggers[lane]=0;
        v_open[0]=55;v_open[1]=62;v_open[2]=69;v_open[3]=76;
        u_open[0]=67;u_open[1]=60;u_open[2]=64;u_open[3]=69;
        repeat(4)@(posedge clk);@(negedge clk);reset=0;
        @(posedge clk);#1;
        check(!b_gate && b_lifted,"reset keeps bow silent");
        b_ready=1;
        // Motion validity is latched in the SAME snapshot as delta; there is
        // deliberately no separate transient motion_valid wire in this bench.
        // ---- R10 弓速契约（依据 mouse_typec 报告 §2.2 / §4.2）----
        // 实测 PAW3395 静止时有 ±1 count 确定性偏置；旧契约把 1 count 当 attack，
        // 静止鼠标会持续开弓（"不碰也响"）。新算法 DZ=1 后必须完全静默。
        for(frame=0;frame<20;frame=frame+1) bow_sample(8'h80,16'sd1,16'sd1);
        check(!b_gate && b_speed==0,"R10 deadband: +/-1 count bias never opens the gate");
        // 慢弓门限：CPI=3200 下 8 count/样本 -> 9 样本窗口 SUM=72 >= 40 即开弓。
        for(frame=0;frame<9;frame=frame+1) bow_sample(8'h80,16'sd0,16'sd8);
        check(b_gate && !b_direction && !b_lifted && b_speed>=40,"R10 slow bow opens at measured threshold");
        // 反向：符号翻转后方向位跟随主轴 dy。
        for(frame=0;frame<12;frame=frame+1) bow_sample(8'h80,16'sd0,-16'sd8);
        check(b_gate && b_direction,"R10 reverse stroke flips direction");
        // 释放：9 样本窗口滑空（10 ms）+ 22 样本释放计数（25 ms）≈ 35 ms，
        // 远低于换弓过零实测 <5 ms，所以不会断音。
        for(frame=0;frame<26;frame=frame+1) bow_sample(8'h80,16'sd0,16'sd0);
        check(b_gate,"R10 contact holds through 26 quiet samples");
        for(frame=0;frame<6;frame=frame+1) bow_sample(8'h80,16'sd0,16'sd0);
        check(!b_gate && b_speed==0,"R10 releases after window drain plus 22 samples");
        // 极端幅度：|d| 饱和后速度必须到 255。
        for(frame=0;frame<9;frame=frame+1) bow_sample(8'h80,16'sd0,-16'sd32768);
        check(b_gate && b_direction && b_speed==255,"signed minimum magnitude saturates speed");
        // 跳弓：4 段交替换弓，每段 70 样本（间隔 70 落在 53..220 样本窗口）。
        // 4 count/样本 × 70 = 280 > 换弓迟滞 252，保证每段都能过阈值。
        for(frame=0;frame<70;frame=frame+1) bow_sample(8'h80,16'sd0, 16'sd4);
        for(frame=0;frame<70;frame=frame+1) bow_sample(8'h80,16'sd0,-16'sd4);
        for(frame=0;frame<70;frame=frame+1) bow_sample(8'h80,16'sd0, 16'sd4);
        for(frame=0;frame<70;frame=frame+1) bow_sample(8'h80,16'sd0,-16'sd4);
        check(b_bounce,"R10 four strokes inside 60..250 ms triggers bounce");
        // watchdog：8 ms 无样本必须关弓（400000 clk = 8 ms @50 MHz）。
        for(frame=0;frame<9;frame=frame+1) bow_sample(8'h80,16'sd0,16'sd8);
        repeat(399990)@(posedge clk);#1;
        check(b_gate,"watchdog remains open just before eight ms");
        repeat(20)@(posedge clk);#1;
        check(!b_gate && b_lifted,"eight ms sample watchdog closes gate");
        for(frame=0;frame<9;frame=frame+1) bow_sample(8'h80,16'sd0,16'sd8);
        check(b_gate,"watchdog is recoverable");
        @(negedge clk);b_ready=0;@(posedge clk);#1;check(!b_gate,"not-ready closes gate without waiting");

        // Every physical key is a chromatic uke fret, independent per lane.
        left_valid=4'hf;
        for(lane=0;lane<4;lane=lane+1)begin
            for(f=1;f<=16;f=f+1)begin
                finger(lane,f);
                check(notes[(lane+4)*7 +:7]==u_open[lane]+f,"uke fret is 1..16 semitones");
                for(frame=0;frame<4;frame=frame+1)
                    if(frame!=lane)check(notes[(frame+4)*7 +:7]==u_open[frame],"uke notes do not leak across strings");
            end
            finger(lane,0);
            check(notes[lane*7 +:7]==v_open[lane] && notes[(lane+4)*7 +:7]==u_open[lane],"release selects both open notes");
        end
        finger(0,3);check(notes[6:0]==55,"group 0 hold uses base octave");
        finger(0,8);check(notes[6:0]==67,"group 1 hold selects octave +12");
        finger(0,13);check(notes[6:0]==79,"group 2 hold selects octave +24");
        finger(0,16);check(notes[6:0]==91,"fret16 is +36 high anchor");
        finger(0,5); // first group's fast right from class zero
        wait_ms(39);check(notes[6:0]==55,"fast right does not step before 40 ms");
        wait_ms(1);check(notes[6:0]==56,"fast right steps one semitone at 40 ms");
        finger(0,3);hold_note=notes[6:0];
        wait_ms(80);check(notes[6:0]==hold_note,"hold stops pitch without reset");
        finger(0,4);check(notes[6:0]==56,"same-group gesture change preserves pitch class");
        wait_ms(159);check(notes[6:0]==56,"slow right does not step before 160 ms");
        wait_ms(1);check(notes[6:0]==57,"slow right steps at 160 ms");
        finger(0,2);wait_ms(160);check(notes[6:0]==56,"slow left decrements at 160 ms");
        finger(0,1);wait_ms(40);check(notes[6:0]==55,"fast left decrements at 40 ms");
        wait_ms(80);check(notes[6:0]==55,"pitch class lower clamp never wraps");
        finger(0,5);wait_ms(520);check(notes[6:0]==66,"pitch class upper clamp is eleven");
        finger(0,8);check(notes[6:0]==78,"octave change preserves pitch class");
        finger(0,0);check(bowed==0 && notes[6:0]==55,"no touch removes selected bowed strings");
        finger(2,13);check(bowed==4'b0100 && notes[20:14]==93,"string2 octave selection independent");
        @(negedge clk);left_valid[2]=0;@(posedge clk);#1;
        check(notes[20:14]==69 && !bowed[2],"uncalibrated string cannot play held input");

        p_healthy=1;
        // R10.1 压电契约：R8 瞬态核（三阶差分 fast>3×自适应基线）+ 4 帧收集窗 + guard 60。
        // 必须按真实四通道轮询驱动：piezo_onset_bank 用 channel==3 计帧，只驱动单通道
        // 会让收集窗永不结束（旧测试台的建模缺陷，不是设计行为）。
        for(frame=0;frame<2000;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,2048);
        for(lane=0;lane<4;lane=lane+1)check(triggers[lane]==0,"R10 warmup emits no trigger");
        // 单次拨弦：通道 0 走 2548/1548 交替（±500 三阶差分），其余通道基线
        for(frame=0;frame<8;frame=frame+1)begin
            piezo_sample(3,(frame[0])?1548:2548);   // ADC CH3 = 第四弦(s0)
            piezo_sample(0,2048);piezo_sample(1,2048);piezo_sample(2,2048);
        end
        for(frame=0;frame<40;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,2048);
        check(triggers[0]==1 && p_velocity[7:0]>=12,"R10 single pluck yields exactly one fire");
        // guard 60 样本内再次拨弦必须被拒（8+40 帧 < 60 帧 guard）
        for(frame=0;frame<8;frame=frame+1)begin
            piezo_sample(3,(frame[0])?1548:2548);   // ADC CH3 = 第四弦(s0)
            piezo_sample(0,2048);piezo_sample(1,2048);piezo_sample(2,2048);
        end
        for(frame=0;frame<40;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,2048);
        check(triggers[0]==1,"R10 guard rejects immediate retrigger");
        // 越过 guard（再等 200 帧 ≈32 ms，让自适应基线衰减回噪声底）
        // 后第二次拨弦必须能触发：这是"连续两次快速演奏"
        for(frame=0;frame<200;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,2048);
        for(frame=0;frame<8;frame=frame+1)begin
            piezo_sample(3,(frame[0])?1248:2848);   // ADC CH3 = s0
            piezo_sample(0,2048);piezo_sample(1,2048);piezo_sample(2,2048);
        end
        for(frame=0;frame<40;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,2048);
        check(triggers[0]==2,"R10 re-arms after guard and detects the fast second pluck");
        // 其余三弦用各自独立核，互不影响
        for(lane=1;lane<4;lane=lane+1)begin
            old_count=triggers[lane];
            for(frame=0;frame<8;frame=frame+1)begin
                // 弦 lane 的 ADC 通道 = 3-lane（CH0 贴第一弦 s3）
                piezo_sample(0,(lane==3)?((frame[0])?1548:2548):2048);
                piezo_sample(1,(lane==2)?((frame[0])?1548:2548):2048);
                piezo_sample(2,(lane==1)?((frame[0])?1548:2548):2048);
                piezo_sample(3,(lane==0)?((frame[0])?1548:2548):2048);
            end
            for(frame=0;frame<80;frame=frame+1)
                for(f=0;f<4;f=f+1)piezo_sample(f,2048);
            check(triggers[lane]==old_count+1 && p_velocity[lane*8 +:8]>=12,"R10 each string fires independently");
        end
        @(negedge clk);p_healthy=0;@(posedge clk);#1;
        check(p_trigger==0 && p_velocity==0,"health loss clears all detector state");
        p_healthy=1;
        // Full-scale constant DC after re-warm: high-pass rejects it, no trigger.
        for(frame=0;frame<2000;frame=frame+1)
            for(lane=0;lane<4;lane=lane+1)piezo_sample(lane,4095);
        check(triggers[0]==2 && triggers[1]==1 && triggers[2]==1 && triggers[3]==1,"v3 full-scale DC re-warm cannot false-trigger");
        $display("PASS performer controls: %0d checks; default 50MHz timing, four pitch lanes, bow contact and v3 rise-speed piezo fire events",checks);
        $finish;
    end
    initial begin #2000000000; $display("FAIL performer controls timeout");$finish;end
endmodule
