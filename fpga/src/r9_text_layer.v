// Centralized fonts: one synchronous ROM per size, shared by all labels/digits.
// Tile-map -> dynamic-token register -> font ROM -> bit test: four stages.
module r9_text_layer(
    input wire clk,input wire reset,input wire [10:0] x,input wire [9:0] y,input wire frame_start,
    input wire [1:0] i_mode,input wire [19:0] i_fret_bus,input wire [3:0] i_left_valid,input wire [3:0] i_left_fault,
    input wire [27:0] i_notes,input wire [31:0] i_vel,input wire [7:0] i_bow_speed,
    input wire [15:0] i_peak,input wire [15:0] i_rms,input wire [15:0] i_crest_tenths,
    input wire [15:0] i_ev_total,input wire [3:0] i_fire_flash,input wire [3:0] i_piezo_warm,
    input wire [1:0] i_gain_shift,input wire i_audio_ready,
    output reg hit,output reg [23:0] rgb
);
    function [7:0] hexchar;
        input [3:0] value;
        begin hexchar=value<10 ? 8'd48+value : 8'd55+value;end
    endfunction
`include "r9_note_hz.vh"
    reg [19:0] bcd[0:15];
`include "r9_text_dynamic.vh"
    reg [1:0] selected;
    reg [1:0] convert_state;
    reg [3:0] convert_index;
    reg convert_start;
    reg [15:0] convert_value;
    wire convert_done;
    wire [19:0] convert_bcd;
    stage_bcd u_bcd(.clk(clk),.reset(reset),.start(convert_start),.value(convert_value),.bcd(convert_bcd),.done(convert_done));
    wire [31:0] peak_wide={16'd0,i_peak},rms_wide={16'd0,i_rms};
    wire [31:0] peak_scaled=((peak_wide<<10)-(peak_wide<<4)-(peak_wide<<3)+32'd16384)>>15;
    wire [31:0] rms_scaled=((rms_wide<<10)-(rms_wide<<4)-(rms_wide<<3)+32'd16384)>>15;
    integer n;
    always @(posedge clk) begin
        if(reset) begin
            selected<=0;convert_state<=0;convert_index<=0;convert_start<=0;convert_value<=0;
            for(n=0;n<16;n=n+1) bcd[n]<=0;
        end else begin
            convert_start<=0;
            if(frame_start && convert_state==0) begin
                if(i_fire_flash[0]) selected<=0;
                else if(i_fire_flash[1]) selected<=1;
                else if(i_fire_flash[2]) selected<=2;
                else if(i_fire_flash[3]) selected<=3;
                convert_index<=0;convert_state<=1;
            end else if(convert_state==1) begin
                case(convert_index)
                0:convert_value<={14'd0,selected}+16'd1;
                1:convert_value<={11'd0,i_fret_bus[selected*5 +: 5]};
                2:convert_value<=note_hz(i_notes[selected*7 +: 7]);
                3:convert_value<={8'd0,i_bow_speed};
                4,5,6,7:convert_value<=note_hz(i_notes[(convert_index-4)*7 +: 7]);
                8,9,10,11:convert_value<={8'd0,i_vel[(convert_index-8)*8 +: 8]};
                12:convert_value<=peak_scaled[15:0];
                13:convert_value<=rms_scaled[15:0];
                14:convert_value<=i_crest_tenths;
                default:convert_value<=i_ev_total;
                endcase
                convert_start<=1;convert_state<=2;
            end else if(convert_state==2 && convert_done) begin
                bcd[convert_index]<=convert_bcd;
                if(convert_index==15) convert_state<=0;
                else begin convert_index<=convert_index+1'b1;convert_state<=1;end
            end
        end
    end
    function [23:0] palette;
        input [3:0] c;
        begin
            case(c)
            1:palette=24'hF1F3F6;2:palette=24'h4FD1C5;3:palette=24'hE9B353;
            4:palette=24'hE06A5E;5:palette=24'hACB5BF;6:palette=24'h727C86;
            7:palette=24'h6FC9DE;8:palette=24'hD9B36A;9:palette=24'h7FCB9A;10:palette=24'hC88BB4;
            default:palette=24'h48525C;
            endcase
        end
    endfunction
    reg [15:0] small_map[0:8191] /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] large_map[0:2047] /* synthesis syn_romstyle="block_rom" */;
    reg [7:0] font_small[0:2047] /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] font_large[0:4095] /* synthesis syn_romstyle="block_rom" */;
    initial begin
        $readmemh("src/rom/r9_small_map.hex",small_map);$readmemh("src/rom/r9_large_map.hex",large_map);
        $readmemh("src/rom/r9_font8x16.hex",font_small);$readmemh("src/rom/r9_font16x32.hex",font_large);
    end
    // LEVELS uses an 80px row pitch, so alternate big-number rows also start
    // on a half tile. Keep true 16x32 glyphs at their physical design position.
    wire levels_half=(x>=848 && x<1260) && ((y>=192 && y<240)||(y>=352 && y<400));
    wire [9:0] big_y=(y>=464 || levels_half) ? y-10'd16 : y;
    wire [12:0] small_address=({7'd0,y[9:4]}<<7)+({7'd0,y[9:4]}<<5)+{5'd0,x[10:3]};
    // The lower panels start half a 32px tile below the upper grid. Hide the
    // otherwise duplicated first half of their header in the inter-panel gap.
    wire [10:0] large_address=(y>=448 && y<464) ? 11'd2047 :
        ({6'd0,big_y[9:5]}<<6)+({6'd0,big_y[9:5]}<<4)+{4'd0,x[10:4]};
    reg [15:0] sm1,lg1;
    reg [2:0] sx1;
    reg [3:0] sy1,lx1;
    reg [4:0] ly1;
    reg [7:0] sc2,lc2;
    reg [2:0] sx2,sx3;
    reg [3:0] sy2,lx2,lx3;
    reg [4:0] ly2;
    reg [3:0] scol2,lcol2,scol3,lcol3;
    reg [7:0] sbits3;
    reg [15:0] lbits3;
    always @(posedge clk) begin
        sm1<=small_map[small_address];lg1<=large_map[large_address];
        sx1<=x[2:0];sy1<=y[3:0];lx1<=x[3:0];ly1<=big_y[4:0];
        sc2<=token_char(sm1[11:0]);lc2<=token_char(lg1[11:0]);
        sx2<=sx1;sy2<=sy1;lx2<=lx1;ly2<=ly1;scol2<=sm1[15:12];lcol2<=lg1[15:12];
        sbits3<=font_small[{sc2[6:0],sy2}];lbits3<=font_large[{lc2[6:0],ly2}];
        sx3<=sx2;lx3<=lx2;scol3<=scol2;lcol3<=lcol2;
        if(reset) begin hit<=0;rgb<=0;end
        else if(lbits3[15-lx3]) begin hit<=1;rgb<=palette(lcol3);end
        else if(sbits3[7-sx3]) begin hit<=1;rgb<=palette(scol3);end
        else begin hit<=0;rgb<=0;end
    end
endmodule
