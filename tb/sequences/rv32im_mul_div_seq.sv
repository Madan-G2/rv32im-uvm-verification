/*
 * rv32im_mul_div_seq.sv — M-extension directed sequences
 *
 * Seven directed tests covering all MUL/DIV/REM variants
 * and the mandatory spec corner cases.
 */

`ifndef RV32IM_MUL_DIV_SEQ_SV
`define RV32IM_MUL_DIV_SEQ_SV

class rv32im_mul_div_seq extends rv32im_base_seq;
  `uvm_object_utils(rv32im_mul_div_seq)

  function new(string name = "rv32im_mul_div_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info("MULDIV_SEQ", "=== Starting M-Extension Directed Tests ===", UVM_LOW)

    test_mul_basic();
    test_mulh_variants();
    test_div_basic();
    test_div_by_zero();           /* BUG-004 target */
    test_div_overflow();
    test_rem_remu();
    test_mul_negative();

    `uvm_info("MULDIV_SEQ", "=== M-Extension Tests Complete ===", UVM_LOW)
  endtask

  /* ── Test 1: MUL basic ──────────────────────────────────────── */
  task test_mul_basic();
    `uvm_info("MULDIV_SEQ", "Test 1: MUL basic (3 × 7 = 21)", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h003));    /* x1 = 3               */
    send_instr(enc_addi(2, 0, 12'h007));    /* x2 = 7               */
    send_instr(enc_mul (3, 1, 2));          /* x3 = 21              */
    send_instr(enc_nop());
    /* MUL producing zero */
    send_instr(enc_addi(4, 0, 12'h000));    /* x4 = 0               */
    send_instr(enc_mul (5, 4, 1));          /* x5 = 0 × 3 = 0       */
    send_instr(enc_nop());
  endtask

  /* ── Test 2: MULH / MULHU / MULHSU variants ─────────────────── */
  task test_mulh_variants();
    `uvm_info("MULDIV_SEQ", "Test 2: MULH/MULHU/MULHSU", UVM_MEDIUM)
    /* Large values to exercise upper 32 bits */
    send_instr(enc_lui  (1, 20'h7FFFF));    /* x1 ≈ 0x7FFFF000      */
    send_instr(enc_lui  (2, 20'h00002));    /* x2 ≈ 0x00002000      */

    send_instr(enc_mulh  (3, 1, 2));        /* upper(signed×signed)  */
    send_instr(enc_mulhu (4, 1, 2));        /* upper(unsigned×unsigned)*/
    send_instr(enc_mulhsu(5, 1, 2));        /* upper(signed×unsigned) */
    send_instr(enc_nop());

    /* Negative × positive */
    send_instr(enc_addi(6, 0, 12'hFF0 & 12'hFFF)); /* x6 = -16 (sign ext) */
    send_instr(enc_addi(7, 0, 12'h002));    /* x7 = 2               */
    send_instr(enc_mul  (8, 6, 7));         /* x8 = -32             */
    send_instr(enc_mulh (9, 6, 7));         /* upper 32 of -32 = -1  */
    send_instr(enc_nop());
  endtask

  /* ── Test 3: DIV basic ──────────────────────────────────────── */
  task test_div_basic();
    `uvm_info("MULDIV_SEQ", "Test 3: DIV/DIVU basic", UVM_MEDIUM)
    /* 20 / 4 = 5 */
    send_instr(enc_addi(1, 0, 12'h014));    /* x1 = 20              */
    send_instr(enc_addi(2, 0, 12'h004));    /* x2 = 4               */
    send_instr(enc_div  (3, 1, 2));         /* x3 = 5               */
    send_instr(enc_divu (4, 1, 2));         /* x4 = 5               */
    send_instr(enc_nop());
    /* Negative dividend: -20 / 4 = -5 */
    send_instr(enc_addi(5, 0, 12'hFEC & 12'hFFF)); /* x5 = -20     */
    send_instr(enc_div  (6, 5, 2));         /* x6 = -5              */
    send_instr(enc_divu (7, 5, 2));         /* x7 = large positive  */
    send_instr(enc_nop());
  endtask

  /* ── Test 4: DIV by zero — BUG-004 target ───────────────────── */
  /* RISC-V spec §M: dividend/divisor = 0 → quotient = -1 (0xFFFFFFFF)
   *                                        remainder = dividend         */
  task test_div_by_zero();
    `uvm_info("MULDIV_SEQ",
      "Test 4: DIV by zero (spec: quotient = 0xFFFFFFFF)", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h042));    /* x1 = 66              */
    /* x0 always = 0, use as divisor */
    send_instr(enc_div  (3, 1, 0));         /* DIV x3, x1, x0
                                               expected: x3 = 0xFFFF_FFFF */
    send_instr(enc_divu (4, 1, 0));         /* DIVU x4, x1, x0
                                               expected: x4 = 0xFFFF_FFFF */
    send_instr(enc_rem  (5, 1, 0));         /* REM x5, x1, x0
                                               expected: x5 = 66          */
    send_instr(enc_remu (6, 1, 0));         /* REMU x6, x1, x0
                                               expected: x6 = 66          */
    send_instr(enc_nop());
  endtask

  /* ── Test 5: DIV overflow (INT_MIN / -1) ───────────────────── */
  /* RISC-V spec: INT_MIN ÷ -1 → quotient = INT_MIN, remainder = 0 */
  task test_div_overflow();
    `uvm_info("MULDIV_SEQ",
      "Test 5: DIV overflow (INT_MIN / -1)", UVM_MEDIUM)
    /* Load INT_MIN (0x80000000) = LUI x1, 0x80000 */
    send_instr(enc_lui  (1, 20'h80000));    /* x1 = 0x80000000      */
    /* Load -1 = ADDI x2, x0, -1 */
    send_instr(enc_addi (2, 0, 12'hFFF));   /* x2 = -1 (sign-ext)   */
    send_instr(enc_div  (3, 1, 2));         /* x3 = INT_MIN (0x80000000) */
    send_instr(enc_rem  (4, 1, 2));         /* x4 = 0               */
    send_instr(enc_nop());
  endtask

  /* ── Test 6: REM / REMU basic ───────────────────────────────── */
  task test_rem_remu();
    `uvm_info("MULDIV_SEQ", "Test 6: REM/REMU basic", UVM_MEDIUM)
    /* 17 % 5 = 2 */
    send_instr(enc_addi(1, 0, 12'h011));    /* x1 = 17              */
    send_instr(enc_addi(2, 0, 12'h005));    /* x2 = 5               */
    send_instr(enc_rem  (3, 1, 2));         /* x3 = 2               */
    send_instr(enc_remu (4, 1, 2));         /* x4 = 2               */
    send_instr(enc_nop());
    /* -17 % 5 = -2 (signed) */
    send_instr(enc_addi(5, 0, 12'hFEF & 12'hFFF)); /* x5 = -17     */
    send_instr(enc_rem  (6, 5, 2));         /* x6 = -2              */
    send_instr(enc_nop());
  endtask

  /* ── Test 7: MUL negative operands ─────────────────────────── */
  task test_mul_negative();
    `uvm_info("MULDIV_SEQ", "Test 7: MUL with negative operands", UVM_MEDIUM)
    /* -1 × -1 = 1 */
    send_instr(enc_addi(1, 0, 12'hFFF));    /* x1 = -1              */
    send_instr(enc_addi(2, 0, 12'hFFF));    /* x2 = -1              */
    send_instr(enc_mul (3, 1, 2));          /* x3 = 1               */
    send_instr(enc_mulh(4, 1, 2));          /* x4 = 0 (upper)       */
    send_instr(enc_nop());
    /* INT_MIN × 2 (overflow test) */
    send_instr(enc_lui  (5, 20'h80000));    /* x5 = INT_MIN         */
    send_instr(enc_addi (6, 0, 12'h002));   /* x6 = 2               */
    send_instr(enc_mul  (7, 5, 6));         /* x7 = 0 (overflow)    */
    send_instr(enc_mulh (8, 5, 6));         /* x8 = -1 (upper)      */
    send_instr(enc_nop());
  endtask

endclass : rv32im_mul_div_seq

`endif // RV32IM_MUL_DIV_SEQ_SV
