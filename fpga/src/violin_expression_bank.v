// R9: four independent expression states share one arithmetic pipeline and
// one MIDI lookup. All inputs are snapshotted. Each output lane is updated
// while busy; consumers latch the complete bus only at o_valid (48 clocks).
// Matches settled R8 period arithmetic, including its equal-target corner.
// i_start while busy is ignored. A transaction takes 48 clocks.
module violin_expression_bank #(
    parameter integer DELAY_LINE_LENGTH=1024,
    parameter integer SAMPLE_RATE_MILLIHZ=48828125
)(
    input i_clk, input i_reset, input i_start,
    input [27:0] i_note, input [27:0] i_pluck_note,
    input [3:0] i_gate, input [3:0] i_auto,
    input [31:0] i_depth, input [31:0] i_rate, input [31:0] i_glide,
    output reg [127:0] o_period, output reg [191:0] o_pluck_parameters,
    output o_ready, output reg o_valid
);
`include "src/instrument_pitch.vh"
`include "src/instrument_excitation.vh"
// One synchronous table serves both note streams. Prefetch the next bowed
// note on transaction acceptance / lane advance; phase 1 consumes its period.
// Subsequent reads serve the plucked note committed at phase 11. No extra
// pipeline stage or change to the 48-clock transaction is needed.
reg [47:0] pluck_rom [0:127] /* synthesis syn_romstyle = "block_rom" */;
reg [47:0] pluck_read;
reg [1:0] lane;
reg [27:0] pluck_notes;
integer rom_index;
wire [6:0] lookup_note;
initial
begin
    for(rom_index=0;rom_index<128;rom_index=rom_index+1)
        pluck_rom[rom_index]={excitation_step_q16(rom_index),midi_period_q16(rom_index)};
end
always @(posedge i_clk)
begin
    pluck_read<=pluck_rom[lookup_note];
