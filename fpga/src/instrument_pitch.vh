// 共享音高函数：A4 = 440 Hz，周期格式 Q16.16，单位为音频采样点。
// SAMPLE_RATE_MILLIHZ 是实际 PT8211 采样率（mHz），与 FPGA 系统时钟不同。
// case 中的乘除数均为 elaboration 常量；综合时形成 MIDI→周期查表，
// 运行时不实现 64 位除法器。跨模块使用函数定义，每个模块独立展开。
// 无 include guard：本头文件需要在尤克里里、提琴各自的 module 内分别展开。
// 周期钳位到 8..DELAY_LINE_LENGTH；钳位音符不保证原始 MIDI 音准。
function [31:0] midi_period_q16;
    input [6:0] i_note;
    reg [63:0] r_scaled_period_q16;
    begin
        case (i_note)
            7'd0: r_scaled_period_q16 = (64'd391399059 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd1: r_scaled_period_q16 = (64'd369431518 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd2: r_scaled_period_q16 = (64'd348696920 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd3: r_scaled_period_q16 = (64'd329126065 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd4: r_scaled_period_q16 = (64'd310653639 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd5: r_scaled_period_q16 = (64'd293217990 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd6: r_scaled_period_q16 = (64'd276760929 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd7: r_scaled_period_q16 = (64'd261227531 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd8: r_scaled_period_q16 = (64'd246565957 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd9: r_scaled_period_q16 = (64'd232727273 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd10: r_scaled_period_q16 = (64'd219665295 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd11: r_scaled_period_q16 = (64'd207336429 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd12: r_scaled_period_q16 = (64'd195699529 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd13: r_scaled_period_q16 = (64'd184715759 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd14: r_scaled_period_q16 = (64'd174348460 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd15: r_scaled_period_q16 = (64'd164563033 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd16: r_scaled_period_q16 = (64'd155326819 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd17: r_scaled_period_q16 = (64'd146608995 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd18: r_scaled_period_q16 = (64'd138380464 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd19: r_scaled_period_q16 = (64'd130613766 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd20: r_scaled_period_q16 = (64'd123282978 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd21: r_scaled_period_q16 = (64'd116363636 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd22: r_scaled_period_q16 = (64'd109832647 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd23: r_scaled_period_q16 = (64'd103668214 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd24: r_scaled_period_q16 = (64'd97849765 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd25: r_scaled_period_q16 = (64'd92357879 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd26: r_scaled_period_q16 = (64'd87174230 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd27: r_scaled_period_q16 = (64'd82281516 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd28: r_scaled_period_q16 = (64'd77663410 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd29: r_scaled_period_q16 = (64'd73304497 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd30: r_scaled_period_q16 = (64'd69190232 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd31: r_scaled_period_q16 = (64'd65306883 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd32: r_scaled_period_q16 = (64'd61641489 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd33: r_scaled_period_q16 = (64'd58181818 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd34: r_scaled_period_q16 = (64'd54916324 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd35: r_scaled_period_q16 = (64'd51834107 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd36: r_scaled_period_q16 = (64'd48924882 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd37: r_scaled_period_q16 = (64'd46178940 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd38: r_scaled_period_q16 = (64'd43587115 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd39: r_scaled_period_q16 = (64'd41140758 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd40: r_scaled_period_q16 = (64'd38831705 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd41: r_scaled_period_q16 = (64'd36652249 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd42: r_scaled_period_q16 = (64'd34595116 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd43: r_scaled_period_q16 = (64'd32653441 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd44: r_scaled_period_q16 = (64'd30820745 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd45: r_scaled_period_q16 = (64'd29090909 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd46: r_scaled_period_q16 = (64'd27458162 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd47: r_scaled_period_q16 = (64'd25917054 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd48: r_scaled_period_q16 = (64'd24462441 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd49: r_scaled_period_q16 = (64'd23089470 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd50: r_scaled_period_q16 = (64'd21793557 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd51: r_scaled_period_q16 = (64'd20570379 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd52: r_scaled_period_q16 = (64'd19415852 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd53: r_scaled_period_q16 = (64'd18326124 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd54: r_scaled_period_q16 = (64'd17297558 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd55: r_scaled_period_q16 = (64'd16326721 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd56: r_scaled_period_q16 = (64'd15410372 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd57: r_scaled_period_q16 = (64'd14545455 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd58: r_scaled_period_q16 = (64'd13729081 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd59: r_scaled_period_q16 = (64'd12958527 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd60: r_scaled_period_q16 = (64'd12231221 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd61: r_scaled_period_q16 = (64'd11544735 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd62: r_scaled_period_q16 = (64'd10896779 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd63: r_scaled_period_q16 = (64'd10285190 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd64: r_scaled_period_q16 = (64'd9707926 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd65: r_scaled_period_q16 = (64'd9163062 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd66: r_scaled_period_q16 = (64'd8648779 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd67: r_scaled_period_q16 = (64'd8163360 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd68: r_scaled_period_q16 = (64'd7705186 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd69: r_scaled_period_q16 = (64'd7272727 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd70: r_scaled_period_q16 = (64'd6864540 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd71: r_scaled_period_q16 = (64'd6479263 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd72: r_scaled_period_q16 = (64'd6115610 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd73: r_scaled_period_q16 = (64'd5772367 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd74: r_scaled_period_q16 = (64'd5448389 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd75: r_scaled_period_q16 = (64'd5142595 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd76: r_scaled_period_q16 = (64'd4853963 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd77: r_scaled_period_q16 = (64'd4581531 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd78: r_scaled_period_q16 = (64'd4324390 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd79: r_scaled_period_q16 = (64'd4081680 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd80: r_scaled_period_q16 = (64'd3852593 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd81: r_scaled_period_q16 = (64'd3636364 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd82: r_scaled_period_q16 = (64'd3432270 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd83: r_scaled_period_q16 = (64'd3239632 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd84: r_scaled_period_q16 = (64'd3057805 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd85: r_scaled_period_q16 = (64'd2886184 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd86: r_scaled_period_q16 = (64'd2724195 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd87: r_scaled_period_q16 = (64'd2571297 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd88: r_scaled_period_q16 = (64'd2426982 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd89: r_scaled_period_q16 = (64'd2290766 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd90: r_scaled_period_q16 = (64'd2162195 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd91: r_scaled_period_q16 = (64'd2040840 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd92: r_scaled_period_q16 = (64'd1926297 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd93: r_scaled_period_q16 = (64'd1818182 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd94: r_scaled_period_q16 = (64'd1716135 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd95: r_scaled_period_q16 = (64'd1619816 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd96: r_scaled_period_q16 = (64'd1528903 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd97: r_scaled_period_q16 = (64'd1443092 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd98: r_scaled_period_q16 = (64'd1362097 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd99: r_scaled_period_q16 = (64'd1285649 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd100: r_scaled_period_q16 = (64'd1213491 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd101: r_scaled_period_q16 = (64'd1145383 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd102: r_scaled_period_q16 = (64'd1081097 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd103: r_scaled_period_q16 = (64'd1020420 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd104: r_scaled_period_q16 = (64'd963148 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd105: r_scaled_period_q16 = (64'd909091 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd106: r_scaled_period_q16 = (64'd858068 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd107: r_scaled_period_q16 = (64'd809908 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd108: r_scaled_period_q16 = (64'd764451 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd109: r_scaled_period_q16 = (64'd721546 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd110: r_scaled_period_q16 = (64'd681049 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd111: r_scaled_period_q16 = (64'd642824 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd112: r_scaled_period_q16 = (64'd606745 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd113: r_scaled_period_q16 = (64'd572691 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd114: r_scaled_period_q16 = (64'd540549 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd115: r_scaled_period_q16 = (64'd510210 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd116: r_scaled_period_q16 = (64'd481574 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd117: r_scaled_period_q16 = (64'd454545 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd118: r_scaled_period_q16 = (64'd429034 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd119: r_scaled_period_q16 = (64'd404954 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd120: r_scaled_period_q16 = (64'd382226 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd121: r_scaled_period_q16 = (64'd360773 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd122: r_scaled_period_q16 = (64'd340524 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd123: r_scaled_period_q16 = (64'd321412 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd124: r_scaled_period_q16 = (64'd303373 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd125: r_scaled_period_q16 = (64'd286346 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd126: r_scaled_period_q16 = (64'd270274 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            7'd127: r_scaled_period_q16 = (64'd255105 * SAMPLE_RATE_MILLIHZ + 64'd24414062) / 64'd48828125;
            default: r_scaled_period_q16 = 64'd0;
        endcase
        if (r_scaled_period_q16 < (64'd8 << 16))
            midi_period_q16 = 32'd524288;
        else if (r_scaled_period_q16 > (DELAY_LINE_LENGTH * 64'd65536))
            midi_period_q16 = DELAY_LINE_LENGTH * 32'd65536;
        else
            midi_period_q16 = r_scaled_period_q16[31:0];
    end
endfunction

// 整数周期接口保留给诊断；真实模型另减滤波群延迟并使用 Q0.8 小数。
function [15:0] midi_to_period;
    input [6:0] i_note;
    reg [31:0] r_period_q16;
    begin
        r_period_q16 = midi_period_q16(i_note);
        midi_to_period = r_period_q16[31:16];
    end
endfunction
