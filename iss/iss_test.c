/*
 * iss_test.c — Standalone self-test for the RV32IM ISS
 *
 * Compiles and runs without VCS or any SystemVerilog tooling.
 * Uses rv32im_iss.c directly (no DPI wrapper).
 *
 * Build:
 *   gcc -O2 -Wall -I. iss_test.c rv32im_iss.c -o iss_test
 *   ./iss_test
 *
 * Tests:
 *   1. Basic ALU  — ADDI / ADD / SUB / MUL / EBREAK
 *   2. Branches   — BEQ taken / BNE not-taken
 *   3. Load/Store — SW + LW round-trip, LB sign-extension (BUG-005 scenario)
 *   4. M-ext      — DIV by zero (BUG-004 scenario), REM overflow
 *   5. SRA        — arithmetic right shift with negative operand (BUG-003 scenario)
 */

#include "rv32im_iss.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Test infrastructure ─────────────────────────────────────── */
static int g_pass = 0, g_fail = 0;

#define CHECK(label, got, expected) do { \
    if ((uint32_t)(got) == (uint32_t)(expected)) { \
        printf("  PASS  %-40s  got=0x%08X\n", label, (uint32_t)(got)); \
        g_pass++; \
    } else { \
        printf("  FAIL  %-40s  got=0x%08X  expected=0x%08X\n", \
               label, (uint32_t)(got), (uint32_t)(expected)); \
        g_fail++; \
    } \
} while (0)

static rv32im_state_t s;

/* Run n instructions from the start; return after n commits or halt */
static void run(int n) {
    for (int i = 0; i < n && !s.halted; i++)
        iss_step(&s);
}

/* ============================================================
 * Test 1: Basic ALU
 * ============================================================*/
static void test_alu(void) {
    printf("\n[Test 1] Basic ALU (ADDI / ADD / SUB / MUL)\n");
    iss_init(&s);
    s.verbose = 0;
    /* addi x1,x0,5 */  iss_write_instr(&s, 0,  0x00500093u);
    /* addi x2,x0,7 */  iss_write_instr(&s, 4,  0x00700113u);
    /* add  x3,x1,x2*/  iss_write_instr(&s, 8,  0x002081b3u);
    /* sub  x4,x1,x2*/  iss_write_instr(&s, 12, 0x402081b3u); /* sub x3... use x4 */
    /* mul  x5,x1,x2*/  iss_write_instr(&s, 16, 0x0220c2b3u);
    /* ebreak        */  iss_write_instr(&s, 20, 0x00100073u);

    /* Correct encodings: */
    iss_init(&s);
    s.verbose = 0;
    /* addi x1, x0, 5 */
    iss_write_instr(&s, 0,  (5  << 20) | (0 << 15) | (0 << 12) | (1 << 7) | 0x13u);
    /* addi x2, x0, 7 */
    iss_write_instr(&s, 4,  (7  << 20) | (0 << 15) | (0 << 12) | (2 << 7) | 0x13u);
    /* add  x3, x1, x2: funct7=0,rs2=2,rs1=1,funct3=0,rd=3,opcode=0x33 */
    iss_write_instr(&s, 8,  (0 << 25) | (2 << 20) | (1 << 15) | (0 << 12) | (3 << 7) | 0x33u);
    /* sub  x4, x2, x1: funct7=0x20,rs2=1,rs1=2,funct3=0,rd=4,opcode=0x33 */
    iss_write_instr(&s, 12, (0x20u<<25)| (1 << 20) | (2 << 15) | (0 << 12) | (4 << 7) | 0x33u);
    /* mul  x5, x1, x2: funct7=1,rs2=2,rs1=1,funct3=0,rd=5,opcode=0x33 */
    iss_write_instr(&s, 16, (0x01u<<25)| (2 << 20) | (1 << 15) | (0 << 12) | (5 << 7) | 0x33u);
    /* ebreak */
    iss_write_instr(&s, 20, 0x00100073u);

    run(10);

    CHECK("ADDI x1=5",         s.x[1], 5);
    CHECK("ADDI x2=7",         s.x[2], 7);
    CHECK("ADD  x3=5+7=12",    s.x[3], 12);
    CHECK("SUB  x4=7-5=2",     s.x[4], 2);
    CHECK("MUL  x5=5*7=35",    s.x[5], 35);
    CHECK("x0 always 0",       s.x[0], 0);
}


/* ============================================================
 * Test 2: Branch taken / not-taken
 * ============================================================*/
