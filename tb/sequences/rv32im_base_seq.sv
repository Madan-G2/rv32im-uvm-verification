/*
 * rv32im_base_seq.sv — Base sequence class
 *
 * Provides instruction-encoding helper tasks used by all derived sequences.
 * Derived sequences override body() to build their specific instruction stream.
 */

`ifndef RV32IM_BASE_SEQ_SV
`define RV32IM_BASE_SEQ_SV

class rv32im_base_seq extends uvm_sequence #(rv32im_txn);
  `uvm_object_utils(rv32im_base_seq)

  /* Number of instructions to generate per run */
  int unsigned num_instrs = 50;

  function new(string name = "rv32im_base_seq");
    super.new(name);
  endfunction

  /* ================================================================
   * Instruction encoding helpers
   * All return a 32-bit instruction word.
   * Register indices are 0..31; immediates are passed as integers
   * and masked to the appropriate field width internally.
   * ================================================================*/

  /* ── R-type ──────────────────────────────────────────────── */
  function automatic logic [31:0] enc_r(
    input int funct7, input int rs2, input int rs1,
    input int funct3, input int rd,  input int opcode);
    return {funct7[6:0], rs2[4:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]};
  endfunction

  function automatic logic [31:0] enc_add (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h0, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_sub (int rd, int rs1, int rs2);
    return enc_r(7'h20, rs2, rs1, 3'h0, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_sll (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h1, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_slt (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h2, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_sltu(int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h3, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_xor (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h4, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_srl (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h5, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_sra (int rd, int rs1, int rs2);
    return enc_r(7'h20, rs2, rs1, 3'h5, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_or  (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h6, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_and (int rd, int rs1, int rs2);
    return enc_r(7'h00, rs2, rs1, 3'h7, rd, 7'h33); endfunction

  /* M-extension R-type */
  function automatic logic [31:0] enc_mul   (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h0, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_mulh  (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h1, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_mulhsu(int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h2, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_mulhu (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h3, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_div   (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h4, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_divu  (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h5, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_rem   (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h6, rd, 7'h33); endfunction
  function automatic logic [31:0] enc_remu  (int rd, int rs1, int rs2);
    return enc_r(7'h01, rs2, rs1, 3'h7, rd, 7'h33); endfunction

  /* ── I-type ──────────────────────────────────────────────── */
  function automatic logic [31:0] enc_i(
    input int imm12, input int rs1, input int funct3,
    input int rd, input int opcode);
    return {imm12[11:0], rs1[4:0], funct3[2:0], rd[4:0], opcode[6:0]};
  endfunction

  function automatic logic [31:0] enc_addi (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h0, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_slti (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h2, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_sltiu(int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h3, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_xori (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h4, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_ori  (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h6, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_andi (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h7, rd, 7'h13); endfunction
  function automatic logic [31:0] enc_slli (int rd, int rs1, int shamt);
    return {7'h00, shamt[4:0], rs1[4:0], 3'h1, rd[4:0], 7'h13}; endfunction
  function automatic logic [31:0] enc_srli (int rd, int rs1, int shamt);
    return {7'h00, shamt[4:0], rs1[4:0], 3'h5, rd[4:0], 7'h13}; endfunction
  function automatic logic [31:0] enc_srai (int rd, int rs1, int shamt);
    return {7'h20, shamt[4:0], rs1[4:0], 3'h5, rd[4:0], 7'h13}; endfunction
  function automatic logic [31:0] enc_jalr (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h0, rd, 7'h67); endfunction

  /* Loads */
  function automatic logic [31:0] enc_lb  (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h0, rd, 7'h03); endfunction
  function automatic logic [31:0] enc_lh  (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h1, rd, 7'h03); endfunction
  function automatic logic [31:0] enc_lw  (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h2, rd, 7'h03); endfunction
  function automatic logic [31:0] enc_lbu (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h4, rd, 7'h03); endfunction
  function automatic logic [31:0] enc_lhu (int rd, int rs1, int imm);
    return enc_i(imm, rs1, 3'h5, rd, 7'h03); endfunction

  /* ── S-type (stores) ─────────────────────────────────────── */
  function automatic logic [31:0] enc_s(
    input int imm12, input int rs2, input int rs1,
    input int funct3, input int opcode);
    return {imm12[11:5], rs2[4:0], rs1[4:0], funct3[2:0], imm12[4:0], opcode[6:0]};
  endfunction

  function automatic logic [31:0] enc_sb (int rs1, int rs2, int imm);
    return enc_s(imm, rs2, rs1, 3'h0, 7'h23); endfunction
  function automatic logic [31:0] enc_sh (int rs1, int rs2, int imm);
    return enc_s(imm, rs2, rs1, 3'h1, 7'h23); endfunction
  function automatic logic [31:0] enc_sw (int rs1, int rs2, int imm);
    return enc_s(imm, rs2, rs1, 3'h2, 7'h23); endfunction

  /* ── B-type (branches) ───────────────────────────────────── */
  function automatic logic [31:0] enc_b(
    input int imm13, input int rs2, input int rs1,
    input int funct3);
    logic [12:1] b = imm13[12:1];
    return {b[12], b[10:5], rs2[4:0], rs1[4:0], funct3[2:0], b[4:1], b[11], 7'h63};
  endfunction

  function automatic logic [31:0] enc_beq (int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h0); endfunction
  function automatic logic [31:0] enc_bne (int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h1); endfunction
  function automatic logic [31:0] enc_blt (int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h4); endfunction
  function automatic logic [31:0] enc_bge (int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h5); endfunction
  function automatic logic [31:0] enc_bltu(int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h6); endfunction
  function automatic logic [31:0] enc_bgeu(int rs1, int rs2, int imm);
    return enc_b(imm, rs2, rs1, 3'h7); endfunction

  /* ── U-type ──────────────────────────────────────────────── */
  function automatic logic [31:0] enc_lui  (int rd, int imm20);
    return {imm20[19:0], rd[4:0], 7'h37}; endfunction
  function automatic logic [31:0] enc_auipc(int rd, int imm20);
    return {imm20[19:0], rd[4:0], 7'h17}; endfunction

  /* ── J-type (JAL) ────────────────────────────────────────── */
  function automatic logic [31:0] enc_jal(int rd, int imm21);
    logic [20:1] j = imm21[20:1];
    return {j[20], j[10:1], j[11], j[19:12], rd[4:0], 7'h6F};
  endfunction

  /* ── NOP ─────────────────────────────────────────────────── */
  function automatic logic [31:0] enc_nop();
    return enc_addi(0, 0, 0); /* ADDI x0, x0, 0 */
  endfunction

  /* ── CSR / System ────────────────────────────────────────── */
  function automatic logic [31:0] enc_csrrw(int rd, int csr, int rs1);
    return {csr[11:0], rs1[4:0], 3'h1, rd[4:0], 7'h73}; endfunction
  function automatic logic [31:0] enc_csrrs(int rd, int csr, int rs1);
    return {csr[11:0], rs1[4:0], 3'h2, rd[4:0], 7'h73}; endfunction
  function automatic logic [31:0] enc_ecall();
    return 32'h00000073; endfunction
  function automatic logic [31:0] enc_ebreak();
    return 32'h00100073; endfunction
  function automatic logic [31:0] enc_mret();
    return 32'h30200073; endfunction

  /* ================================================================
   * send_instr: create a txn from an encoded instruction and send it
   * ================================================================*/
  task automatic send_instr(logic [31:0] instr_word,
                             instr_type_e itype = R_TYPE);
    rv32im_txn txn;
    txn = rv32im_txn::type_id::create("txn");
    start_item(txn);
    txn.instr = instr_word;
    txn.itype = itype;
    finish_item(txn);
  endtask

  /* Default body — subclasses override */
  virtual task body();
    `uvm_fatal("BASE_SEQ", "body() not overridden in derived sequence")
  endtask

endclass : rv32im_base_seq

`endif // RV32IM_BASE_SEQ_SV
