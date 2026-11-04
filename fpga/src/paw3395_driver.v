`timescale 1ns/1ps
// PAW3395DM-T6QU driver for Tang Mega 60K.
// Implements the datasheet power-up sequence, the 0x6C poll,
// and motion polling of Delta_X/Y registers. NRESET is actively driven.
//
// ---- R61：轮询节拍改造（延迟优先档，见 src/latency_profile.vh）------------
// 稳态每一轮的时钟构成（R60 -> R61）：
//
//   R60  空等 50000 clk (1 ms) + 自检 2 字 + Motion 5 字 + SQUAL 1 字
//        ≈ 1000 us + 8×24 us = 1120 us/轮  →  893 Hz
//   R61  空等 6000 clk (120 us) + Motion 5 字（14.3 us/字）
//        ≈ 120 us + 72 us = 201 us/轮     → 4975 Hz      （5.6x）
//
// 三处关键取舍，都在下面代码里就地标注：
//   1) 空等 1 ms 是纯延迟，与任何判据无关，直接压到 120 us。
//      PAW3395 的 Motion 寄存器是累计式（读后清零），读得越快粒度越细，
//      不存在"读太快拿不到数据"的问题。
//   2) Product_ID(0x00)/Inverse_ID(0x5F) 自检从"每轮"改成"每 16 轮"。
//      它只用于运行期掉线检测，不是延迟路径；原本每轮白花 2 个字（29 us）。
//   3) SQUAL(0x07) 只喂屏幕诊断，同样 16 轮读一次，省 1 个字。
//      sample_valid 的置位从 S_QUALITY_WAIT 前移到 S_QUALITY_CMD ——
//      跳过 SQUAL 的那一轮也照样给下游一个样本，样本率不因分频而抖。
// ---------------------------------------------------------------------------
`include "latency_profile.vh"
module paw3395_spi_engine #(
    parameter integer CLK_DIV = 5,
    parameter integer LEAD_CYCLES = 50,
    parameter integer SRAD_CYCLES = 100,
    parameter integer TRAIL_CYCLES = 250
)(
    input wire clk, input wire rst_n, input wire start, input wire write_op,
    input wire [7:0] addr, input wire [7:0] wdata, input wire miso,
    output reg ncs, output reg sclk, output reg mosi,
    output reg [7:0] rdata, output reg done, output reg busy
);
    localparam [3:0] E_IDLE=0,E_LEAD=1,E_SETUP=2,E_FALL=3,E_RISE=4,E_WAIT=5,E_DFALL=6,E_DRISE=7,E_TAIL=8;
    reg [3:0] state; reg [31:0] divcnt, waitcnt; reg [7:0] tx; reg [7:0] rx;
    reg [3:0] bitidx; reg read_mode; reg data_phase;
    always @(posedge clk) begin
        done <= 1'b0;
        if (!rst_n) begin
            state<=E_IDLE; ncs<=1'b1; sclk<=1'b1; mosi<=1'b0; rdata<=0; busy<=0;
            divcnt<=0; waitcnt<=0; tx<=0; rx<=0; bitidx<=0; read_mode<=0; data_phase<=0;
        end else if (state==E_IDLE) begin
            ncs<=1'b1; sclk<=1'b1; mosi<=1'b0; busy<=1'b0;
            if (start) begin
                ncs<=1'b0; busy<=1'b1; read_mode<=!write_op; data_phase<=1'b0;
                tx <= write_op ? (addr | 8'h80) : (addr & 8'h7F);
                bitidx<=7; divcnt<=0; waitcnt<=0; state<=E_LEAD;
            end
        end else if (state==E_LEAD || state==E_WAIT || state==E_TAIL) begin
            // Wait parameters are system-clock cycles, independent of SCLK divider.
            divcnt<=0;
            case(state)
                E_LEAD: if(waitcnt>=LEAD_CYCLES-1) begin waitcnt<=0;state<=E_FALL;end else waitcnt<=waitcnt+1;
                E_WAIT: if(waitcnt>=SRAD_CYCLES-1) begin waitcnt<=0;bitidx<=7;rx<=0;data_phase<=1;state<=E_DFALL;end else waitcnt<=waitcnt+1;
                E_TAIL: if(waitcnt>=TRAIL_CYCLES-1) begin ncs<=1;busy<=0;done<=1;state<=E_IDLE;end else waitcnt<=waitcnt+1;
            endcase
        end else if (divcnt < CLK_DIV-1) begin
            divcnt<=divcnt+1;
        end else begin
            divcnt<=0;
            case(state)
                // PAW3395 samples MOSI on rising SCLK and changes MISO on falling SCLK.
                // The reference MCU uses CPOL=1, CPHA=1 (SPI mode 3).
                E_FALL: begin mosi<=tx[bitidx]; sclk<=1'b0; state<=E_RISE; end
                E_RISE: begin
                    sclk<=1'b1;
                    if (bitidx!=0) begin bitidx<=bitidx-4'd1; state<=E_FALL; end
                    else if (!read_mode && !data_phase) begin
                        tx<=wdata; bitidx<=7; data_phase<=1'b1; state<=E_FALL;
                    end else if (read_mode && !data_phase) begin
                        waitcnt<=0; state<=E_WAIT;
                    end else begin
                        state<=E_TAIL; waitcnt<=0;
                    end
                end
                E_DFALL: begin sclk<=1'b0; state<=E_DRISE; end
                E_DRISE: begin
                    sclk<=1'b1;
                    rx[bitidx]<=miso;
                    if (bitidx!=0) begin bitidx<=bitidx-4'd1; state<=E_DFALL; end
                    else begin rdata<={rx[7:1],miso}; state<=E_TAIL; waitcnt<=0; end
                end
                default: state<=E_IDLE;
            endcase
        end
    end
