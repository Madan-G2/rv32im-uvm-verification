/*
 * rv32im_scoreboard.sv — Instruction-level scoreboard
 *
 * Receives committed transactions from the monitor.
 * For each commit calls iss_dpi_step() to get the expected result
 * from the C golden ISS, then compares against DUT output.
 *
 * Mismatch → UVM_ERROR with full diagnostic.
 * On any error: dumps ISS register file and disassembly context.
 */

`ifndef RV32IM_SCOREBOARD_SV
`define RV32IM_SCOREBOARD_SV

class rv32im_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rv32im_scoreboard)

  /* Analysis imp — receives from monitor ap_commit */
  `uvm_analysis_imp_decl(_commit)
  uvm_analysis_imp_commit #(rv32im_txn, rv32im_scoreboard) ap_commit;

  /* Statistics */
  int unsigned check_count;
  int unsigned pass_count;
  int unsigned fail_count;
  int unsigned trap_count;

  /* Per-opcode error tracking */
  int unsigned opcode_errors [7:0];   /* indexed by opcode[6:3] */

  function new(string name = "rv32im_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_commit = new("ap_commit", this);
    iss_dpi_init();
    `uvm_info("SB", "Scoreboard initialized — C ISS golden model active", UVM_LOW)
  endfunction

  /* ----------------------------------------------------------------
   * write_commit: called for every commit or trap observed by monitor
   * ----------------------------------------------------------------*/
  function void write_commit(rv32im_txn txn);

    /* ── Exception path ──────────────────────────────────────── */
    if (txn.is_trap) begin
      /* Step ISS — it will also take the exception */
      int unsigned rd_exp, res_exp, npc_exp, mcause_exp, mepc_exp;
      int          trap_exp;
      iss_dpi_step(txn.instr, txn.pc,
                   rd_exp, res_exp, npc_exp,
                   trap_exp, mcause_exp, mepc_exp);
      trap_count++;

      if (!trap_exp) begin
        fail_count++;
        `uvm_error("SB",
          $sformatf("TRAP MISMATCH: DUT took trap (mcause=%08h mepc=%08h) "
                    "but ISS did NOT expect trap for instr=%08h PC=%08h",
                    txn.mcause, txn.mepc, txn.instr, txn.pc))
      end else if (txn.mcause !== mcause_exp) begin
        fail_count++;
        `uvm_error("SB",
          $sformatf("MCAUSE MISMATCH: PC=%08h instr=%08h "
                    "DUT_mcause=%08h ISS_mcause=%08h",
                    txn.pc, txn.instr, txn.mcause, mcause_exp))
      end else begin
        pass_count++;
        `uvm_info("SB",
          $sformatf("TRAP MATCH: PC=%08h mcause=%08h ✓", txn.pc, txn.mcause),
          UVM_HIGH)
      end
      check_count++;
      return;
    end

    /* ── Normal instruction commit ───────────────────────────── */
    int unsigned rd_exp, res_exp, npc_exp, mcause_exp, mepc_exp;
    int          trap_exp;

    iss_dpi_step(txn.instr, txn.pc,
                 rd_exp, res_exp, npc_exp,
                 trap_exp, mcause_exp, mepc_exp);
    check_count++;

    /* Compare rd index */
    if (txn.rd !== rd_exp[4:0]) begin
      fail_count++;
      `uvm_error("SB",
        $sformatf("RD MISMATCH: PC=%08h instr=%08h (%s)\n"
                  "  DUT: rd=x%0d  ISS: rd=x%0d",
                  txn.pc, txn.instr, txn.opcode_str(),
                  txn.rd, rd_exp))
      iss_dpi_dump_regs();
      return;
    end

    /* Compare result value (only if rd != x0) */
    if (txn.rd != 5'd0 && txn.result !== res_exp) begin
      fail_count++;
      `uvm_error("SB",
        $sformatf("RESULT MISMATCH: PC=%08h instr=%08h (%s)\n"
                  "  DUT: x%0d=%08h  ISS: x%0d=%08h  diff=%08h",
                  txn.pc, txn.instr, txn.opcode_str(),
                  txn.rd, txn.result,
                  rd_exp, res_exp,
                  txn.result ^ res_exp))
      iss_dpi_dump_regs();
      return;
    end

    /* ISS expected a trap but DUT didn't take one */
    if (trap_exp && !txn.is_trap) begin
      fail_count++;
      `uvm_error("SB",
        $sformatf("MISSED TRAP: PC=%08h instr=%08h ISS expects trap "
                  "mcause=%08h but DUT committed normally",
                  txn.pc, txn.instr, mcause_exp))
      return;
    end

    pass_count++;
    `uvm_info("SB",
      $sformatf("PASS #%0d PC=%08h %s x%0d=%08h",
                check_count, txn.pc, txn.opcode_str(), txn.rd, txn.result),
      UVM_HIGH)

  endfunction

  /* ----------------------------------------------------------------
   * check_phase: final pass/fail summary
   * ----------------------------------------------------------------*/
  function void check_phase(uvm_phase phase);
    `uvm_info("SB", "=== Scoreboard Final Report ===", UVM_LOW)
    `uvm_info("SB", $sformatf("  Total checks : %0d", check_count), UVM_LOW)
    `uvm_info("SB", $sformatf("  Pass         : %0d", pass_count),  UVM_LOW)
    `uvm_info("SB", $sformatf("  Fail         : %0d", fail_count),  UVM_LOW)
    `uvm_info("SB", $sformatf("  Traps caught : %0d", trap_count),  UVM_LOW)

    if (fail_count > 0)
      `uvm_error("SB", $sformatf("TEST FAILED: %0d scoreboard mismatches", fail_count))
    else if (check_count == 0)
      `uvm_warning("SB", "No commits observed — check DUT and monitor connectivity")
    else
      `uvm_info("SB", "ALL CHECKS PASSED ✓", UVM_LOW)
  endfunction

endclass : rv32im_scoreboard

`endif // RV32IM_SCOREBOARD_SV
