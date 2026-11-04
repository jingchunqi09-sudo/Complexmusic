`timescale 1ns/1ps
module revision6_reverb_tb #(parameter integer SAMPLE_RATE_MILLIHZ=48828125);
    reg clk=0,reset=1,clear=0,tick=0,bypass=0;
    reg signed [15:0] sample=0;
    reg [7:0] wet=255,damping=96;
    reg [1:0] tail=3;
    wire signed [15:0] output_sample;
    wire valid,ready;
    wire [31:0] guards;
    integer frames=0,max_latency=0,latency=0,init_cycles=0,n,impulse_file;
    integer first_wet=-1,after_bypass_nonzero=0,late_nonzero=0,positive_clips=0,negative_clips=0;
    reg signed [15:0] result;
    reg [31:0] saved_guards;
    reg [63:0] early_energy=0,late_energy=0;
    reg signed [31:0] square;
    reg [1023:0] impulse_path;
    integer plusarg_found;
    always #5 clk=~clk;
    small_room_reverb #(.SAMPLE_RATE_MILLIHZ(SAMPLE_RATE_MILLIHZ)) dut(.i_clk(clk),.i_reset(reset),.i_clear(clear),.i_sample_tick(tick),
        .i_sample(sample),.i_bypass(bypass),.i_wet(wet),.i_damping(damping),.i_tail(tail),
        .o_sample(output_sample),.o_sample_valid(valid),.o_ready(ready),.o_guard_count(guards));
    task wait_ready;
        begin
            init_cycles=0;
            while(!ready)
            begin
                @(negedge clk);init_cycles=init_cycles+1;
                if(init_cycles>3000) $fatal(1,"delay RAM initialization did not finish");
                if(valid) $fatal(1,"PCM published during initialization");
            end
        end
    endtask
    task send;
        input signed [15:0] value;
        begin
            if(!ready) $fatal(1,"reverb is not ready for the next frame");
            @(negedge clk);sample=value;tick=1;
            @(negedge clk);tick=0;latency=1;
            while(!valid)
            begin
                @(negedge clk);latency=latency+1;
                if(latency>100) $fatal(1,"sample processing exceeds 100 system clocks");
                if(!ready) $fatal(1,"initialized ready flickers during computation (would mute the board amplifier)");
            end
            if((^output_sample)===1'bx) $fatal(1,"unknown sample after ready");
            if(!ready) $fatal(1,"ready did not return with the completed sample");
            result=output_sample;
            if(latency>max_latency) max_latency=latency;
            // No duplicate valid pulses and fixed sample period >= WCET.
            repeat(64-latency)
            begin @(negedge clk);if(valid) $fatal(1,"duplicate output valid");end
            frames=frames+1;
        end
    endtask
    task emergency_clear;
        begin
            @(negedge clk);clear=1;@(negedge clk);
            if(ready || valid || output_sample!==0) $fatal(1,"emergency clear did not mute/cancel PCM");
            clear=0;wait_ready;
        end
    endtask
    initial
    begin
        repeat(3) @(negedge clk);reset=0;wait_ready;
        if(init_cycles!=dut.C3) $fatal(1,"initialization did not clear one common address each clock");
        // Bypass is bit accurate for the entire signed range. Internal delay
        // state continues evolving; this is not a memory-clear bypass.
        bypass=1;
        for(n=0;n<512;n=n+1)
        begin
            case(n%5)
                0: sample=32767;1:sample=-32768;2:sample=1;3:sample=-1;default:sample=n;
            endcase
            send(sample);
            if(result!==sample) $fatal(1,"bypass changed the dry frame");
        end
        emergency_clear;bypass=0;
        for(n=0;n<300;n=n+1) send(0);
        if(dut.r_wet_smooth!=255) $fatal(1,"wet control failed to reach its target");
        impulse_path="sim/results/revision6_reverb_impulse.txt";
        plusarg_found=$value$plusargs("impulse_path=%s",impulse_path);
        impulse_file=$fopen(impulse_path,"w");
        if(!impulse_file) $fatal(1,"cannot open impulse export");
        for(n=0;n<120000;n=n+1)
        begin
            bypass=n>=3000 && n<4000;
            send(n==0 ? 16'sd12000 : 16'sd0);
            $fwrite(impulse_file,"%0d\n",result);
            if(n==0 && result!==12000) $fatal(1,"dry onset waited for a wet delay line");
            if(n>0 && n<dut.C0 && result!==0) $fatal(1,"wet response precedes its physical digital delay");
            if(n>0 && result!=0 && first_wet<0) first_wet=n;
            // R06 soft bypass: finish at most 255 steps plus the existing
            // one-frame wet snapshot; settled bypass must remain exact dry.
            if(bypass && n>=3256 && result!==0) $fatal(1,"settled bypass leaked the wet tail");
            if(n>=4000 && n<7000 && result!=0) after_bypass_nonzero=after_bypass_nonzero+1;
            square=$signed(result)*$signed(result);
            if(n>=2000 && n<10000) early_energy=early_energy+square;
            if(n>=100000) begin late_energy=late_energy+square;if(result!=0) late_nonzero=late_nonzero+1;end
        end
        $fclose(impulse_file);
        if(first_wet!=dut.C0) $fatal(1,"comb/AP frame attribution is shifted: first=%0d expected=%0d",first_wet,dut.C0);
        if(after_bypass_nonzero==0) $fatal(1,"bypass destroyed or froze the tail state");
        if(early_energy==0 || late_energy!=0 || late_nonzero!=0) $fatal(1,"no-input tail failed to decay to exact silence");
        if(guards!=0) $fatal(1,"normal impulse hit numeric guards");
        if({dut.r_lp0,dut.r_lp1,dut.r_lp2,dut.r_lp3}!==0) $fatal(1,"LP fixed-point state retained a limit cycle");
        $display("IMPULSE first_wet=%0d after_bypass_nonzero=%0d early_energy=%0d late_energy=%0d guards=%0d",
            first_wet,after_bypass_nonzero,early_energy,late_energy,guards);
        // All four coefficient/damping settings must remain causal and quiet
        // before the first comb tap, including damping extremes.
        for(n=0;n<4;n=n+1)
        begin
            tail=n;damping=n[0] ? 255 : 0;wet=n[1] ? 255 : 0;emergency_clear;
            send(-12000);if(result!==-12000) $fatal(1,"negative dry onset changed");
            repeat(128) begin send(0);if(result!==0) $fatal(1,"short-tail test generated output before first tap");end
        end
        // Sustained full-scale positive/negative input exercises output
        // headroom guards. Saturation must be counted, never wrap polarity.
        emergency_clear;tail=3;damping=0;wet=255;
        for(n=0;n<10000;n=n+1)
        begin send(32767);if(result<0) $fatal(1,"positive full-scale mix wrapped negative");if(result==32767) positive_clips=positive_clips+1;end
        if(guards==0) $fatal(1,"full-scale wet+dry clipping was not counted");
        saved_guards=guards;emergency_clear;
        if(guards!=saved_guards) $fatal(1,"emergency clear erased guard diagnostics");
        for(n=0;n<10000;n=n+1)
        begin send(-32768);if(result>0) $fatal(1,"negative full-scale mix wrapped positive");if(result==-32768) negative_clips=negative_clips+1;end
        if(guards<=saved_guards) $fatal(1,"negative full-scale clipping was not counted");
        // Clear an in-flight wet sample; no old valid may escape the reset.
        @(negedge clk);sample=12000;tick=1;
        @(negedge clk);tick=0;repeat(5) @(negedge clk);emergency_clear;
        for(n=0;n<2000;n=n+1) begin send(0);if(result!==0) $fatal(1,"clear retained delay history");end
        // Zero wet must preserve the dry stream without using bypass.
        wet=0;bypass=0;emergency_clear;
        for(n=0;n<512;n=n+1)
        begin send(n[0] ? -16000 : 16000);if(result!==(n[0] ? -16'sd16000 : 16'sd16000)) $fatal(1,"wet=0 changed dry output");end
        // A rejected busy tick is counted, cannot replace the accepted frame,
        // and cannot later emerge as an unlabelled extra sample.
        saved_guards=guards;
        @(negedge clk);sample=123;tick=1;
        @(negedge clk);tick=0;repeat(3) @(negedge clk);sample=999;tick=1;
        @(negedge clk);tick=0;
        while(!valid) @(negedge clk);
        if(output_sample!==123 || guards!=saved_guards+1) $fatal(1,"busy tick altered or lost the accepted sample");
        repeat(64) begin @(negedge clk);if(valid) $fatal(1,"rejected tick generated extra PCM");end
        $display("PASS revision6_reverb_tb: Fs_mHz=%0d frames=%0d max_latency=%0d init=%0d first_wet=%0d clips=%0d/%0d guards=%0d",
            SAMPLE_RATE_MILLIHZ,frames,max_latency,dut.C3,first_wet,positive_clips,negative_clips,guards);
        $finish;
    end
endmodule
