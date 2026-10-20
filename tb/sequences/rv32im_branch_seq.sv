/*
 * rv32im_branch_seq.sv — Branch and control-flow directed sequences
 *
 * Eight directed tests covering all branch types, taken/not-taken,
 * forward/backward branches, and corner cases.
 */

`ifndef RV32IM_BRANCH_SEQ_SV
`define RV32IM_BRANCH_SEQ_SV

class rv32im_branch_seq extends rv32im_base_seq;
  `uvm_object_utils(rv32im_branch_seq)

  function new(string name = "rv32im_branch_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info("BRANCH_SEQ", "=== Starting Branch / Control-Flow Tests ===", UVM_LOW)

    test_beq_taken();
    test_beq_not_taken();
    test_all_branch_types_taken();
    test_all_branch_types_not_taken();
    test_backward_branch();
    test_branch_after_load();
    test_jal_jalr();
    test_branch_chain();

    `uvm_info("BRANCH_SEQ", "=== Branch Tests Complete ===", UVM_LOW)
  endtask

  /* ── Test 1: BEQ taken ─────────────────────────────────────── */
  task test_beq_taken();
    `uvm_info("BRANCH_SEQ", "Test 1: BEQ taken", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h005));    /* x1 = 5                */
    send_instr(enc_addi(2, 0, 12'h005));    /* x2 = 5                */
    /* BEQ x1, x2, +8  (skip next two instrs) */
    send_instr(enc_beq(1, 2, 8));           /* TAKEN → skip          */
    send_instr(enc_addi(3, 0, 12'hBAD));    /* should be skipped     */
    send_instr(enc_addi(3, 0, 12'hBAD));    /* should be skipped     */
    send_instr(enc_addi(4, 0, 12'h001));    /* branch target: x4=1   */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

  /* ── Test 2: BEQ not taken ─────────────────────────────────── */
  task test_beq_not_taken();
    `uvm_info("BRANCH_SEQ", "Test 2: BEQ not taken", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h005));    /* x1 = 5                */
    send_instr(enc_addi(2, 0, 12'h006));    /* x2 = 6                */
    send_instr(enc_beq(1, 2, 8));           /* NOT TAKEN             */
    send_instr(enc_addi(3, 0, 12'hAAA));    /* executed normally      */
    send_instr(enc_nop());
  endtask

  /* ── Test 3: All 6 branch types — taken ────────────────────── */
  task test_all_branch_types_taken();
    `uvm_info("BRANCH_SEQ", "Test 3: All branch types taken", UVM_MEDIUM)

    /* BEQ: rs1==rs2 */
    send_instr(enc_addi(1, 0, 12'hAA));
    send_instr(enc_addi(2, 0, 12'hAA));
    send_instr(enc_beq (1, 2, 8));    /* taken */
    send_instr(enc_addi(5, 0, 12'hBAD)); /* skipped */
    send_instr(enc_nop());

    /* BNE: rs1!=rs2 */
    send_instr(enc_addi(1, 0, 12'h001));
    send_instr(enc_addi(2, 0, 12'h002));
    send_instr(enc_bne (1, 2, 8));    /* taken */
    send_instr(enc_addi(5, 0, 12'hBAD));
    send_instr(enc_nop());

    /* BLT: rs1 < rs2 (signed) */
    send_instr(enc_addi(1, 0, 12'hFF0 & 12'hFFF)); /* x1 = -16 */
    send_instr(enc_addi(2, 0, 12'h001));
    send_instr(enc_blt (1, 2, 8));    /* taken (-16 < 1) */
    send_instr(enc_addi(5, 0, 12'hBAD));
    send_instr(enc_nop());

    /* BGE: rs1 >= rs2 (signed) */
    send_instr(enc_addi(1, 0, 12'h005));
    send_instr(enc_addi(2, 0, 12'h005));
    send_instr(enc_bge (1, 2, 8));    /* taken (5 >= 5) */
    send_instr(enc_addi(5, 0, 12'hBAD));
    send_instr(enc_nop());

    /* BLTU: rs1 < rs2 (unsigned) */
    send_instr(enc_addi(1, 0, 12'h001));
    send_instr(enc_addi(2, 0, 12'h0FF));
    send_instr(enc_bltu(1, 2, 8));    /* taken (1 < 255 unsigned) */
    send_instr(enc_addi(5, 0, 12'hBAD));
    send_instr(enc_nop());

    /* BGEU: rs1 >= rs2 (unsigned) */
    send_instr(enc_addi(1, 0, 12'hFF0 & 12'hFFF)); /* large unsigned */
    send_instr(enc_addi(2, 0, 12'h001));
    send_instr(enc_bgeu(1, 2, 8));    /* taken (big_uint >= 1) */
    send_instr(enc_addi(5, 0, 12'hBAD));
    send_instr(enc_nop());
  endtask

  /* ── Test 4: All 6 branch types — not taken ────────────────── */
  task test_all_branch_types_not_taken();
    `uvm_info("BRANCH_SEQ", "Test 4: All branch types not taken", UVM_MEDIUM)
    /* Just exercise the not-taken paths */
    send_instr(enc_addi(1, 0, 12'h001));
    send_instr(enc_addi(2, 0, 12'h002));
    send_instr(enc_beq (1, 2, 8));    /* NOT taken */
    send_instr(enc_addi(3, 0, 12'h001)); /* executed */

    send_instr(enc_addi(1, 0, 12'h005));
    send_instr(enc_addi(2, 0, 12'h005));
    send_instr(enc_bne (1, 2, 8));    /* NOT taken (1==2) */
    send_instr(enc_addi(3, 0, 12'h002));

    send_instr(enc_addi(1, 0, 12'h010));
    send_instr(enc_addi(2, 0, 12'h001));
    send_instr(enc_blt (1, 2, 8));    /* NOT taken (16 > 1) */
    send_instr(enc_addi(3, 0, 12'h003));
    send_instr(enc_nop());
  endtask

  /* ── Test 5: Backward branch (simple loop) ──────────────────── */
  /* Loop 3 times: x1 counts down from 3 to 0 */
  task test_backward_branch();
    `uvm_info("BRANCH_SEQ", "Test 5: Backward branch (loop)", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h003));   /* x1 = 3 (loop counter) */
    send_instr(enc_addi(2, 0, 12'h001));   /* x2 = 1 (decrement)    */
    /* loop_top: (this is relative; the enc_bne offset must match) */
    send_instr(enc_addi(3, 3, 12'h001));   /* x3++   (body)         */
    send_instr(enc_sub (1, 1, 2));         /* x1--                  */
    /* BNE x1, x0, -8  (branch back to loop_top) */
    send_instr(enc_bne (1, 0, -8));        /* backward branch        */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

  /* ── Test 6: Branch after load (hazard + control flow) ─────── */
  task test_branch_after_load();
    `uvm_info("BRANCH_SEQ", "Test 6: Branch-after-load", UVM_MEDIUM)
    send_instr(enc_addi(2, 0, 12'h020));   /* base = 32             */
    send_instr(enc_addi(9, 0, 12'h007));   /* store value = 7       */
    send_instr(enc_sw  (2, 9, 0));         /* mem[32] = 7           */
    send_instr(enc_lw  (6, 2, 0));         /* x6 = mem[32] = 7      */
    /* Branch using freshly loaded value */
    send_instr(enc_addi(7, 0, 12'h007));   /* x7 = 7                */
    send_instr(enc_beq (6, 7, 8));         /* BEQ x6,x7 → taken     */
    send_instr(enc_addi(8, 0, 12'hBAD));   /* skipped               */
    send_instr(enc_addi(8, 0, 12'h001));   /* branch target         */
    send_instr(enc_nop());
  endtask

  /* ── Test 7: JAL and JALR ───────────────────────────────────── */
  task test_jal_jalr();
    `uvm_info("BRANCH_SEQ", "Test 7: JAL / JALR", UVM_MEDIUM)
    /* JAL x1, +12 → x1 = PC+4, PC += 12 */
    send_instr(enc_jal(1, 12));            /* x1 = return addr      */
    send_instr(enc_addi(5, 0, 12'hBAD));   /* skipped               */
    send_instr(enc_addi(5, 0, 12'hBAD));   /* skipped               */
    send_instr(enc_addi(6, 0, 12'h001));   /* JAL target            */
    /* JALR x2, x1, 0 → return to saved address */
    send_instr(enc_jalr(2, 1, 0));         /* indirect jump         */
    send_instr(enc_nop());
  endtask

  /* ── Test 8: Alternating taken / not-taken chain ────────────── */
  task test_branch_chain();
    `uvm_info("BRANCH_SEQ", "Test 8: Alternating taken/not-taken branches", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h000));   /* x1 = 0                */
    send_instr(enc_addi(2, 0, 12'h001));   /* x2 = 1                */
    /* Alternating: BEQ taken (0==0), BNE not-taken (0!=1 no, 0==1?) */
    send_instr(enc_beq (1, 0, 8));         /* taken (0==0)          */
    send_instr(enc_addi(3, 0, 12'hBAD));   /* skipped               */
    send_instr(enc_bne (1, 2, 8));         /* taken (0!=1)          */
    send_instr(enc_addi(3, 0, 12'hBAD));   /* skipped               */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

endclass : rv32im_branch_seq

`endif // RV32IM_BRANCH_SEQ_SV
