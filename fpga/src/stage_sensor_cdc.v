//-----------------------------------------------------------------------------
// stage_sensor_cdc.v —— 传感器显示信号的 50MHz → 视频时钟同步（R7）
//
// 慢变显示量（品位/弓位置/事件计数等）逐位双寄存器同步。
// ev_valid/fire 是 50MHz 单周期脉冲：先在样本域展宽成 ~100ms/~60ms 的
// 闪烁保持，再同步到视频域，避免跨域丢脉冲。
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module stage_sensor_cdc (
    input  wire        i_sys_clk,
    input  wire        i_sys_reset,
    input  wire [19:0] i_fret_bus,
    input  wire [3:0]  i_left_valid,
    input  wire [3:0]  i_left_fault,
    input  wire signed [15:0] i_bow_pos_x,
    input  wire signed [15:0] i_bow_pos_y,
    input  wire [7:0]  i_bow_speed,
    input  wire        i_bow_dir,
    input  wire [3:0]  i_bow_gates,
    input  wire        i_ev_valid,
    input  wire [3:0]  i_ev_strings,
    input  wire [15:0] i_ev_total,
    input  wire [3:0]  i_fire,
    input  wire [3:0]  i_piezo_warm,
    input  wire [7:0]  i_bow_debug,
    input  wire [63:0] i_piezo_ay,
    input  wire        i_pix_clk,
    input  wire        i_pix_reset,
    output reg  [19:0] o_fret_bus,
    output reg  [3:0]  o_left_valid,
    output reg  [3:0]  o_left_fault,
    output reg  signed [15:0] o_bow_pos_x,
    output reg  signed [15:0] o_bow_pos_y,
    output reg  [7:0]  o_bow_speed,
    output reg         o_bow_dir,
    output reg  [3:0]  o_bow_gates,
    output reg         o_ev_flash,
    output reg  [3:0]  o_ev_strings,
    output reg  [15:0] o_ev_total,
    output reg  [3:0]  o_fire_flash,
    output reg  [3:0]  o_piezo_warm,
    output reg  [7:0]  o_bow_debug,
    output reg  [63:0] o_piezo_ay
);

    // ---- 样本域：事件/发声闪烁保持 ----
    reg [22:0] ev_cnt;
    reg [3:0]  ev_strings_hold;
    reg [21:0] fire_cnt [0:3];
    reg        ev_flash_s;
    reg [3:0]  fire_flash_s;
    integer k;
    always @(posedge i_sys_clk) begin
        if (i_sys_reset) begin
            ev_cnt <= 0; ev_strings_hold <= 0; ev_flash_s <= 0; fire_flash_s <= 0;
            for (k = 0; k < 4; k = k + 1) fire_cnt[k] <= 0;
        end else begin
            if (i_ev_valid) begin
                ev_cnt <= 23'd5_000_000;          // ≈100 ms
                ev_strings_hold <= i_ev_strings;
                ev_flash_s <= 1'b1;
            end else if (ev_cnt != 0) begin
                ev_cnt <= ev_cnt - 1'b1;
                if (ev_cnt == 1) ev_flash_s <= 1'b0;
            end
            for (k = 0; k < 4; k = k + 1) begin
                if (i_fire[k]) begin
                    fire_cnt[k] <= 22'd3_000_000; // ≈60 ms
                    fire_flash_s[k] <= 1'b1;
                end else if (fire_cnt[k] != 0) begin
                    fire_cnt[k] <= fire_cnt[k] - 1'b1;
                    if (fire_cnt[k] == 1) fire_flash_s[k] <= 1'b0;
                end
            end
        end
    end

    // ---- 视频域：两级同步 ----
    reg [19:0] q_fret;      reg [3:0] q_lvalid, q_lfault;
    reg signed [15:0] q_bpx, q_bpy;
    reg [7:0]  q_spd;       reg q_dir;
    reg [3:0]  q_bgates;
    reg        q_evflash;   reg [3:0] q_evstr;
    reg [15:0] q_evtot;
    reg [3:0]  q_fflash, q_warm;
    reg [7:0]  q_bdbg;
    reg [63:0] q_ay;

    always @(posedge i_pix_clk) begin
        if (i_pix_reset) begin
            o_fret_bus <= 0; o_left_valid <= 0; o_left_fault <= 0;
            o_bow_pos_x <= 0; o_bow_pos_y <= 0; o_bow_speed <= 0; o_bow_dir <= 0;
            o_bow_gates <= 0; o_ev_flash <= 0; o_ev_strings <= 0; o_ev_total <= 0;
            o_fire_flash <= 0; o_piezo_warm <= 0; o_bow_debug <= 0; o_piezo_ay <= 0;
            q_fret <= 0; q_lvalid <= 0; q_lfault <= 0; q_bpx <= 0; q_bpy <= 0;
            q_spd <= 0; q_dir <= 0; q_bgates <= 0; q_evflash <= 0; q_evstr <= 0;
            q_evtot <= 0; q_fflash <= 0; q_warm <= 0; q_bdbg <= 0; q_ay <= 0;
        end else begin
            q_fret <= i_fret_bus;       o_fret_bus <= q_fret;
            q_lvalid <= i_left_valid;   o_left_valid <= q_lvalid;
            q_lfault <= i_left_fault;   o_left_fault <= q_lfault;
            q_bpx <= i_bow_pos_x;       o_bow_pos_x <= q_bpx;
            q_bpy <= i_bow_pos_y;       o_bow_pos_y <= q_bpy;
            q_spd <= i_bow_speed;       o_bow_speed <= q_spd;
            q_dir <= i_bow_dir;         o_bow_dir <= q_dir;
            q_bgates <= i_bow_gates;    o_bow_gates <= q_bgates;
            q_evflash <= ev_flash_s;    o_ev_flash <= q_evflash;
            q_evstr <= ev_strings_hold; o_ev_strings <= q_evstr;
            q_evtot <= i_ev_total;      o_ev_total <= q_evtot;
            q_fflash <= fire_flash_s;   o_fire_flash <= q_fflash;
            q_warm <= i_piezo_warm;     o_piezo_warm <= q_warm;
            q_bdbg <= i_bow_debug;      o_bow_debug <= q_bdbg;
            q_ay <= i_piezo_ay;         o_piezo_ay <= q_ay;
        end
    end

endmodule

`default_nettype wire
