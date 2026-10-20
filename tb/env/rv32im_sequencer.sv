/*
 * rv32im_sequencer.sv — UVM sequencer for RV32IM agent
 */

`ifndef RV32IM_SEQUENCER_SV
`define RV32IM_SEQUENCER_SV

class rv32im_sequencer extends uvm_sequencer #(rv32im_txn);
  `uvm_component_utils(rv32im_sequencer)

  function new(string name = "rv32im_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : rv32im_sequencer

`endif // RV32IM_SEQUENCER_SV
