/*
 * tb_top.sv — Testbench top module
 *
 * - Clock/reset generation
 * - DUT (ibex_core) instantiation
 * - rv32im_if connection
 * - Commit / trap observation port wiring (ibex register file write port tap)
 * - SVA checker bind statements
 * - UVM run
 *
 * Usage (VCS):
 *   vcs ... +UVM_TESTNAME=rv32im_rand_test +ntb_random_seed=42
 */

`timescale 1ns/1ps

/* ── Imports ──────────────────────────────────────────────────── */
import uvm_pkg::*;
`include "uvm_macros.svh"

import rv32im_pkg::*;

/* ── Include all TB files ─────────────────────────────────────── */
`include "rv32im_if.sv"

/* env */
`include "rv32im_sequencer.sv"
`include "rv32im_driver.sv"
`include "rv32im_monitor.sv"
`include "rv32im_agent.sv"
`include "rv32im_scoreboard.sv"
`include "rv32im_coverage.sv"
`include "rv32im_env.sv"

/* sequences */
`include "rv32im_base_seq.sv"
`include "rv32im_rand_seq.sv"
`include "rv32im_hazard_seq.sv"
`include "rv32im_branch_seq.sv"
`include "rv32im_mul_div_seq.sv"
`include "rv32im_exception_seq.sv"

/* tests */
`include "rv32im_base_test.sv"
`include "rv32im_smoke_test.sv"
`include "rv32im_rand_test.sv"
`include "rv32im_directed_test.sv"

/* SVA checkers */
`include "pipeline_fsm.sva"
`include "hazard_checks.sva"

/* ================================================================
 * tb_top
 * ================================================================*/
