`timescale 1ns/1ps
// Independent per-string slot decision. Each string has 16 electrodes.
// A fault blocks only its own string; other strings keep working.
//
// R6 rule change: when one string hits several electrodes at once, the
// highest fret number wins instead of declaring the string ambiguous.
// Reason: the sounding length of a string is set by the contact closest to
// the bridge, which is the highest fret on this ascending channel->fret map
// (user requirement 2026-10-29; channels 0..15 map to frets 1..16).
// Safety kept: an acquisition fault still blocks the string, and >=COMMON_CELLS
// simultaneous hits (whole-hand contact) still count as common-mode and block.
module left_hand_string_decoder #(
    parameter integer COMMON_CELLS=8,
    // R10：单槽零命中不立即清品。现场"按下后品位一直闪"的成因是某一槽的
    // final_hit 短暂全零（命中率在 press/release 门限附近抖动），decoder 收到
    // count=0 就把 fret 清成 0，发空弦音，听感是音高在品与空弦之间跳。
    // 连续 HOLD_SLOTS+1 个槽都零命中才真正释放。
    // R11.2 起默认 1：现场按住时仍闪，单靠 release 门限压不住。
    // R13 改为 2：用户反馈"太容易释放"，保持 2 槽（连续 3 槽零命中才回空弦，
    // ≈3.75 ms）。松手延迟增加 2.5 ms，人耳不可辨；换来按住期间音高不再跳空弦。
    // R15 改为 3（2 位寄存器上限）：用户再次反馈"还是不要轻易释放"，
    // 连续 4 槽零命中才回空弦（4×1.25 ms = 5 ms）。仍远低于人耳可辨的松手延迟。
    // 置 0 可恢复"零命中立即回空弦"的旧契约（回归里 tb_left_string_decoder 用 0）。
    parameter integer HOLD_SLOTS=3,
    parameter [79:0] CHANNEL_FRETS={5'd16,5'd15,5'd14,5'd13,5'd12,5'd11,
        5'd10,5'd9,5'd8,5'd7,5'd6,5'd5,5'd4,5'd3,5'd2,5'd1}
)(
    input wire clk_50m,reset,
    input wire [15:0] evidence,input wire evidence_valid,
    input wire [1:0] evidence_string,input wire evidence_fault,
    output reg [19:0] fret_bus,output reg [3:0] valid_mask,
    output reg [3:0] multi_mask,output reg [3:0] common_mask,
    output reg [3:0] fault_mask
);
    reg [4:0] count;
    reg [4:0] best_fret;
    reg [1:0] hold_count [0:3];
    integer channel;
    always @(posedge clk_50m) begin
        if(reset)begin
            fret_bus<=0;valid_mask<=0;multi_mask<=0;common_mask<=0;fault_mask<=0;
            for(channel=0;channel<4;channel=channel+1) hold_count[channel]<=2'd0;
        end else if(evidence_valid)begin
            count=0;best_fret=0;
            for(channel=0;channel<16;channel=channel+1)begin
                if(evidence[channel] && CHANNEL_FRETS[channel*5 +:5]!=0)begin
                    count=count+1'b1;
                    if(CHANNEL_FRETS[channel*5 +:5]>best_fret)
                        best_fret=CHANNEL_FRETS[channel*5 +:5];
                end
            end
            fault_mask[evidence_string]<=evidence_fault;
            multi_mask[evidence_string]<=count>1;
            common_mask[evidence_string]<=COMMON_CELLS!=0 && count>=COMMON_CELLS;
            if(evidence_fault || (COMMON_CELLS!=0 && count>=COMMON_CELLS))begin
                valid_mask[evidence_string]<=0;
                hold_count[evidence_string]<=2'd0;
            end else begin
                // Zero hits is a legal idle: the string keeps open-string
                // rights; any hits publish the highest fret among them.
                valid_mask[evidence_string]<=1;
                if(count!=0)begin
                    fret_bus[evidence_string*5 +:5]<=best_fret;
                    hold_count[evidence_string]<=2'd0;
                end else if(hold_count[evidence_string]>=HOLD_SLOTS[1:0])begin
                    // 连续 HOLD_SLOTS 槽零命中：确认松手，回空弦
                    fret_bus[evidence_string*5 +:5]<=5'd0;
                end else begin
                    // 单槽抖动：保持上一个品，不产生空弦音
                    hold_count[evidence_string]<=hold_count[evidence_string]+1'b1;
                end
            end
        end
    end
endmodule
