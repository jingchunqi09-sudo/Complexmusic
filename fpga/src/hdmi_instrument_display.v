// Gowin device adapter only. Audio stays on 50MHz; video owns its PLL/clocks.
// R9: one held-snapshot mailbox for audio and all multi-bit sensor metadata.
// R10.1: 由 R7 的 instrument_dashboard 切换为 R9 的 r9_audio_monitor + r9_stage_dashboard。
//        端口与 R7 版本一致，仅新增 i_mode（顶层给 2'b00，暂无按键切换）。
module hdmi_instrument_display (
    input i_clk_50m, input i_reset, input [1:0] i_mode, input i_pcm_valid, input signed [15:0] i_pcm,
    input [27:0] i_notes, input [3:0] i_gates, input [3:0] i_instruments,
    input [63:0] i_open_notes,
    input [31:0] i_bow_speeds, input [95:0] i_bow_positions, input [3:0] i_directions,
    input [31:0] i_velocities, input [31:0] i_latency_us, input i_audio_ready,
    // R7 传感器显示输入（50 MHz 域，来自 physical_performer_frontend）
    input [19:0] i_fret_bus, input [3:0] i_left_valid, input [3:0] i_left_fault,
    input signed [15:0] i_bow_pos_x, input signed [15:0] i_bow_pos_y,
    input [7:0] i_bow_speed, input i_bow_dir, input [3:0] i_bow_gates,
    input i_ev_valid, input [3:0] i_ev_strings, input [15:0] i_ev_total,
    input [3:0] i_fire, input [3:0] i_piezo_warm,
    input [7:0] i_bow_debug, input [63:0] i_piezo_ay,
    input i_piezo_smpl_valid, input [1:0] i_piezo_smpl_ch,
    // R33：曲谱指引目标（来自曲谱事件锁存，只用于显示）
    input [2:0] i_guide_lane, input [4:0] i_guide_fret, input i_guide_valid,
    output [2:0] o_tmds_data_p, output [2:0] o_tmds_data_n,
    output o_tmds_clock_p, output o_tmds_clock_n
);
    wire w_pixel_clk, w_serial_clk, w_pll_lock;
    reg [2:0] r_pixel_reset;
    reg [2:0] r_system_reset;
    wire [10:0] w_x;
    wire [9:0] w_y;
    wire w_de, w_hsync, w_vsync, w_frame_start;
    wire [27:0] w_notes;
    wire [3:0] w_gates;
    wire [31:0] w_velocities, w_latency;
    wire w_ready, w_capture_valid;
    wire [8:0] w_wave_address;
    wire signed [15:0] w_wave_sample;
    wire signed [15:0] w_wave_max;
    wire [15:0] w_peak,w_rms,w_crest;
    wire [1:0] w_mode,w_gain;
    wire [19:0] w_fret;
    wire [3:0] w_left_valid,w_left_fault,w_bow_gates,w_warm,w_fire;
    wire signed [15:0] w_bow_x,w_bow_y;
    wire [7:0] w_bow_speed;
    wire [15:0] w_ev_total;
    wire [63:0] w_bands;
    wire [2:0] w_guide_lane;
    wire [4:0] w_guide_fret;
    wire       w_guide_valid;
    wire [3:0] w_instruments;       // R54：view_instrument 的像素域副本
    wire w_spectrum_fault;
    wire [7:0] w_red, w_green, w_blue;
    wire w_draw_de, w_draw_hsync, w_draw_vsync;
    TMDS_PLL u_video_pll (.clkin(i_clk_50m),.clkout0(w_serial_clk),.clkout1(w_pixel_clk),.lock(w_pll_lock));
    // Async assertion, local synchronous release after PLL lock.
    always @(posedge w_pixel_clk or posedge i_reset or negedge w_pll_lock)
    begin
        if (i_reset || !w_pll_lock) r_pixel_reset<=3'b111;
        else r_pixel_reset<={r_pixel_reset[1:0],1'b0};
    end
    always @(posedge i_clk_50m or posedge i_reset or negedge w_pll_lock)
    begin
        if(i_reset || !w_pll_lock) r_system_reset<=3'b111;
        else r_system_reset<={r_system_reset[1:0],1'b0};
    end
    video_timing_720p u_timing (
        .i_clk(w_pixel_clk),.i_reset(r_pixel_reset[2]),.o_x(w_x),.o_y(w_y),
        .o_de(w_de),.o_hsync(w_hsync),.o_vsync(w_vsync),.o_frame_start(w_frame_start));
    r9_audio_monitor u_monitor(
        .i_sys_clk(i_clk_50m),.i_sys_reset(r_system_reset[2]),.i_pcm_valid(i_pcm_valid),.i_pcm(i_pcm),
        .i_mode(i_mode),.i_notes(i_notes),.i_gates(i_gates),.i_velocities(i_velocities),
        .i_fret_bus(i_fret_bus),.i_left_valid(i_left_valid),.i_left_fault(i_left_fault),
        .i_bow_x(i_bow_pos_x),.i_bow_y(i_bow_pos_y),.i_bow_speed(i_bow_speed),.i_bow_gates(i_bow_gates),
        .i_ev_total(i_ev_total),.i_fire(i_fire),.i_piezo_warm(i_piezo_warm),.i_audio_ready(i_audio_ready),.i_latency_us(i_latency_us),
        .i_guide_lane(i_guide_lane),.i_guide_fret(i_guide_fret),.i_guide_valid(i_guide_valid),
        .i_instruments(i_instruments),
        .o_guide_lane(w_guide_lane),.o_guide_fret(w_guide_fret),.o_guide_valid(w_guide_valid),
        .o_instruments(w_instruments),
        .i_pix_clk(w_pixel_clk),.i_pix_reset(r_pixel_reset[2]),.i_frame_start(w_frame_start),.i_wave_address(w_wave_address),
        .o_wave_min(w_wave_sample),.o_wave_max(w_wave_max),.o_mode(w_mode),.o_notes(w_notes),.o_gates(w_gates),
        .o_velocities(w_velocities),.o_fret_bus(w_fret),.o_left_valid(w_left_valid),.o_left_fault(w_left_fault),
        .o_bow_x(w_bow_x),.o_bow_y(w_bow_y),.o_bow_speed(w_bow_speed),.o_bow_gates(w_bow_gates),
        .o_ev_total(w_ev_total),.o_fire_flash(w_fire),.o_piezo_warm(w_warm),.o_audio_ready(w_ready),.o_latency_us(w_latency),
        .o_peak(w_peak),.o_rms(w_rms),.o_crest_tenths(w_crest),.o_gain_shift(w_gain),.o_bands(w_bands),
        .o_capture_valid(w_capture_valid),.o_spectrum_fault(w_spectrum_fault));
    r9_stage_dashboard u_dashboard(
        .clk(w_pixel_clk),.reset(r_pixel_reset[2]),.x(w_x),.y(w_y),.de(w_de),.hsync(w_hsync),.vsync(w_vsync),.frame_start(w_frame_start),
        .i_mode(w_mode),.i_fret_bus(w_fret),.i_left_valid(w_left_valid),.i_left_fault(w_left_fault),
        .i_bow_x(w_bow_x),.i_bow_y(w_bow_y),.i_bow_speed(w_bow_speed),.i_bow_gates(w_bow_gates),
        .i_notes(w_notes),.i_gates(w_gates),.i_vel(w_velocities),.i_ev_total(w_ev_total),.i_fire_flash(w_fire),.i_piezo_warm(w_warm),
        .i_audio_ready(w_ready),.i_capture_valid(w_capture_valid),.i_peak(w_peak),.i_rms(w_rms),.i_crest_tenths(w_crest),
        .i_gain_shift(w_gain),.i_bands(w_bands),.o_trace_address(w_wave_address),.i_trace_min(w_wave_sample),.i_trace_max(w_wave_max),
        .i_guide_lane(w_guide_lane),.i_guide_fret(w_guide_fret),.i_guide_valid(w_guide_valid),
        .i_instruments(w_instruments),
        .o_red(w_red),.o_green(w_green),.o_blue(w_blue),.o_de(w_draw_de),.o_hsync(w_draw_hsync),.o_vsync(w_draw_vsync));
    DVI_TX_Top u_dvi(
        .I_rst_n(!i_reset && w_pll_lock),.I_serial_clk(w_serial_clk),.I_rgb_clk(w_pixel_clk),
        .I_rgb_de(w_draw_de),.I_rgb_hs(w_draw_hsync),.I_rgb_vs(w_draw_vsync),.I_rgb_r(w_red),.I_rgb_g(w_green),.I_rgb_b(w_blue),
        .O_tmds_data_p(o_tmds_data_p),.O_tmds_data_n(o_tmds_data_n),.O_tmds_clk_p(o_tmds_clock_p),.O_tmds_clk_n(o_tmds_clock_n));
endmodule
