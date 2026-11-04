// CEA 720p: 1280/110/40/220 by 720/5/5/20, positive sync.
module video_timing_720p (
    input i_clk, input i_reset,
    output reg [10:0] o_x, output reg [9:0] o_y,
    output o_de, output o_hsync, output o_vsync, output reg o_frame_start
);
    assign o_de = o_x < 1280 && o_y < 720;
    assign o_hsync = o_x >= 1390 && o_x < 1430;
    assign o_vsync = o_y >= 725 && o_y < 730;
    // Snapshot exchange occurs in vertical blank, not in the visible frame.
    // Predict the next counter state, so this registered pulse is cycle-exact
    // with the original x==0 && y==720 decode. Breaks the high-fanout
    // combinational counter-to-snapshot-enable path; no extra frame delay.
    always @(posedge i_clk)
        if (i_reset) o_frame_start <= 1'b0;
        else o_frame_start <= o_x == 1649 && o_y == 719;
    always @(posedge i_clk)
    begin
        if (i_reset)
        begin
            o_x <= 0;
            o_y <= 0;
        end
        else if (o_x == 1649)
        begin
            o_x <= 0;
            o_y <= o_y == 749 ? 0 : o_y + 1'b1;
        end
        else
            o_x <= o_x + 1'b1;
    end
endmodule