endmodule

module paw3395_driver #(
    parameter integer RESET_CYCLES=50000,
    parameter integer POWER_WAIT_CYCLES=2500000,
    parameter integer WAIT_5MS_CYCLES=250000,
    // 初始化阶段 0x6C 的轮询间隔。这是器件上电时序契约（datasheet ±1%），
    // **不属于感知延迟路径**，R61 不动它。
    parameter integer WAIT_1MS_CYCLES=50000,
    // R61：稳态每轮之间的空等。R60 的名字叫 WAIT_1MS，但它在 S_MOTION_CMD 里
    // 每轮都等 1 ms，是整条右手弓链最大的单点延迟。改名以消除歧义。
    parameter integer POLL_GAP_CYCLES=`R61_PAW_POLL_GAP_CYCLES,
    // R61：SPI 时钟 25 -> 13，SCLK 1 MHz -> 1.92 MHz（器件上限 2 MHz）。
    // 单字时长 24 us -> 14.3 us，Motion 五字共省 48 us/轮。
    parameter integer SPI_CLK_DIV=`R61_PAW_SPI_CLK_DIV,
    parameter integer SPI_SRAD_CYCLES=100,
    parameter integer CPI=1000,
    parameter integer DISABLE_REST=1,
    // R47：进入 S_ERROR 后等待多久自动重试（默认 100 ms @ 50 MHz）。
    // 原来 S_ERROR 没有任何出口，SPI 抖一次就永久死机，只能按复位键。
    parameter integer RETRY_CYCLES=5000000,
    // R47：运行期自检允许"连续失败几次"才判错。1 = 老行为（错一次就死）。
    parameter integer CHECK_FAIL_MAX=3,
    // ---- R49：运行期"软恢复" ------------------------------------------------
    // R47 的恢复是"拉硬件复位 + 重跑 140 条初始化"。代价有两条：
    //   1) 入口把 ready 拉 0 —— bow_motion_tracker 里 !ready 是**电平**判据，
    //      一个 20 ns 的脉冲就足以 gate<=0、sped<=0；
    //   2) 最长 100 ms 没有采样 —— 早超过 tracker 的 8 ms 看门狗。
    // 两条叠起来 = "断音 + 重新起音"。偶发一次听不出来，反复发生就是
    // 用户报的"一直有混响"（实际是连续的重新起音糊在一起）。
    // R49 把**运行期偶发**错误改成软恢复：ready 保持 1，不碰 paw_nreset、
    // 不重写 0x3A、不重跑初始化表，只等 2 ms 后重读两个 ID。
    // 2 ms < 8 ms 看门狗，下游看到的是"弓停了一拍"，gate 不关、不重新起音。
    parameter integer SOFT_RETRY_CYCLES=100000,
    // 连续软恢复这么多次还不行，才认为传感器真的掉了，走完整重新初始化
    // （那种情况下音本来就已经断了，重新起音是应有的行为）。
    // R49：最初写 8 次（16 ms），三家评审一致说偏保守：连续 4 次（8 ms）软恢复
    // 失败就不能再当"单点抖动"看，而且 8 ms 恰好是 bow_motion_tracker 的看门狗
    // 窗口 —— 再拖下去本来也要关弓。取 4。
    parameter integer SOFT_RETRY_MAX=4
)(
    input wire clk_50m, input wire reset_n, input wire paw_miso, input wire paw_motion,
    output reg paw_nreset, output wire paw_ncs, output wire paw_sclk, output wire paw_mosi,
    output reg signed [15:0] delta_x, output reg signed [15:0] delta_y,
    output reg motion_valid, output reg ready, output reg init_error,
    output reg [7:0] debug_product_id, debug_inverse_id, debug_motion, debug_squal,
    output reg [15:0] debug_cpi_x, debug_cpi_y,
    output reg [3:0] debug_error,
    // One-cycle strobe after the complete Motion/Delta/SQUAL poll.  This is
    // an internal sensor sample boundary; it is deliberately not a UART
    // event and is used by the physical bow adapter below.
    output reg sample_valid
);
    localparam [4:0] S_RESET=0,S_PWRWAIT=1,S_PWR_LAUNCH=2,S_PWR_CMD=3,S_PWR_WAIT=4,
                     S_INIT_CMD=5,S_INIT_LAUNCH=6,S_INIT_WAIT=7,S_POLL_WAIT=8,S_POLL_LAUNCH=9,
                     S_POLL_CMD=10,S_FINAL_CMD=11,S_FINAL_LAUNCH=12,S_FINAL_WAIT=13,S_READY=14,
                     S_CLEAR_CMD=15,S_CLEAR_LAUNCH=16,S_CLEAR_WAIT=17,S_MOTION_CMD=18,S_MOTION_SET=19,S_MOTION_LAUNCH=20,S_MOTION_WAIT=21,S_ERROR=22,
                     S_CHECK_CMD=23,S_CHECK_LAUNCH=24,S_CHECK_WAIT=25,S_QUALITY_CMD=26,S_QUALITY_LAUNCH=27,S_QUALITY_WAIT=28,
                     S_AWAKE_CMD=29,S_AWAKE_LAUNCH=30,S_AWAKE_WAIT=31;
    // Datasheet: resolution = (register value + 1) * 50 CPI.
    // CPI must be a multiple of 50 in the range 50..26000.
    localparam [15:0] CPI_SETTING = CPI / 50 - 1;
    reg [4:0] state; reg [31:0] count; reg [7:0] init_index; reg [5:0] poll_count; reg [3:0] final_index;
    reg spi_start, spi_write; reg [7:0] spi_addr, spi_wdata; wire spi_done, spi_busy; wire [7:0] spi_rdata;
    reg [7:0] dx_l, dy_l; reg [2:0] clear_index, motion_reg_index;
    reg [1:0] check_phase, check_index;
    // R47：不能用 count 做重试计时 —— 进入 S_ERROR 时 count 的值不可控
    // （各状态的 else 分支都在让它自增，可能是任意值）。必须独立计数并在入口清零。
    reg [22:0] retry_cnt;
    reg [1:0]  fail_streak;      // 运行期自检连续失败次数（0..3）
    reg [3:0]  soft_tries;       // R49：连续软恢复次数，拿到一次正常采样就清零
    // R61：ID 自检 / SQUAL 读数的轮次分频计数。两者都只服务诊断，不在延迟路径上。
    reg [3:0]  audit_div;
    reg [3:0]  qual_div;
    reg check_failed;
    reg [1:0] awake_phase;
    reg [7:0] awake_value;
    // Periodic Motion polling also works when the optional MOTION wire is absent.

    paw3395_spi_engine #(.CLK_DIV(SPI_CLK_DIV),.SRAD_CYCLES(SPI_SRAD_CYCLES)) u_spi (
        .clk(clk_50m),.rst_n(reset_n),.start(spi_start),.write_op(spi_write),.addr(spi_addr),.wdata(spi_wdata),.miso(paw_miso),
        .ncs(paw_ncs),.sclk(paw_sclk),.mosi(paw_mosi),.rdata(spi_rdata),.done(spi_done),.busy(spi_busy));

    function [7:0] init_reg; input [7:0] i; begin init_reg=0; case(i)
              0: init_reg = 8'h7F;
              1: init_reg = 8'h40;
              2: init_reg = 8'h7F;
              3: init_reg = 8'h40;
              4: init_reg = 8'h7F;
              5: init_reg = 8'h55;
              6: init_reg = 8'h56;
              7: init_reg = 8'h57;
              8: init_reg = 8'h58;
              9: init_reg = 8'h7F;
              10: init_reg = 8'h42;
              11: init_reg = 8'h43;
              12: init_reg = 8'h4B;
              13: init_reg = 8'h4D;
              14: init_reg = 8'h53;
              15: init_reg = 8'h7F;
              16: init_reg = 8'h43;
              17: init_reg = 8'h44;
              18: init_reg = 8'h4D;
              19: init_reg = 8'h51;
              20: init_reg = 8'h53;
              21: init_reg = 8'h55;
              22: init_reg = 8'h5A;
              23: init_reg = 8'h5B;
              24: init_reg = 8'h61;
              25: init_reg = 8'h62;
              26: init_reg = 8'h6D;
              27: init_reg = 8'h6E;
              28: init_reg = 8'h70;
              29: init_reg = 8'h4A;
              30: init_reg = 8'h60;
              31: init_reg = 8'h7F;
              32: init_reg = 8'h6D;
              33: init_reg = 8'h6E;
              34: init_reg = 8'h6F;
              35: init_reg = 8'h53;
              36: init_reg = 8'h55;
              37: init_reg = 8'h7A;
              38: init_reg = 8'h7D;
              39: init_reg = 8'h7F;
              40: init_reg = 8'h41;
              41: init_reg = 8'h42;
              42: init_reg = 8'h43;
              43: init_reg = 8'h7F;
              44: init_reg = 8'h71;
              45: init_reg = 8'h7F;
              46: init_reg = 8'h62;
              47: init_reg = 8'h63;
              48: init_reg = 8'h65;
              49: init_reg = 8'h66;
              50: init_reg = 8'h67;
              51: init_reg = 8'h68;
              52: init_reg = 8'h69;
              53: init_reg = 8'h6A;
              54: init_reg = 8'h6C;
              55: init_reg = 8'h6D;
              56: init_reg = 8'h51;
              57: init_reg = 8'h53;
              58: init_reg = 8'h54;
              59: init_reg = 8'h71;
              60: init_reg = 8'h72;
              61: init_reg = 8'h73;
              62: init_reg = 8'h7F;
              63: init_reg = 8'h4A;
              64: init_reg = 8'h4C;
              65: init_reg = 8'h55;
              66: init_reg = 8'h7F;
              67: init_reg = 8'h4B;
              68: init_reg = 8'h4C;
              69: init_reg = 8'h61;
              70: init_reg = 8'h62;
              71: init_reg = 8'h63;
              72: init_reg = 8'h7F;
              73: init_reg = 8'h4C;
              74: init_reg = 8'h56;
              75: init_reg = 8'h41;
              76: init_reg = 8'h4D;
              77: init_reg = 8'h7F;
              78: init_reg = 8'h4A;
              79: init_reg = 8'h4B;
              80: init_reg = 8'h4C;
              81: init_reg = 8'h41;
              82: init_reg = 8'h55;
              83: init_reg = 8'h56;
              84: init_reg = 8'h49;
              85: init_reg = 8'h42;
              86: init_reg = 8'h43;
              87: init_reg = 8'h44;
              88: init_reg = 8'h54;
              89: init_reg = 8'h5A;
              90: init_reg = 8'h5F;
              91: init_reg = 8'h5B;
              92: init_reg = 8'h5E;
              93: init_reg = 8'h61;
              94: init_reg = 8'h62;
              95: init_reg = 8'h7F;
              96: init_reg = 8'h48;
              97: init_reg = 8'h4F;
              98: init_reg = 8'h52;
              99: init_reg = 8'h51;
              100: init_reg = 8'h54;
              101: init_reg = 8'h53;
              102: init_reg = 8'h56;
              103: init_reg = 8'h55;
              104: init_reg = 8'h58;
              105: init_reg = 8'h57;
              106: init_reg = 8'h5A;
              107: init_reg = 8'h5B;
              108: init_reg = 8'h5C;
              109: init_reg = 8'h5D;
              110: init_reg = 8'h71;
              111: init_reg = 8'h70;
              112: init_reg = 8'h73;
              113: init_reg = 8'h72;
              114: init_reg = 8'h75;
              115: init_reg = 8'h74;
              116: init_reg = 8'h77;
              117: init_reg = 8'h76;
              118: init_reg = 8'h7F;
              119: init_reg = 8'h4C;
              120: init_reg = 8'h7F;
              121: init_reg = 8'h4F;
              122: init_reg = 8'h4E;
              123: init_reg = 8'h52;
              124: init_reg = 8'h51;
              125: init_reg = 8'h54;
              126: init_reg = 8'h5A;
              127: init_reg = 8'h77;
              128: init_reg = 8'h47;
              129: init_reg = 8'h5B;
              130: init_reg = 8'h64;
              131: init_reg = 8'h65;
              132: init_reg = 8'h66;
              133: init_reg = 8'h67;
              134: init_reg = 8'h78;
              135: init_reg = 8'h79;
              136: init_reg = 8'h40;
              137: init_reg = 8'h55;
              138: init_reg = 8'h23;
              139: init_reg = 8'h22;
              default: init_reg=0; endcase end endfunction
    function [7:0] init_val; input [7:0] i; begin init_val=0; case(i)
              0: init_val = 8'h07;
              1: init_val = 8'h41;
              2: init_val = 8'h00;
              3: init_val = 8'h80;
              4: init_val = 8'h0E;
              5: init_val = 8'h0D;
              6: init_val = 8'h1B;
              7: init_val = 8'hE8;
              8: init_val = 8'hD5;
              9: init_val = 8'h14;
              10: init_val = 8'hBC;
              11: init_val = 8'h74;
              12: init_val = 8'h20;
              13: init_val = 8'h00;
              14: init_val = 8'h0E;
              15: init_val = 8'h05;
              16: init_val = 8'h64;
              17: init_val = 8'h04;
              18: init_val = 8'h06;
              19: init_val = 8'h40;
              20: init_val = 8'h40;
              21: init_val = 8'hCA;
              22: init_val = 8'hE8;
              23: init_val = 8'hEA;
              24: init_val = 8'h31;
              25: init_val = 8'h64;
              26: init_val = 8'hB8;
              27: init_val = 8'h0F;
              28: init_val = 8'h02;
              29: init_val = 8'h2A;
              30: init_val = 8'h26;
              31: init_val = 8'h06;
              32: init_val = 8'h70;
              33: init_val = 8'h60;
              34: init_val = 8'h04;
              35: init_val = 8'h02;
              36: init_val = 8'h11;
              37: init_val = 8'h01;
              38: init_val = 8'h51;
              39: init_val = 8'h07;
              40: init_val = 8'h10;
              41: init_val = 8'h32;
              42: init_val = 8'h00;
              43: init_val = 8'h08;
              44: init_val = 8'h4F;
              45: init_val = 8'h09;
              46: init_val = 8'h1F;
              47: init_val = 8'h1F;
              48: init_val = 8'h03;
              49: init_val = 8'h03;
              50: init_val = 8'h1F;
              51: init_val = 8'h1F;
              52: init_val = 8'h03;
              53: init_val = 8'h03;
              54: init_val = 8'h1F;
              55: init_val = 8'h1F;
              56: init_val = 8'h04;
              57: init_val = 8'h20;
              58: init_val = 8'h20;
              59: init_val = 8'h0C;
              60: init_val = 8'h07;
              61: init_val = 8'h07;
              62: init_val = 8'h0A;
              63: init_val = 8'h14;
              64: init_val = 8'h14;
              65: init_val = 8'h19;
              66: init_val = 8'h14;
              67: init_val = 8'h30;
              68: init_val = 8'h03;
              69: init_val = 8'h0B;
              70: init_val = 8'h0A;
              71: init_val = 8'h02;
              72: init_val = 8'h15;
              73: init_val = 8'h02;
              74: init_val = 8'h02;
              75: init_val = 8'h91;
              76: init_val = 8'h0A;
              77: init_val = 8'h0C;
              78: init_val = 8'h10;
              79: init_val = 8'h0C;
              80: init_val = 8'h40;
              81: init_val = 8'h25;
              82: init_val = 8'h18;
              83: init_val = 8'h14;
              84: init_val = 8'h0A;
              85: init_val = 8'h00;
              86: init_val = 8'h2D;
              87: init_val = 8'h0C;
              88: init_val = 8'h1A;
              89: init_val = 8'h0D;
              90: init_val = 8'h1E;
              91: init_val = 8'h05;
              92: init_val = 8'h0F;
              93: init_val = 8'h22;
              94: init_val = 8'h41;
              95: init_val = 8'h0D;
              96: init_val = 8'hDD;
              97: init_val = 8'h03;
              98: init_val = 8'h49;
              99: init_val = 8'h00;
              100: init_val = 8'h5B;
              101: init_val = 8'h00;
              102: init_val = 8'h64;
              103: init_val = 8'h00;
              104: init_val = 8'hA5;
              105: init_val = 8'h02;
              106: init_val = 8'h29;
              107: init_val = 8'h47;
              108: init_val = 8'h81;
              109: init_val = 8'h40;
              110: init_val = 8'hDC;
              111: init_val = 8'h07;
              112: init_val = 8'h00;
              113: init_val = 8'h08;
              114: init_val = 8'hDC;
              115: init_val = 8'h07;
              116: init_val = 8'h00;
              117: init_val = 8'h08;
              118: init_val = 8'h10;
              119: init_val = 8'hD0;
              120: init_val = 8'h00;
              121: init_val = 8'h63;
              122: init_val = 8'h00;
              123: init_val = 8'h63;
              124: init_val = 8'h00;
              125: init_val = 8'h54;
              126: init_val = 8'h10;
              127: init_val = 8'h4F;
              128: init_val = 8'h01;
              129: init_val = 8'h40;
              130: init_val = 8'h60;
              131: init_val = 8'h06;
              132: init_val = 8'h13;
              133: init_val = 8'h0F;
              134: init_val = 8'h01;
              135: init_val = 8'h9C;
              136: init_val = 8'h00;
              137: init_val = 8'h02;
              138: init_val = 8'h70;
              139: init_val = 8'h01;
              default: init_val=0; endcase end endfunction
    function [7:0] final_reg; input [7:0] i; begin final_reg=0; case(i)
              0: final_reg = 8'h22;
              1: final_reg = 8'h55;
              2: final_reg = 8'h7F;
              3: final_reg = 8'h40;
              4: final_reg = 8'h7F;
              5: final_reg = 8'h68;
              6: final_reg = 8'h7F;
              7: final_reg = 8'h48;
              8: final_reg = 8'h49;
              9: final_reg = 8'h4A;
              10: final_reg = 8'h4B;
              11: final_reg = 8'h47;
              default: final_reg=0; endcase end endfunction
    function [7:0] final_val; input [7:0] i; begin final_val=0; case(i)
              0: final_val = 8'h00;
              1: final_val = 8'h00;
              2: final_val = 8'h07;
              3: final_val = 8'h40;
              4: final_val = 8'h00;
              5: final_val = 8'h01;
              6: final_val = 8'h00;
              7: final_val = CPI_SETTING[7:0];
              8: final_val = CPI_SETTING[15:8];
              9: final_val = CPI_SETTING[7:0];
              10: final_val = CPI_SETTING[15:8];
              11: final_val = 8'h01;
              default: final_val=0; endcase end endfunction

    always @(posedge clk_50m) begin
        spi_start<=1'b0; motion_valid<=1'b0; sample_valid<=1'b0;
        if(!reset_n) begin
            state<=S_RESET; count<=0; init_index<=0; poll_count<=0; final_index<=0; clear_index<=0; motion_reg_index<=0;
            paw_nreset<=1'b0; delta_x<=0; delta_y<=0; dx_l<=0; dy_l<=0; ready<=1'b0; init_error<=1'b0;
            spi_write<=0; spi_addr<=0; spi_wdata<=0;
            debug_product_id<=0;debug_inverse_id<=0;debug_motion<=0;debug_squal<=0;
            debug_cpi_x<=0;debug_cpi_y<=0;debug_error<=0;
            sample_valid<=1'b0;
            check_phase<=0;check_index<=0;check_failed<=0;
            retry_cnt<=23'd0; fail_streak<=2'd0; soft_tries<=4'd0;
            audit_div<=4'd0; qual_div<=4'd0;
            awake_phase<=0;awake_value<=0;
        end else begin
            // Keep the poll timer running during the SPI read as well as waiting.
            // Thus consecutive 0x6C reads start 1ms apart (datasheet +/-1%).
            if(state==S_POLL_WAIT || state==S_POLL_LAUNCH || state==S_POLL_CMD)
                count<=count+1;
            case(state)
                S_RESET: begin paw_nreset<=1'b0; ready<=1'b0; if(count>=RESET_CYCLES-1) begin count<=0; paw_nreset<=1'b1; state<=S_PWRWAIT; end else count<=count+1; end
                S_PWRWAIT: begin if(count>=POWER_WAIT_CYCLES-1) begin count<=0; spi_write<=1; spi_addr<=8'h3A; spi_wdata<=8'h5A; state<=S_PWR_LAUNCH; end else count<=count+1; end
                S_PWR_LAUNCH: begin spi_start<=1'b1; state<=S_PWR_CMD; end
                S_PWR_CMD: begin if(spi_done) begin count<=0; state<=S_PWR_WAIT; end end
                S_PWR_WAIT: begin if(count>=WAIT_5MS_CYCLES-1) begin count<=0;init_index<=0;check_phase<=0;check_index<=0;state<=S_CHECK_CMD;end else count<=count+1;end
                S_INIT_CMD: begin spi_write<=1; spi_addr<=init_reg(init_index); spi_wdata<=init_val(init_index); state<=S_INIT_LAUNCH; end
                S_INIT_LAUNCH: begin spi_start<=1'b1; state<=S_INIT_WAIT; end
                S_INIT_WAIT: begin if(spi_done) begin if(init_index==8'd139) begin count<=0;poll_count<=0;state<=S_POLL_WAIT;end else begin init_index<=init_index+8'd1; state<=S_INIT_CMD; end end end
                S_CLEAR_CMD: begin spi_write<=0; spi_addr<=8'h02 + {5'd0,clear_index}; state<=S_CLEAR_LAUNCH; end
                S_CLEAR_LAUNCH: begin spi_start<=1'b1; state<=S_CLEAR_WAIT; end
                S_CLEAR_WAIT: begin if(spi_done) begin if(clear_index==3'd4) begin check_phase<=1;check_index<=0;check_failed<=0;state<=S_CHECK_CMD;end else begin clear_index<=clear_index+3'd1; state<=S_CLEAR_CMD; end end end
                S_POLL_WAIT: begin if(count>=WAIT_1MS_CYCLES-1) begin count<=0; spi_write<=0; spi_addr<=8'h6C; state<=S_POLL_LAUNCH; end end
                S_POLL_LAUNCH: begin spi_start<=1'b1; state<=S_POLL_CMD; end
                S_POLL_CMD: begin if(spi_done) begin if(spi_rdata==8'h80) begin final_index<=0;state<=S_FINAL_CMD;end else if(poll_count>=6'd59) begin init_error<=1;ready<=0;debug_error<=2;retry_cnt<=23'd0;state<=S_ERROR;end else begin poll_count<=poll_count+6'd1;state<=S_POLL_WAIT;end end end
                S_FINAL_CMD: begin spi_write<=1; spi_addr<=final_reg(final_index); spi_wdata<=final_val(final_index); state<=S_FINAL_LAUNCH; end
                S_FINAL_LAUNCH: begin spi_start<=1'b1; state<=S_FINAL_WAIT; end
                S_FINAL_WAIT: begin if(spi_done) begin if(final_index==4'd11) begin
                    if(DISABLE_REST) begin awake_phase<=0;state<=S_AWAKE_CMD;end
                    else begin clear_index<=0;state<=S_CLEAR_CMD;end
                end else begin final_index<=final_index+4'd1;state<=S_FINAL_CMD;end end end
                // Datasheet 8.3: preserve reserved bits when changing AWAKE.
                // Read 0x40, set bit7, write, then verify before allowing READY.
                S_AWAKE_CMD: begin spi_addr<=8'h40;spi_write<=awake_phase==1;spi_wdata<=awake_value;state<=S_AWAKE_LAUNCH;end
                S_AWAKE_LAUNCH: begin spi_start<=1;state<=S_AWAKE_WAIT;end
                S_AWAKE_WAIT: if(spi_done) begin
                    if(awake_phase==0) begin awake_value<=spi_rdata|8'h80;awake_phase<=1;state<=S_AWAKE_CMD;end
                    else if(awake_phase==1) begin awake_phase<=2;state<=S_AWAKE_CMD;end
                    else if(spi_rdata!=awake_value) begin init_error<=1;ready<=0;debug_error<=5;retry_cnt<=23'd0;state<=S_ERROR;end
                    else begin clear_index<=0;state<=S_CLEAR_CMD;end
                end
                S_CHECK_CMD: begin
                    spi_write<=0;
                    if(check_phase==1) spi_addr<=8'h48+check_index;
                    else spi_addr<=check_index==0 ? 8'h00 : 8'h5F;
                    state<=S_CHECK_LAUNCH;
                end
                S_CHECK_LAUNCH: begin spi_start<=1;state<=S_CHECK_WAIT;end
                S_CHECK_WAIT: if(spi_done) begin
                    if(check_phase==1) begin
                        case(check_index)
                            0: debug_cpi_x[7:0]<=spi_rdata;
                            1: debug_cpi_x[15:8]<=spi_rdata;
                            2: debug_cpi_y[7:0]<=spi_rdata;
                            3: debug_cpi_y[15:8]<=spi_rdata;
                        endcase
                        if(spi_rdata != (check_index[0] ? CPI_SETTING[15:8] : CPI_SETTING[7:0])) check_failed<=1;
                        if(check_index==3) begin
                            if(check_failed || spi_rdata!=CPI_SETTING[15:8]) begin
                                // R47：初始化阶段（check_phase==1）错一次就判错 —— 配置没写对；
                                //      运行期（check_phase==2）要连续 CHECK_FAIL_MAX 次才判错，
                                //      单次 SPI 抖动只丢一个采样，不再整机死。
                                if(check_phase==1 || fail_streak>=CHECK_FAIL_MAX-1) begin
                                    init_error<=1;ready<=0;debug_error<=3;
                                    retry_cnt<=23'd0;state<=S_ERROR;
                                end else begin
                                    fail_streak<=fail_streak+2'd1;
                                    ready<=1;count<=0;state<=S_READY;
                                end
                            end else begin
                                fail_streak<=2'd0;init_error<=0;
                                ready<=1;count<=0;state<=S_READY;
                            end
                        end else begin check_index<=check_index+2'd1;state<=S_CHECK_CMD;end
                    end else if(check_index==0) begin
                        debug_product_id<=spi_rdata;check_index<=1;state<=S_CHECK_CMD;
                    end else begin
                        debug_inverse_id<=spi_rdata;
                        // 运行期自检实际读的是 Product_ID(0x00) + Inverse_ID(0x5F)，
                        // **不是 CPI**（CPI 只在初始化 check_phase==1 时核对）。
                        // 实测确认：ph=2 只读到 idx=0/1 就回 S_MOTION_SET，从不到 idx=3。
                        if(debug_product_id!=8'h51 || spi_rdata!=8'hAE) begin
                            // R47：初始化阶段严格；运行期连续 CHECK_FAIL_MAX 次才判错，
                            // 单次 MISO 抖动只丢一个采样，不再整机死。
                            // R49：运行期（check_phase==2）**ready 与 init_error 都不许动**。
                            //      前端是 .ready(paw_ready && !paw_error) —— 两个信号
                            //      任意一个拉低一拍，bow_motion_tracker 就 gate<=0，
                            //      恢复后整音重新起音。这就是"混响感"的真正来源。
                            //      故障信息保留在 debug_error 里给 MONITOR 页看。
                            if(check_phase==0 || fail_streak>=CHECK_FAIL_MAX-1) begin
                                init_error <= (check_phase != 2);
                                ready     <= (check_phase != 2);   // 只有初始化阶段才冻结下游
                                debug_error<=check_phase==0 ? 1 : 4;
                                retry_cnt<=23'd0;state<=S_ERROR;
                            end else begin
                                fail_streak<=fail_streak+2'd1;
                                ready<=1;
                                motion_reg_index<=0;state<=S_MOTION_SET;
                            end
                        end else if(check_phase==0) begin
                            fail_streak<=2'd0;
                            state<=S_INIT_CMD;
                        end else begin
                            fail_streak<=2'd0;init_error<=0;
                            motion_reg_index<=0;state<=S_MOTION_SET;
                        end
                    end
                end
                S_READY: begin state<=S_MOTION_CMD; end
                // R47：原来这里没有任何出口 —— 一旦进来只能按复位键。
                // R49：分成两条路，**运行期不再整机重来**。
                //
                //   路 A（check_phase==2，运行期偶发 MISO 抖动）
                //     ready 保持 1，把 delta 清零，等 2 ms 后回 S_CHECK_CMD
                //     重读 Product_ID / Inverse_ID。成功就继续读运动，
                //     全过程 < 8 ms 看门狗 -> 下游 gate 不关，不重新起音。
                //
                //   路 B（初始化阶段失败，或连续软恢复 SOFT_RETRY_MAX 次仍失败）
                //     才拉 paw_nreset、重写 0x3A、重跑 140 条初始化。
                //     这种情况音本来就断了，重新起音是正确的。
                S_ERROR: begin
                    if (check_phase==2 && soft_tries < SOFT_RETRY_MAX) begin
                        // 关键三条：ready / init_error 保持"正常"，下游完全无感
                        ready<=1'b1;
                        init_error<=1'b0;
                        if (retry_cnt==23'd0) begin
                            // 清掉上一次的增量，防止"卡住的非零 delta"被当成持续运弓
                            delta_x<=16'sd0; delta_y<=16'sd0;
                        end
                        if(retry_cnt>=SOFT_RETRY_CYCLES-1) begin
                            retry_cnt<=23'd0; count<=0;
                            check_index<=0; check_failed<=1'b0;
                            soft_tries<=soft_tries+4'd1;
                            state<=S_CHECK_CMD;           // check_phase 仍是 2 -> 只读两个 ID
                        end else begin
                            retry_cnt<=retry_cnt+23'd1;
                        end
                    end else begin
                        // 真的掉了：这时才冻结下游并走完整重新初始化
                        ready<=1'b0;
                        init_error<=1'b1;
                        if(retry_cnt>=RETRY_CYCLES-1) begin
                            retry_cnt<=23'd0; count<=0;
                            init_error<=1'b0; check_failed<=1'b0; fail_streak<=2'd0;
                            soft_tries<=4'd0;
                            check_phase<=0; check_index<=0;
                            poll_count<=0; init_index<=0; final_index<=0;
                            state<=S_RESET;
                        end else begin
                            retry_cnt<=retry_cnt+23'd1;
                        end
                    end
                end
                S_MOTION_CMD: begin
                    if(count>=POLL_GAP_CYCLES-1) begin
                        count<=0;
                        // R61：轮间空等 120 us；ID 自检按 R61_PAW_AUDIT_DIV 轮分频。
                        // 跳过自检的那些轮直接进 S_MOTION_SET —— 少两次 SPI 传输，
                        // 而且 motion_reg_index 必须在这里清 0，否则会从上一轮
                        // 剩下的寄存器号（通常是 4）开始读，Motion 的"读后冻结"
                        // 语义就断了，四个 Delta 字节可能来自不同时刻。
                        if (audit_div >= `R61_PAW_AUDIT_DIV-1) begin
                            audit_div<=4'd0;
                            check_phase<=2;check_index<=0;
                            // R47：运行期每轮必须清掉，否则一次抖动会把 check_failed
                            // 永久留在 1，之后每次检查都必判错 -> 必然进 S_ERROR 死锁。
                            check_failed<=1'b0;
                            state<=S_CHECK_CMD;
                        end else begin
                            audit_div<=audit_div+4'd1;
                            motion_reg_index<=3'd0;
                            state<=S_MOTION_SET;
                        end
                    end else count<=count+1;
                end
                // Reading Motion (0x02) first freezes all four Delta bytes.
                S_MOTION_SET: begin spi_write<=0; spi_addr<=8'h02 + {5'd0,motion_reg_index}; state<=S_MOTION_LAUNCH; end
                S_MOTION_LAUNCH: begin spi_start<=1'b1; state<=S_MOTION_WAIT; end
                S_MOTION_WAIT: begin
                    if(spi_done) begin
                        case(motion_reg_index)
                            0: begin
                                debug_motion<=spi_rdata;
                                if (spi_rdata[7]) begin motion_reg_index<=1; state<=S_MOTION_SET; end
                                else begin
                                    // R59：**MOT=0 必须把位移清零**。
                                    // Motion 寄存器 bit7 (MOT) = "自上次读该寄存器以来有运动"。
                                    // MOT=0 表示"这一轮没有任何位移"，所以 delta 必须是 0。
                                    //
                                    // 原来的写法是直接跳去读 SQUAL，**delta_x/delta_y 一个都不动**，
                                    // 于是它们保留上一次运弓结束时的值；而 S_QUALITY_WAIT 里
                                    // `sample_valid<=1'b1` 是无条件的 —— 下游 bow_motion_tracker
                                    // 每 2 ms 收到一个"位移 = 上次那个大值"的**假样本**。
                                    //
                                    // 后果（实板现象，与显示/hold/版本全部无关）：
                                    //   sum_w 9 个样本全是那个值 -> sum_sat 恒 > CLOSE_TH(12)
                                    //   -> `gate && (sum_sat > CLOSE_TH)` 恒真 -> gate 永不关
                                    //   -> next_gates[0] = selected_strings[0] & bow_gate 恒 1
                                    //   -> **某一根弦一直自己响，停不下来**（哪根由 pick_r 上次锁定的决定）。
                                    //
                                    // 8 ms 看门狗也救不了：它只在 sample_valid=0 时计时，而这里
                                    // sample_valid 每轮都被置 1。R49 的软恢复又把运行期 ready 冻在 1，
                                    // "ready=0 -> 强制 gate<=0" 这条最后保护也不再生效。
                                    //
                                    // 清零后行为恢复正常：停弓 -> delta=0 -> sum_sat 衰减 ->
                                    // quiet 累计到 RELEASE_SAMPLES(21 样本≈42 ms) -> gate 正常关闭。
                                    // 运弓期间 MOT=1，走上面的分支，行为与修改前逐拍相同。
                                    delta_x<=16'sd0;
                                    delta_y<=16'sd0;
                                    motion_valid<=1'b0;
                                    state<=S_QUALITY_CMD;
                                end
                            end
                            1: begin dx_l<=spi_rdata; motion_reg_index<=2; state<=S_MOTION_SET; end
                            2: begin delta_x<={spi_rdata,dx_l}; motion_reg_index<=3; state<=S_MOTION_SET; end
                            3: begin dy_l<=spi_rdata; motion_reg_index<=4; state<=S_MOTION_SET; end
                            4: begin delta_y<={spi_rdata,dy_l};motion_valid<=!debug_motion[3];state<=S_QUALITY_CMD;end
                        endcase
                    end
                end
                // R61：sample_valid 的置位从 S_QUALITY_WAIT 前移到本状态入口。
                // 理由：SQUAL 现在按 R61_PAW_QUAL_DIV 轮分频，被跳过的那一轮
                // 也必须给下游一个样本，否则样本周期会在 16 轮里出现长短交替，
                // 而 bow_motion_tracker 的 9 样本窗按"样本数"计时，
                // 就会变成 15 短 1 长 —— 弓速曲线会出现 16 周期的幅度调制（听得出来）。
                // 移位后：无论读不读 SQUAL，都是"Motion 四字节齐了 -> 一个样本"。
                S_QUALITY_CMD: begin
                    sample_valid<=1'b1; count<=0; soft_tries<=4'd0;
                    // R49：拿到一次完整采样 = 当前没有故障。debug_error 只进屏幕
                    // （hdmi MONITOR 页），**不参与任何音频门控**，所以用它做
                    // "现在是否在软恢复"的独立指示：常亮 4 = 正在反复重试。
                    debug_error<=4'd0;
                    if (qual_div >= `R61_PAW_QUAL_DIV-1) begin
                        qual_div<=4'd0;
                        spi_write<=0;spi_addr<=8'h07;state<=S_QUALITY_LAUNCH;
                    end else begin
                        qual_div<=qual_div+4'd1;
                        state<=S_MOTION_CMD;
                    end
                end
                S_QUALITY_LAUNCH: begin spi_start<=1;state<=S_QUALITY_WAIT;end
                S_QUALITY_WAIT: if(spi_done) begin
                    debug_squal<=spi_rdata;
                    state<=S_MOTION_CMD;
                end
                default: state<=S_RESET;
            endcase
        end
    end
endmodule
