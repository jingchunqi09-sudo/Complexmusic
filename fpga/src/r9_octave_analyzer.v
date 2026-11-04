// Audio observation only: no enable or ready ever feeds the performer/audio path.
// Eight RBJ constant-peak-gain bandpass filters share one signed 27x18 multiplier.
// Q2.16 coefficients; Q9 signal with 2 headroom bits, 47-bit state accumulators.
// Each PCM sample takes 81 system cycles; actual input gap is 1024 cycles.
module r9_octave_analyzer(
    input wire clk, input wire reset,
    input wire sample_valid, input wire signed [15:0] sample,
    output reg [63:0] bands,
    output reg overrun
);
`include "r9_filter_coeff.vh"
    reg signed [46:0] z1[0:7],z2[0:7];
    reg [26:0] envelope[0:7];
    reg signed [26:0] x,y,mul_a;
    reg signed [17:0] mul_b;
    reg signed [44:0] product;
    reg signed [46:0] b2x;
    reg [3:0] state;
    reg [2:0] band;
    reg signed [46:0] accumulator;
    wire signed [46:0] scaled=accumulator >>> 16;
    wire signed [26:0] y_next=(scaled > 47'sd67108863) ? 27'sd67108863 :
                                      (scaled < -47'sd67108864) ? -27'sd67108864 : scaled[26:0];
    wire [26:0] magnitude=y_next[26] ? -y_next : y_next;
    wire [26:0] release_amount=(envelope[band] >> 11)==0 ? 27'd1 : envelope[band] >> 11;
    wire [26:0] released=envelope[band]>release_amount ? envelope[band]-release_amount : 27'd0;
    wire [26:0] env_next=magnitude>released ? magnitude : released;
    // Direct leading-bit cases avoid a priority encoder + variable shifter
    // in one cycle. Bars are a visual logarithmic scale, not measured dBFS.
    function [7:0] meter;
        input [26:0] level_q9;
        reg [17:0] level;
        begin
            level=level_q9[26:9];
            casez(level)
            18'b1?????????????????: meter=8'd255;
            18'b01????????????????: meter=8'd255;
            18'b001???????????????: meter=8'd240+{4'd0,level[14 -: 4]};
            18'b0001??????????????: meter=8'd220+{4'd0,level[13 -: 4]};
            18'b00001?????????????: meter=8'd200+{4'd0,level[12 -: 4]};
            18'b000001????????????: meter=8'd180+{4'd0,level[11 -: 4]};
            18'b0000001???????????: meter=8'd160+{4'd0,level[10 -: 4]};
            18'b00000001??????????: meter=8'd140+{4'd0,level[9 -: 4]};
            18'b000000001?????????: meter=8'd120+{4'd0,level[8 -: 4]};
            18'b0000000001????????: meter=8'd100+{4'd0,level[7 -: 4]};
            18'b00000000001???????: meter=8'd80+{4'd0,level[6 -: 4]};
            18'b000000000001??????: meter=8'd60+{4'd0,level[5 -: 4]};
            18'b0000000000001?????: meter=8'd40+{4'd0,level[4 -: 4]};
            18'b00000000000001????: meter=8'd20+{4'd0,level[3 -: 4]};
            18'b000000000000001???: meter={4'd0,level[2:0],1'b0};
            default: meter=0;
            endcase
        end
    endfunction
    integer j;
    always @(posedge clk) begin
        product<=mul_a*mul_b;
        if(reset) begin
            state<=0;band<=0;x<=0;y<=0;mul_a<=0;mul_b<=0;product<=0;b2x<=0;
            bands<=0;overrun<=0;accumulator<=0;
            for(j=0;j<8;j=j+1) begin z1[j]<=0;z2[j]<=0;envelope[j]<=0;end
        end else begin
            if(sample_valid && state!=0) overrun<=1;
            case(state)
            0: if(sample_valid) begin x<={{2{sample[15]}},sample,9'd0};band<=0;state<=1;end
            1: begin mul_a<=x;mul_b<=coefficient(band,0);state<=2;end
            2: state<=3;
            3: begin accumulator<=$signed({{2{product[44]}},product})+z1[band];state<=4;end
            4: begin
                y<=y_next;envelope[band]<=env_next;
                mul_a<=y_next;mul_b<=coefficient(band,1);state<=5;
            end
            5: begin bands[band*8 +: 8]<=meter(envelope[band]);state<=6;end
            6: begin
                z1[band]<=z2[band]-$signed({{2{product[44]}},product});
                mul_a<=x;mul_b<=-coefficient(band,0);state<=7;
            end
            7: state<=8;
            8: begin b2x<={{2{product[44]}},product};mul_a<=y;mul_b<=coefficient(band,2);state<=9;end
            9: state<=10;
            10: begin
                z2[band]<=b2x-$signed({{2{product[44]}},product});
                if(band==7) state<=0;
                else begin band<=band+1'b1;state<=1;end
            end
            default:state<=0;
            endcase
        end
    end
endmodule
