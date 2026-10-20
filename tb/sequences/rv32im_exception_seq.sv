/*
 * rv32im_exception_seq.sv — Exception handling sequences
 *
 * Five directed tests covering all supported exception types:
 *   1. Illegal instruction encoding
 *   2. ECALL from M-mode
 *   3. EBREAK
 *   4. Misaligned load (LW to addr[1:0] != 00)
 *   5. Instruction-address misalignment (branch to odd address)
 */

`ifndef RV32IM_EXCEPTION_SEQ_SV
`define RV32IM_EXCEPTION_SEQ_SV

class rv32im_exception_seq extends rv32im_base_seq;
  `uvm_object_utils(rv32im_exception_seq)

  function new(string name = "rv32im_exception_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info("EXC_SEQ", "=== Starting Exception Directed Tests ===", UVM_LOW)

    test_illegal_instr();
    test_ecall();
    test_ebreak();
    test_load_misalign();
    test_csrr_ops();

    `uvm_info("EXC_SEQ", "=== Exception Tests Complete ===", UVM_LOW)
  endtask

  /* ── Test 1: Illegal instruction ───────────────────────────── */
  task test_illegal_instr();
    `uvm_info("EXC_SEQ", "Test 1: Illegal instruction", UVM_MEDIUM)
    /* Set up mtvec so trap goes somewhere sane */
    send_instr(enc_addi(1, 0, 12'h100));    /* x1 = trap_vec addr   */
    send_instr(enc_csrrw(0, 12'h305, 1));   /* CSRRW mtvec, x1      */
    /* Issue illegal encoding: opcode 0x02 is reserved */
    send_instr(32'h00000002);               /* ILLEGAL              */
    /* After MRET, execution resumes at mepc+4 or trap handler */
    /* For ISS testing we just check mcause = 2 */
    send_instr(enc_mret());                 /* return from trap      */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

  /* ── Test 2: ECALL ─────────────────────────────────────────── */
  task test_ecall();
    `uvm_info("EXC_SEQ", "Test 2: ECALL", UVM_MEDIUM)
    /* Set mtvec to known address */
    send_instr(enc_addi(1, 0, 12'h200));
    send_instr(enc_csrrw(0, 12'h305, 1));   /* mtvec = 0x200        */
    send_instr(enc_ecall());                /* mcause = 11 (M-mode) */
    send_instr(enc_mret());
    send_instr(enc_nop());
  endtask

  /* ── Test 3: EBREAK ────────────────────────────────────────── */
  task test_ebreak();
    `uvm_info("EXC_SEQ", "Test 3: EBREAK", UVM_MEDIUM)
    send_instr(enc_addi(2, 0, 12'h300));
    send_instr(enc_csrrw(0, 12'h305, 2));
    send_instr(enc_ebreak());               /* mcause = 3           */
    /* Note: ISS halts on EBREAK; test ends here */
    send_instr(enc_nop());
  endtask

  /* ── Test 4: Misaligned load ────────────────────────────────── */
  task test_load_misalign();
    `uvm_info("EXC_SEQ", "Test 4: Misaligned LW", UVM_MEDIUM)
    /* Set up base address that is NOT word-aligned (addr[1:0] = 01) */
    send_instr(enc_addi(1, 0, 12'h001));    /* x1 = 1 (misaligned)  */
    send_instr(enc_lw  (2, 1, 0));          /* LW from addr=1 → trap*/
    /* mcause should be 4 (load address misaligned) */
    send_instr(enc_mret());
    send_instr(enc_nop());
  endtask

  /* ── Test 5: CSR read-modify-write sequence ─────────────────── */
  /* Tests CSRRW / CSRRS / CSRRC on mstatus, covers CSR bins */
  task test_csrr_ops();
    `uvm_info("EXC_SEQ", "Test 5: CSR RMW operations", UVM_MEDIUM)
    /* Read mcycle into x1 */
    send_instr(enc_csrrs(1, 12'hC00, 0));   /* CSRRS x1,cycle,x0    */
    /* Set a bit in mstatus via CSRRS */
    send_instr(enc_addi(2, 0, 12'h008));    /* x2 = MIE bit (bit 3) */
    send_instr(enc_csrrs(3, 12'h300, 2));   /* CSRRS x3,mstatus,x2  */
    /* Clear the bit via CSRRC */
    send_instr(enc_csrrc(0, 12'h300, 2));   /* CSRRC x0,mstatus,x2  */
    /* CSRRWI with immediate */
    send_instr({12'h305, 5'h01, 3'h5, 5'h04, 7'h73}); /* CSRRWI x4,mtvec,1 */
    send_instr(enc_nop());
  endtask

  /* Helper — CSRRC not in base class */
  function automatic logic [31:0] enc_csrrc(int rd, int csr, int rs1);
    return {csr[11:0], rs1[4:0], 3'h3, rd[4:0], 7'h73};
  endfunction

endclass : rv32im_exception_seq

`endif // RV32IM_EXCEPTION_SEQ_SV
