/*
 * rv32im_agent.sv — UVM agent for RV32IM verification environment
 *
 * Active agent: instantiates driver, monitor, and sequencer.
 * Set is_active = UVM_PASSIVE to drop the driver/sequencer
 * (useful for second monitor-only agent on a clean RTL port).
 */

`ifndef RV32IM_AGENT_SV
`define RV32IM_AGENT_SV

class rv32im_agent extends uvm_agent;
  `uvm_component_utils(rv32im_agent)

  /* Sub-components */
  rv32im_driver     driver;
  rv32im_monitor    monitor;
  rv32im_sequencer  sequencer;

  /* Analysis port forwarded from monitor — env connects to scoreboard */
  uvm_analysis_port #(rv32im_txn) ap_commit;
  uvm_analysis_port #(rv32im_txn) ap_coverage;

  function new(string name = "rv32im_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    monitor = rv32im_monitor::type_id::create("monitor", this);

    if (get_is_active() == UVM_ACTIVE) begin
      driver    = rv32im_driver   ::type_id::create("driver",    this);
      sequencer = rv32im_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    /* Forward analysis ports from monitor */
    ap_commit   = monitor.ap_commit;
    ap_coverage = monitor.ap_coverage;

    if (get_is_active() == UVM_ACTIVE)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

endclass : rv32im_agent

`endif // RV32IM_AGENT_SV
