`timescale 1ns/1ps
// Actual map plus exact frontend note_bus sampling register.  No audio/DSP
// stub or sensor model is required to expose a one-cycle intermediate note.
module tb_pitch_group_boundary;
  reg clk=0;always #10 clk=~clk;
  reg reset=1;
  reg [19:0] fret=0;
  wire [55:0] old_notes,new_notes;
  wire [3:0] b0,b1;
  reg [55:0] old_frontend,new_frontend;
  performer_pitch_map_before prod(.clk(clk),.reset(reset),.fret_bus(fret),.valid_mask(4'hf),.note_bus(old_notes),.bowed_strings(b0));
  performer_pitch_map cand(.clk(clk),.reset(reset),.fret_bus(fret),.valid_mask(4'hf),.note_bus(new_notes),.bowed_strings(b1));
  always @(posedge clk)begin
    if(reset)begin old_frontend<=0;new_frontend<=0;end
    else begin old_frontend<=old_notes;new_frontend<=new_notes;end
  end
  integer old_errors=0,new_errors=0,steps=0;
  integer i,before_old,before_new,target;
  task transition;
    input integer next_fret,next_note;
    begin
      before_old=old_frontend[6:0];before_new=new_frontend[6:0];target=next_note;
      @(negedge clk);fret[4:0]=next_fret;
      for(i=0;i<3;i=i+1)begin
        @(posedge clk);#1;
        if(old_frontend[6:0]!=before_old && old_frontend[6:0]!=target)begin
          old_errors=old_errors+1;
          $display("COUNTEREXAMPLE production fret=%0d cycle=%0d old=%0d observed=%0d target=%0d",next_fret,i,before_old,old_frontend[6:0],target);
        end
        if(new_frontend[6:0]!=before_new && new_frontend[6:0]!=target)begin
          new_errors=new_errors+1;
          $display("FAIL candidate fret=%0d observed=%0d old=%0d target=%0d",next_fret,new_frontend[6:0],before_new,target);
        end
      end
      if(old_frontend[6:0]!=target || new_frontend[6:0]!=target)$fatal(1,"did not settle to expected note");
      steps=steps+1;
    end
  endtask
  initial begin
    repeat(4)@(negedge clk);reset=0;repeat(4)@(negedge clk);
    transition(3,55); // group0 hold
    transition(8,67); // group0 -> group1: old value is allowed
    transition(0,55);
    transition(13,79); // open -> group2, retained group1 exposes +12
    transition(16,91);
    transition(3,55); // +36 anchor -> group0, retained group2 exposes +24
    transition(13,79);
    transition(0,55);
    transition(8,67); // open -> group1, retained group2 exposes +24
    if(old_errors!=3)$fatal(1,"expected exactly three deterministic production transient-note counterexamples");
    if(new_errors!=0)$fatal(1,"candidate has transient notes");
    $display("PASS pitch group boundary: transitions=%0d production_counterexamples=%0d candidate_errors=%0d",steps,old_errors,new_errors);
    $finish;
  end
endmodule
