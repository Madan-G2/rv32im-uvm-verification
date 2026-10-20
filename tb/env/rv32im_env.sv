/*
 * rv32im_env.sv — Top-level UVM environment
 *
 * Instantiates and connects:
 *   agent     → scoreboard (ap_commit)
 *   agent     → coverage   (ap_coverage)
 */

`ifndef RV32IM_ENV_SV
`define RV32IM_ENV_SV

class rv32im_env extends uvm_env;
  `uvm_component_utils(rv32im_env)

  rv32im_agent       agent;
  rv32im_scoreboard  scoreboard;
  rv32im_coverage    coverage;

  function new(string name = "rv32im_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent      = rv32im_agent     ::type_id::create("agent",      this);
    scoreboard = rv32im_scoreboard::type_id::create("scoreboard", this);
    coverage   = rv32im_coverage  ::type_id::create("coverage",   this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.ap_commit.connect(scoreboard.ap_commit);
    agent.ap_coverage.connect(coverage.analysis_export);
  endfunction

endclass : rv32im_env

`endif // RV32IM_ENV_SV
