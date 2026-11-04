//-----------------------------------------------------------------------------
// instrument_dashboard.v —— R7 舞台显示（2026-10-30 重写）
//
// 布局（1280×720）：
//   顶部：STRING STAGE 标题 + 载波/采样率
//   左：尤克里里琴颈（4 弦×16 品，按品高亮，stage_fretboard）
//   中：小提琴 + 琴弓方位（stage_violin，弓随鼠标位移、触弦点高亮）
//   右：4 通道压电包络波形（彩色、滚动、GATE 参考线、发声闪烁、当前值）
//   左下：PCM 输出波形 + PEAK/RMS
//   底部：事件计数、左手状态块、PAW 状态、弓速/方向、最近识别弦
//
// 流水：A 拍锁存坐标并给出压电 RAM 读地址；B 拍组合全部绘制并输出寄存。
// de/hs/vs 同步延迟 2 拍。所有绘制子模块均为组合逻辑（73 MHz 像素时钟）。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module instrument_dashboard (
    input  wire        i_clk,
    input  wire        i_reset,
    input  wire [10:0] i_x,
    input  wire [9:0]  i_y,
    input  wire        i_de,
    input  wire        i_hsync,
    input  wire        i_vsync,
    input  wire        i_frame_start,
    // PCM（保留自旧版）
    input  wire signed [15:0] i_wave_sample,
    input  wire signed [15:0] i_wave_max,
    input  wire [15:0] i_peak,
    input  wire [15:0] i_rms,
    input  wire        i_ready,
    input  wire        i_capture_valid,
    output wire [7:0]  o_wave_address,
    // 传感器显示（视频域，已 CDC）
    input  wire [19:0] i_fret_bus,
    input  wire [3:0]  i_left_valid,
    input  wire [3:0]  i_left_fault,
    input  wire signed [15:0] i_bow_pos_x,
    input  wire signed [15:0] i_bow_pos_y,
    input  wire [7:0]  i_bow_speed,
    input  wire        i_bow_dir,
    input  wire [3:0]  i_bow_gates,
    input  wire        i_ev_flash,
    input  wire [3:0]  i_ev_strings,
    input  wire [15:0] i_ev_total,
    input  wire [3:0]  i_fire_flash,
    input  wire [3:0]  i_piezo_warm,
    input  wire [7:0]  i_bow_debug,
    input  wire [63:0] i_piezo_ay,
    // 压电波形 RAM（双口，读侧视频域）
    output wire [7:0]  o_piezo_wave_addr,
    input  wire [15:0] i_piezo_wave0,
    input  wire [15:0] i_piezo_wave1,
    input  wire [15:0] i_piezo_wave2,
    input  wire [15:0] i_piezo_wave3,
    output reg  [7:0]  o_red,
    output reg  [7:0]  o_green,
    output reg  [7:0]  o_blue,
    output reg         o_de,
    output reg         o_hsync,
    output reg         o_vsync
);

    // ---------------- Stage A：锁存坐标 + RAM 地址 ----------------
    // BCD 帧调度：每帧依次转换 8 个显示值（8×16=128 时钟，远小于帧长）
    reg [3:0] bcd_ch;
    reg bcd_start;
    reg [15:0] bcd_value;
    wire [19:0] bcd_out;
    wire bcd_done;
    reg [19:0] bcd_evtot, bcd_spd, bcd_peak, bcd_rms;
    reg [19:0] bcd_ay0, bcd_ay1, bcd_ay2, bcd_ay3;
    stage_bcd u_bcd(.clk(i_clk), .reset(i_reset), .start(bcd_start),
        .value(bcd_value), .bcd(bcd_out), .done(bcd_done));
    always @(*) begin
        case (bcd_ch)
            0: bcd_value = i_ev_total;
            1: bcd_value = i_piezo_ay[15:0];
            2: bcd_value = i_piezo_ay[31:16];
            3: bcd_value = i_piezo_ay[47:32];
            4: bcd_value = i_piezo_ay[63:48];
            5: bcd_value = {8'd0, i_bow_speed};
            6: bcd_value = i_peak;
            default: bcd_value = i_rms;
        endcase
    end
    always @(posedge i_clk) begin
        if (i_reset) begin
            bcd_ch <= 0; bcd_start <= 0;
            bcd_evtot<=0; bcd_spd<=0; bcd_peak<=0; bcd_rms<=0;
            bcd_ay0<=0; bcd_ay1<=0; bcd_ay2<=0; bcd_ay3<=0;
        end else begin
            bcd_start <= 0;
            if (i_frame_start) begin
                bcd_ch <= 0; bcd_start <= 1;
            end else if (bcd_done) begin
                case (bcd_ch)
                    0: bcd_evtot <= bcd_out;
                    1: bcd_ay0 <= bcd_out;
                    2: bcd_ay1 <= bcd_out;
                    3: bcd_ay2 <= bcd_out;
                    4: bcd_ay3 <= bcd_out;
                    5: bcd_spd <= bcd_out;
                    6: bcd_peak <= bcd_out;
                    default: bcd_rms <= bcd_out;
                endcase
                if (bcd_ch != 7) begin
                    bcd_ch <= bcd_ch + 1'b1;
                    bcd_start <= 1;
                end
            end
        end
    end

    reg [10:0] r_x;
    reg [9:0]  r_y;
    reg        r_de, r_hsync, r_vsync;
    always @(posedge i_clk) begin
        r_x <= i_x; r_y <= i_y;
        r_de <= i_de; r_hsync <= i_hsync; r_vsync <= i_vsync;
    end
    assign o_wave_address = (i_x >= 16 && i_x < 272) ? (i_x[7:0] - 8'd16) : 8'd0;
    assign o_piezo_wave_addr = (i_x >= 760) ? ((i_x - 760) >> 1) : 8'd0;

    // ---------------- 子模块：琴颈 / 小提琴 ----------------
    wire fb_hit;
    wire [23:0] fb_rgb;
    stage_fretboard u_fretboard (
        .x(r_x), .y(r_y), .fret_bus(i_fret_bus),
        .valid_mask(i_left_valid), .fault_mask(i_left_fault),
        .hit(fb_hit), .rgb(fb_rgb));

    wire vn_hit;
    wire [23:0] vn_rgb;
    stage_violin u_violin (
        .clk(i_clk),
        .x(r_x), .y(r_y), .bow_pos_x(i_bow_pos_x), .bow_pos_y(i_bow_pos_y),
        .gate_bus(i_bow_gates), .bow_speed(i_bow_speed), .bow_dir(i_bow_dir),
        .hit(vn_hit), .rgb(vn_rgb));

    // ---------------- 文本标签 ----------------
    wire t_title, t_fret, t_bow, t_pcm, t_events, t_carrier, t_rate, t_paw, t_warm;
    stage_text #(.TEXT("STRING STAGE"), .LEN(12), .X0(24), .Y0(14), .SCALE(2)) u_t0(.x(r_x), .y(r_y), .hit(t_title));
    stage_text #(.TEXT("FRETBOARD"), .LEN(9), .X0(24), .Y0(76)) u_t1(.x(r_x), .y(r_y), .hit(t_fret));
    stage_text #(.TEXT("BOW"), .LEN(3), .X0(440), .Y0(76)) u_t2(.x(r_x), .y(r_y), .hit(t_bow));
    stage_text #(.TEXT("PCM OUT"), .LEN(7), .X0(24), .Y0(424)) u_t3(.x(r_x), .y(r_y), .hit(t_pcm));
    stage_text #(.TEXT("EVENTS"), .LEN(6), .X0(24), .Y0(616)) u_t4(.x(r_x), .y(r_y), .hit(t_events));
    stage_text #(.TEXT("CARRIER 260KHZ"), .LEN(14), .X0(200), .Y0(616)) u_t5(.x(r_x), .y(r_y), .hit(t_carrier));
    stage_text #(.TEXT("PIEZO 6.2K"), .LEN(10), .X0(400), .Y0(616)) u_t6(.x(r_x), .y(r_y), .hit(t_rate));
    stage_text #(.TEXT("PAW"), .LEN(3), .X0(550), .Y0(616)) u_t7(.x(r_x), .y(r_y), .hit(t_paw));
    stage_text #(.TEXT("WARM"), .LEN(4), .X0(1000), .Y0(94)) u_t8(.x(r_x), .y(r_y), .hit(t_warm));

    // PAW 状态文本（ready/error 两种颜色与内容）
    wire paw_err = i_bow_debug[3];
    wire paw_rdy = i_bow_debug[2];
    wire t_paw_rdy, t_paw_err;
    stage_text #(.TEXT("RDY"), .LEN(3), .X0(580), .Y0(616)) u_t9(.x(r_x), .y(r_y), .hit(t_paw_rdy));
    stage_text #(.TEXT("ERR"), .LEN(3), .X0(580), .Y0(616)) u_t10(.x(r_x), .y(r_y), .hit(t_paw_err));

    // 压电 lane 标签与当前值
    wire [3:0] t_ch;
    stage_text #(.TEXT("CH1"), .LEN(3), .X0(766), .Y0(94))  u_c0(.x(r_x), .y(r_y), .hit(t_ch[0]));
    stage_text #(.TEXT("CH2"), .LEN(3), .X0(766), .Y0(214)) u_c1(.x(r_x), .y(r_y), .hit(t_ch[1]));
    stage_text #(.TEXT("CH3"), .LEN(3), .X0(766), .Y0(334)) u_c2(.x(r_x), .y(r_y), .hit(t_ch[2]));
    stage_text #(.TEXT("CH4"), .LEN(3), .X0(766), .Y0(454)) u_c3(.x(r_x), .y(r_y), .hit(t_ch[3]));

    // 数字显示：事件计数、各 lane 当前包络值、弓速、PCM 峰/RMS（BCD 由帧调度提供）
    wire n_events, n_bowspd, n_peak, n_rms;
    stage_number #(.DIGITS(5), .X0(100), .Y0(616)) u_n0(.x(r_x), .y(r_y), .bcd(bcd_evtot), .hit(n_events));
    stage_number #(.DIGITS(3), .X0(960), .Y0(616)) u_n1(.x(r_x), .y(r_y), .bcd(bcd_spd), .hit(n_bowspd));
    stage_number #(.DIGITS(5), .X0(300), .Y0(424)) u_n2(.x(r_x), .y(r_y), .bcd(bcd_peak), .hit(n_peak));
    stage_number #(.DIGITS(5), .X0(300), .Y0(440)) u_n3(.x(r_x), .y(r_y), .bcd(bcd_rms), .hit(n_rms));

    wire [3:0] n_ay;
    stage_number #(.DIGITS(4), .X0(820), .Y0(94))  u_a0(.x(r_x), .y(r_y), .bcd(bcd_ay0), .hit(n_ay[0]));
    stage_number #(.DIGITS(4), .X0(820), .Y0(214)) u_a1(.x(r_x), .y(r_y), .bcd(bcd_ay1), .hit(n_ay[1]));
    stage_number #(.DIGITS(4), .X0(820), .Y0(334)) u_a2(.x(r_x), .y(r_y), .bcd(bcd_ay2), .hit(n_ay[2]));
    stage_number #(.DIGITS(4), .X0(820), .Y0(454)) u_a3(.x(r_x), .y(r_y), .bcd(bcd_ay3), .hit(n_ay[3]));

    wire t_bowdir_l, t_bowdir_r, t_peak, t_rms, t_bowspd;
    stage_text #(.TEXT("<"), .LEN(1), .X0(1000), .Y0(616)) u_d0(.x(r_x), .y(r_y), .hit(t_bowdir_l));
    stage_text #(.TEXT(">"), .LEN(1), .X0(1000), .Y0(616)) u_d1(.x(r_x), .y(r_y), .hit(t_bowdir_r));
    stage_text #(.TEXT("PEAK"), .LEN(4), .X0(300), .Y0(408)) u_d2(.x(r_x), .y(r_y), .hit(t_peak));
    stage_text #(.TEXT("RMS"), .LEN(3), .X0(300), .Y0(440)) u_d3(.x(r_x), .y(r_y), .hit(t_rms));
    stage_text #(.TEXT("BOW SPD"), .LEN(7), .X0(880), .Y0(616)) u_d4(.x(r_x), .y(r_y), .hit(t_bowspd));

    // ---------------- 压电波形 lane ----------------
    // lane_top = 90/210/330/450，mid = top+74，高度限 60
    reg [15:0] wave_v;
    reg [1:0]  lane_idx;
    reg        in_lane;
    reg [9:0]  lane_top;
    always @(*) begin
        in_lane = 1'b0; lane_idx = 0; lane_top = 0; wave_v = 0;
        if (r_x >= 760 && r_x < 1272) begin
            if (r_y >= 90 && r_y < 200)  begin in_lane = 1'b1; lane_idx = 0; lane_top = 90;  wave_v = i_piezo_wave0; end
            else if (r_y >= 210 && r_y < 320) begin in_lane = 1'b1; lane_idx = 1; lane_top = 210; wave_v = i_piezo_wave1; end
            else if (r_y >= 330 && r_y < 440) begin in_lane = 1'b1; lane_idx = 2; lane_top = 330; wave_v = i_piezo_wave2; end
            else if (r_y >= 450 && r_y < 560) begin in_lane = 1'b1; lane_idx = 3; lane_top = 450; wave_v = i_piezo_wave3; end
        end
    end
    wire [9:0] lane_mid = lane_top + 74;
    // wave 计算拆到 B1/B2：B1 锁存 lane 信息与坐标，B2 组合波形命中。
    // GATE 参考虚线（CH0=13,CH1=25,CH2=22,CH3=15，按各自 shift）
    wire [9:0] gate_h = (lane_idx == 0) ? 10'd3 : (lane_idx == 1) ? 10'd3 :
                        (lane_idx == 2) ? 10'd2 : 10'd3;

    reg [23:0] lane_color;
    always @(*) begin
        case (lane_idx)
            2'd0: lane_color = 24'h00C8DC;
            2'd1: lane_color = 24'hE6BE28;
            2'd2: lane_color = 24'h3CC85A;
            default: lane_color = 24'hDC46AA;
        endcase
    end

    // ---------------- PCM 波形（保留，简化固定量程） ----------------
    wire pcm_zone = (r_x >= 16) && (r_x < 272) && (r_y >= 440) && (r_y < 520);

    // ---------------- 底部状态块 ----------------
    // 左手 4 色块：x 700/740/780/820，y 608..632
    reg left_block_hit;
    reg [23:0] left_block_rgb;
    integer lb;
    always @(*) begin
        left_block_hit = 1'b0; left_block_rgb = 24'h000000;
        for (lb = 0; lb < 4; lb = lb + 1) begin
            if ((r_x >= 700+lb*40) && (r_x < 724+lb*40) && (r_y >= 608) && (r_y < 632)) begin
                left_block_hit = 1'b1;
                if (i_left_fault[lb]) left_block_rgb = 24'hE04038;
                else if (i_left_valid[lb]) left_block_rgb = 24'h3CC85A;
                else left_block_rgb = 24'h4A5058;
            end
        end
    end
    // 最近识别弦 4 色块：x 1080/1120/1160/1200，y 608..632（ev_flash 期间亮）
    reg ev_block_hit;
    reg [23:0] ev_block_rgb;
    integer eb;
    always @(*) begin
        ev_block_hit = 1'b0; ev_block_rgb = 24'h000000;
        for (eb = 0; eb < 4; eb = eb + 1) begin
            if ((r_x >= 1080+eb*40) && (r_x < 1104+eb*40) && (r_y >= 608) && (r_y < 632)) begin
                ev_block_hit = 1'b1;
                if (i_ev_flash && i_ev_strings[eb]) begin
                    case (eb)
                        0: ev_block_rgb = 24'h00C8DC;
                        1: ev_block_rgb = 24'hE6BE28;
                        2: ev_block_rgb = 24'h3CC85A;
                        default: ev_block_rgb = 24'hDC46AA;
                    endcase
                end else ev_block_rgb = 24'h3A3F46;
            end
        end
    end

    // ---------------- Stage B1：锁存坐标、lane 信息、几何/文本命中、RAM 数据 ----------------
    wire [7:0] bg_r = 8'd8  + r_y[9:6];
    wire [7:0] bg_g = 8'd12 + r_y[9:6];
    wire [7:0] bg_b = 8'd24 + r_y[9:5];

    reg [10:0] r_x_b1;
    reg [9:0]  r_y_b1;
    reg        in_lane_b1;
    reg [9:0]  lane_top_b1, lane_mid_b1;
    reg [1:0]  lane_idx_b1;
    reg [23:0] lane_color_b1;
    reg [15:0] wave_v_b1;
    reg        pcm_zone_b1;
    reg signed [15:0] pcm_sample_b1;
    reg fb_hit_b1;
    reg [23:0] fb_rgb_b1;
    reg [19:0] t_b1;
    reg [7:0]  n_b1;
    reg left_block_hit_b1, ev_block_hit_b1;
    reg [23:0] left_block_rgb_b1, ev_block_rgb_b1;
    reg [7:0]  bg_r_b1, bg_g_b1, bg_b_b1;
    reg [3:0]  fire_flash_b1, warm_b1;
    reg [7:0]  bow_debug_b1;
    reg        bow_dir_b1, ev_flash_b1;
    reg [3:0]  ev_strings_b1, left_valid_b1, left_fault_b1;
    reg        de_b1, hsync_b1, vsync_b1;
    always @(posedge i_clk) begin
        r_x_b1 <= r_x; r_y_b1 <= r_y;
        in_lane_b1 <= in_lane; lane_top_b1 <= lane_top; lane_mid_b1 <= lane_mid;
        lane_idx_b1 <= lane_idx; lane_color_b1 <= lane_color; wave_v_b1 <= wave_v;
        pcm_zone_b1 <= pcm_zone; pcm_sample_b1 <= i_wave_sample;
        fb_hit_b1 <= fb_hit; fb_rgb_b1 <= fb_rgb;
        t_b1 <= {t_title,t_fret,t_bow,t_pcm,t_events,t_carrier,t_rate,t_paw,t_warm,
                t_paw_rdy,t_paw_err,t_ch,t_bowdir_l,t_bowdir_r,t_peak,t_rms,t_bowspd};
        n_b1 <= {n_events,n_bowspd,n_peak,n_rms,n_ay};
        left_block_hit_b1 <= left_block_hit; left_block_rgb_b1 <= left_block_rgb;
        ev_block_hit_b1 <= ev_block_hit; ev_block_rgb_b1 <= ev_block_rgb;
        bg_r_b1 <= bg_r; bg_g_b1 <= bg_g; bg_b_b1 <= bg_b;
        fire_flash_b1 <= i_fire_flash; warm_b1 <= i_piezo_warm;
        bow_debug_b1 <= i_bow_debug; bow_dir_b1 <= i_bow_dir;
        ev_flash_b1 <= i_ev_flash; ev_strings_b1 <= i_ev_strings;
        left_valid_b1 <= i_left_valid; left_fault_b1 <= i_left_fault;
        de_b1 <= r_de; hsync_b1 <= r_hsync; vsync_b1 <= r_vsync;
    end

    // ---------------- Stage B2：波形/PCM 命中（B1 锁存量组合）+ 全部信号延迟 ----------------
    wire [15:0] wave_scaled = (lane_idx_b1 == 1 || lane_idx_b1 == 2) ? (wave_v_b1 >> 3) : (wave_v_b1 >> 2);
    wire [9:0]  wave_h = (wave_scaled > 60) ? 10'd60 : wave_scaled[9:0];
    wire [9:0]  wave_line_y = lane_mid_b1 - wave_h;
    wire wave_pixel = in_lane_b1 && (r_x_b1 >= 762) &&
        ((r_y_b1 == wave_line_y) || (r_y_b1 == wave_line_y - 1));
    wire lane_baseline = in_lane_b1 && (r_y_b1 == lane_mid_b1) && (r_x_b1 >= 762);
    wire lane_frame = in_lane_b1 && (r_y_b1 == lane_top_b1 + 16) && (r_x_b1 >= 762);
    wire gate_dash = in_lane_b1 && (r_y_b1 == lane_mid_b1 - gate_h) && (r_x_b1 >= 762) && (r_x_b1[2] == 1'b0);

    wire signed [15:0] pcm_h_s = pcm_sample_b1 >>> 9;
    wire signed [9:0] pcm_h = (pcm_h_s > 40) ? 10'sd40 : (pcm_h_s < -40) ? -10'sd40 : pcm_h_s[9:0];
    wire signed [10:0] pcm_line_s = 11'sd480 - pcm_h;
    wire [9:0] pcm_line_y = pcm_line_s[9:0];
    wire pcm_pixel = pcm_zone_b1 && ((r_y_b1 == pcm_line_y) || (r_y_b1 == pcm_line_y - 1));
    wire pcm_baseline = pcm_zone_b1 && (r_y_b1 == 480);

    reg wave_pixel_b2, lane_baseline_b2, lane_frame_b2, gate_dash_b2;
    reg [23:0] lane_color_b2;
    reg [1:0] lane_idx_b2;
    reg pcm_pixel_b2, pcm_baseline_b2;
    reg fb_hit_b2;
    reg [23:0] fb_rgb_b2;
    reg [19:0] t_b2;
    reg [7:0]  n_b2;
    reg left_block_hit_b2, ev_block_hit_b2;
    reg [23:0] left_block_rgb_b2, ev_block_rgb_b2;
    reg [7:0]  bg_r_b2, bg_g_b2, bg_b_b2;
    reg [3:0]  fire_flash_b2, warm_b2;
    reg [7:0]  bow_debug_b2;
    reg        bow_dir_b2, ev_flash_b2;
    reg [3:0]  ev_strings_b2, left_valid_b2, left_fault_b2;
    reg        de_b2, hsync_b2, vsync_b2;
    always @(posedge i_clk) begin
        wave_pixel_b2 <= wave_pixel;
        lane_baseline_b2 <= lane_baseline;
        lane_frame_b2 <= lane_frame;
        gate_dash_b2 <= gate_dash;
        lane_color_b2 <= lane_color_b1; lane_idx_b2 <= lane_idx_b1;
        pcm_pixel_b2 <= pcm_pixel; pcm_baseline_b2 <= pcm_baseline;
        fb_hit_b2 <= fb_hit_b1; fb_rgb_b2 <= fb_rgb_b1;
        t_b2 <= t_b1; n_b2 <= n_b1;
        left_block_hit_b2 <= left_block_hit_b1; left_block_rgb_b2 <= left_block_rgb_b1;
        ev_block_hit_b2 <= ev_block_hit_b1; ev_block_rgb_b2 <= ev_block_rgb_b1;
        bg_r_b2 <= bg_r_b1; bg_g_b2 <= bg_g_b1; bg_b_b2 <= bg_b_b1;
        fire_flash_b2 <= fire_flash_b1; warm_b2 <= warm_b1;
        bow_debug_b2 <= bow_debug_b1; bow_dir_b2 <= bow_dir_b1;
        ev_flash_b2 <= ev_flash_b1; ev_strings_b2 <= ev_strings_b1;
        left_valid_b2 <= left_valid_b1; left_fault_b2 <= left_fault_b1;
        de_b2 <= de_b1; hsync_b2 <= hsync_b1; vsync_b2 <= vsync_b1;
    end

    // 解包（便于 Stage C 阅读）
    wire b_title=t_b2[19], b_fret=t_b2[18], b_bow=t_b2[17], b_pcm=t_b2[16],
         b_events=t_b2[15], b_carrier=t_b2[14], b_rate=t_b2[13], b_paw=t_b2[12],
         b_warm=t_b2[11], b_paw_rdy=t_b2[10], b_paw_err=t_b2[9];
    wire [3:0] b_ch = t_b2[8:5];
    wire b_dir_l=t_b2[4], b_dir_r=t_b2[3], b_peak_lbl=t_b2[2], b_rms_lbl=t_b2[1], b_bowspd=t_b2[0];
    wire b_n_events=n_b2[7], b_n_bowspd=n_b2[6], b_n_peak=n_b2[5], b_n_rms=n_b2[4];
    wire [3:0] b_n_ay = n_b2[3:0];
    wire b_paw_err_flag = bow_debug_b2[3];
    wire b_paw_rdy_flag = bow_debug_b2[2];

    // ---------------- Stage C：组合最终颜色并输出寄存 ----------------
    reg [23:0] rgb_next;
    always @(*) begin
        rgb_next = {bg_r_b2, bg_g_b2, bg_b_b2};
        if ((r_x >= 752 && r_y >= 84 && r_y < 568) || (r_y >= 600 && r_y < 648))
            rgb_next = {bg_r_b2 + 8'd4, bg_g_b2 + 8'd6, bg_b_b2 + 8'd10};
        if (b_title)   rgb_next = 24'hE8F0FF;
        if (b_fret)    rgb_next = 24'h9AB0C8;
        if (b_bow)     rgb_next = 24'h9AB0C8;
        if (b_pcm)     rgb_next = 24'h9AB0C8;
        if (b_events)  rgb_next = 24'h9AB0C8;
        if (b_carrier) rgb_next = 24'h7A90A8;
        if (b_rate)    rgb_next = 24'h7A90A8;
        if (b_paw)     rgb_next = 24'h9AB0C8;
        if (b_bowspd)  rgb_next = 24'h9AB0C8;
        if (b_peak_lbl) rgb_next = 24'h7A90A8;
        if (b_rms_lbl) rgb_next = 24'h7A90A8;
        if (b_paw_err_flag ? b_paw_err : (b_paw_rdy_flag && b_paw_rdy))
            rgb_next = b_paw_err_flag ? 24'hE04038 : 24'h3CC85A;
        if (bow_dir_b2 ? b_dir_r : b_dir_l) rgb_next = 24'hE6BE28;
        if (b_n_events)  rgb_next = 24'hE8F0FF;
        if (b_n_bowspd)  rgb_next = 24'hE8F0FF;
        if (b_n_peak)    rgb_next = 24'hE8F0FF;
        if (b_n_rms)     rgb_next = 24'hE8F0FF;
        if (b_n_ay[0])   rgb_next = 24'h00C8DC;
        if (b_n_ay[1])   rgb_next = 24'hE6BE28;
        if (b_n_ay[2])   rgb_next = 24'h3CC85A;
        if (b_n_ay[3])   rgb_next = 24'hDC46AA;
        if (b_ch[0])   rgb_next = 24'h00C8DC;
        if (b_ch[1])   rgb_next = 24'hE6BE28;
        if (b_ch[2])   rgb_next = 24'h3CC85A;
        if (b_ch[3])   rgb_next = 24'hDC46AA;
        if (b_warm && !warm_b2[0]) rgb_next = 24'h7A90A8;
        if (fb_hit_b2) rgb_next = fb_rgb_b2;
        if (vn_hit) rgb_next = vn_rgb;
        if (lane_baseline_b2) rgb_next = 24'h2A3440;
        if (gate_dash_b2)     rgb_next = 24'h6A4040;
        if (lane_frame_b2)    rgb_next = fire_flash_b2[lane_idx_b2] ? lane_color_b2 : 24'h2A3440;
        if (wave_pixel_b2)    rgb_next = lane_color_b2;
        if (pcm_baseline_b2) rgb_next = 24'h2A3440;
        if (pcm_pixel_b2)    rgb_next = 24'h80A0FF;
        if (left_block_hit_b2) rgb_next = left_block_rgb_b2;
        if (ev_block_hit_b2)   rgb_next = ev_block_rgb_b2;
    end

    always @(posedge i_clk) begin
        o_red   <= de_b2 ? rgb_next[23:16] : 8'd0;
        o_green <= de_b2 ? rgb_next[15:8]  : 8'd0;
        o_blue  <= de_b2 ? rgb_next[7:0]   : 8'd0;
        o_de    <= de_b2;
        o_hsync <= hsync_b2;
        o_vsync <= vsync_b2;
    end

endmodule

`default_nettype wire
