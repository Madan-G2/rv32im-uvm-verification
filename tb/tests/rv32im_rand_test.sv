/*
 * rv32im_rand_test.sv — Constrained-random regression test
 * Runs rv32im_rand_seq with configurable number of instructions.
 * +num_instrs=N overrides the default.
 */

`ifndef RV32IM_RAND_TEST_SV
`define RV32IM_RAND_TEST_SV

class rv32im_rand_test extends rv32im_base_test;
  `uvm_component_utils(rv32im_rand_test)

  function new(string name = "rv32im_rand_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task do_test(uvm_phase phase);
    rv32im_rand_seq    rand_seq;
    rv32im_hazard_seq  hz_seq;
    rv32im_branch_seq  br_seq;
    rv32im_mul_div_seq md_seq;

    int n;
    if (!$value$plusargs("num_instrs=%0d", n)) n = 200;

    /* Random instructions */
    rand_seq = rv32im_rand_seq::type_id::create("rand_seq");
    rand_seq.num_instrs = n;
    run_seq(rand_seq);

    /* Hazard patterns */
    hz_seq = rv32im_hazard_seq::type_id::create("hz_seq");
    run_seq(hz_seq);

    /* Branch patterns */
    br_seq = rv32im_branch_seq::type_id::create("br_seq");
    run_seq(br_seq);

    /* M-extension */
    md_seq = rv32im_mul_div_seq::type_id::create("md_seq");
    run_seq(md_seq);

    `uvm_info("RAND_TEST", "All sequences complete", UVM_LOW)
  endtask

endclass : rv32im_rand_test

`endif // RV32IM_RAND_TEST_SV
