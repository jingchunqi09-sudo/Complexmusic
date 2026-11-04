`timescale 1ns/1ps
// Long natural release audit, 30 s at 48k, one physical model and no envelope cutoff.
module revision5_ukulele_decay_tb;
    reg clk=0,reset=1,tick=0,trigger=0;
    reg [6:0] note=69;
    wire signed [15:0] pcm;
    wire ready;
    integer k,n,a,peak,tail_peak,fd,ft;
    reg signed [63:0] sum;
    reg [63:0] squares;
    reg [511:0] path;
    always #10 clk=~clk;
    ukulele_waveguide_voice #(.DELAY_LINE_LENGTH(1024),.SAMPLE_RATE_MILLIHZ(48000000)) dut (
        .i_clk(clk),.i_reset(reset),.i_sample_tick(tick),.i_trigger(trigger),.i_gate(1'b0),
        .i_midi_note(note),.i_velocity(8'd255),.o_audio_sample(pcm),.o_ready(ready));
    task sample;
        begin
            repeat(12) @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(2) @(negedge clk);
            if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"invalid PCM");
            if(dut.MODAL_BODY.u_body.o_guard_count!=0 || dut.MODAL_BODY.u_body.o_clip_count!=0)
                $fatal(1,"natural tail guarded/clipped");
        end
    endtask
    initial begin
        fd=$fopen("sim/results/revision5_ukulele/natural_decay_blocks.csv","w");
        if(!fd)$fatal(1,"cannot write decay evidence");
        $fwrite(fd,"midi,end_sample,count,sum,squares,peak\n");
        for(k=0;k<3;k=k+1)begin
            reset=1;repeat(3) @(negedge clk);reset=0;repeat(1050) @(negedge clk);
            if(!ready)$fatal(1,"not ready");
            note=k==0?60:k==1?69:84;repeat(12) @(negedge clk);trigger=1;sample;trigger=0;
            $sformat(path,"sim/results/revision5_ukulele/natural_tail%0d.txt",note);ft=$fopen(path,"w");
            if(!ft)$fatal(1,"cannot write natural tail");
            sum=0;squares=0;peak=0;tail_peak=0;
            for(n=0;n<1440000;n=n+1)begin
                sample;a=$signed(pcm);sum=sum+a;squares=squares+a*a;
                if(a<0)a=-a;if(a>peak)peak=a;
                if(n>=1431808)begin $fwrite(ft,"%0d\n",$signed(pcm));if(a>tail_peak)tail_peak=a;end
                if(n%3840==3839)begin
                    $fwrite(fd,"%0d,%0d,3840,%0d,%0d,%0d\n",note,n+1,sum,squares,peak);
                    sum=0;squares=0;peak=0;
                end
            end
            $fclose(ft);
            $display("NATURAL_TAIL midi=%0d peak_last8192=%0d",note,tail_peak);
        end
        $fclose(fd);
        $display("PASS revision5_ukulele_decay_tb: 3 notes x 30s, no STOP or envelope truncation, known PCM, no rails/guards/clips");
        $finish;
    end
endmodule
