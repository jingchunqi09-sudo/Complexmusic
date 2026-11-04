// External PT8211 BCK domain, 32 BCK/frame. System/model clock stays 50MHz.
// Bundled-data mailbox: producer holds PCM/tag until consumer acknowledgement.
// A frame requests its successor at bit0 (32 BCK before the next load); no free-running
// second sample clock, periodic drops, rate conversion or multi-bit CDC sampling.
module pt8211_external_tx (
input i_clk,
input i_reset,
input i_bck,
input signed [15:0] i_sample,
input i_sample_valid,
input i_sample_event,
input i_sample_ready,
input [31:0] i_sample_first_sequence, input [15:0] i_sample_event_count,
output reg [31:0] o_frame_first_sequence, output reg [15:0] o_frame_event_count,
input [31:0] i_sample_sequence, input [63:0] i_sample_event_clock,
output reg [31:0] o_frame_event_sequence, output reg [63:0] o_frame_event_clock,
output o_hp_bck,
output reg o_hp_ws,
output reg o_hp_din,
output reg o_sample_tick,
output reg signed [15:0] o_frame_pcm,
output reg o_frame_pcm_valid,
output reg o_left_word_complete,
output reg o_frame_word_complete,
output reg o_event_frame_complete,
output reg [31:0] o_underrun_count,
output reg [31:0] o_overrun_count,
output reg [31:0] o_frame_sequence
);
assign o_hp_bck = i_bck;
// Reset assertion is common; release is local to the falling BCK edge.
reg [2:0] r_audio_release;
always @(negedge i_bck or posedge i_reset)
if (i_reset) r_audio_release <= 0;
else r_audio_release <= {r_audio_release[1:0],1'b1};
wire w_audio_reset;
assign w_audio_reset = !r_audio_release[2];

reg r_request_toggle;
reg [2:0] r_request_sync;
reg r_request_seen;
reg r_requested;
reg signed [15:0] r_pcm_hold;
reg r_event_hold;
reg [31:0] r_sequence_hold, r_first_hold;
reg [63:0] r_clock_hold;
reg [15:0] r_count_hold;
reg [31:0] r_frame_sequence_tag, r_frame_first_tag;
reg [63:0] r_frame_clock_tag;
reg [15:0] r_frame_count_tag;
reg r_response_toggle;
reg [2:0] r_ack_sync;
reg r_ack_toggle;
reg [2:0] r_response_sync;
reg [4:0] r_next_bit;
reg [15:0] r_frame_sample;
reg r_frame_event;
reg r_frame_started;
reg [15:0] r_serial_shift;
reg r_frame_toggle;
reg r_underrun_toggle;
reg r_started;

// Requests and acknowledgements are the only producer-domain control CDC.
always @(posedge i_clk)
begin
    if (i_reset)
    begin
        r_request_sync<=0; r_request_seen<=0; r_requested<=0;
        r_ack_sync<=0; r_pcm_hold<=0; r_event_hold<=0;
        r_sequence_hold<=0; r_clock_hold<=0; r_first_hold<=0; r_count_hold<=0;
        r_response_toggle<=0; o_sample_tick<=0; o_overrun_count<=0;
    end
    else
    begin
        r_request_sync<={r_request_sync[1:0],r_request_toggle};
        r_ack_sync<={r_ack_sync[1:0],r_ack_toggle};
        o_sample_tick<=0;
        if (r_request_sync[2]!=r_request_seen)
        begin
            r_request_seen<=r_request_sync[2];
            if (i_sample_ready && r_response_toggle==r_ack_sync[2])
            begin
                o_sample_tick<=1;
                r_requested<=1;
                if (r_requested) o_overrun_count<=o_overrun_count+1'b1;
            end
            else if (i_sample_ready) o_overrun_count<=o_overrun_count+1'b1;
        end
        if (i_sample_valid && r_requested && r_request_sync[2]==r_request_seen)
        begin
            r_pcm_hold<=i_sample;
            r_event_hold<=i_sample_event;
            r_sequence_hold<=i_sample_sequence; r_clock_hold<=i_sample_event_clock;
            r_first_hold<=i_sample_first_sequence; r_count_hold<=i_sample_event_count;
            r_response_toggle<=~r_response_toggle;
            r_requested<=0;
        end
    end
end
always @(negedge i_bck or posedge i_reset)
begin
    if (i_reset)
    begin
        r_response_sync<=0; r_ack_toggle<=0; r_request_toggle<=0;
        r_next_bit<=0; r_frame_sample<=0; r_frame_event<=0; r_frame_started<=0;
        r_frame_sequence_tag<=0; r_frame_clock_tag<=0; r_frame_first_tag<=0; r_frame_count_tag<=0;
        r_serial_shift<=0; o_hp_ws<=0; o_hp_din<=0;
        r_frame_toggle<=0; r_underrun_toggle<=0; r_started<=0;
    end
    else if (w_audio_reset)
    begin
        r_response_sync<=0; r_ack_toggle<=0; r_request_toggle<=0;
        r_next_bit<=0; r_frame_sample<=0; r_frame_event<=0; r_frame_started<=0;
        r_frame_sequence_tag<=0; r_frame_clock_tag<=0; r_frame_first_tag<=0; r_frame_count_tag<=0;
        r_serial_shift<=0; o_hp_ws<=0; o_hp_din<=0;
        r_frame_toggle<=0; r_underrun_toggle<=0; r_started<=0;
    end
    else
    begin
        r_response_sync<={r_response_sync[1:0],r_response_toggle};
        if (r_next_bit==0)
        begin
            r_frame_started <= 1;
            // At least three BCK edges have elapsed since publication.
            // The bus remains held until this acknowledgement returns.
            if (r_response_sync[2]!=r_ack_toggle)
            begin
                r_frame_sample<=r_pcm_hold;
                r_frame_event<=r_event_hold;
                r_frame_sequence_tag<=r_sequence_hold; r_frame_clock_tag<=r_clock_hold;
                r_frame_first_tag<=r_first_hold; r_frame_count_tag<=r_count_hold;
                r_serial_shift<={r_pcm_hold[14:0],1'b0};
                o_hp_din<=r_pcm_hold[15];
                r_ack_toggle<=r_response_sync[2];
                r_started<=1;
            end
            else
            begin
                // Zero-fill failed deadlines; do not repeat a stale bow sample.
                r_frame_sample<=0; r_frame_event<=0;
                r_frame_sequence_tag<=0; r_frame_clock_tag<=0; r_frame_first_tag<=0; r_frame_count_tag<=0;
                r_serial_shift<=0; o_hp_din<=0;
                if (r_started) r_underrun_toggle<=~r_underrun_toggle;
            end
            o_hp_ws<=1;
            r_frame_toggle<=~r_frame_toggle;
        end
        else if (r_next_bit==16)
        begin
            r_serial_shift<={r_frame_sample[14:0],1'b0};
            o_hp_din<=r_frame_sample[15]; o_hp_ws<=0;
        end
        else
        begin
            o_hp_din<=r_serial_shift[15];
            r_serial_shift<={r_serial_shift[14:0],1'b0};
        end
        if (r_next_bit==0) r_request_toggle<=~r_request_toggle;
        r_next_bit<=r_next_bit+1'b1;
    end
end
// Completion markers refer to actual receiver rising edges, then cross as
// toggles to 50MHz. They are never inferred from model completion timing.
reg r_left_toggle, r_complete_toggle, r_event_toggle;
always @(posedge i_bck or posedge i_reset)
begin
    if (i_reset)
    begin
        r_left_toggle<=0; r_complete_toggle<=0; r_event_toggle<=0;
    end
    else if (w_audio_reset)
    begin
        r_left_toggle<=0; r_complete_toggle<=0; r_event_toggle<=0;
    end
    else
    begin
        if (r_frame_started && r_next_bit==16) r_left_toggle<=~r_left_toggle;
        if (r_frame_started && r_next_bit==0)
        begin
            r_complete_toggle<=~r_complete_toggle;
            if (r_frame_event) r_event_toggle<=~r_event_toggle;
        end
    end
end
reg [2:0] r_frame_sync, r_left_sync, r_complete_sync, r_event_sync, r_under_sync;
reg r_frame_seen, r_left_seen, r_complete_seen, r_event_seen, r_under_seen;
always @(posedge i_clk)
begin
    if (i_reset)
    begin
        r_frame_sync<=0; r_left_sync<=0; r_complete_sync<=0;
        r_event_sync<=0; r_under_sync<=0;
        r_frame_seen<=0; r_left_seen<=0; r_complete_seen<=0;
        r_event_seen<=0; r_under_seen<=0;
        o_frame_pcm<=0; o_frame_pcm_valid<=0; o_left_word_complete<=0;
        o_frame_word_complete<=0; o_event_frame_complete<=0;
        o_underrun_count<=0; o_frame_sequence<=0;
        o_frame_event_sequence<=0; o_frame_event_clock<=0;
        o_frame_first_sequence<=0; o_frame_event_count<=0;
    end
    else
    begin
        r_frame_sync<={r_frame_sync[1:0],r_frame_toggle};
        r_left_sync<={r_left_sync[1:0],r_left_toggle};
        r_complete_sync<={r_complete_sync[1:0],r_complete_toggle};
        r_event_sync<={r_event_sync[1:0],r_event_toggle};
        r_under_sync<={r_under_sync[1:0],r_underrun_toggle};
        o_frame_pcm_valid<=0; o_left_word_complete<=0;
        o_frame_word_complete<=0; o_event_frame_complete<=0;
        if (r_frame_sync[2]!=r_frame_seen)
        begin
            r_frame_seen<=r_frame_sync[2]; o_frame_pcm<=r_frame_sample;
            o_frame_event_sequence<=r_frame_sequence_tag; o_frame_event_clock<=r_frame_clock_tag;
            o_frame_first_sequence<=r_frame_first_tag; o_frame_event_count<=r_frame_count_tag;
            o_frame_pcm_valid<=1; o_frame_sequence<=o_frame_sequence+1'b1;
        end
        if (r_left_sync[2]!=r_left_seen)
        begin
            r_left_seen<=r_left_sync[2]; o_left_word_complete<=1;
        end
        if (r_complete_sync[2]!=r_complete_seen)
        begin
            r_complete_seen<=r_complete_sync[2]; o_frame_word_complete<=1;
        end
        if (r_event_sync[2]!=r_event_seen)
        begin
            r_event_seen<=r_event_sync[2]; o_event_frame_complete<=1;
        end
        if (r_under_sync[2]!=r_under_seen)
        begin
            r_under_seen<=r_under_sync[2]; o_underrun_count<=o_underrun_count+1'b1;
        end
    end
end
endmodule