static void test_branch(void) {
    printf("\n[Test 2] Branch (BEQ taken, BNE not-taken)\n");
    iss_init(&s);
    s.verbose = 0;

    /* Layout (byte addresses):
     *   0:  addi x1, x0, 5
     *   4:  addi x2, x0, 5
     *   8:  beq  x1, x2, +8   → taken → jump to 16
     *  12:  addi x3, x0, 0xBAD  ← should be skipped
     *  16:  addi x4, x0, 1     ← branch target
     *  20:  addi x5, x0, 3
     *  24:  addi x6, x0, 4
     *  28:  bne  x5, x6, +8   → NOT taken (3 != 4 — wait, should be 3!=4 so taken)
     *        Fix: bne x5,x5 to NOT take: use same regs
     *  28:  bne  x5, x5, +8   → NOT taken (5==5)
     *  32:  addi x7, x0, 99   ← executed (bne not taken)
     *  36:  ebreak
     */

    /* addi x1,x0,5 */
    iss_write_instr(&s,  0, (5  <<20)|(0<<15)|(0<<12)|(1<<7)|0x13u);
    /* addi x2,x0,5 */
    iss_write_instr(&s,  4, (5  <<20)|(0<<15)|(0<<12)|(2<<7)|0x13u);
    /* beq x1,x2,+8 (offset=8: imm13=8 → bit12=0,bit11=0,bits10:5=0,bits4:1=0b1000=4)
     * Encoding: imm[12|10:5] rs2 rs1 000 imm[4:1|11] 1100011
     * imm=8 = 0b0000_0000_1000: bit12=0,bit11=0,bits10:5=0b000000,bits4:1=0b0100 (=4, since bit1=0)
     * Wait: imm is a 13-bit signed offset, bit0=0. imm=8: bit3=1, rest=0.
     * bits[4:1] = 4 (0b0100), bits[10:5]=0, bit11=0, bit12=0.
     * inst = {bit12, bits10:5, rs2[4:0], rs1[4:0], 000, bits4:1, bit11, 1100011}
     *      = {0, 000000, 00010, 00001, 000, 0100, 0, 1100011}
     *      = 0x00208463 */
    iss_write_instr(&s,  8, 0x00208463u);
    /* addi x3,x0,0xBAD → 0xBAD = 2989, but imm12 is signed -1619 if bit11=1... use 0x7FF */
    iss_write_instr(&s, 12, (0xBAD<<20)|(0<<15)|(0<<12)|(3<<7)|0x13u); /* x3=skipped */
    /* addi x4,x0,1 — branch target at addr 16 */
    iss_write_instr(&s, 16, (1  <<20)|(0<<15)|(0<<12)|(4<<7)|0x13u);
    /* addi x5,x0,3 */
    iss_write_instr(&s, 20, (3  <<20)|(0<<15)|(0<<12)|(5<<7)|0x13u);
    /* bne x5,x5,+8 → NOT taken (x5==x5). Encoding: rs1=5,rs2=5,imm=8
     * 0x00529463 = {0,000000,00101,00101,001,0100,0,1100011} */
    iss_write_instr(&s, 24, 0x00529463u);
    /* addi x6,x0,99 — executed (bne not taken) */
    iss_write_instr(&s, 28, (99 <<20)|(0<<15)|(0<<12)|(6<<7)|0x13u);
    /* ebreak */
    iss_write_instr(&s, 32, 0x00100073u);

    run(20);

    CHECK("BEQ taken: x4=1 (target executed)", s.x[4], 1);
    /* x3 should be 0 if the skip worked, or 0xFFFFF BAD-sign-extended if not */
    /* Since 0xBAD as imm12 sign-extends: bit11 of 0xBAD = 1 → -1619 = 0xFFFFF9AD */
    /* We just check x3 != the target value */
    CHECK("BEQ taken: skip over x3 (should be 0)", s.x[3], 0);
    CHECK("BNE not-taken: x6=99 (executed)",  s.x[6], 99);
}


/* ============================================================
 * Test 3: Load / Store + LB sign-extension (BUG-005 scenario)
 * ============================================================*/
