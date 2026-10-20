/*
 * rv32im_pkg.sv — UVM package for RV32IM verification environment
 *
 * Contains:
 *   - DPI-C import declarations
 *   - Shared typedefs and enums
 *   - rv32im_txn (sequence item)
 *
 * Include order in flist.f:
 *   1. rv32im_pkg.sv          (this file)
 *   2. rv32im_if.sv
 *   3. All env / seq / test files
 */

`ifndef RV32IM_PKG_SV
`define RV32IM_PKG_SV

package rv32im_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  /* ================================================================
   * DPI-C imports — C golden reference model
   * ================================================================*/
  import "DPI-C" context function void iss_dpi_init    ();
  import "DPI-C" context function void iss_dpi_reset   ();
  import "DPI-C" context function void iss_dpi_write_instr(
      input  int unsigned addr,
      input  int unsigned word);
  import "DPI-C" context function void iss_dpi_step(
      input  int unsigned instr,
      input  int unsigned pc,
      output int unsigned rd_o,
      output int unsigned result_o,
      output int unsigned next_pc_o,
      output int          trap_o,
      output int unsigned mcause_o,
      output int unsigned mepc_o);
  import "DPI-C" context function void iss_dpi_dump_regs ();
  import "DPI-C" context function void iss_dpi_set_verbose(input int v);
  import "DPI-C" context function int unsigned iss_dpi_get_reg(input int idx);

  /* ================================================================
   * Instruction type enum
   * ================================================================*/
  typedef enum logic [2:0] {
    R_TYPE  = 3'd0,
    I_TYPE  = 3'd1,
    S_TYPE  = 3'd2,
    B_TYPE  = 3'd3,
    U_TYPE  = 3'd4,
    J_TYPE  = 3'd5,
    CSR_TYPE= 3'd6,
    SYS_TYPE= 3'd7
  } instr_type_e;

  /* Opcode constants (bits [6:0]) */
  typedef enum logic [6:0] {
    OP_LUI    = 7'h37,
    OP_AUIPC  = 7'h17,
    OP_JAL    = 7'h6F,
    OP_JALR   = 7'h67,
    OP_BRANCH = 7'h63,
    OP_LOAD   = 7'h03,
    OP_STORE  = 7'h23,
    OP_IMM    = 7'h13,
    OP_REG    = 7'h33,
    OP_FENCE  = 7'h0F,
    OP_SYSTEM = 7'h73
  } opcode_e;

  /* funct3 for branches */
  typedef enum logic [2:0] {
    BEQ  = 3'h0, BNE  = 3'h1,
    BLT  = 3'h4, BGE  = 3'h5,
    BLTU = 3'h6, BGEU = 3'h7
  } branch_funct3_e;

  /* ================================================================
   * rv32im_txn — sequence item (stimulus + observed)
   * ================================================================*/
  class rv32im_txn extends uvm_sequence_item;
    `uvm_object_utils_begin(rv32im_txn)
      `uvm_field_int  (instr,      UVM_ALL_ON)
      `uvm_field_int  (pc,         UVM_ALL_ON)
      `uvm_field_int  (rd,         UVM_ALL_ON)
      `uvm_field_int  (result,     UVM_ALL_ON)
      `uvm_field_int  (rs1_val,    UVM_ALL_ON)
      `uvm_field_int  (rs2_val,    UVM_ALL_ON)
      `uvm_field_enum (instr_type_e, itype, UVM_ALL_ON)
      `uvm_field_int  (is_trap,    UVM_ALL_ON)
      `uvm_field_int  (mcause,     UVM_ALL_ON)
    `uvm_object_utils_end

    /* ---- Stimulus fields (set by sequence, driven by driver) ---- */
    rand logic [31:0] instr;       /* 32-bit instruction encoding       */
    rand instr_type_e itype;       /* decoded type (for coverage)       */
    rand logic [31:0] rs1_val;     /* initial rs1 value to preload      */
    rand logic [31:0] rs2_val;     /* initial rs2 value to preload      */
    rand logic [7:0]  mem_latency; /* instruction grant latency (0-3)   */

    /* ---- Observed fields (filled by monitor) ---- */
    logic [31:0] pc;
    logic [4:0]  rd;
    logic [31:0] result;
    logic        is_trap;
    logic [31:0] mcause;
    logic [31:0] mepc;

    /* ---- Default constraints ---- */
    constraint c_mem_latency { mem_latency inside {[0:3]}; }

    /* Derive itype from opcode */
    constraint c_itype_from_opcode {
      (instr[6:0] == 7'h33) -> itype == R_TYPE;
      (instr[6:0] == 7'h13) -> itype == I_TYPE;
      (instr[6:0] == 7'h23) -> itype == S_TYPE;
      (instr[6:0] == 7'h63) -> itype == B_TYPE;
      (instr[6:0] inside {7'h37, 7'h17}) -> itype == U_TYPE;
      (instr[6:0] == 7'h6F) -> itype == J_TYPE;
      (instr[6:0] == 7'h73 && instr[14:12] != 3'h0) -> itype == CSR_TYPE;
      (instr[6:0] == 7'h73 && instr[14:12] == 3'h0) -> itype == SYS_TYPE;
    }

    function new(string name = "rv32im_txn");
      super.new(name);
    endfunction

    /* Decode opcode string for reporting */
    function string opcode_str();
      case (instr[6:0])
        7'h37: return "LUI";
        7'h17: return "AUIPC";
        7'h6F: return "JAL";
        7'h67: return "JALR";
        7'h63: return $sformatf("BRANCH(f3=%0h)", instr[14:12]);
        7'h03: return $sformatf("LOAD(f3=%0h)",   instr[14:12]);
        7'h23: return $sformatf("STORE(f3=%0h)",  instr[14:12]);
        7'h13: return $sformatf("ALUI(f3=%0h)",   instr[14:12]);
        7'h33: return (instr[31:25]==7'h01) ?
                      $sformatf("MEXT(f3=%0h)",   instr[14:12]) :
                      $sformatf("ALU(f3=%0h)",    instr[14:12]);
        7'h73: return (instr[14:12]==0) ? "SYSTEM" : "CSR";
        default: return "UNKNOWN";
      endcase
    endfunction

  endclass : rv32im_txn

endpackage : rv32im_pkg

`endif // RV32IM_PKG_SV
