// R9 scanline dashboard; no frame buffer, no audio-path control.
// Input edge -> ROM read -> region registers -> compose -> output = 5 stages.
// The text, mask, raw trace and HS/VS/DE paths are checked by tb_r9_display.
module r9_stage_dashboard(
    input wire clk,input wire reset,input wire [10:0] x,input wire [9:0] y,
    input wire de,input wire hsync,input wire vsync,input wire frame_start,
    input wire [1:0] i_mode,
    input wire [19:0] i_fret_bus,input wire [3:0] i_left_valid,input wire [3:0] i_left_fault,
    input wire signed [15:0] i_bow_x,input wire signed [15:0] i_bow_y,
    input wire [7:0] i_bow_speed,input wire [3:0] i_bow_gates,
    input wire [27:0] i_notes,input wire [3:0] i_gates,input wire [31:0] i_vel,
    input wire [15:0] i_ev_total,input wire [3:0] i_fire_flash,input wire [3:0] i_piezo_warm,
    input wire i_audio_ready,input wire i_capture_valid,
    input wire [15:0] i_peak,input wire [15:0] i_rms,input wire [15:0] i_crest_tenths,
    input wire [1:0] i_gain_shift,input wire [63:0] i_bands,
    // R33：曲谱指引目标（弦 0..3 对应琴颈图四行；fret 0 = 空弦）
    // R55：小提琴不再画指引，这三个信号只在 lane 4..7（尤克里里）时使用。
    input wire [2:0] i_guide_lane,input wire [4:0] i_guide_fret,input wire i_guide_valid,
    // R54：当前显示的是哪件乐器（view_instrument 的像素域副本）。
    // 尤克里里曲谱不带品位，只用它判断"这根弦是不是真的在响"。
    input wire [3:0] i_instruments,
    output wire [8:0] o_trace_address,
    input wire signed [15:0] i_trace_min,input wire signed [15:0] i_trace_max,
    output reg [7:0] o_red,output reg [7:0] o_green,output reg [7:0] o_blue,
    output reg o_de,output reg o_hsync,output reg o_vsync
);
    localparam [23:0] BG=24'h080A0D,PANEL=24'h101317,EDGE=24'h20272E,
        TEAL=24'h4FD1C5,AMBER=24'hE9B353,RED=24'hE06A5E;
    function [23:0] string_color;
        input [1:0] row;
        begin case(row)
        0:string_color=24'h6FC9DE;1:string_color=24'hD9B36A;
        2:string_color=24'h7FCB9A;default:string_color=24'hC88BB4;
        endcase end
    endfunction
    function [10:0] fret_x;
        input [4:0] f;
        begin case(f)
        0:fret_x=112;1:fret_x=154;2:fret_x=193;3:fret_x=230;4:fret_x=265;
        5:fret_x=298;6:fret_x=330;7:fret_x=359;8:fret_x=387;9:fret_x=413;
        10:fret_x=438;11:fret_x=461;12:fret_x=483;13:fret_x=504;
        14:fret_x=524;15:fret_x=542;default:fret_x=560;
        endcase end
    endfunction
    function [23:0] wood_color;
        input [4:0] band;
        begin case(band)
        0:wood_color=24'h83552F;1:wood_color=24'h7F522D;2:wood_color=24'h7B4F2C;3:wood_color=24'h774C2B;
        4:wood_color=24'h734929;5:wood_color=24'h6F4628;6:wood_color=24'h6B4327;7:wood_color=24'h674026;
        8:wood_color=24'h633D24;9:wood_color=24'h5F3A23;10:wood_color=24'h5B3722;11:wood_color=24'h573421;
        12:wood_color=24'h53311F;13:wood_color=24'h4F2E1E;14:wood_color=24'h4B2B1D;15:wood_color=24'h47281C;
        16:wood_color=24'h43251A;17:wood_color=24'h3F2219;18:wood_color=24'h3B1F18;19:wood_color=24'h371C16;
        20:wood_color=24'h331915;21:wood_color=24'h2F1714;22:wood_color=24'h2B1412;23:wood_color=24'h271210;
        24:wood_color=24'h230F0F;25:wood_color=24'h1F0D0D;26:wood_color=24'h1B0B0B;27:wood_color=24'h170909;
        28:wood_color=24'h130708;29:wood_color=24'h0F0506;30:wood_color=24'h0B0304;default:wood_color=24'h070202;
        endcase end
    endfunction
    function [7:0] shade;
        input [7:0] v;input [1:0] amount;
        begin case(amount)
        0:shade=v-(v>>2)-(v>>4);1:shade=v-(v>>3)-(v>>4);
        2:shade=v-(v>>4);default:shade=v;
        endcase end
    endfunction
    wire [23:0] accent=i_mode==0 ? TEAL : i_mode==1 ? AMBER : RED;
    wire text_hit;
    wire [23:0] text_rgb;
    r9_text_layer u_text(.clk(clk),.reset(reset),.x(x),.y(y),.frame_start(frame_start),
        .i_mode(i_mode),.i_fret_bus(i_fret_bus),.i_left_valid(i_left_valid),.i_left_fault(i_left_fault),
        .i_notes(i_notes),.i_vel(i_vel),.i_bow_speed(i_bow_speed),.i_peak(i_peak),.i_rms(i_rms),
        .i_crest_tenths(i_crest_tenths),.i_ev_total(i_ev_total),.i_fire_flash(i_fire_flash),
        .i_piezo_warm(i_piezo_warm),.i_gain_shift(i_gain_shift),.i_audio_ready(i_audio_ready),.hit(text_hit),.rgb(text_rgb));
    reg [7:0] mask_rom[0:43519] /* synthesis syn_romstyle="block_rom" */;
    initial $readmemh("src/rom/r9_violin_mask.hex",mask_rom);
    wire mask_in=(x>=584 && x<840 && y>=106 && y<446);
    wire [8:0] mask_y=y[8:0]-9'd106;
    wire [7:0] mask_x=x[7:0]-8'd72;
    wire [15:0] mask_address=mask_in ? {mask_y,mask_x[7:1]} : 16'd0;
    reg [7:0] mask_data1;
    reg [10:0] x1,x2;
    // R33：曲谱指引目标框的坐标。**R54 改成纯组合 wire**：
    // 原来这三个是"在 always @(*) 里按条件赋值的 reg"，条件不满足时保持旧值，
    // 综合器只能推断成 latch —— 上电初值不确定，第一次进 GUIDE 页可能画在随机位置。
    // 改成 wire 后逻辑完全等价，但没有 latch，也便于仿真观察。
    // 闪烁位仍在时序块里（gd_frame）。
    wire [10:0] g_xl = (i_guide_fret==5'd0) ? 11'd4  : fret_x(i_guide_fret-1'b1);
    wire [10:0] g_xr = (i_guide_fret==5'd0) ? 11'd20 : fret_x(i_guide_fret);
    // g_yc：小提琴四行的行中心，174 + lane*40（lane 0..3 → 174 / 214 / 254 / 294）。
    // 只对 lane<4 有意义：lane=4 会算出 334，超出琴颈 154..314，
    // 所以尤克里里另用自己的行表 uke_yc（见下），不复用这一个。
    wire [9:0]  g_yc = 10'd174 + ({8'd0,i_guide_lane}<<5) + ({8'd0,i_guide_lane}<<3);
    // R54：尤克里里弦指引（lane 4..7）。行号 = lane-4。
    //
    // 三处刻意的低风险写法（多模型评审 B1/B3 一致要求）：
    //   ① 行中心用 4 选 1 常量表，**不用加法器** —— 和 ncy 的 174+40r 等价，
    //      但不会给 neck 那串比较器再接一个"移位+加"的新支路。
    //   ② 命中判据 uke_hit_r **在时序块里打一拍**，颜色级只读 1 bit 寄存器，
    //      不在组合路径上直接索引 i_gates/i_instruments（hold 只有 184 ps）。
    //   ③ i_guide_lane 是 3 位，天然只可能是 0..7，uke_row 不会折回。
    function [9:0] uke_row_y;
        input [1:0] r;
        begin case(r)
        0:uke_row_y=10'd174;1:uke_row_y=10'd214;2:uke_row_y=10'd254;default:uke_row_y=10'd294;
        endcase end
    endfunction
    wire [1:0] uke_row  = i_guide_lane[1:0];
    wire       uke_on   = (i_mode==2'd0) && i_guide_valid && i_guide_lane[2];
    wire [9:0] uke_yc   = uke_row_y(uke_row);
    reg        uke_hit_r;
    reg [3:0]  gd_frame;
    wire       guide_blink = gd_frame[3];
    reg [9:0] y1,y2;
    // Region-local coordinate copies reduce the high-fanout x1/y1 cone in
    // the 73.333MHz pixel path. They preserve the same one-cycle coordinate
    // latency while allowing Gowin to place each region's comparator tree
    // near its destination registers.
    reg [10:0] x_frame1,x_neck1,x_vio1,x_levels1,x_spec1;
    reg [9:0] y_frame1,y_neck1,y_vio1,y_levels1,y_spec1;
    reg [3:0] de_pipe,hs_pipe,vs_pipe;
    // Match 512 bins to 560 columns, including both endpoint bins.
    wire [10:0] trace_dx_full=x-11'd52;
    wire [9:0] trace_dx=x>=52 && x<612 ? trace_dx_full[9:0] : 10'd0;
    wire [16:0] trace_wide={7'd0,trace_dx};
    wire [16:0] trace_product=(trace_wide<<7)-(trace_wide<<3)-(trace_wide<<1)-trace_wide+17'd64;
    assign o_trace_address=trace_product[15:7];
    // R10.1: 这三个寄存器原本声明在 always 块之后（第 152-154 行），
    // ModelSim 按"先声明后使用"报 vlog-2730；前移到使用点之前。
    reg [7:0] spec_level1;
    reg spec_active1;
    reg [3:0] spec_phase1;
    reg signed [27:0] trace_min2,trace_max2;
    wire signed [18:0] boost_min=$signed({{3{i_trace_min[15]}},i_trace_min}) <<< i_gain_shift;
    wire signed [18:0] boost_max=$signed({{3{i_trace_max[15]}},i_trace_max}) <<< i_gain_shift;
    wire signed [27:0] min_wide={{9{boost_min[18]}},boost_min};
    wire signed [27:0] max_wide={{9{boost_max[18]}},boost_max};
    wire [1:0] level_row0=y<188 ? 0 : y<268 ? 1 : y<348 ? 2 : 3;
    wire [1:0] neck_row0=y<194 ? 0 : y<234 ? 1 : y<274 ? 2 : 3;
    reg [1:0] level_row1,neck_row1;
    reg [7:0] level_velocity1;
    reg [6:0] level_note1;
    reg [4:0] neck_fret1;
    reg level_gate1;
    always @(posedge clk) begin
        mask_data1<=mask_rom[mask_address];x1<=x;y1<=y;x2<=x1;y2<=y1;
        x_frame1<=x;x_neck1<=x;x_vio1<=x;x_levels1<=x;x_spec1<=x;
        y_frame1<=y;y_neck1<=y;y_vio1<=y;y_levels1<=y;y_spec1<=y;
        // R33：指引框闪烁（每 8 帧翻转一次，约 0.13 s @60 fps）
        if(reset) gd_frame<=4'd0;
        else if(frame_start) gd_frame<=gd_frame+4'd1;
        // R54：uke 命中位打一拍（见上面 ②）。i_gates 是 view 选过的，
        // 只有当前确实是 uke（4'hf）才算命中，否则小提琴的 gate 会让 uke 行误绿。
        uke_hit_r <= (i_instruments==4'hf) && i_gates[uke_row];
        // Split spectrum selection from height/colour arithmetic.  The
        // previous x_spec1 -> spec2 path combined a variable part-select,
        // shift and compares and was the worst full-PNR video path.
        if(x_spec1>=636 && x_spec1<768) begin
            spec_active1<=1'b1;
            spec_phase1<=x_spec1[3:0];
            spec_level1<=band_pick((x_spec1-11'd636)>>4,i_bands);
        end else begin
            spec_active1<=1'b0;
            spec_phase1<=4'd0;
            spec_level1<=8'd0;
        end
        trace_min2<=(min_wide<<6)+(min_wide<<3)+(min_wide<<1);
        trace_max2<=(max_wide<<6)+(max_wide<<3)+(max_wide<<1);
        level_row1<=level_row0;level_velocity1<=i_vel[level_row0*8 +: 8];level_note1<=i_notes[level_row0*7 +: 7];
        level_gate1<=i_gates[level_row0]||i_fire_flash[level_row0];
        neck_row1<=neck_row0;neck_fret1<=i_fret_bus[neck_row0*5 +: 5];
        if(reset) begin de_pipe<=0;hs_pipe<=0;vs_pipe<=0;end
        else begin de_pipe<={de_pipe[2:0],de};hs_pipe<={hs_pipe[2:0],hsync};vs_pipe<={vs_pipe[2:0],vsync};end
    end
    // Parallel region functions are registered before coverage selection.
    reg [23:0] frame_c,neck_c,vio_c,levels_c,spec_c;
    reg [23:0] frame2,neck2,vio2,levels2,spec2;
    reg [23:0] frame3,neck3,vio3,levels3,spec3;
    reg [23:0] scope3,base4;
    reg [10:0] bx0,bx1;
    reg [9:0] by0,by1;
    reg panel_hit;
    reg [1:0] nr,lr;
    reg [9:0] ncy,ly0;
    reg [4:0] nf;
    reg [10:0] nfl,nfr;
    reg [23:0] nc;
    reg [7:0] lv;
    reg [6:0] ln;
    reg [9:0] llen;
    reg [3:0] lthick;
    reg [3:0] px;
    reg [8:0] my,wood_offset;
    reg [4:0] band;
    reg [23:0] wood;
    reg signed [11:0] bow_dx,bow_dy;
    reg signed [15:0] bow_x,bow_y;
    reg [2:0] si;
    reg [7:0] sl;
    reg [8:0] sh;
    reg [10:0] spec_dx;
    function [7:0] band_pick;
        input [3:0] band_index;
        input [63:0] band_bus;
        begin
            case(band_index)
            0:band_pick=band_bus[7:0];
            1:band_pick=band_bus[15:8];
            2:band_pick=band_bus[23:16];
            3:band_pick=band_bus[31:24];
            4:band_pick=band_bus[39:32];
            5:band_pick=band_bus[47:40];
            6:band_pick=band_bus[55:48];
            default:band_pick=band_bus[63:56];
            endcase
        end
    endfunction
    integer fi;
    always @(*) begin
        bx0=0;bx1=0;by0=0;by1=0;panel_hit=1;
        if(x_frame1>=20 && x_frame1<576 && y_frame1>=64 && y_frame1<452) begin bx0=20;bx1=576;by0=64;by1=452;end
        else if(x_frame1>=584 && x_frame1<840 && y_frame1>=64 && y_frame1<452) begin bx0=584;bx1=840;by0=64;by1=452;end
        else if(x_frame1>=848 && x_frame1<1260 && y_frame1>=64 && y_frame1<452) begin bx0=848;bx1=1260;by0=64;by1=452;end
        else if(x_frame1>=20 && x_frame1<1044 && y_frame1>=464 && y_frame1<704) begin bx0=20;bx1=1044;by0=464;by1=704;end
        else if(x_frame1>=1056 && x_frame1<1260 && y_frame1>=464 && y_frame1<704) begin bx0=1056;bx1=1260;by0=464;by1=704;end
        else panel_hit=0;
        frame_c=BG;
        if(panel_hit) begin
            frame_c=PANEL;
            if(y_frame1<by0+44) frame_c=y_frame1<by0+20 ? 24'h1B2026 : 24'h15191E;
            if(x_frame1==bx0 || x_frame1==bx1-1 || y_frame1==by1-1) frame_c=EDGE;
            if(y_frame1==by0) frame_c=24'h39434E;
            if(x_frame1>=bx0+2 && x_frame1<bx0+5 && y_frame1>=by0+10 && y_frame1<by0+34) frame_c=accent;
        end
        if(y_frame1>=8 && y_frame1<40) begin
            if(x_frame1>=20 && x_frame1<120) frame_c=i_mode==0 ? 24'h143832 : PANEL;
            if(x_frame1>=132 && x_frame1<232) frame_c=i_mode==1 ? 24'h3C301D : PANEL;
            if(x_frame1>=244 && x_frame1<356) frame_c=i_mode==2 ? 24'h3D2423 : PANEL;
        end
        if(y_frame1==48 && x_frame1>=20 && x_frame1<1260) frame_c=EDGE;
        // Neck rows and proportional fret locations.
        nr=neck_row1;
        ncy=10'd174+({8'd0,nr}<<5)+({8'd0,nr}<<3);
        nf=neck_fret1;
        if(nf>16) nf=0;
        nfl=fret_x(nf==0 ? 5'd0 : nf-1'b1);nfr=fret_x(nf);
        nc=string_color(nr);neck_c=0;
        if(x_neck1>=46 && x_neck1<112 && y_neck1>=148 && y_neck1<320) neck_c=24'h251A14;
        if(x_neck1>=112 && x_neck1<560 && y_neck1>=154 && y_neck1<314) neck_c=24'h1B1613;
        // R13b：原实现每个通道 >>2（亮度只剩 1/4），实板完全看不清选中的格子。
        // 改为满亮度 + 每通道加 32 提亮（饱和到 255）。这是纯加法与比较，
        // 组合深度 2 级，不影响视频域时序。
        if(x_neck1>nfl && x_neck1<nfr && y_neck1+14>=ncy && y_neck1<ncy+14 && nf!=0 && i_left_valid[nr] && !i_left_fault[nr])
            neck_c={(nc[23:16]>8'hDF)?8'hFF:(nc[23:16]+8'h20),
                    (nc[15:8] >8'hDF)?8'hFF:(nc[15:8] +8'h20),
                    (nc[7:0]  >8'hDF)?8'hFF:(nc[7:0]  +8'h20)};
        if(y_neck1>=154 && y_neck1<314) begin
            for(fi=1;fi<=16;fi=fi+1) if(x_neck1==fret_x(fi) || x_neck1==fret_x(fi)+1) neck_c=24'h59626B;
            if(x_neck1==111 || x_neck1==112 || x_neck1==113) neck_c=24'hC7D3DC;
        end
        if(y_neck1>=231 && y_neck1<=237 && ((x_neck1>=209 && x_neck1<=215)||(x_neck1>=278 && x_neck1<=284)||
            (x_neck1>=341 && x_neck1<=347)||(x_neck1>=423 && x_neck1<=429)||(x_neck1>=531 && x_neck1<=537))) neck_c=24'h63747F;
        if((y_neck1>=224 && y_neck1<=228 || y_neck1>=240 && y_neck1<=244) && x_neck1>=470 && x_neck1<=476) neck_c=24'h63747F;
        if(x_neck1>=46 && x_neck1<560 && y_neck1>=ncy && y_neck1<ncy+2)
            neck_c=i_left_valid[nr] && !i_left_fault[nr] ? nc : 24'h3A3F46;
        if(x_neck1>=57 && x_neck1<67 && (y_neck1>=164 && y_neck1<184 || y_neck1>=244 && y_neck1<264)) neck_c=24'hA4ADB2;
        if(x_neck1>=81 && x_neck1<91 && (y_neck1>=204 && y_neck1<224 || y_neck1>=284 && y_neck1<304)) neck_c=24'hA4ADB2;
        if(y_neck1>=322 && y_neck1<328) for(fi=1;fi<=16;fi=fi+1) if(x_neck1==fret_x(fi)) neck_c=24'h63747F;
        // ---- R54：GUIDE 页曲谱指引。小提琴（lane 0..3）与尤克里里（lane 4..7）各一套 ----
        //
        // 小提琴：品格框，黄=还没按到，绿=按对了（R33 规则；本版只把坐标从 reg 改成 wire）
        // 尤克里里：该行上下各 3 px 横线 + 最左空弦块填实；该弦真的在响时变绿
        //
        // 两边共用 g_xl / g_xr 定 x 范围，y 各自取行中心：
        //   小提琴 g_yc  = 174 + lane*40（lane 0..3 → 174 / 214 / 254 / 294）
        //   尤克里里 uke_yc 用 4 选 1 常量表 —— **不能复用 g_yc**，lane=4 会算到 334，
        //   超出琴颈 154..314，这正是 R33 当年只能写 lane<4 的原因。
        // ---- 小提琴：品格框 + 空弦块 ----
        if (i_mode==0 && i_guide_valid && i_guide_lane<2'd4 && guide_blink) begin
            if(x_neck1>=g_xl && x_neck1<=g_xr && y_neck1+8>=g_yc && y_neck1<=g_yc+22) begin
                // 只在边框上着色，保留格内原有的按品填充
                if(x_neck1==g_xl || x_neck1==g_xr || y_neck1+8==g_yc || y_neck1==g_yc+22)
                    neck_c = (i_fret_bus[i_guide_lane*5 +: 5] == i_guide_fret &&
                              i_left_valid[i_guide_lane]) ? 24'h28E070 : 24'hF0C020;
            end
            // 空弦目标：琴枕左侧整块闪一下，便于一眼看到
            if(i_guide_fret==5'd0 && x_neck1>=4 && x_neck1<20 &&
               y_neck1+8>=g_yc && y_neck1<=g_yc+22)
                neck_c = (i_fret_bus[i_guide_lane*5 +: 5] == 5'd0 &&
                          i_left_valid[i_guide_lane]) ? 24'h28E070 : 24'hF0C020;
        end
        // ---- 尤克里里：弦线 + 空弦块 + 品格框 ----
        //
        // 纵向分层（行高 30 px，互不重叠，别再改成重叠版本）：
        //   yc-8 .. yc-6   上弦线       yc-5        品框上边
        //   yc-5 .. yc+19  品格内区       yc+19       品框下边
        //   yc+20 .. yc+22 下弦线
        //
        // 硬件限制（写清楚，免得以后误判成 bug）：尤克里里 4 根弦**没有按品传感**
        // （i_fret_bus 只有 20 bit = 4 路，i_left_valid 4 位，都只覆盖琴弦 0..3）。
        // 所以绿色只能由"这根弦真的响了"（uke_hit_r）触发，**无法验证左手按得准不准**。
        if (uke_on && guide_blink) begin
            // 右手：该弦整行上下提示线
            if (x_neck1>=46 && x_neck1<560) begin
                if (y_neck1+8>=uke_yc && y_neck1+8<uke_yc+3)
                    neck_c = uke_hit_r ? 24'h28E070 : 24'hE9B353;
                if (y_neck1<=uke_yc+22 && y_neck1>uke_yc+19)
                    neck_c = uke_hit_r ? 24'h28E070 : 24'hE9B353;
            end
            // 左手：目标品格框。空弦（fret=0）不画框 —— 左侧空弦块填实已表达"空弦"，
            // 再画框会和它叠在一起；fret>=1 时 g_xl>=112，永远不会碰到那块。
            if (i_guide_fret!=5'd0 &&
                x_neck1>=g_xl && x_neck1<=g_xr &&
                y_neck1+5>=uke_yc && y_neck1<=uke_yc+19) begin
                if (x_neck1==g_xl || x_neck1==g_xr ||
                    y_neck1+5==uke_yc || y_neck1==uke_yc+19)
                    neck_c = uke_hit_r ? 24'h28E070 : 24'hF0C020;
            end
            // 空弦：琴枕左侧的空弦区（x 46..112）整块填实。
            // 多模型评审一致指出：只靠屏幕最左那 16 px（x 4..20）在 2~3 米外太弱，
            // 而"空弦"恰恰是唯一没有品框可指的情况，必须有个靠得住的大目标。
            if (i_guide_fret==5'd0 && x_neck1>=46 && x_neck1<112 &&
                y_neck1+8>=uke_yc && y_neck1<=uke_yc+22)
                neck_c = uke_hit_r ? 24'h28E070 : 24'hE9B353;
            // 最左空弦块填实（哪根弦的第三个锚点，远处也能一眼看到）
            if (x_neck1>=4 && x_neck1<20 && y_neck1+8>=uke_yc && y_neck1<=uke_yc+22)
                neck_c = uke_hit_r ? 24'h28E070 : 24'hE9B353;
        end
        // Four-bit category + depth-shading mask; both align with x/y copies.
        px=x_vio1[0] ? mask_data1[3:0] : mask_data1[7:4];my=y_vio1[8:0]-9'd106;
        wood_offset=my-9'd84;band=my<84 ? 5'd0 : wood_offset[7:3];
        if(my>=340) band=31;
        wood=wood_color(band);vio_c=0;
        if(x_vio1>=584 && x_vio1<840 && y_vio1>=106 && y_vio1<446) begin
            case(px[1:0])
            1:vio_c={shade(wood[23:16],px[3:2]),shade(wood[15:8],px[3:2]),shade(wood[7:0],px[3:2])};
            2:vio_c=24'h28180D;3:vio_c=24'hD9BE90;default:vio_c=0;
            endcase
            if(y_vio1>=153 && y_vio1<339 && (x_vio1==705 || x_vio1==710 || x_vio1==715 || x_vio1==720)) vio_c=24'h8E856D;
        end
        bow_x=i_bow_x>62 ? 16'sd62 : i_bow_x< -62 ? -16'sd62 : i_bow_x;
        bow_y=i_bow_y>34 ? 16'sd34 : i_bow_y< -34 ? -16'sd34 : i_bow_y;
        bow_dx=$signed({1'b0,x_vio1})-12'sd712-$signed(bow_x[11:0]);
        bow_dy=$signed({2'b0,y_vio1})-12'sd300-$signed(bow_y[11:0]);
        if(x_vio1>584 && x_vio1<839 && y_vio1>=110 && y_vio1<430) begin
            if(bow_dx>=-104 && bow_dx<=104 && bow_dy>=2 && bow_dy<=4) vio_c=bow_dy==2 ? 24'hFCF8EE : 24'hE7DFCB;
            if(bow_dx>=-104 && bow_dx<=104 && bow_dy>=-6 && bow_dy<=-4 && (bow_dx<=58 || bow_dy<=-5)) vio_c=bow_dy==-6 ? 24'hC08B52 : 24'h8A5A33;
            if(bow_dx>=-104 && bow_dx< -88 && bow_dy>=-7 && bow_dy<=6) vio_c=24'h241608;
            if(bow_dx>=-91 && bow_dx< -88 && bow_dy>=-7 && bow_dy<=6) vio_c=24'hCBD5DD;
            if(bow_dx>=-99 && bow_dx<=-96 && bow_dy>=-2 && bow_dy<=1) vio_c=24'hD9BE90;
            if(bow_dx>=-108 && bow_dx< -104 && bow_dy>=-2 && bow_dy<=1) vio_c=24'hCBD5DD;
            if(bow_dx>=101 && bow_dx<=106 && bow_dy>=-3 && bow_dy<=3) vio_c=24'hC0A276;
            if(|i_bow_gates && bow_dx>=-3 && bow_dx<=3 && bow_dy>=2 && bow_dy<=6) vio_c=TEAL;
        end
        // Actual gate/velocity bars, rather than simulated envelopes.
        lr=level_row1;
        case(lr) 0:ly0=176;1:ly0=256;2:ly0=336;default:ly0=416;endcase
        lv=level_velocity1;ln=level_note1;
        llen={2'd0,lv}+({2'd0,lv}>>2)+({2'd0,lv}>>3);lthick=4+ln[6:4];
        levels_c=0;
        if(x_levels1>=880 && x_levels1<1232 && y_levels1>=ly0 && y_levels1<ly0+12) levels_c=24'h050708;
        if(x_levels1>=880 && x_levels1<880+llen && y_levels1>=ly0+6-(lthick>>1) && y_levels1<ly0+6+(lthick>>1) && level_gate1) levels_c=string_color(lr);
        if(x_levels1>=872 && x_levels1<876 && y_levels1>=ly0-48 && y_levels1<ly0-40) levels_c=level_gate1 ? TEAL : EDGE;
        // Eight octave bands derived from actual mixed PCM.
        sl=spec_level1;sh=({4'd0,sl}+( {4'd0,sl}<<3))>>4;
        spec_c=0;
        if(spec_active1 && y_spec1>=516 && y_spec1<664) begin
            spec_c=24'h050708;
            if(spec_phase1>=2 && spec_phase1<14 && y_spec1>=664-sh && i_capture_valid)
                spec_c=y_spec1<560 ? AMBER : y_spec1<612 ? 24'h7EE8B4 : TEAL;
            if(spec_phase1>=2 && spec_phase1<14 && y_spec1==664-sh && sh!=0) spec_c=24'hD9F2E8;
        end
    end
    wire signed [27:0] top_trace=28'sd590-(trace_max2 >>> 15);
    wire signed [27:0] bottom_trace=28'sd590-(trace_min2 >>> 15);
    reg [23:0] scope_c;
    always @(*) begin
        scope_c=0;
        if(x2>=52 && x2<612 && y2>=516 && y2<664) begin
            scope_c=24'h050708;
            if(x2==52 || x2==122 || x2==192 || x2==262 || x2==332 || x2==402 || x2==472 || x2==542 || x2==611 ||
               y2==516 || y2==541 || y2==565 || y2==615 || y2==639 || y2==663) scope_c=24'h1C252D;
            if(y2==590) scope_c=24'h34434E;
            if(i_capture_valid && $signed({18'd0,y2})>=top_trace-1 && $signed({18'd0,y2})<=bottom_trace+1) scope_c=24'h93F8E6;
        end
    end
    always @(posedge clk) begin
        frame2<=frame_c;neck2<=neck_c;vio2<=vio_c;levels2<=levels_c;spec2<=spec_c;
        frame3<=frame2;neck3<=neck2;vio3<=vio2;levels3<=levels2;spec3<=spec2;scope3<=scope_c;
        if(scope3!=0) base4<=scope3;
        else if(spec3!=0) base4<=spec3;
        else if(levels3!=0) base4<=levels3;
        else if(vio3!=0) base4<=vio3;
        else if(neck3!=0) base4<=neck3;
        else base4<=frame3;
        if(reset) begin o_red<=0;o_green<=0;o_blue<=0;o_de<=0;o_hsync<=0;o_vsync<=0;end
        else begin
            {o_red,o_green,o_blue}<=de_pipe[3] ? (text_hit ? text_rgb : base4) : 24'd0;
            o_de<=de_pipe[3];o_hsync<=hs_pipe[3];o_vsync<=vs_pipe[3];
        end
    end
endmodule