static void test_load_store(void) {
    printf("\n[Test 3] Load/Store + LB sign-extension\n");
    iss_init(&s);
    s.verbose = 0;

    /* Set x1 = 128 (base address in data memory)
     * Store 0xAB to mem[128] via SB
     * Load with LB: should sign-extend → 0xFFFFFFAB
     * Load with LBU: should zero-extend → 0x000000AB
     * Store 0x12345678 via SW, load back with LW */

    uint32_t base = 128;

    /* addi x1, x0, 128 */
    iss_write_instr(&s,  0, (base<<20)|(0<<15)|(0<<12)|(1<<7)|0x13u);
    /* addi x2, x0, 0xAB  (note: 0xAB=171, fits in 12-bit positive) */
    iss_write_instr(&s,  4, (0xABu<<20)|(0<<15)|(0<<12)|(2<<7)|0x13u);
    /* sb x2, 0(x1): store byte  — funct3=0, opcode=0x23, imm=0
     * {imm[11:5], rs2, rs1, 000, imm[4:0], 0100011}
     * = {0000000, 00010, 00001, 000, 00000, 0100011} = 0x00208023 */
    iss_write_instr(&s,  8, 0x00208023u);
    /* lb x3, 0(x1): load byte signed  — funct3=0, opcode=0x03
     * = {000000000000, 00001, 000, 00011, 0000011} = 0x00008183 */
    iss_write_instr(&s, 12, 0x00008183u);
    /* lbu x4, 0(x1): load byte unsigned — funct3=4
     * = {000000000000, 00001, 100, 00100, 0000011} = 0x00008203... */
    /* {12'b0, rs1=1, funct3=4, rd=4, opcode=3} */
    iss_write_instr(&s, 16, (0<<20)|(1<<15)|(4<<12)|(4<<7)|0x03u);
    /* lui x5, upper(0x12345)  then addi x5,x5,0x678 */
    /* LUI x5, 0x12345 → x5 = 0x12345000 */
    iss_write_instr(&s, 20, (0x12345u<<12)|(5<<7)|0x37u);
    /* addi x5, x5, 0x678 → x5 = 0x12345678 */
    iss_write_instr(&s, 24, (0x678u<<20)|(5<<15)|(0<<12)|(5<<7)|0x13u);
    /* sw x5, 4(x1): store word at addr 132
     * imm=4: {0000000, rs2=5, rs1=1, 010, 00100, 0100011} = 0x0050A223 */
    iss_write_instr(&s, 28, 0x0050A223u);
    /* lw x6, 4(x1): load word from addr 132
     * {000000000100, rs1=1, 010, rd=6, 0000011} = 0x0040A303 */
    iss_write_instr(&s, 32, 0x0040A303u);
    /* ebreak */
    iss_write_instr(&s, 36, 0x00100073u);

    run(20);

    CHECK("SB+LB  sign-ext 0xAB→0xFFFFFFAB", s.x[3], 0xFFFFFFABu);
    CHECK("SB+LBU zero-ext 0xAB→0x000000AB", s.x[4], 0x000000ABu);
    CHECK("SW+LW  round-trip 0x12345678",     s.x[6], 0x12345678u);
}


/* ============================================================
 * Test 4: M-extension — DIV by zero + REM overflow (BUG-004 scenario)
 * ============================================================*/
static void test_mext(void) {
    printf("\n[Test 4] M-extension: DIV by zero, REM, overflow\n");
    iss_init(&s);
    s.verbose = 0;

    /* addi x1, x0, 42 */
    iss_write_instr(&s,  0, (42<<20)|(0<<15)|(0<<12)|(1<<7)|0x13u);
    /* x0 = 0 always — div x2, x1, x0 (by zero)
     * div: funct7=1,rs2=0,rs1=1,funct3=4,rd=2,opcode=0x33 */
    iss_write_instr(&s,  4, (1<<25)|(0<<20)|(1<<15)|(4<<12)|(2<<7)|0x33u);
    /* rem x3, x1, x0 (by zero): spec→ remainder = dividend = 42 */
    iss_write_instr(&s,  8, (1<<25)|(0<<20)|(1<<15)|(6<<12)|(3<<7)|0x33u);
    /* divu x4, x1, x0 (unsigned by zero): spec → 0xFFFFFFFF */
    iss_write_instr(&s, 12, (1<<25)|(0<<20)|(1<<15)|(5<<12)|(4<<7)|0x33u);
    /* INT_MIN / -1: lui x5,0x80000 → x5=0x80000000 */
    iss_write_instr(&s, 16, (0x80000u<<12)|(5<<7)|0x37u);
    /* addi x6, x0, -1 → x6 = 0xFFFFFFFF */
    iss_write_instr(&s, 20, (0xFFFu<<20)|(0<<15)|(0<<12)|(6<<7)|0x13u);
    /* div x7, x5, x6 (INT_MIN / -1): spec → INT_MIN = 0x80000000 */
    iss_write_instr(&s, 24, (1<<25)|(6<<20)|(5<<15)|(4<<12)|(7<<7)|0x33u);
    /* rem x8, x5, x6 (INT_MIN / -1): spec → 0 */
    iss_write_instr(&s, 28, (1<<25)|(6<<20)|(5<<15)|(6<<12)|(8<<7)|0x33u);
    /* mul x9, x6, x6 (-1 × -1 = 1, lower 32) */
    iss_write_instr(&s, 32, (1<<25)|(6<<20)|(6<<15)|(0<<12)|(9<<7)|0x33u);
    /* ebreak */
    iss_write_instr(&s, 36, 0x00100073u);

    run(15);

    CHECK("DIV  42/0  = 0xFFFFFFFF (-1)",  s.x[2], 0xFFFFFFFFu);
    CHECK("REM  42%0  = 42 (dividend)",     s.x[3], 42u);
    CHECK("DIVU 42/0  = 0xFFFFFFFF",        s.x[4], 0xFFFFFFFFu);
    CHECK("DIV  INT_MIN/-1 = INT_MIN",       s.x[7], 0x80000000u);
    CHECK("REM  INT_MIN/-1 = 0",            s.x[8], 0u);
    CHECK("MUL  (-1)*(-1)  = 1",            s.x[9], 1u);
}