end
localparam integer PHASE_PER_DECIHZ=64'd4294967296000/(SAMPLE_RATE_MILLIHZ*10);
localparam integer AUTO_DELAY_SAMPLES=SAMPLE_RATE_MILLIHZ/3000;
// The only use of held age is the auto-vibrato delay/ramp. Beyond this
// threshold it has no observable effect, so retain a saturated bounded age.
localparam integer AGE_MAX=AUTO_DELAY_SAMPLES+768;
localparam integer AGE_WIDTH=$clog2(AGE_MAX+1);
// Validity covers only current and goal; other physical states retain reset.
reg [3:0] lane_valid;
reg [3:0] phase;
reg [27:0] notes;
reg [3:0] gates, autos, previous_gate;
reg [31:0] depths, rates, glides;
reg [31:0] current [0:3];
reg [31:0] goal [0:3];
reg [31:0] step [0:3];
reg [31:0] oscillator [0:3];
reg [AGE_WIDTH-1:0] held [0:3];
reg [AGE_WIDTH-1:0] next_held;
reg [31:0] target, origin, old_goal, old_step, old_phase;
reg [31:0] distance, new_step, new_current, new_phase;
reg up, retarget, snap, gate, old_gate;
reg [7:0] depth, rate, glide;
reg [4:0] shift;
reg [31:0] seed, magnitude;
reg [31:0] mul_a;
reg [7:0] mul_b;
reg [39:0] product;
wire [31:0] effective_period;
wire [7:0] triangle;
wire [31:0] auto_age;
assign lookup_note = phase==0 && i_start ? i_note[6:0] :
                     phase==12 && lane<3 ? notes[(lane+1'b1)*7 +:7] :
                     pluck_notes[lane*7 +:7];
assign o_ready=phase==0;
assign auto_age=next_held-AUTO_DELAY_SAMPLES;
assign triangle=new_phase[30] ? 8'd127-{1'b0,new_phase[29:23]} : {1'b0,new_phase[29:23]};
assign effective_period=gate ? (new_phase[31] ? new_current-magnitude : new_current+magnitude) : new_current;
integer n;
always @(posedge i_clk)
begin
    // One registered multiplier serves phase, depth and triangular modulation.
    product<=mul_a*mul_b;
    if(i_reset)
    begin
        phase<=0; lane<=0; o_valid<=0; previous_gate<=0; lane_valid<=0;
        pluck_notes<=0;o_pluck_parameters<={4{48'h200000080000}};
        notes<=0; gates<=0; autos<=0; depths<=0; rates<=0; glides<=0;
        o_period<={4{32'd524288}};
        target<=0; origin<=0; old_goal<=0; old_step<=0; old_phase<=0;
        next_held<=0; distance<=0; new_step<=0; new_current<=0; new_phase<=0;
        up<=0; retarget<=0; snap<=0; gate<=0; old_gate<=0;
        depth<=0; rate<=0; glide<=0; shift<=0; seed<=0; magnitude<=0;
        mul_a<=0; mul_b<=0;
        for(n=0;n<4;n=n+1)
        begin
            step[n]<=1;
            oscillator[n]<=0; held[n]<=0;
        end
    end
    else
    begin
        o_valid<=0;
        case(phase)
        0:
        begin
            if(i_start)
            begin
                notes<=i_note; pluck_notes<=i_pluck_note; gates<=i_gate; autos<=i_auto;
                depths<=i_depth; rates<=i_rate; glides<=i_glide;
                lane<=0; phase<=1;
            end
        end
        1:
        begin
            target<=pluck_read[31:0];
            origin<=lane_valid[lane] ? current[lane] : 32'd524288;
            old_goal<=lane_valid[lane] ? goal[lane] : 32'd524288; old_step<=step[lane];
            old_phase<=oscillator[lane]; gate<=gates[lane]; old_gate<=previous_gate[lane];
            next_held<=!gates[lane] || !previous_gate[lane] ? 0 :
                held[lane]>=AGE_MAX ? held[lane] : held[lane]+1'b1;
            glide<=glides[lane*8 +:8]==0 && autos[lane] ? 8'd6 : glides[lane*8 +:8];
            depth<=depths[lane*8 +:8]>63 ? 63 : depths[lane*8 +:8];
            rate<=rates[lane*8 +:8]==0 && autos[lane] ? 8'd48 : rates[lane*8 +:8];
            phase<=2;
        end
        2:
        begin
            distance<=target>origin ? target-origin : origin-target;
            up<=target>origin; retarget<=target!=old_goal;
            snap<=!gate || !old_gate || glide==0;
            shift<=glide<=5 ? 8 : glide<=10 ? 9 : glide<=20 ? 10 :
                glide<=40 ? 11 : glide<=80 ? 12 : glide<=160 ? 13 : 14;
            mul_a<=PHASE_PER_DECIHZ; mul_b<=rate;
            phase<=3;
        end
        3:
        begin
            new_step<=retarget ? ((distance>>shift)==0 ? 1 : distance>>shift) : old_step;
            if(depth==0 && autos[lane] && next_held>=AUTO_DELAY_SAMPLES)
                depth<=auto_age>=768 ? 12 : (auto_age>>6)+1;
            phase<=4;
        end
        4:
        begin
            new_current<=snap || (!retarget && distance<=old_step) ? target :
                up ? origin+new_step : origin-new_step;
            new_phase<=!gate ? old_phase : !old_gate ? 0 : old_phase+product[31:0];
            phase<=5;
        end
        5:
        begin
            seed<=(new_current>>11)+(new_current>>14)+(new_current>>16)+(new_current>>17)+(new_current>>18);
            phase<=6;
        end
        6:
        begin
            mul_a<=seed; mul_b<=depth; phase<=7;
        end
        7: phase<=8;
        8:
        begin
            mul_a<=product[31:0]; mul_b<=triangle; phase<=9;
        end
        9: phase<=10;
        10:
        begin
            magnitude<=product[31:0]>>7; phase<=11;
        end
        11:
        begin
            current[lane]<=new_current; goal[lane]<=target; lane_valid[lane]<=1'b1;
            if(retarget && !snap) step[lane]<=new_step;
            oscillator[lane]<=new_phase; held[lane]<=next_held; previous_gate[lane]<=gate;
            o_period[lane*32 +:32]<=effective_period; o_pluck_parameters[lane*48 +:48]<=pluck_read; phase<=12;
        end
        12:
        begin
            if(lane==3)
            begin
                o_valid<=1; phase<=0;
            end
            else
            begin
                lane<=lane+1'b1; phase<=1;
            end
        end
        default: phase<=0;
        endcase
    end
end
endmodule
