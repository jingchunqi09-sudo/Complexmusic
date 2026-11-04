// Independent display tap. Audio never waits for this module.
// 1024 actual PCM samples = 20.97152 ms at Fs=48828.125 Hz; 512 min/max bins.
// The completed RAM bank and bundled metadata remain held until a frame accepts
// them. A new request then writes only the other bank. No per-bit bus CDC.
module r9_audio_monitor(
    input wire i_sys_clk,input wire i_sys_reset,
    input wire i_pcm_valid,input wire signed [15:0] i_pcm,
    input wire [1:0] i_mode,input wire [27:0] i_notes,input wire [3:0] i_gates,
    input wire [31:0] i_velocities,input wire [19:0] i_fret_bus,
    input wire [3:0] i_left_valid,input wire [3:0] i_left_fault,
    input wire signed [15:0] i_bow_x,input wire signed [15:0] i_bow_y,
    input wire [7:0] i_bow_speed,input wire [3:0] i_bow_gates,
    input wire [15:0] i_ev_total,input wire [3:0] i_fire,
    input wire [3:0] i_piezo_warm,input wire i_audio_ready,input wire [31:0] i_latency_us,
    // R33：曲谱指引目标（弦号 + 品位 + 有效）。三个信号变化率是"音符级"（~10 Hz），
    // 用两级触发器同步到像素域即可；不做握手，最坏只会在换音那一帧出现一次错位。
    input wire [2:0] i_guide_lane,input wire [4:0] i_guide_fret,input wire i_guide_valid,
    // R54：当前显示的是哪件乐器（view_instrument，拨弦=4'hf / 弓=4'h0）。
    // 只给"尤克里里弦指引"判断命中用：i_gates 是按 view 选过的，
    // 不带上这一位的话，uke 事件来了但人还在拉小提琴，uke 行会被误判成"已弹对"。
    input wire [3:0] i_instruments,
    input wire i_pix_clk,input wire i_pix_reset,input wire i_frame_start,
    input wire [8:0] i_wave_address,
    output reg signed [15:0] o_wave_min,output reg signed [15:0] o_wave_max,
    output reg [1:0] o_mode,output reg [27:0] o_notes,output reg [3:0] o_gates,
    output reg [31:0] o_velocities,output reg [19:0] o_fret_bus,
    output reg [3:0] o_left_valid,output reg [3:0] o_left_fault,
    output reg signed [15:0] o_bow_x,output reg signed [15:0] o_bow_y,
    output reg [7:0] o_bow_speed,output reg [3:0] o_bow_gates,
    output reg [15:0] o_ev_total,output reg [3:0] o_fire_flash,
    output reg [3:0] o_piezo_warm,output reg o_audio_ready,
    output reg [31:0] o_latency_us,
    output reg [15:0] o_peak,output reg [15:0] o_rms,output reg [15:0] o_crest_tenths,
    output reg [1:0] o_gain_shift,output reg [63:0] o_bands,
    output reg o_capture_valid,output wire o_spectrum_fault,
    output reg [2:0] o_guide_lane,output reg [4:0] o_guide_fret,output reg o_guide_valid,
    output reg [3:0] o_instruments
);
    reg [31:0] samples[0:1023] /* synthesis syn_ramstyle="block_ram" */;
    wire [63:0] bands_sys;
    r9_octave_analyzer u_octave(.clk(i_sys_clk),.reset(i_sys_reset),
        .sample_valid(i_pcm_valid),.sample(i_pcm),.bands(bands_sys),.overrun(o_spectrum_fault));
    reg request,ack,seen;
    reg [1:0] request_sync,ack_sync;
    reg capture_busy,completed_bank,display_bank;
    reg [9:0] index;
    reg signed [15:0] even_sample;
    reg [40:0] square_sum;
    reg [15:0] peak,hold_peak,hold_rms,hold_crest;
    reg [1:0] hold_gain;
    reg [63:0] hold_bands;
    reg [194:0] hold_payload;
    reg [11:0] fire_count[0:3];
    reg [3:0] fire_flash;
    wire [15:0] magnitude=i_pcm[15] ? -i_pcm : i_pcm;
    wire [31:0] square=$signed(i_pcm)*$signed(i_pcm);
    wire [15:0] new_peak=magnitude>peak ? magnitude : peak;
    wire signed [15:0] bin_min=i_pcm<even_sample ? i_pcm : even_sample;
    wire signed [15:0] bin_max=i_pcm>even_sample ? i_pcm : even_sample;
    reg [31:0] sqrt_value;
    reg [33:0] sqrt_remainder;
    reg [15:0] sqrt_root;
    reg [4:0] sqrt_count;
    wire [33:0] sqrt_shift={sqrt_remainder[31:0],sqrt_value[31:30]};
    wire [33:0] sqrt_trial={16'd0,sqrt_root,2'b01};
    wire sqrt_take=sqrt_shift>=sqrt_trial;
    wire [15:0] rms_result={sqrt_root[14:0],sqrt_take};
    reg [19:0] divide_numerator,divide_quotient;
    reg [20:0] divide_remainder;
    reg [15:0] divide_denominator;
    reg [4:0] divide_count;
    wire [20:0] divide_shift={divide_remainder[19:0],divide_numerator[19]};
    wire divide_take=divide_shift>={5'd0,divide_denominator};
    wire [19:0] divide_result={divide_quotient[18:0],divide_take};
    integer k;
    always @(posedge i_sys_clk) begin
        if(!i_sys_reset && capture_busy && i_pcm_valid && index[0])
            samples[{~completed_bank,index[9:1]}]<={bin_max,bin_min};
    end
    always @(posedge i_pix_clk)
        {o_wave_max,o_wave_min}<=samples[{display_bank,i_wave_address}];
    always @(posedge i_sys_clk) begin
        if(i_sys_reset) begin
            request_sync<=0;ack<=0;seen<=0;capture_busy<=0;completed_bank<=0;index<=0;
            square_sum<=0;peak<=0;even_sample<=0;hold_peak<=0;hold_rms<=0;hold_crest<=0;
            hold_gain<=0;hold_bands<=0;hold_payload<=0;
            sqrt_value<=0;sqrt_remainder<=0;sqrt_root<=0;sqrt_count<=0;
            divide_count<=0;divide_numerator<=0;divide_denominator<=0;
            divide_quotient<=0;divide_remainder<=0;fire_flash<=0;
            for(k=0;k<4;k=k+1) fire_count[k]<=0;
        end else begin
            request_sync<={request_sync[0],request};
            for(k=0;k<4;k=k+1) begin
                if(i_fire[k]) begin fire_count[k]<=12'd3000;fire_flash[k]<=1;end
                else if(i_pcm_valid && fire_count[k]!=0) begin
                    fire_count[k]<=fire_count[k]-1'b1;
                    if(fire_count[k]==1) fire_flash[k]<=0;
                end
            end
            if(!capture_busy && sqrt_count==0 && divide_count==0 && request_sync[1]!=seen) begin
                seen<=request_sync[1];capture_busy<=1;index<=0;square_sum<=0;peak<=0;
                hold_payload<={i_mode,i_notes,i_gates,i_velocities,i_fret_bus,i_left_valid,i_left_fault,
                    i_bow_x,i_bow_y,i_bow_speed,i_bow_gates,i_ev_total,i_piezo_warm,fire_flash,i_audio_ready,i_latency_us};
            end else if(capture_busy && i_pcm_valid) begin
                even_sample<=i_pcm;index<=index+1'b1;
                peak<=new_peak;square_sum<=square_sum+square;
                if(index==1023) begin
                    capture_busy<=0;completed_bank<=~completed_bank;
                    hold_peak<=new_peak;hold_bands<=bands_sys;
                    hold_gain<=new_peak<=16'd7045 ? 2'd2 : new_peak<=16'd14090 ? 2'd1 : 2'd0;
                    sqrt_value<=(square_sum+square)>>10;
                    sqrt_root<=0;sqrt_remainder<=0;sqrt_count<=16;
                end
            end
            if(sqrt_count!=0) begin
                sqrt_value<={sqrt_value[29:0],2'b00};
                sqrt_remainder<=sqrt_take ? sqrt_shift-sqrt_trial : sqrt_shift;
                sqrt_root<={sqrt_root[14:0],sqrt_take};sqrt_count<=sqrt_count-1'b1;
                if(sqrt_count==1) begin
                    hold_rms<=rms_result;
                    if(rms_result==0) begin hold_crest<=0;ack<=seen;end
                    else begin
                        divide_numerator<=({4'd0,hold_peak}<<3)+({4'd0,hold_peak}<<1);
                        divide_denominator<=rms_result;divide_remainder<=0;divide_quotient<=0;divide_count<=20;
                    end
                end
            end
            if(divide_count!=0) begin
                divide_numerator<={divide_numerator[18:0],1'b0};
                divide_remainder<=divide_take ? divide_shift-{5'd0,divide_denominator} : divide_shift;
                divide_quotient<=divide_result;divide_count<=divide_count-1'b1;
                if(divide_count==1) begin hold_crest<=divide_result>999 ? 16'd999 : divide_result[15:0];ack<=seen;end
            end
        end
    end
    always @(posedge i_pix_clk) begin
        if(i_pix_reset) begin
            request<=0;ack_sync<=0;display_bank<=0;o_capture_valid<=0;
            {o_mode,o_notes,o_gates,o_velocities,o_fret_bus,o_left_valid,o_left_fault,
             o_bow_x,o_bow_y,o_bow_speed,o_bow_gates,o_ev_total,o_piezo_warm,o_fire_flash,o_audio_ready,o_latency_us}<=0;
            o_peak<=0;o_rms<=0;o_crest_tenths<=0;o_gain_shift<=0;o_bands<=0;
        end else begin
            ack_sync<={ack_sync[0],ack};
            if(i_frame_start && ack_sync[1]==request) begin
                if(request || o_capture_valid) begin
                    display_bank<=completed_bank;o_capture_valid<=1;
                    {o_mode,o_notes,o_gates,o_velocities,o_fret_bus,o_left_valid,o_left_fault,
                     o_bow_x,o_bow_y,o_bow_speed,o_bow_gates,o_ev_total,o_piezo_warm,o_fire_flash,o_audio_ready,o_latency_us}<=hold_payload;
                    o_peak<=hold_peak;o_rms<=hold_rms;o_crest_tenths<=hold_crest;
                    o_gain_shift<=hold_gain;o_bands<=hold_bands;
                end
                request<=~request;
            end
        end
    end

    // ---------------- R33：曲谱指引目标跨域（独立两级同步） ----------------
    // 不走 hold_payload 握手：那套是给"每帧都要一致"的演奏数据用的，
    // 指引目标只在换音时变化，慢变量用 2FF 就够，代价是 1~2 行像素的瞬时错位。
    reg [2:0] gd_lane_s1, gd_lane_s2;
    reg [4:0] gd_fret_s1, gd_fret_s2;
    reg       gd_vld_s1,  gd_vld_s2;
    reg [3:0] gd_inst_s1, gd_inst_s2;
    always @(posedge i_pix_clk) begin
        gd_lane_s1 <= i_guide_lane;
        gd_fret_s1 <= i_guide_fret;
        gd_vld_s1  <= i_guide_valid;
        gd_inst_s1 <= i_instruments;
        gd_lane_s2 <= gd_lane_s1;
        gd_fret_s2 <= gd_fret_s1;
        gd_vld_s2  <= gd_vld_s1;
        gd_inst_s2 <= gd_inst_s1;
        o_guide_lane  <= gd_lane_s2;
        o_guide_fret  <= gd_fret_s2;
        o_guide_valid <= gd_vld_s2;
        o_instruments <= gd_inst_s2;
    end
endmodule
