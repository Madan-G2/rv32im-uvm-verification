/*
 * rv32im_rand_seq.sv — Constrained-random instruction sequence
 *
 * Generates a randomised mix of RV32IM instructions.
 * Constraints ensure:
 *   - Legal opcode distribution across all ISA groups
 *   - rd != x0 bias (makes scoreboard mismatches visible)
 *   - Immediate fields in full range including sign-extension corners
 *   - Mixed load/store interleave
 */

`ifndef RV32IM_RAND_SEQ_SV
`define RV32IM_RAND_SEQ_SV

/* ── Randomised instruction transaction ──────────────────────── */
class rv32im_rand_txn extends rv32im_txn;
  `uvm_object_utils(rv32im_rand_txn)

  /* Opcode group selection weights */
  rand int unsigned grp;  /* 0=ALU-R, 1=ALU-I, 2=LOAD, 3=STORE,
                             4=BRANCH, 5=JAL/JALR, 6=LUI/AUIPC,
                             7=MEXT,   8=CSR */

  rand logic [4:0] rd_r, rs1_r, rs2_r;
  rand logic [11:0] imm12;
  rand logic [4:0]  shamt;
  rand logic [2:0]  f3;
  rand logic [6:0]  f7_alu;   /* only 7'h00 or 7'h20 for ALU */
  rand logic [19:0] imm20;
  rand logic [20:1] imm21;    /* JAL offset */
  rand logic [12:1] imm13;    /* branch offset */

  /* Opcode distribution */
  constraint c_grp_dist {
    grp dist {
      0 := 20,   /* ALU-R     */
      1 := 20,   /* ALU-I     */
      2 := 10,   /* LOAD      */
      3 := 10,   /* STORE     */
      4 := 15,   /* BRANCH    */
      5 := 5,    /* JAL/JALR  */
      6 := 5,    /* LUI/AUIPC */
      7 := 10,   /* M-ext     */
      8 := 5     /* CSR       */
    };
  }

  /* Bias rd away from x0 (4:1 non-zero) */
  constraint c_rd_nonzero  { rd_r  inside {[1:31]}; }
  constraint c_rs1_nonzero { rs1_r inside {[1:31]}; }

  /* funct7 for base ALU only 00 or 20 */
  constraint c_f7_legal { f7_alu inside {7'h00, 7'h20}; }

  /* Branch offsets: forward small jumps (avoid leaving imem) */
  constraint c_branch_offset { imm13 inside {[1:15]}; }

  /* JAL offset: small forward jump */
  constraint c_jal_offset { imm21 inside {[1:30]}; }

  /* funct3 legal per group */
  constraint c_f3_alu  { grp == 0 -> f3 inside {3'h0,3'h1,3'h2,3'h3,
                                                  3'h4,3'h5,3'h6,3'h7}; }
  constraint c_f3_load { grp == 2 -> f3 inside {3'h0,3'h1,3'h2,3'h4,3'h5}; }
  constraint c_f3_st   { grp == 3 -> f3 inside {3'h0,3'h1,3'h2}; }
  constraint c_f3_br   { grp == 4 -> f3 inside {3'h0,3'h1,3'h4,3'h5,3'h6,3'h7}; }
  constraint c_f3_mext { grp == 7 -> f3 inside {[3'h0:3'h7]}; }

  function new(string name = "rv32im_rand_txn");
    super.new(name);
  endfunction

  /* Build instruction word from randomised fields after solving */
  function void post_randomize();
    logic [31:0] w;
    case (grp)
      0: begin /* ALU-R */
          itype = R_TYPE;
          /* Avoid illegal f7/f3 combos: only ADD/SUB and SRA differ */
          if (f3 == 3'h0)
            w = {f7_alu, rs2_r, rs1_r, 3'h0, rd_r, 7'h33};
          else if (f3 == 3'h5)
            w = {f7_alu, rs2_r, rs1_r, 3'h5, rd_r, 7'h33};
          else
            w = {7'h00,  rs2_r, rs1_r, f3, rd_r, 7'h33};
        end
      1: begin /* ALU-I */
          itype = I_TYPE;
          if (f3 == 3'h1)       /* SLLI */
            w = {7'h00, shamt, rs1_r, 3'h1, rd_r, 7'h13};
          else if (f3 == 3'h5)  /* SRLI/SRAI */
            w = {f7_alu, shamt, rs1_r, 3'h5, rd_r, 7'h13};
          else
            w = {imm12, rs1_r, f3, rd_r, 7'h13};
        end
      2: begin /* LOAD */
          itype = I_TYPE;
          w = {imm12, rs1_r, f3, rd_r, 7'h03};
        end
      3: begin /* STORE */
          itype = S_TYPE;
          w = {imm12[11:5], rs2_r, rs1_r, f3, imm12[4:0], 7'h23};
        end
      4: begin /* BRANCH */
          itype = B_TYPE;
          w = {imm13[12], imm13[10:5], rs2_r, rs1_r, f3,
               imm13[4:1], imm13[11], 7'h63};
        end
      5: begin /* JAL */
          itype = J_TYPE;
          w = {imm21[20], imm21[10:1], imm21[11],
               imm21[19:12], rd_r, 7'h6F};
        end
      6: begin /* LUI / AUIPC */
          itype = U_TYPE;
          w = ($urandom() & 1) ? {imm20, rd_r, 7'h37} :  /* LUI   */
                                  {imm20, rd_r, 7'h17};   /* AUIPC */
        end
      7: begin /* M-extension */
          itype = R_TYPE;
          w = {7'h01, rs2_r, rs1_r, f3, rd_r, 7'h33};
        end
      8: begin /* CSR (CSRRW / CSRRS with mcycle) */
          itype = CSR_TYPE;
          logic [11:0] csr_sel;
          csr_sel = ($urandom() & 1) ? 12'hC00 : 12'h300; /* CYCLE / MSTATUS */
          w = {csr_sel, rs1_r, 3'h1, rd_r, 7'h73}; /* CSRRW */
        end
      default: w = 32'h0000_0013; /* NOP */
    endcase
    instr = w;
  endfunction

endclass : rv32im_rand_txn

/* ── Sequence ──────────────────────────────────────────────────── */
class rv32im_rand_seq extends rv32im_base_seq;
  `uvm_object_utils(rv32im_rand_seq)

  int unsigned num_instrs = 200;  /* default: 200 random instructions */

  function new(string name = "rv32im_rand_seq");
    super.new(name);
  endfunction

  task body();
    rv32im_rand_txn txn;

    `uvm_info("RAND_SEQ",
      $sformatf("Starting random sequence: %0d instructions", num_instrs),
      UVM_MEDIUM)

    /* Initialise some registers with known values via ADDI */
    /* x1 = 0xDEAD_0000, x2 = 0x1000 (stack pointer region)      */
    send_instr(enc_lui  (1, 20'hDEAD0));        /* LUI x1, 0xDEAD0     */
    send_instr(enc_addi (2, 0, 12'h100));       /* ADDI x2, x0, 0x100  */
    send_instr(enc_addi (3, 0, 12'hFF & 12'hFF)); /* ADDI x3, x0, 255 */

    repeat (num_instrs) begin
      txn = rv32im_rand_txn::type_id::create("rand_txn");
      start_item(txn);
      if (!txn.randomize())
        `uvm_fatal("RAND_SEQ", "Randomization failed")
      finish_item(txn);
    end

    /* Tail: a few NOPs to flush the pipeline */
    repeat (5) send_instr(enc_nop());

    `uvm_info("RAND_SEQ", "Random sequence complete", UVM_MEDIUM)
  endtask

endclass : rv32im_rand_seq

`endif // RV32IM_RAND_SEQ_SV
