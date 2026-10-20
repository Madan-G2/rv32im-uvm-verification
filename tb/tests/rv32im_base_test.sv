/*
 * rv32im_base_test.sv — Base test class
 * All tests extend this; it builds the environment and provides
 * common configuration helpers.
 */

`ifndef RV32IM_BASE_TEST_SV
`define RV32IM_BASE_TEST_SV

class rv32im_base_test extends uvm_test;
  `uvm_component_utils(rv32im_base_test)

  rv32im_env env;

  function new(string name = "rv32im_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = rv32im_env::type_id::create("env", this);
    /* Set UVM verbosity from plusarg: +UVM_VERBOSITY=UVM_HIGH */
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    /* Print topology */
    uvm_top.print_topology();
  endfunction

  /* Helper: run a sequence on the agent sequencer */
  task run_seq(uvm_sequence #(rv32im_txn) seq, int drain_cycles = 20);
    seq.start(env.agent.sequencer);
    /* Allow pipeline to drain */
    #(drain_cycles * 10);  /* assumes 10ns clock period */
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    do_test(phase);
    phase.drop_objection(this);
  endtask

  /* Derived classes override this */
  virtual task do_test(uvm_phase phase);
    `uvm_fatal("BASE_TEST", "do_test() not overridden")
  endtask

endclass : rv32im_base_test

`endif // RV32IM_BASE_TEST_SV
