/*
 * rv32im_directed_test.sv — Coverage-closure directed test
 * Runs ALL sequences including exception tests, targeting
 * the bins most likely to be uncovered after random runs:
 *   - x0 destination write
 *   - SRA with negative operand
 *   - LB with byte >= 0x80 (sign-extension check — BUG-005 target)
 *   - CSR read-modify-write
 */

`ifndef RV32IM_DIRECTED_TEST_SV
`define RV32IM_DIRECTED_TEST_SV

class rv32im_directed_test extends rv32im_base_test;
  `uvm_component_utils(rv32im_directed_test)

  function new(string name = "rv32im_directed_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task do_test(uvm_phase phase);
    rv32im_rand_seq       rand_seq;
    rv32im_hazard_seq     hz_seq;
    rv32im_branch_seq     br_seq;
    rv32im_mul_div_seq    md_seq;
    rv32im_exception_seq  exc_seq;
    rv32im_base_seq       dir_seq;

    /* Phase 1: Random */
    rand_seq = rv32im_rand_seq::type_id::create("rand_seq");
    rand_seq.num_instrs = 500;
    run_seq(rand_seq);

    /* Phase 2: All directed sequences */
    hz_seq  = rv32im_hazard_seq  ::type_id::create("hz_seq");
    br_seq  = rv32im_branch_seq  ::type_id::create("br_seq");
    md_seq  = rv32im_mul_div_seq ::type_id::create("md_seq");
    exc_seq = rv32im_exception_seq::type_id::create("exc_seq");

    run_seq(hz_seq);
    run_seq(br_seq);
    run_seq(md_seq);
    run_seq(exc_seq);

    /* Phase 3: Targeted coverage-closure instructions */
    dir_seq = rv32im_base_seq::type_id::create("dir_seq");
    begin
      /* BUG-005 target: LB with byte >= 0x80 */
      /* Store 0xAB then load with LB — should sign-extend to 0xFFFF_FFAB */
      dir_seq.send_instr(dir_seq.enc_addi(2, 0, 12'h040)); /* base=64      */
      dir_seq.send_instr(dir_seq.enc_addi(1, 0, 12'hAB));  /* x1=0xAB     */
      dir_seq.send_instr(dir_seq.enc_sb  (2, 1, 0));        /* mem[64]=0xAB*/
      dir_seq.send_instr(dir_seq.enc_lb  (3, 2, 0));        /* x3=sign_ext(0xAB)
                                                                = 0xFFFF_FFAB (correct)
                                                                = 0x0000_00AB (BUG-005) */

      /* SRA with negative operand */
      dir_seq.send_instr(dir_seq.enc_addi(4, 0, 12'hFF0 & 12'hFFF)); /* x4=-16 */
      dir_seq.send_instr(dir_seq.enc_srai(5, 4, 2));         /* x5 = -16>>2 = -4 */
      dir_seq.send_instr(dir_seq.enc_addi(6, 0, 12'h002));
      dir_seq.send_instr(dir_seq.enc_sra (7, 4, 6));         /* SRA register form */

      /* Write to x0 (rd=0) — result must not change x0 */
      dir_seq.send_instr(dir_seq.enc_addi(0, 1, 12'h001));   /* ADDI x0,x1,1 → x0=0 */
      dir_seq.send_instr(dir_seq.enc_add (0, 2, 3));          /* ADD x0,x2,x3 → x0=0 */

      /* SLTI/SLTIU sign-extension corner */
      dir_seq.send_instr(dir_seq.enc_addi(1, 0, 12'h000));   /* x1=0           */
      dir_seq.send_instr(dir_seq.enc_slti (8, 1, 12'h001));  /* 0 < 1 → x8=1  */
      dir_seq.send_instr(dir_seq.enc_sltiu(9, 1, 12'hFFF));  /* 0 < 4095 → x9=1 */

      /* AUIPC */
      dir_seq.send_instr(dir_seq.enc_auipc(10, 20'h00001));  /* x10=PC+0x1000  */

      /* JALR with non-zero offset */
      dir_seq.send_instr(dir_seq.enc_addi(11, 0, 12'h000));
      dir_seq.send_instr(dir_seq.enc_jalr(12, 11, 8));        /* jump to +8     */

      /* LHU and LH */
      dir_seq.send_instr(dir_seq.enc_addi(2, 0, 12'h080));   /* base=128       */
      dir_seq.send_instr(dir_seq.enc_addi(1, 0, 12'hFF0 & 12'hFFF)); /* 0xFF0 */
      dir_seq.send_instr(dir_seq.enc_sh  (2, 1, 0));          /* store halfword */
      dir_seq.send_instr(dir_seq.enc_lh  (3, 2, 0));          /* sign-ext load  */
      dir_seq.send_instr(dir_seq.enc_lhu (4, 2, 0));          /* zero-ext load  */

      dir_seq.send_instr(dir_seq.enc_nop());
      dir_seq.send_instr(dir_seq.enc_nop());
      dir_seq.send_instr(dir_seq.enc_nop());
    end
    run_seq(dir_seq);

    `uvm_info("DIRECTED_TEST", "Coverage-closure directed test complete", UVM_LOW)
  endtask

endclass : rv32im_directed_test

`endif // RV32IM_DIRECTED_TEST_SV
