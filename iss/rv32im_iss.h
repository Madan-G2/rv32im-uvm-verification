/*
 * rv32im_iss.h — RISC-V RV32IM Instruction-Set Simulator
 *
 * Golden reference model for the UVM scoreboard.
 * Called from SystemVerilog via DPI-C after every committed instruction.
 *
 * Project: RV32IM UVM Verification Environment
 */

#ifndef RV32IM_ISS_H
#define RV32IM_ISS_H

#include <stdint.h>

/* --------------------------------------------------------------------------
 * Memory sizes
 * --------------------------------------------------------------------------*/
#define ISS_IMEM_SIZE  (256 * 1024)   /* 256 KB instruction memory */
#define ISS_DMEM_SIZE  (256 * 1024)   /* 256 KB data memory        */

/* --------------------------------------------------------------------------
 * Exception cause codes (RISC-V spec Table 3.6)
 * --------------------------------------------------------------------------*/
#define EXC_INSTR_MISALIGN   0
#define EXC_INSTR_FAULT      1
#define EXC_ILLEGAL_INSTR    2
#define EXC_BREAKPOINT       3
#define EXC_LOAD_MISALIGN    4
#define EXC_LOAD_FAULT       5
#define EXC_STORE_MISALIGN   6
#define EXC_STORE_FAULT      7
#define EXC_ECALL_M          11

/* --------------------------------------------------------------------------
 * CSR addresses
 * --------------------------------------------------------------------------*/
#define CSR_MSTATUS  0x300
#define CSR_MISA     0x301
#define CSR_MIE      0x304
#define CSR_MTVEC    0x305
#define CSR_MEPC     0x341
#define CSR_MCAUSE   0x342
#define CSR_MTVAL    0x343
#define CSR_MIP      0x344
#define CSR_CYCLE    0xC00
#define CSR_INSTRET  0xC02

/* --------------------------------------------------------------------------
 * CPU State
 * --------------------------------------------------------------------------*/
typedef struct {
    uint32_t x[32];          /* integer register file x0..x31              */
    uint32_t pc;             /* program counter                             */

    /* CSRs */
    uint32_t mstatus;
    uint32_t misa;
    uint32_t mie;
    uint32_t mtvec;
    uint32_t mepc;
    uint32_t mcause;
    uint32_t mtval;
    uint32_t mip;
    uint64_t cycle;
    uint64_t instret;

    /* Memory */
    uint8_t  imem[ISS_IMEM_SIZE];
    uint8_t  dmem[ISS_DMEM_SIZE];

    /* Execution state */
    int      halted;         /* 1 after EBREAK or unrecoverable fault       */
    int      verbose;        /* 1 = print each instruction to stdout        */
} rv32im_state_t;

/* --------------------------------------------------------------------------
 * Step result — returned to scoreboard for comparison
 * --------------------------------------------------------------------------*/
typedef struct {
    uint32_t rd;             /* destination register index (0 = no write)  */
    uint32_t result;         /* value written to rd                         */
    uint32_t next_pc;        /* PC after this instruction                   */
    int      trap;           /* 1 if exception was taken                    */
    uint32_t mcause;         /* exception cause (valid when trap==1)        */
    uint32_t mepc;           /* exception PC  (valid when trap==1)          */
} iss_result_t;

/* --------------------------------------------------------------------------
 * Public API
 * --------------------------------------------------------------------------*/

/* Initialise state (zeroes regs, sets pc=0, misa=RV32IM) */
void         iss_init   (rv32im_state_t *s);

/* Reset: zeroes regs, restores pc=0, clears traps */
void         iss_reset  (rv32im_state_t *s);

/* Load a raw binary image into instruction memory at base_addr */
int          iss_load_imem(rv32im_state_t *s,
                           const uint8_t *data, uint32_t len,
                           uint32_t base_addr);

/* Load a raw binary image into data memory at base_addr */
int          iss_load_dmem(rv32im_state_t *s,
                           const uint8_t *data, uint32_t len,
                           uint32_t base_addr);

/* Write a single 32-bit word into instruction memory */
void         iss_write_instr(rv32im_state_t *s,
                              uint32_t addr, uint32_t word);

/* Execute one instruction (the one at s->pc).
 * Returns result struct; advances s->pc.
 * On exception: sets trap fields, jumps to mtvec, returns trap info. */
iss_result_t iss_step   (rv32im_state_t *s);

/* Execute one instruction given explicitly (for DPI use — instr already
 * fetched by the SV driver, passed in to avoid needing imem sync) */
iss_result_t iss_step_instr(rv32im_state_t *s, uint32_t instr);

/* Disassemble one instruction into buf (for debug logging) */
void         iss_disasm (uint32_t instr, uint32_t pc, char *buf, int buflen);

/* Dump register file to stdout */
void         iss_dump_regs(const rv32im_state_t *s);

#endif /* RV32IM_ISS_H */
