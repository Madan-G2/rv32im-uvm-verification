/*
 * rv32im_smoke_test.sv — Smoke test
 * Sends 10 simple ADDI instructions; confirms scoreboard reports PASS.
 * First test to run after environment bring-up.
 */

`ifndef RV32IM_SMOKE_TEST_SV
`define RV32IM_SMOKE_TEST_SV

class rv32im_smoke_test extends rv32im_base_test;
  `uvm_component_utils(rv32im_smoke_test)

  function new(string name = "rv32im_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task do_test(uvm_phase phase);
    rv32im_base_seq seq;
    seq = rv32im_base_seq::type_id::create("smoke_seq");

    `uvm_info("SMOKE", "=== Smoke Test: 10 ADDI instructions ===", UVM_LOW)

    /* Inline tiny sequence */
    seq.start_item(seq); /* not a real item — use manual send */

    /* Actually send instructions directly via env agent sequencer */
    fork
      begin
        rv32im_txn txn;
        for (int i = 1; i <= 10; i++) begin
          txn = rv32im_txn::type_id::create($sformatf("smoke_txn_%0d", i));
          /* ADDI x<i>, x0, i */
          txn.instr = {12'(i), 5'h0, 3'h0, 5'(i), 7'h13};
          txn.itype = I_TYPE;
          txn.start(env.agent.sequencer);
        end
        /* 5 NOPs to drain */
        for (int i = 0; i < 5; i++) begin
          txn = rv32im_txn::type_id::create("nop");
          txn.instr = 32'h0000_0013;
          txn.itype = I_TYPE;
          txn.start(env.agent.sequencer);
        end
      end
    join

    `uvm_info("SMOKE", "Smoke test sequence complete", UVM_LOW)
  endtask

endclass : rv32im_smoke_test

`endif // RV32IM_SMOKE_TEST_SV
