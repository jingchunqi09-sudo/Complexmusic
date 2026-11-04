`ifndef INSTRUMENT_CONSTANTS_VH
`define INSTRUMENT_CONSTANTS_VH
// Active physical-performance build constants. No packet/UART protocol.
`define INST_CLOCK_HZ             50000000
`define INST_PT8211_BCLK_HZ        1562500
`define INST_DEFAULT_ATTACK       8'd80
`define INST_DEFAULT_DECAY        8'd24
`define INST_DEFAULT_SUSTAIN      8'd190
`define INST_DEFAULT_RELEASE      8'd24
// Lane 0 is least significant: violin G3/D4/A4/E5; high-G uke G4/C4/E4/A4.
`define INST_VIOLIN_OPEN_NOTES     32'h4C453E37
`define INST_UKULELE_OPEN_NOTES    32'h45403C43
`define INST_DEFAULT_OPEN_NOTES   {`INST_UKULELE_OPEN_NOTES, `INST_VIOLIN_OPEN_NOTES}
`endif