module tb_top;

  /* ── Clock and reset ─────────────────────────────────────────── */
  logic clk;
  logic rst_n;

  /* 100 MHz clock (10 ns period) */
  initial clk = 0;
  always #5 clk = ~clk;

  /* Reset: assert for 20 cycles */
  initial begin
    rst_n = 0;
    iss_dpi_init();
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    iss_dpi_reset();
    `uvm_info("TB_TOP", "Reset de-asserted", UVM_LOW)
  end

  /* ── Interface instantiation ─────────────────────────────────── */
  rv32im_if dut_if (.clk(clk), .rst_n(rst_n));

  /* ── Commit / trap observation wiring ───────────────────────────
   *
   * ibex exposes its register file write port.
   * We tap:
   *   ibex_core_i.rf_we_wb         → write enable (= commit_valid)
   *   ibex_core_i.rf_waddr_wb_o    → write address (= commit_rd)
   *   ibex_core_i.rf_wdata_wb_mux_we → write data (= commit_result)
   *   ibex_core_i.pc_wb_o          → committed PC
   *   ibex_core_i.instr_rdata_id_i → instruction in WB
   *
   * Exception / trap:
   *   ibex_core_i.csr_save_cause   → high when exception taken
   *   ibex_core_i.csr_mcause_i     → cause value
   *   ibex_core_i.csr_mepc_i       → exception PC
   *
   * NOTE: These hierarchical paths depend on ibex version.
   *       Adjust if the signal names differ in your ibex checkout.
   */
  assign dut_if.commit_valid  = ibex_core_i.rf_we_wb;
  assign dut_if.commit_rd     = ibex_core_i.rf_waddr_wb_o;
  assign dut_if.commit_result = ibex_core_i.rf_wdata_fwd_wb_o;
  assign dut_if.commit_pc     = ibex_core_i.pc_wb_o;
  assign dut_if.commit_instr  = ibex_core_i.instr_rdata_id_i;

  assign dut_if.trap_valid    = ibex_core_i.csr_save_cause;
  assign dut_if.trap_cause    = ibex_core_i.csr_mcause_i;
  assign dut_if.trap_pc       = ibex_core_i.csr_mepc_i;

  /* ── DUT instantiation (ibex_core) ───────────────────────────── */
  ibex_core #(
    .PMPEnable        (0),
    .MHPMCounterNum   (0),
    .RV32M            (ibex_pkg::RV32MFast),
    .RV32B            (ibex_pkg::RV32BNone),
    .RegFile          (ibex_pkg::RegFileFF),
    .BranchTargetALU  (0),
    .WritebackStage   (0),
    .ICache           (0),
    .ICacheECC        (0),
    .BranchPredictor  (0),
    .DbgTriggerEn     (0),
    .SecureIbex       (0),
    .DmHaltAddr       (32'h1A110800),
    .DmExceptionAddr  (32'h1A110808)
  ) ibex_core_i (
    .clk_i               (clk),
    .rst_ni              (rst_n),

    /* Instruction fetch */
    .instr_req_o         (dut_if.instr_req_o),
    .instr_gnt_i         (dut_if.instr_gnt_i),
    .instr_rvalid_i      (dut_if.instr_rvalid_i),
    .instr_addr_o        (dut_if.instr_addr_o),
    .instr_rdata_i       (dut_if.instr_rdata_i),
    .instr_rdata_intg_i  (7'h0),
    .instr_err_i         (dut_if.instr_err_i),

    /* Data memory */
    .data_req_o          (dut_if.data_req_o),
    .data_gnt_i          (dut_if.data_gnt_i),
    .data_rvalid_i       (dut_if.data_rvalid_i),
    .data_we_o           (dut_if.data_we_o),
    .data_be_o           (dut_if.data_be_o),
    .data_addr_o         (dut_if.data_addr_o),
    .data_wdata_o        (dut_if.data_wdata_o),
    .data_wdata_intg_o   (),
    .data_rdata_i        (dut_if.data_rdata_i),
    .data_rdata_intg_i   (7'h0),
    .data_err_i          (dut_if.data_err_i),

    /* Interrupts (unused) */
    .irq_software_i      (1'b0),
    .irq_timer_i         (1'b0),
    .irq_external_i      (1'b0),
    .irq_fast_i          (dut_if.irq_fast_i),
    .irq_nm_i            (dut_if.irq_nm_i),

    /* Debug (unused) */
    .debug_req_i         (1'b0),
    .crash_dump_o        (),

    /* Core status outputs */
    .alert_minor_o       (),
    .alert_major_internal_o(),
    .alert_major_bus_o   (),
    .core_sleep_o        ()
  );

  /* ── SVA checker instantiation (bind-style) ─────────────────── */
  pipeline_fsm_checker u_pipeline_sva (
    .clk          (clk),
    .rst_n        (rst_n),
    .instr_req_o  (dut_if.instr_req_o),
    .instr_gnt_i  (dut_if.instr_gnt_i),
    .instr_addr_o (dut_if.instr_addr_o),
    .commit_valid (dut_if.commit_valid),
    .commit_rd    (dut_if.commit_rd),
    .commit_result(dut_if.commit_result),
    .commit_pc    (dut_if.commit_pc),
    .trap_valid   (dut_if.trap_valid)
  );

  hazard_checks_checker u_hazard_sva (
    .clk          (clk),
    .rst_n        (rst_n),
    .commit_valid (dut_if.commit_valid),
    .commit_rd    (dut_if.commit_rd),
    .commit_result(dut_if.commit_result),
    .commit_pc    (dut_if.commit_pc),
    .commit_instr (dut_if.commit_instr),
    .trap_valid   (dut_if.trap_valid),
    .stall        (1'b0),   /* tie to 0 if not tapping internal */
    .flush        (1'b0),
    .instr_valid_id(1'b0)
  );

  /* ── UVM config_db: pass virtual interface to environment ─────── */
  initial begin
    uvm_config_db #(virtual rv32im_if)::set(
      null, "uvm_test_top.*", "vif", dut_if);
    run_test();  /* test name from +UVM_TESTNAME plusarg */
  end

  /* ── Simulation timeout ─────────────────────────────────────── */
  initial begin
    int timeout_cycles;
    if (!$value$plusargs("timeout=%0d", timeout_cycles))
      timeout_cycles = 1_000_000;
    repeat (timeout_cycles) @(posedge clk);
    `uvm_fatal("TB_TOP", $sformatf("Simulation timeout after %0d cycles",
                                    timeout_cycles))
  end

  /* ── VCD / FSDB dump (optional) ─────────────────────────────── */
  initial begin
    if ($test$plusargs("vcd_dump")) begin
      $dumpfile("sim/vcs/dump.vcd");
      $dumpvars(0, tb_top);
      `uvm_info("TB_TOP", "VCD dump enabled", UVM_LOW)
    end
  end

endmodule : tb_top
