//=============================================================================
// disp_v3_stage —— 1280x720 舞台显示 v3 顶层
//
// 端口 = r9_stage_dashboard 的 41 路全覆盖，仅顺序不同；
// 替换时必须显式连接 i_guide_lane/i_guide_fret/i_guide_valid，
// 漏连不会报错（隐式线网），会静默丢失曲谱指引。
// 自检：python scripts/check_port_contract.py src\r9_stage_dashboard.v src\disp_v3_stage.v
//
// 流水线（对标 Project F：de 是延迟链的锚点）：
//   S0 坐标 -> 各区域组合判色（纯比较/查表）
//   S1 锁存区域色 + 坐标副本
//   S2 区域覆盖合成
//   S3 叠加文本层（文本层自身 3 拍）
//   S4 输出寄存，de/hs/vs 同深度延迟 4 拍
//
// 不新增时钟域、不新增 FIFO、不使用 DDR3；新增存储只有音符头等常量表。
//=============================================================================
`include "disp_v3_defs.vh"

module disp_v3_stage (
    input  wire        clk,
    input  wire        reset,
    input  wire [10:0] x,
    input  wire [9:0]  y,
    input  wire        de,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        frame_start,
    input  wire [1:0]  i_mode,
    input  wire [19:0] i_fret_bus,
    input  wire [3:0]  i_left_valid,
    input  wire [3:0]  i_left_fault,
    input  wire signed [15:0] i_bow_x,
    input  wire signed [15:0] i_bow_y,
    input  wire [7:0]  i_bow_speed,
    input  wire [3:0]  i_bow_gates,
    input  wire [27:0] i_notes,
    input  wire [3:0]  i_gates,
    input  wire [31:0] i_vel,
    input  wire [15:0] i_ev_total,
    input  wire [3:0]  i_fire_flash,
    input  wire [3:0]  i_piezo_warm,
    // R33 曲谱指引（与 r9_stage_dashboard 同名同宽，迁移后直接对接顶层 g_lane/g_fret/g_show）
    input  wire [2:0]  i_guide_lane,
    input  wire [4:0]  i_guide_fret,
    input  wire        i_guide_valid,
    input  wire        i_audio_ready,
    input  wire        i_capture_valid,
    input  wire [15:0] i_peak,
    input  wire [15:0] i_rms,
    input  wire [15:0] i_crest_tenths,
    input  wire [1:0]  i_gain_shift,
    input  wire [63:0] i_bands,
    output wire [8:0]  o_trace_address,
    input  wire signed [15:0] i_trace_min,
    input  wire signed [15:0] i_trace_max,
    output reg  [7:0]  o_red,
    output reg  [7:0]  o_green,
    output reg  [7:0]  o_blue,
    output reg         o_de,
    output reg         o_hsync,
    output reg         o_vsync
);
`include "r9_note_hz.vh"
`include "disp_v3_funcs.vh"

    // R42b：x/y 每个像素都要驱动六个面板 + 文本层，共几百个比较器。
    // 直接从 u_timing 的组合输出扇出，单条支线布线 3~4 ns（CLS 86%），
    // 实测最差路径 u_timing/o_y -> 面板寄存器 35.4 ns（预算 13.6）。
    // 这里插一级本地寄存，把 o_y 的扇出从几百降到 1，面板改从旁边的寄存器取坐标。
    // 代价：整条显示链晚 1 个像素（不可见），de/hs/vs 同步多延 1 拍。
    reg [10:0] x_r;  reg [9:0] y_r;
    always @(posedge clk) begin
        x_r <= x;
        y_r <= y;
    end


    //------------------------------------------------------------------
    // 动画状态
    //------------------------------------------------------------------
    wire [15:0] w_flash;
    wire [31:0] w_vpk;
    wire [63:0] w_band_pk;
    wire [7:0]  w_breath;
    wire [23:0] w_name_cur;
    wire [95:0] w_name_s;
    wire [39:0] w_staff_y;
    wire [29:0] w_hist_y;
    wire [2:0]  w_hist_v;
    wire [1:0]  w_sel;

    disp_v3_anim u_anim (
        .i_clk(clk), .i_reset(reset), .i_frame_start(frame_start),
        .i_fire(i_fire_flash), .i_vel(i_vel), .i_notes(i_notes), .i_bands(i_bands),
        .o_flash(w_flash), .o_vpk(w_vpk), .o_band_pk(w_band_pk), .o_breath(w_breath),
        .o_name_cur(w_name_cur), .o_name_s(w_name_s), .o_staff_y(w_staff_y),
        .o_hist_y(w_hist_y), .o_hist_v(w_hist_v), .o_sel(w_sel));

    wire [3:0] w_flash_cur = w_flash[w_sel*4 +: 4];
    wire [4:0] w_fret_cur  = i_fret_bus[w_sel*5 +: 5];
    wire [15:0] w_freq     = note_hz(i_notes[w_sel*7 +: 7]);

    //------------------------------------------------------------------
    // 面板框 + 顶栏（纯比较，成本极低）
    //------------------------------------------------------------------
    wire [23:0] accent = (i_mode == 2'd0) ? `C_TEAL : (i_mode == 2'd1) ? `C_AMBER : `C_RED;

    // 顶栏 MASTER 电平：四弦力度取最大，映射到 12 格（每格约 21），
    // 放在 "MASTER" 文字右侧（x 1052 起），不要压字
    wire [7:0] vel_max = (i_vel[31:24] > i_vel[23:16] ? i_vel[31:24] : i_vel[23:16]) >
                         (i_vel[15:8]  > i_vel[7:0]   ? i_vel[15:8]  : i_vel[7:0])
                       ? (i_vel[31:24] > i_vel[23:16] ? i_vel[31:24] : i_vel[23:16])
                       : (i_vel[15:8]  > i_vel[7:0]   ? i_vel[15:8]  : i_vel[7:0]);
    wire [11:0] lit_cnt = {4'd0, vel_max} / 12'd21;
    wire [11:0] seg_idx = (x - 11'd1052) >> 3;          // 每格 8 px
    wire w_master_bar = (seg_idx < lit_cnt) && (((x - 11'd1052) & 7) < 6);

    reg [23:0] frame_c;
    reg        panel_hit;
    reg [10:0] bx0, bx1;
    reg [9:0]  by0, by1;

    always @(*) begin
        bx0 = 11'd0; bx1 = 11'd0; by0 = 10'd0; by1 = 10'd0; panel_hit = 1'b0;
        if ((x >= `A_X0) && (x < `A_X1) && (y >= `A_Y0) && (y < `A_Y1)) begin
            bx0 = `A_X0; bx1 = `A_X1; by0 = `A_Y0; by1 = `A_Y1; panel_hit = 1'b1;
        end else if ((x >= `B_X0) && (x < `B_X1) && (y >= `B_Y0) && (y < `B_Y1)) begin
            bx0 = `B_X0; bx1 = `B_X1; by0 = `B_Y0; by1 = `B_Y1; panel_hit = 1'b1;
        end else if ((x >= `C_X0) && (x < `C_X1) && (y >= `C_Y0) && (y < `C_Y1)) begin
            bx0 = `C_X0; bx1 = `C_X1; by0 = `C_Y0; by1 = `C_Y1; panel_hit = 1'b1;
        end else if ((x >= `D_X0) && (x < `D_X1) && (y >= `D_Y0) && (y < `D_Y1)) begin
            bx0 = `D_X0; bx1 = `D_X1; by0 = `D_Y0; by1 = `D_Y1; panel_hit = 1'b1;
        end else if ((x >= `E_X0) && (x < `E_X1) && (y >= `E_Y0) && (y < `E_Y1)) begin
            bx0 = `E_X0; bx1 = `E_X1; by0 = `E_Y0; by1 = `E_Y1; panel_hit = 1'b1;
        end else if ((x >= `F_X0) && (x < `F_X1) && (y >= `F_Y0) && (y < `F_Y1)) begin
            bx0 = `F_X0; bx1 = `F_X1; by0 = `F_Y0; by1 = `F_Y1; panel_hit = 1'b1;
        end

        if (y < 10'd52) begin
            // 顶栏
            frame_c = (y < 10'd26) ? 24'h101820 : 24'h0A0F14;
            if (y == 10'd51) frame_c = `C_EDGE_DIM;
            if ((y >= 10'd9) && (y < 10'd41)) begin
                if ((x >= 11'd20)  && (x < 11'd120)) frame_c = (i_mode == 0) ? 24'h2A7A70 : 24'h161E27;
                if ((x >= 11'd128) && (x < 11'd236)) frame_c = (i_mode == 1) ? 24'h7A5A26 : 24'h161E27;
                if ((x >= 11'd244) && (x < 11'd344)) frame_c = (i_mode == 2) ? 24'h7A302C : 24'h161E27;
            end
            // MASTER 电平段：12 格，x 1052..1147，亮格数 = max(vel)/21
            if ((y >= 10'd10) && (y < 10'd18) && (x >= 11'd1052) && (x < 11'd1148)) begin
                frame_c = 24'h141E27;
                if (w_master_bar) frame_c = (x < 11'd1124) ? `C_TEAL :
                                            (x < 11'd1136) ? `C_AMBER : `C_RED;
            end
        end else if (panel_hit) begin
            frame_c = `C_PANEL;
            if (y < by0 + `HDR_H) frame_c = (y < by0 + `HDR_H / 2) ? `C_HDR_A : `C_HDR_B;
            if ((x == bx0) || (x == bx1 - 1) || (y == by1 - 1)) frame_c = `C_EDGE;
            if (y == by0) frame_c = `C_EDGE_HI;
            if ((x >= bx0 + 1) && (x < bx0 + 4) && (y >= by0 + 10) && (y < by0 + 36)) frame_c = accent;
        end else begin
            frame_c = `C_BG1;
        end
    end

    //------------------------------------------------------------------
    // 六个区域（全部组合）
    //------------------------------------------------------------------
    wire [15:0] w_mask_addr;
    wire [7:0]  w_mask_data;

    wire u_hit, v_hit, l_hit, d_hit, e_hit, f_hit;
    wire [23:0] u_rgb, v_rgb, l_rgb, d_rgb, e_rgb, f_rgb;

    disp_v3_ukulele u_uke (
        .i_clk(clk), .i_x(x_r), .i_y(y_r), .i_mode(i_mode), .i_sel(w_sel),
        .i_fret_bus(i_fret_bus), .i_valid(i_left_valid), .i_fault(i_left_fault),
        .i_flash(w_flash), .i_breath(w_breath),
        .i_guide_lane(i_guide_lane), .i_guide_fret(i_guide_fret), .i_guide_valid(i_guide_valid),
        .o_hit(u_hit), .o_rgb(u_rgb));

    disp_v3_violin u_vio (
        .i_clk(clk), .i_x(x_r), .i_y(y_r),
        .i_bow_x(i_bow_x), .i_bow_y(i_bow_y), .i_bow_gates(i_bow_gates),
        .i_flash_cur(w_flash_cur), .i_sel(w_sel),
        .o_mask_addr(w_mask_addr), .i_mask_data(w_mask_data),
        .o_hit(v_hit), .o_rgb(v_rgb));

    disp_v3_levels u_lvl (
        .i_clk(clk), .i_x(x_r), .i_y(y_r), .i_vpk(w_vpk),
        .i_flash_cur(w_flash_cur), .i_sel(w_sel), .i_gates(i_gates),
        .o_hit(l_hit), .o_rgb(l_rgb));

    disp_v3_score u_scr (
        .i_clk(clk), .i_x(x_r), .i_y(y_r), .i_staff_y(w_staff_y),
        .i_hist_y(w_hist_y), .i_hist_v(w_hist_v),
        .i_flash_cur(w_flash_cur), .i_sel(w_sel), .i_gates(i_gates),
        .o_hit(d_hit), .o_rgb(d_rgb));

    disp_v3_scope u_scp (
        .i_clk(clk), .i_x(x_r), .i_y(y_r),
        .i_tmin(i_trace_min), .i_tmax(i_trace_max),
        .i_gain_shift(i_gain_shift), .i_capture_valid(i_capture_valid),
        .o_hit(e_hit), .o_rgb(e_rgb));

    disp_v3_params u_par (
        .i_clk(clk), .i_x(x_r), .i_y(y_r),
        .i_bands(i_bands), .i_band_pk(w_band_pk),
        .o_hit(f_hit), .o_rgb(f_rgb));

    //------------------------------------------------------------------
    // 掩模 ROM（4bpp，256x340 -> 43520 B）+ 波形地址
    //------------------------------------------------------------------
    reg [7:0] mask_rom [0:43519] /* synthesis syn_romstyle="block_rom" */;
    initial $readmemh("src/rom/disp_v3_violin_mask.hex", mask_rom);
    reg [7:0] mask_q;
    always @(posedge clk) mask_q <= mask_rom[w_mask_addr];
    assign w_mask_data = mask_q;

    // 波形：350 列映射到 512 bin（SC_GW=350）
    // 修正：原实现 (tdx<<9)+(tdx<<2) 再取 [15:7] 等价于 tdx×4.03，
    // 9 位地址满量程 511 → 第 128 列就绕回 bin 4，整条波形重复约 2.7 次。
    // 与文件内注释「512/456 ≈ 1.123」的意图也不符。改为 187/128 = 1.4609
    // （512/350 = 1.4629，最大偏差 0.13%，末列落在 bin 509）。
    wire [10:0] tdx_full = x - `SC_GX;
    wire [9:0]  tdx = (x >= `SC_GX && x < `SC_GX + `SC_GW) ? tdx_full[9:0] : 10'd0;
    wire [16:0] twide = {7'd0, tdx};
    // 用移位加法而不是 `*187`：常量乘法若写成 * 会被综合成 DSP，
    // 而本工程 DSP 只剩 0.5 块余量（117.5/118），必须留在 LUT 里做。
    wire [16:0] tprod = (twide<<7) + (twide<<5) + (twide<<4) + (twide<<3)
                      + (twide<<1) +  twide;
    assign o_trace_address = tprod[15:7];

    //------------------------------------------------------------------
    // 流水线：S1 锁存 -> S2 覆盖
    //------------------------------------------------------------------
    reg [3:0] de_pipe, hs_pipe, vs_pipe;
    reg [23:0] u1, v1, l1, d1, e1, f1, fr1;
    reg        ph1;
    reg [23:0] base1;

    always @(posedge clk) begin
        u1 <= u_rgb; v1 <= v_rgb; l1 <= l_rgb;
        d1 <= d_rgb; e1 <= e_rgb; f1 <= f_rgb;
        fr1 <= frame_c; ph1 <= panel_hit;
        if (reset) begin
            de_pipe <= 4'd0; hs_pipe <= 4'd0; vs_pipe <= 4'd0;
        end else begin
            de_pipe <= {de_pipe[2:0], de};
            hs_pipe <= {hs_pipe[2:0], hsync};
            vs_pipe <= {vs_pipe[2:0], vsync};
        end
    end

    // 覆盖优先级：波形 > 频谱 > 电平 > 小提琴 > 尤克里里 > 曲谱 > 面板框
    // （与 r9 相同的"先判定者胜"结构；曲谱放最后是因为它面积大且多为底色）
    always @(*) begin
        if (e1 != 24'd0)      base1 = e1;
        else if (f1 != 24'd0) base1 = f1;
        else if (l1 != 24'd0) base1 = l1;
        else if (v1 != 24'd0) base1 = v1;
        else if (d1 != 24'd0) base1 = d1;
        else if (u1 != 24'd0) base1 = u1;
        else                  base1 = fr1;
    end

    //------------------------------------------------------------------
    // 文本层
    //   i_cents：音分偏差 x10。R16 的显示链目前没有实测频率偏差信号，
    //   这里接 0；接入真实测频后把 w_cents 换成上游信号即可（端口不变）。
    //------------------------------------------------------------------
    wire signed [7:0] w_cents = 8'sd0;
    wire signed [7:0] w_bow   = i_bow_x[7:0];

    wire t_hit;
    wire [23:0] t_rgb;
    disp_v3_text u_text (
        .i_clk(clk), .i_reset(reset), .i_x(x_r), .i_y(y_r), .i_frame_start(frame_start),
        .i_mode(i_mode), .i_name_cur(w_name_cur), .i_name_s(w_name_s),
        .i_vel(i_vel), .i_notes(i_notes), .i_fret(w_fret_cur), .i_sel(w_sel),
        .i_freq(w_freq), .i_gain(i_gain_shift), .i_cents(w_cents),
        .i_bow(w_bow), .i_bow_speed(i_bow_speed), .i_bow_gates(i_bow_gates),
        .i_piezo_warm(i_piezo_warm),
        .i_peak(i_peak), .i_rms(i_rms), .i_crest_tenths(i_crest_tenths),
        .o_hit(t_hit), .o_rgb(t_rgb));

    //------------------------------------------------------------------
    // 输出
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            o_red <= 8'd0; o_green <= 8'd0; o_blue <= 8'd0;
            o_de <= 1'b0; o_hsync <= 1'b0; o_vsync <= 1'b0;
        end else begin
            {o_red, o_green, o_blue} <= de_pipe[3] ? (t_hit ? t_rgb : base1) : 24'd0;
            o_de    <= de_pipe[3];
            o_hsync <= hs_pipe[2];
            o_vsync <= vs_pipe[2];
        end
    end

endmodule