/* ============================================================
 * Test 5: SRA arithmetic right shift (BUG-003 scenario)
 * ============================================================*/
static void test_sra(void) {
    printf("\n[Test 5] SRA arithmetic right shift\n");
    iss_init(&s);
    s.verbose = 0;

    /* addi x1, x0, -16 (0xFFFFFFF0) */
    iss_write_instr(&s,  0, (0xFF0u<<20)|(0<<15)|(0<<12)|(1<<7)|0x13u);
    /* srai x2, x1, 2: x2 = -16 >> 2 = -4 = 0xFFFFFFFC
     * {0100000, shamt=2, rs1=1, 101, rd=2, 0010011} */
    iss_write_instr(&s,  4, (0x20u<<25)|(2<<20)|(1<<15)|(5<<12)|(2<<7)|0x13u);
    /* srai x3, x1, 31: x3 = -1 = 0xFFFFFFFF */
    iss_write_instr(&s,  8, (0x20u<<25)|(31<<20)|(1<<15)|(5<<12)|(3<<7)|0x13u);
    /* addi x4, x0, 2 */
    iss_write_instr(&s, 12, (2<<20)|(0<<15)|(0<<12)|(4<<7)|0x13u);
    /* sra x5, x1, x4: x5 = -16 >> 2 = -4 = 0xFFFFFFFC
     * {0100000, rs2=4, rs1=1, 101, rd=5, 0110011} */
    iss_write_instr(&s, 16, (0x20u<<25)|(4<<20)|(1<<15)|(5<<12)|(5<<7)|0x33u);
    /* srli x6, x1, 2: logical: x6 = 0x3FFFFFFC */
    iss_write_instr(&s, 20, (0x00u<<25)|(2<<20)|(1<<15)|(5<<12)|(6<<7)|0x13u);
    /* ebreak */
    iss_write_instr(&s, 24, 0x00100073u);

    run(10);

    CHECK("ADDI x1=-16  (0xFFFFFFF0)", s.x[1], 0xFFFFFFF0u);
    CHECK("SRAI x2=-16>>2=-4 (0xFFFFFFFC)", s.x[2], 0xFFFFFFFCu);
    CHECK("SRAI x3=-16>>31=-1 (0xFFFFFFFF)", s.x[3], 0xFFFFFFFFu);
    CHECK("SRA  x5=-16>>2=-4 (0xFFFFFFFC)", s.x[5], 0xFFFFFFFCu);
    CHECK("SRLI x6=logical  (0x3FFFFFFC)", s.x[6], 0x3FFFFFFCu);
}


/* ============================================================
 * main
 * ============================================================*/
int main(void) {
    printf("=================================================\n");
    printf("  RV32IM ISS Standalone Self-Test\n");
    printf("=================================================\n");

    test_alu();
    test_branch();
    test_load_store();
    test_mext();
    test_sra();

    printf("\n=================================================\n");
    printf("  Results: %d PASS  /  %d FAIL  /  %d total\n",
           g_pass, g_fail, g_pass + g_fail);
    printf("=================================================\n");

    return g_fail > 0 ? 1 : 0;
}
