/*
 * rv32im_hazard_seq.sv — Data hazard directed sequences
 *
 * Eight directed tests targeting pipeline hazard scenarios:
 *   1. RAW EX→EX  (back-to-back register dependency)
 *   2. RAW MEM→EX (one instruction gap)
 *   3. RAW WB→EX  (two instruction gap — no stall needed)
 *   4. Load-use stall (LOAD followed immediately by dependent ALU)
 *   5. Store-after-load (load then store same address)
 *   6. RAW through all 31 GPR pairs
 *   7. Double dependency (rs1 and rs2 both depend on prior results)
 *   8. Chain: A→B→C→D (four-deep forwarding chain)
 */

`ifndef RV32IM_HAZARD_SEQ_SV
`define RV32IM_HAZARD_SEQ_SV

class rv32im_hazard_seq extends rv32im_base_seq;
  `uvm_object_utils(rv32im_hazard_seq)

  function new(string name = "rv32im_hazard_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info("HAZARD_SEQ", "=== Starting Data Hazard Directed Tests ===", UVM_LOW)

    test_raw_ex_ex();
    test_raw_mem_ex();
    test_raw_wb_ex();
    test_load_use();
    test_store_after_load();
    test_all_gpr_pairs();
    test_double_dependency();
    test_forwarding_chain();

    `uvm_info("HAZARD_SEQ", "=== All Hazard Tests Complete ===", UVM_LOW)
  endtask

  /* ── Test 1: RAW EX→EX — back-to-back ──────────────────────── */
  /* x1 = x2 + x3;  x4 = x1 + x5   ← x1 must be forwarded MEM→EX */
  task test_raw_ex_ex();
    `uvm_info("HAZARD_SEQ", "Test 1: RAW EX→EX", UVM_MEDIUM)
    send_instr(enc_addi(2, 0, 12'h0A5));    /* x2 = 165              */
    send_instr(enc_addi(3, 0, 12'h05A));    /* x3 = 90               */
    send_instr(enc_addi(5, 0, 12'h001));    /* x5 = 1                */
    send_instr(enc_add (1, 2, 3));          /* x1 = x2+x3 = 255      */
    send_instr(enc_add (4, 1, 5));          /* x4 = x1+x5 ← HAZARD  */
    send_instr(enc_nop());
  endtask

  /* ── Test 2: RAW MEM→EX — one instruction gap ──────────────── */
  task test_raw_mem_ex();
    `uvm_info("HAZARD_SEQ", "Test 2: RAW MEM→EX", UVM_MEDIUM)
    send_instr(enc_addi(10, 0, 12'hABC & 12'hFFF)); /* x10 = value  */
    send_instr(enc_addi(11, 0, 12'h001));            /* x11 = 1      */
    send_instr(enc_add (12, 10, 11));                /* x12 = x10+x11*/
    send_instr(enc_addi(13, 0, 12'h000));            /* gap instr     */
    send_instr(enc_add (14, 12, 11));       /* x14 = x12+1 ← HAZARD */
    send_instr(enc_nop());
  endtask

  /* ── Test 3: RAW WB→EX — two instruction gap (no stall) ─────── */
  task test_raw_wb_ex();
    `uvm_info("HAZARD_SEQ", "Test 3: RAW WB→EX (no stall expected)", UVM_MEDIUM)
    send_instr(enc_addi(20, 0, 12'h100));   /* x20 = 256             */
    send_instr(enc_addi(21, 0, 12'h001));   /* gap                   */
    send_instr(enc_addi(22, 0, 12'h002));   /* gap                   */
    send_instr(enc_add (23, 20, 21));       /* x23 = x20+x21 ← WB→EX*/
    send_instr(enc_nop());
  endtask

  /* ── Test 4: Load-use stall ─────────────────────────────────── */
  /* LW x6, 0(x2) followed immediately by ADD x7, x6, x3
   * Pipeline must stall one cycle for load-use hazard             */
  task test_load_use();
    `uvm_info("HAZARD_SEQ", "Test 4: Load-use stall", UVM_MEDIUM)
    /* Set up base address in x2 (data memory offset 0) */
    send_instr(enc_addi(2, 0, 12'h004));    /* x2 = 4 (byte addr)   */
    /* Pre-store a known value so load returns something useful */
    send_instr(enc_addi(8, 0, 12'h0BE));    /* x8 = 0xBE             */
    send_instr(enc_sw  (2, 8, 0));          /* mem[x2] = x8          */
    /* Load-use hazard pair */
    send_instr(enc_lw  (6, 2, 0));          /* x6 = mem[x2]   ← LOAD*/
    send_instr(enc_add (7, 6, 3));          /* x7 = x6+x3   ← USE   */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

  /* ── Test 5: Store after load ──────────────────────────────── */
  task test_store_after_load();
    `uvm_info("HAZARD_SEQ", "Test 5: Store-after-load same address", UVM_MEDIUM)
    send_instr(enc_addi(2, 0, 12'h010));    /* base addr = 16        */
    send_instr(enc_addi(9, 0, 12'hCAF & 12'hFFF)); /* x9 = data     */
    send_instr(enc_sw  (2, 9, 0));          /* store to mem[16]      */
    send_instr(enc_lw  (10, 2, 0));         /* load from mem[16]     */
    send_instr(enc_add (11, 10, 9));        /* x11 = loaded+original */
    send_instr(enc_sw  (2, 11, 0));         /* store back            */
    send_instr(enc_nop());
  endtask

  /* ── Test 6: RAW hazard through all GPR pairs (x1..x15) ────── */
  task test_all_gpr_pairs();
    `uvm_info("HAZARD_SEQ", "Test 6: RAW through GPR pairs x1..x15", UVM_MEDIUM)
    for (int r = 1; r <= 14; r++) begin
      /* xr = xr + 1; x(r+1) = xr + 1  ← RAW on xr */
      send_instr(enc_addi(r,     0, r));       /* initialise xr    */
      send_instr(enc_addi(r+1, r, 1));         /* x(r+1) = xr+1   */
      send_instr(enc_add (r+1, r, r+1));       /* depends on both  */
    end
    send_instr(enc_nop());
  endtask

  /* ── Test 7: Double dependency (rs1 AND rs2 both hazarded) ──── */
  task test_double_dependency();
    `uvm_info("HAZARD_SEQ", "Test 7: Double dependency", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'hA));      /* x1 = 10               */
    send_instr(enc_addi(2, 0, 12'hB));      /* x2 = 11               */
    send_instr(enc_add (3, 1, 2));          /* x3 = x1+x2 = 21       */
    send_instr(enc_add (4, 3, 3));          /* x4 = x3+x3 ← both hazard */
    send_instr(enc_nop());
  endtask

  /* ── Test 8: Forwarding chain A→B→C→D ───────────────────────── */
  task test_forwarding_chain();
    `uvm_info("HAZARD_SEQ", "Test 8: Four-deep forwarding chain", UVM_MEDIUM)
    send_instr(enc_addi(1, 0, 12'h001));    /* x1 = 1                */
    send_instr(enc_addi(2, 1, 12'h001));    /* x2 = x1+1 = 2         */
    send_instr(enc_addi(3, 2, 12'h001));    /* x3 = x2+1 = 3         */
    send_instr(enc_addi(4, 3, 12'h001));    /* x4 = x3+1 = 4         */
    send_instr(enc_addi(5, 4, 12'h001));    /* x5 = x4+1 = 5         */
    send_instr(enc_add (6, 5, 4));          /* x6 = 5+4 = 9          */
    send_instr(enc_nop());
    send_instr(enc_nop());
  endtask

endclass : rv32im_hazard_seq

`endif // RV32IM_HAZARD_SEQ_SV
