// No ready signal towards audio. Two 256x32 min/max banks; one frozen for video.
// Toggle handshake: system holds bundled metadata until next completed capture.
module display_observer_cdc #(
    parameter integer BIN_SAMPLES = 8
) (
    input i_sys_clk, input i_sys_reset,
    input i_pcm_valid, input signed [15:0] i_pcm,
    input [27:0] i_notes, input [3:0] i_gates, input [3:0] i_instruments,
    input [63:0] i_open_notes,
    input [31:0] i_bow_speeds, input [95:0] i_bow_positions, input [3:0] i_directions,
    input [31:0] i_velocities, input [31:0] i_latency_us, input i_audio_ready,
    input i_pixel_clk, input i_pixel_reset, input i_frame_start,
    input [7:0] i_wave_address,
    output reg signed [15:0] o_wave_sample,
    output reg signed [15:0] o_wave_max,
    output reg [15:0] o_peak, output reg [15:0] o_rms,
    output reg [31:0] o_bow_speeds, output reg [95:0] o_bow_positions,
    output reg [3:0] o_directions,
    output reg [27:0] o_notes, output reg [3:0] o_gates,
    output reg [63:0] o_open_notes,
    output reg [3:0] o_instruments, output reg [31:0] o_velocities,
    output reg [31:0] o_latency_us, output reg o_audio_ready,
    output reg o_capture_valid
);
    reg [31:0] r_wave_ram [0:511];
    reg [3:0] r_bin_count;
    reg signed [15:0] r_min, r_max;
    wire signed [15:0] w_min, w_max;
    wire [15:0] w_abs;
    wire [31:0] w_square;
    reg [42:0] r_square_sum;
    reg [15:0] r_peak, r_hold_peak, r_hold_rms;
    reg [31:0] r_sqrt_value;
    reg [33:0] r_sqrt_remainder;
    reg [15:0] r_sqrt_root;
    reg [4:0] r_sqrt_count;
    wire [33:0] w_sqrt_shift, w_sqrt_trial;
    wire w_sqrt_take;
    reg [31:0] r_hold_speeds;
    reg [95:0] r_hold_positions;
    reg [3:0] r_hold_directions;
    assign w_min = r_bin_count == 0 || i_pcm < r_min ? i_pcm : r_min;
    assign w_max = r_bin_count == 0 || i_pcm > r_max ? i_pcm : r_max;
    assign w_abs = i_pcm[15] ? -i_pcm : i_pcm;
    assign w_square = $signed(i_pcm) * $signed(i_pcm);
    assign w_sqrt_shift = {r_sqrt_remainder[31:0],r_sqrt_value[31:30]};
    assign w_sqrt_trial = {16'd0,r_sqrt_root,2'b01};
    assign w_sqrt_take = w_sqrt_shift >= w_sqrt_trial;
    reg r_request, r_ack, r_seen;
    reg [1:0] r_request_sync, r_ack_sync;
    reg r_capture_busy, r_completed_bank, r_display_bank;
    reg [7:0] r_write_index;
    reg [27:0] r_hold_notes;
    reg [63:0] r_hold_open_notes;
    reg [3:0] r_hold_gates, r_hold_instruments;
    reg [31:0] r_hold_velocities, r_hold_latency;
    reg r_hold_ready;
    always @(posedge i_sys_clk)
    begin
        if (i_sys_reset)
        begin
            r_request_sync <= 0;
            r_ack <= 0; r_seen <= 0;
            r_capture_busy <= 0; r_completed_bank <= 0; r_write_index <= 0;
            r_hold_notes <= 0; r_hold_gates <= 0; r_hold_instruments <= 0;
            r_hold_open_notes <= 0;
            r_hold_velocities <= 0; r_hold_latency <= 0; r_hold_ready <= 0;
            r_bin_count<=0; r_min<=0; r_max<=0; r_peak<=0; r_square_sum<=0;
            r_hold_peak<=0; r_hold_rms<=0; r_sqrt_count<=0;
            r_sqrt_value<=0; r_sqrt_remainder<=0; r_sqrt_root<=0;
            r_hold_speeds<=0; r_hold_positions<=0; r_hold_directions<=0;
        end
        else
        begin
            r_request_sync <= {r_request_sync[0],r_request};
            if (!r_capture_busy && r_sqrt_count==0 && r_request_sync[1] != r_seen)
            begin
                r_seen <= r_request_sync[1];
                r_capture_busy <= 1;
                r_write_index <= 0;
                r_bin_count<=0; r_peak<=0; r_square_sum<=0;
                r_hold_notes <= i_notes; r_hold_gates <= i_gates;
                r_hold_open_notes <= i_open_notes;
                r_hold_instruments <= i_instruments; r_hold_velocities <= i_velocities;
                r_hold_latency <= i_latency_us; r_hold_ready <= i_audio_ready;
                r_hold_speeds<=i_bow_speeds; r_hold_positions<=i_bow_positions;
                r_hold_directions<=i_directions;
            end
            else if (r_capture_busy && i_pcm_valid)
            begin
                r_min<=w_min; r_max<=w_max;
                r_peak<=w_abs > r_peak ? w_abs : r_peak;
                r_square_sum<=r_square_sum + w_square;
                if (r_bin_count == BIN_SAMPLES-1)
                begin
                    r_bin_count<=0;
                    if (r_write_index == 255)
                    begin
                        r_completed_bank <= ~r_completed_bank;
                        r_capture_busy <= 0;
                        r_hold_peak<=w_abs > r_peak ? w_abs : r_peak;
                        r_sqrt_value<=(r_square_sum + w_square)/(256*BIN_SAMPLES);
                        r_sqrt_remainder<=0; r_sqrt_root<=0; r_sqrt_count<=16;
                    end
                    else r_write_index <= r_write_index + 1'b1;
                end
                else r_bin_count<=r_bin_count+1'b1;
            end
            if(r_sqrt_count!=0)
            begin
                r_sqrt_value<={r_sqrt_value[29:0],2'b00};
                r_sqrt_remainder<=w_sqrt_take ? w_sqrt_shift-w_sqrt_trial : w_sqrt_shift;
                r_sqrt_root<={r_sqrt_root[14:0],w_sqrt_take};
                r_sqrt_count<=r_sqrt_count-1'b1;
                if(r_sqrt_count==1)
                begin
                    r_hold_rms<={r_sqrt_root[14:0],w_sqrt_take};
                    r_ack<=r_seen;
                end
            end
        end
    end
    // No RAM reset; validity hides uninitialised contents from renderer.
    always @(posedge i_sys_clk)
        if (!i_sys_reset && r_capture_busy && i_pcm_valid && r_bin_count==BIN_SAMPLES-1)
            r_wave_ram[{~r_completed_bank,r_write_index}] <= {w_max,w_min};
    always @(posedge i_pixel_clk)
        {o_wave_max,o_wave_sample} <= r_wave_ram[{r_display_bank,i_wave_address}];

    always @(posedge i_pixel_clk)
    begin
        if (i_pixel_reset)
        begin
            r_request <= 0; r_ack_sync <= 0; r_display_bank <= 0;
            o_notes <= 0; o_gates <= 0; o_instruments <= 0; o_velocities <= 0;
            o_open_notes <= 0;
            o_latency_us <= 0; o_audio_ready <= 0; o_capture_valid <= 0;
            o_peak<=0; o_rms<=0; o_bow_speeds<=0; o_bow_positions<=0; o_directions<=0;
        end
        else
        begin
            r_ack_sync <= {r_ack_sync[0],r_ack};
            if (i_frame_start && r_ack_sync[1] == r_request)
            begin
                // Request=0 at power-up is not a completed capture.
                if (r_request != 0 || o_capture_valid)
                begin
                    r_display_bank <= r_completed_bank;
                    o_notes <= r_hold_notes; o_gates <= r_hold_gates;
                    o_open_notes <= r_hold_open_notes;
                    o_instruments <= r_hold_instruments; o_velocities <= r_hold_velocities;
                    o_latency_us <= r_hold_latency; o_audio_ready <= r_hold_ready;
                    o_capture_valid <= 1;
                    o_peak<=r_hold_peak; o_rms<=r_hold_rms;
                    o_bow_speeds<=r_hold_speeds; o_bow_positions<=r_hold_positions;
                    o_directions<=r_hold_directions;
                end
                r_request <= ~r_request;
            end
        end
    end
    // The 4-bit bin counter is an intentional 0..15 contract.  Keep the
    // guard simulation/elaboration-only so the default synthesis netlist has
    // no runtime error circuitry, while invalid overrides fail immediately.
    // synthesis translate_off
    initial
    begin
        if (BIN_SAMPLES < 1 || BIN_SAMPLES > 16)
        begin
            $display("FAIL display_observer_cdc: BIN_SAMPLES must be in [1,16], got %0d", BIN_SAMPLES);
            $fatal(1);
        end
    end
    // synthesis translate_on
endmodule
