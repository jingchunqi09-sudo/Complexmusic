// R8 causal piezo transient. Evidence: algorithm/predictor_findings.md.
// Q8 states retain sub-code decay; smooth low-frequency attacks can be missed.
`timescale 1ns/1ps
`default_nettype none
module piezo_transient_core #(
    parameter integer GATE_Q8=1946, INV=172, WARM=1860, GUARD=246
)(
    input wire clk,reset,sample_valid,input wire [11:0] sample_code,
    output reg candidate,metric_valid,
    output wire [19:0] transient_level,acoustic_level,
    output wire [15:0] ay,output wire warm_done
);
    reg [11:0] x1,x2,x3;
    reg signed [23:0] hp_state,lp_state,lp_r;
    reg [14:0] residual_r;
    reg p_valid;
    reg [23:0] fast_q8,slow_q8,base_q8,acoustic_q8;
    reg [10:0] warm_count;
    reg [7:0] guard_count;
    reg [31:0] transient_product,acoustic_product;
    wire signed [15:0] sx=$signed({4'd0,sample_code});
    wire signed [15:0] sx1=$signed({4'd0,x1});
    wire signed [15:0] sx2=$signed({4'd0,x2});
    wire signed [15:0] sx3=$signed({4'd0,x3});
    wire signed [15:0] d3=sx-(sx1<<<1)-sx1+(sx2<<<1)+sx2-sx3;
    wire [15:0] d3_abs=d3[15] ? -d3 : d3;
    // 235/256 HP and 3/4 LP supply velocity/display, not the decision.
    wire signed [24:0] hd=(($signed({1'b0,sample_code})-$signed({1'b0,x1}))<<<8)+hp_state;
    wire signed [32:0] hd_ext={{8{hd[24]}},hd};
    wire signed [32:0] hp_calc=((hd_ext<<<8)-(hd_ext<<<4)-(hd_ext<<<2)-hd_ext)>>>8;
    wire signed [25:0] lp_ext={{2{lp_state[23]}},lp_state};
    wire signed [23:0] hp_next=hp_calc[23:0];
    wire signed [25:0] lp_calc=($signed({{2{hp_next[23]}},hp_next})+(lp_ext<<<1)+lp_ext)>>>2;
    wire [23:0] abs_lp=lp_r[23] ? -lp_r : lp_r;
    wire [23:0] target_q8={1'b0,residual_r,8'd0};
    wire signed [24:0] df=$signed({1'b0,target_q8})-$signed({1'b0,fast_q8});
    wire signed [24:0] ds=$signed({1'b0,target_q8})-$signed({1'b0,slow_q8});
    wire signed [24:0] da=$signed({1'b0,abs_lp})-$signed({1'b0,acoustic_q8});
    wire signed [24:0] fast_sum=$signed({1'b0,fast_q8})+(df>>>3);
    wire signed [24:0] slow_sum=$signed({1'b0,slow_q8})+(ds>>>7);
    wire signed [24:0] acoustic_sum=$signed({1'b0,acoustic_q8})+(da>>>3);
    wire [23:0] fast_next=fast_sum[23:0];
    wire [23:0] slow_next=slow_sum[23:0];
    wire [23:0] acoustic_next=acoustic_sum[23:0];
    // ceil(base/256): baseline cannot freeze below one code.
    wire [23:0] base_decay=base_q8-(base_q8>>8)-((|base_q8[7:0])?24'd1:24'd0);
    wire [23:0] base_floor=fast_q8>>1;
    wire [23:0] base_track=base_decay>base_floor ? base_decay : base_floor;
    wire [23:0] compare_base=base_q8>slow_q8 ? base_q8 : slow_q8;
    wire [25:0] three_base={2'd0,compare_base}+{1'd0,compare_base,1'b0};
    wire hit=warm_done && guard_count==0 && fast_q8>GATE_Q8 && {2'd0,fast_q8}>three_base;
    wire [23:0] base_hit=fast_q8<<1;
    function [31:0] normalize;
        input [23:0] v;integer k;
        begin
            normalize=32'd0;
            for(k=0;k<8;k=k+1)
                if((INV>>k)&1) normalize=normalize+({8'd0,v}<<k);
        end
    endfunction
    assign transient_level=transient_product[31:12]; // Q4 normalized 256/REF
    assign acoustic_level=acoustic_product[31:12];
    assign ay=abs_lp[23:8];
    assign warm_done=warm_count>=WARM;
    always @(posedge clk) begin
        if(reset) begin
            x1<=0;x2<=0;x3<=0;hp_state<=0;lp_state<=0;lp_r<=0;
            residual_r<=0;p_valid<=0;candidate<=0;metric_valid<=0;
            fast_q8<=0;slow_q8<=0;base_q8<=0;acoustic_q8<=0;
            warm_count<=0;guard_count<=0;transient_product<=0;acoustic_product<=0;
        end else begin
            p_valid<=sample_valid;candidate<=0;metric_valid<=p_valid;
            if(sample_valid) begin
                x3<=x2;x2<=x1;x1<=sample_code;
                residual_r<=d3_abs[14:0];hp_state<=hp_calc[23:0];lp_r<=lp_calc[23:0];
            end
            if(p_valid) begin
                lp_state<=lp_r;
                fast_q8<=fast_next;slow_q8<=slow_next;acoustic_q8<=acoustic_next;
                transient_product<=normalize(fast_q8);acoustic_product<=normalize(acoustic_q8);
                if(!warm_done) warm_count<=warm_count+1'b1;
                if(guard_count!=0) guard_count<=guard_count-1'b1;
                base_q8<=base_track;
                if(hit) begin
                    candidate<=1;guard_count<=GUARD;
                    base_q8<=base_q8>base_hit ? base_q8 : base_hit;
                end
            end
        end
    end
endmodule
`default_nettype wire
