/*
 * rv32im_monitor.sv — UVM monitor for RV32IM DUT
 *
 * Passively observes the DUT's commit port and exception signals.
 * Fires a rv32im_txn on every commit_valid pulse.
 * Broadcasts to two analysis ports:
 *   ap_commit  → scoreboard  (instruction-level result check)
 *   ap_coverage→ coverage collector
 */

`ifndef RV32IM_MONITOR_SV
`define RV32IM_MONITOR_SV

class rv32im_monitor extends uvm_monitor;
  `uvm_component_utils(rv32im_monitor)

  virtual rv32im_if.monitor_mp vif;

  /* Analysis ports */
  uvm_analysis_port #(rv32im_txn) ap_commit;
  uvm_analysis_port #(rv32im_txn) ap_coverage;

  /* Statistics */
  int unsigned commit_count;
  int unsigned trap_count;

  function new(string name = "rv32im_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_commit   = new("ap_commit",   this);
    ap_coverage = new("ap_coverage", this);
    if (!uvm_config_db #(virtual rv32im_if)::get(this, "", "vif", vif))
      `uvm_fatal("MONITOR", "No virtual interface rv32im_if found in config_db")
  endfunction

  /* ----------------------------------------------------------------
   * run_phase: sample on every clock; fire on commit_valid
   * ----------------------------------------------------------------*/
  task run_phase(uvm_phase phase);
    rv32im_txn txn;

    /* Wait for reset de-assertion */
    @(posedge vif.clk iff vif.rst_n);
    `uvm_info("MONITOR", "Reset released — starting observation", UVM_MEDIUM)

    forever begin
      @(vif.mon_cb);

      /* ── Committed instruction ─────────────────────────────── */
      if (vif.mon_cb.commit_valid) begin
        txn = rv32im_txn::type_id::create("txn");

        txn.pc       = vif.mon_cb.commit_pc;
        txn.instr    = vif.mon_cb.commit_instr;
        txn.rd       = vif.mon_cb.commit_rd;
        txn.result   = vif.mon_cb.commit_result;
        txn.is_trap  = 1'b0;

        /* Decode itype from observed opcode */
        case (txn.instr[6:0])
          7'h33:               txn.itype = R_TYPE;
          7'h13, 7'h03, 7'h67: txn.itype = I_TYPE;
          7'h23:               txn.itype = S_TYPE;
          7'h63:               txn.itype = B_TYPE;
          7'h37, 7'h17:        txn.itype = U_TYPE;
          7'h6F:               txn.itype = J_TYPE;
          7'h73: txn.itype = (txn.instr[14:12] == 0) ? SYS_TYPE : CSR_TYPE;
          default:             txn.itype = R_TYPE;
        endcase

        commit_count++;

        `uvm_info("MONITOR",
          $sformatf("COMMIT #%0d PC=%08h instr=%08h rd=x%0d result=%08h",
                    commit_count, txn.pc, txn.instr, txn.rd, txn.result),
          UVM_HIGH)

        ap_commit.write(txn);
        ap_coverage.write(txn);
      end

      /* ── Exception / trap ──────────────────────────────────── */
      if (vif.mon_cb.trap_valid) begin
        txn = rv32im_txn::type_id::create("trap_txn");
        txn.is_trap = 1'b1;
        txn.mcause  = vif.mon_cb.trap_cause;
        txn.mepc    = vif.mon_cb.trap_pc;
        txn.pc      = vif.mon_cb.trap_pc;

        trap_count++;

        `uvm_info("MONITOR",
          $sformatf("TRAP #%0d mcause=%08h mepc=%08h",
                    trap_count, txn.mcause, txn.mepc),
          UVM_MEDIUM)

        /* Traps also go to both ports */
        ap_commit.write(txn);
        ap_coverage.write(txn);
      end
    end
  endtask

  /* ----------------------------------------------------------------
   * report_phase: print stats
   * ----------------------------------------------------------------*/
  function void report_phase(uvm_phase phase);
    `uvm_info("MONITOR",
      $sformatf("=== Monitor summary: %0d commits, %0d traps ===",
                commit_count, trap_count), UVM_LOW)
  endfunction

endclass : rv32im_monitor

`endif // RV32IM_MONITOR_SV
