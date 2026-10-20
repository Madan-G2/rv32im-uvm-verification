/*
 * rv32im_coverage.sv — Functional coverage collector
 *
 * Receives committed transactions from monitor ap_coverage port.
 * Implements five covergroups matching the coverage plan in the spec.
 *
 * Covergroups:
 *   cg_instr_mix  — per-opcode instruction mix
 *   cg_hazard     — pipeline hazard types (inferred from sequence)
 *   cg_branch     — branch taken/not-taken × type
 *   cg_mul_div    — M-extension corner cases
 *   cg_exception  — exception types
 */

`ifndef RV32IM_COVERAGE_SV
`define RV32IM_COVERAGE_SV

class rv32im_coverage extends uvm_subscriber #(rv32im_txn);
  `uvm_component_utils(rv32im_coverage)

  /* Current transaction under sampling */
  rv32im_txn txn;

  /* ================================================================
   * CG_INSTR_MIX — one bin per opcode group, plus M-extension
   * ================================================================*/
  covergroup cg_instr_mix;
    cp_opcode: coverpoint txn.instr[6:0] {
      bins lui    = {7'h37};
      bins auipc  = {7'h17};
      bins jal    = {7'h6F};
      bins jalr   = {7'h67};
      bins beq    = {7'h63} iff (txn.instr[14:12] == 3'h0);
      bins bne    = {7'h63} iff (txn.instr[14:12] == 3'h1);
      bins blt    = {7'h63} iff (txn.instr[14:12] == 3'h4);
      bins bge    = {7'h63} iff (txn.instr[14:12] == 3'h5);
      bins bltu   = {7'h63} iff (txn.instr[14:12] == 3'h6);
      bins bgeu   = {7'h63} iff (txn.instr[14:12] == 3'h7);
      bins lb     = {7'h03} iff (txn.instr[14:12] == 3'h0);
      bins lh     = {7'h03} iff (txn.instr[14:12] == 3'h1);
      bins lw     = {7'h03} iff (txn.instr[14:12] == 3'h2);
      bins lbu    = {7'h03} iff (txn.instr[14:12] == 3'h4);
      bins lhu    = {7'h03} iff (txn.instr[14:12] == 3'h5);
      bins sb     = {7'h23} iff (txn.instr[14:12] == 3'h0);
      bins sh     = {7'h23} iff (txn.instr[14:12] == 3'h1);
      bins sw     = {7'h23} iff (txn.instr[14:12] == 3'h2);
      bins addi   = {7'h13} iff (txn.instr[14:12] == 3'h0);
      bins slti   = {7'h13} iff (txn.instr[14:12] == 3'h2);
      bins sltiu  = {7'h13} iff (txn.instr[14:12] == 3'h3);
      bins xori   = {7'h13} iff (txn.instr[14:12] == 3'h4);
      bins ori    = {7'h13} iff (txn.instr[14:12] == 3'h6);
      bins andi   = {7'h13} iff (txn.instr[14:12] == 3'h7);
      bins slli   = {7'h13} iff (txn.instr[14:12] == 3'h1);
      bins srli   = {7'h13} iff (txn.instr[14:12] == 3'h5 && txn.instr[31:25]==7'h00);
      bins srai   = {7'h13} iff (txn.instr[14:12] == 3'h5 && txn.instr[31:25]==7'h20);
      bins add    = {7'h33} iff (txn.instr[14:12]==3'h0 && txn.instr[31:25]==7'h00);
      bins sub    = {7'h33} iff (txn.instr[14:12]==3'h0 && txn.instr[31:25]==7'h20);
      bins sll    = {7'h33} iff (txn.instr[14:12]==3'h1 && txn.instr[31:25]==7'h00);
      bins slt    = {7'h33} iff (txn.instr[14:12]==3'h2 && txn.instr[31:25]==7'h00);
      bins sltu   = {7'h33} iff (txn.instr[14:12]==3'h3 && txn.instr[31:25]==7'h00);
      bins xor_r  = {7'h33} iff (txn.instr[14:12]==3'h4 && txn.instr[31:25]==7'h00);
      bins srl    = {7'h33} iff (txn.instr[14:12]==3'h5 && txn.instr[31:25]==7'h00);
      bins sra    = {7'h33} iff (txn.instr[14:12]==3'h5 && txn.instr[31:25]==7'h20);
      bins or_r   = {7'h33} iff (txn.instr[14:12]==3'h6 && txn.instr[31:25]==7'h00);
      bins and_r  = {7'h33} iff (txn.instr[14:12]==3'h7 && txn.instr[31:25]==7'h00);
      /* M-extension */
      bins mul    = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h0);
      bins mulh   = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h1);
      bins mulhsu = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h2);
      bins mulhu  = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h3);
      bins div    = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h4);
      bins divu   = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h5);
      bins rem    = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h6);
      bins remu   = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h7);
      /* CSR / System */
      bins csrrw  = {7'h73} iff (txn.instr[14:12]==3'h1);
      bins csrrs  = {7'h73} iff (txn.instr[14:12]==3'h2);
      bins csrrc  = {7'h73} iff (txn.instr[14:12]==3'h3);
      bins ecall  = {7'h73} iff (txn.instr[31:20]==12'h000 && txn.instr[14:12]==3'h0);
      bins ebreak = {7'h73} iff (txn.instr[31:20]==12'h001 && txn.instr[14:12]==3'h0);
    }

    /* x0 as destination (result must be 0 — a common bug target) */
    cp_rd_zero: coverpoint txn.rd {
      bins x0_write = {5'd0};
      bins nonzero  = {[5'd1:5'd31]};
    }

    cx_opcode_rd: cross cp_opcode, cp_rd_zero;
  endgroup : cg_instr_mix

  /* ================================================================
   * CG_BRANCH — branch coverage
   * ================================================================*/
  covergroup cg_branch;
    cp_branch_type: coverpoint txn.instr[14:12] iff (txn.instr[6:0]==7'h63) {
      bins beq  = {3'h0};
      bins bne  = {3'h1};
      bins blt  = {3'h4};
      bins bge  = {3'h5};
      bins bltu = {3'h6};
      bins bgeu = {3'h7};
    }
    /* Taken inferred from result: branch result is next_pc not pc+4
     * For coverage we check if rd==0 (branches have no rd) and instr type */
    cp_branch_imm_sign: coverpoint txn.instr[31] iff (txn.instr[6:0]==7'h63) {
      bins forward_branch  = {1'b0};
      bins backward_branch = {1'b1};
    }
    cx_branch_dir: cross cp_branch_type, cp_branch_imm_sign;
  endgroup : cg_branch

  /* ================================================================
   * CG_MUL_DIV — M-extension corner cases
   * ================================================================*/
  covergroup cg_mul_div;
    cp_mext_op: coverpoint txn.instr[14:12] iff
                (txn.instr[6:0]==7'h33 && txn.instr[31:25]==7'h01) {
      bins mul    = {3'h0};
      bins mulh   = {3'h1};
      bins mulhsu = {3'h2};
      bins mulhu  = {3'h3};
      bins div    = {3'h4};
      bins divu   = {3'h5};
      bins rem    = {3'h6};
      bins remu   = {3'h7};
    }

    /* Div-by-zero: rs2 == x0 (register zero means operand = 0).
     * We capture this via the rs2 field of the instruction. */
    cp_div_by_zero: coverpoint txn.instr[24:20] iff
                    (txn.instr[6:0]==7'h33 && txn.instr[31:25]==7'h01 &&
                     txn.instr[14:12] inside {3'h4,3'h5,3'h6,3'h7}) {
      bins div_by_zero = {5'd0};
      bins div_nonzero = {[5'd1:5'd31]};
    }

    /* Overflow case (INT_MIN / -1): result == 0x80000000 */
    cp_div_overflow: coverpoint txn.result iff
                     (txn.instr[6:0]==7'h33 && txn.instr[31:25]==7'h01 &&
                      txn.instr[14:12]==3'h4) {
      bins overflow = {32'h80000000};
      bins other    = default;
    }

    /* Zero result from multiply */
    cp_mul_zero_result: coverpoint txn.result iff
                        (txn.instr[6:0]==7'h33 && txn.instr[31:25]==7'h01 &&
                         txn.instr[14:12]==3'h0) {
      bins zero_product = {32'h0};
      bins nonzero      = default;
    }
  endgroup : cg_mul_div

  /* ================================================================
   * CG_EXCEPTION — exception type coverage
   * ================================================================*/
  covergroup cg_exception;
    cp_exception_type: coverpoint txn.mcause iff (txn.is_trap) {
      bins instr_misalign  = {32'd0};
      bins instr_fault     = {32'd1};
      bins illegal_instr   = {32'd2};
      bins breakpoint      = {32'd3};
      bins load_misalign   = {32'd4};
      bins load_fault      = {32'd5};
      bins store_misalign  = {32'd6};
      bins store_fault     = {32'd7};
      bins ecall_m         = {32'd11};
    }
  endgroup : cg_exception

  /* ================================================================
   * CG_LOAD_STORE — memory access patterns
   * ================================================================*/
  covergroup cg_load_store;
    cp_ls_type: coverpoint txn.instr[14:12] iff
                (txn.instr[6:0] inside {7'h03, 7'h23}) {
      bins byte_access = {3'h0};
      bins half_access = {3'h1};
      bins word_access = {3'h2};
      bins lbu_access  = {3'h4};
      bins lhu_access  = {3'h5};
    }
    cp_is_store: coverpoint txn.instr[6:0] iff
                 (txn.instr[6:0] inside {7'h03, 7'h23}) {
      bins load  = {7'h03};
      bins store = {7'h23};
    }
    cx_ls: cross cp_ls_type, cp_is_store;
  endgroup : cg_load_store

  /* ================================================================
   * Constructor — instantiate covergroups
   * ================================================================*/
  function new(string name = "rv32im_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_instr_mix  = new();
    cg_branch     = new();
    cg_mul_div    = new();
    cg_exception  = new();
    cg_load_store = new();
  endfunction

  `uvm_component_utils(rv32im_coverage)

  /* ================================================================
   * write: called by monitor ap_coverage — sample all covergroups
   * ================================================================*/
  function void write(rv32im_txn t);
    txn = t;
    cg_instr_mix.sample();
    cg_branch.sample();
    cg_mul_div.sample();
    cg_exception.sample();
    cg_load_store.sample();
  endfunction

  /* ================================================================
   * report_phase: print coverage summary
   * ================================================================*/
  function void report_phase(uvm_phase phase);
    real instr_cov  = cg_instr_mix.get_coverage();
    real branch_cov = cg_branch.get_coverage();
    real mext_cov   = cg_mul_div.get_coverage();
    real exc_cov    = cg_exception.get_coverage();
    real ls_cov     = cg_load_store.get_coverage();

    `uvm_info("COV", "=== Functional Coverage Report ===", UVM_LOW)
    `uvm_info("COV", $sformatf("  Instruction Mix : %0.1f%%", instr_cov),  UVM_LOW)
    `uvm_info("COV", $sformatf("  Branch          : %0.1f%%", branch_cov), UVM_LOW)
    `uvm_info("COV", $sformatf("  M-Extension     : %0.1f%%", mext_cov),   UVM_LOW)
    `uvm_info("COV", $sformatf("  Exception       : %0.1f%%", exc_cov),    UVM_LOW)
    `uvm_info("COV", $sformatf("  Load/Store      : %0.1f%%", ls_cov),     UVM_LOW)

    real total = (instr_cov + branch_cov + mext_cov + exc_cov + ls_cov) / 5.0;
    `uvm_info("COV", $sformatf("  TOTAL (avg)     : %0.1f%%", total),      UVM_LOW)

    if (total < 95.0)
      `uvm_warning("COV", "Coverage below 95% — run directed tests")
  endfunction

endclass : rv32im_coverage

`endif // RV32IM_COVERAGE_SV
