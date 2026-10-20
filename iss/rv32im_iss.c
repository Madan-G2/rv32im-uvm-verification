/*
 * rv32im_iss.c — RISC-V RV32IM Instruction-Set Simulator
 *
 * Full implementation of RV32I base + M-extension (multiply/divide) + Zicsr.
 * Used as the golden reference model in the UVM scoreboard via DPI-C.
 *
 * Encoding reference: RISC-V ISA Spec v2.2 (ratified)
 *
 * Project: RV32IM UVM Verification Environment
 */

#include "rv32im_iss.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* ============================================================
 * Helper macros for instruction field extraction
 * ============================================================*/
#define BITS(x, hi, lo)   (((x) >> (lo)) & ((1u << ((hi)-(lo)+1)) - 1u))
#define BIT(x, b)         (((x) >> (b)) & 1u)

/* Opcode fields */
#define OPCODE(i)   BITS(i,  6,  0)
#define RD(i)       BITS(i, 11,  7)
#define FUNCT3(i)   BITS(i, 14, 12)
#define RS1(i)      BITS(i, 19, 15)
#define RS2(i)      BITS(i, 24, 20)
#define FUNCT7(i)   BITS(i, 31, 25)

/* Immediate extraction with sign-extension */
static inline int32_t imm_i(uint32_t i) {
    return (int32_t)i >> 20;   /* bits [31:20] sign-extended */
}

static inline int32_t imm_s(uint32_t i) {
    uint32_t u = (BITS(i,31,25) << 5) | BITS(i,11,7);
    return (int32_t)(u << 20) >> 20;
}

static inline int32_t imm_b(uint32_t i) {
    uint32_t u = (BIT(i,31) << 12) | (BIT(i,7) << 11) |
                 (BITS(i,30,25) << 5) | (BITS(i,11,8) << 1);
    return (int32_t)(u << 19) >> 19;
}

static inline int32_t imm_u(uint32_t i) {
    return (int32_t)(i & 0xFFFFF000u);
}

static inline int32_t imm_j(uint32_t i) {
    uint32_t u = (BIT(i,31) << 20) | (BITS(i,19,12) << 12) |
                 (BIT(i,20) << 11) | (BITS(i,30,21) << 1);
    return (int32_t)(u << 11) >> 11;
}

/* ============================================================
 * Memory helpers
 * ============================================================*/
static uint32_t dmem_read32(rv32im_state_t *s, uint32_t addr) {
    if (addr + 3 >= ISS_DMEM_SIZE) return 0xDEADBEEFu;
    return (uint32_t)s->dmem[addr]        |
           (uint32_t)s->dmem[addr+1] << 8  |
           (uint32_t)s->dmem[addr+2] << 16 |
           (uint32_t)s->dmem[addr+3] << 24;
}

static uint16_t dmem_read16(rv32im_state_t *s, uint32_t addr) {
    if (addr + 1 >= ISS_DMEM_SIZE) return 0xDEADu;
    return (uint16_t)s->dmem[addr] | ((uint16_t)s->dmem[addr+1] << 8);
}

static uint8_t dmem_read8(rv32im_state_t *s, uint32_t addr) {
    if (addr >= ISS_DMEM_SIZE) return 0xDEu;
    return s->dmem[addr];
}

static void dmem_write32(rv32im_state_t *s, uint32_t addr, uint32_t val) {
    if (addr + 3 >= ISS_DMEM_SIZE) return;
    s->dmem[addr]   = val & 0xFF;
    s->dmem[addr+1] = (val >> 8)  & 0xFF;
    s->dmem[addr+2] = (val >> 16) & 0xFF;
    s->dmem[addr+3] = (val >> 24) & 0xFF;
}

static void dmem_write16(rv32im_state_t *s, uint32_t addr, uint16_t val) {
    if (addr + 1 >= ISS_DMEM_SIZE) return;
    s->dmem[addr]   = val & 0xFF;
    s->dmem[addr+1] = (val >> 8) & 0xFF;
}

static void dmem_write8(rv32im_state_t *s, uint32_t addr, uint8_t val) {
    if (addr >= ISS_DMEM_SIZE) return;
    s->dmem[addr] = val;
}

/* ============================================================
 * CSR helpers
 * ============================================================*/
static uint32_t csr_read(rv32im_state_t *s, uint32_t addr) {
    switch (addr) {
        case CSR_MSTATUS: return s->mstatus;
        case CSR_MISA:    return s->misa;
        case CSR_MIE:     return s->mie;
        case CSR_MTVEC:   return s->mtvec;
        case CSR_MEPC:    return s->mepc;
        case CSR_MCAUSE:  return s->mcause;
        case CSR_MTVAL:   return s->mtval;
        case CSR_MIP:     return s->mip;
        case CSR_CYCLE:   return (uint32_t)(s->cycle & 0xFFFFFFFF);
        case CSR_INSTRET: return (uint32_t)(s->instret & 0xFFFFFFFF);
        default:          return 0;
    }
}

static void csr_write(rv32im_state_t *s, uint32_t addr, uint32_t val) {
    switch (addr) {
        case CSR_MSTATUS: s->mstatus = val; break;
        case CSR_MIE:     s->mie     = val; break;
        case CSR_MTVEC:   s->mtvec   = val; break;
        case CSR_MEPC:    s->mepc    = val; break;
        case CSR_MCAUSE:  s->mcause  = val; break;
        case CSR_MTVAL:   s->mtval   = val; break;
        default: break; /* read-only or unimplemented CSR — ignore */
    }
}

/* Take an exception: update CSRs, jump to mtvec */
static void take_exception(rv32im_state_t *s, uint32_t cause,
                            uint32_t tval, iss_result_t *res) {
    s->mepc   = s->pc;
    s->mcause = cause;
    s->mtval  = tval;
    /* mstatus.MPIE = mstatus.MIE; mstatus.MIE = 0 */
    s->mstatus = (s->mstatus & ~0x88u) |
                 ((s->mstatus & 0x8u) << 4);
    s->pc = s->mtvec & ~0x3u;  /* direct mode (mtvec[1:0]=00) */

    res->trap   = 1;
    res->mcause = cause;
    res->mepc   = s->mepc;
}

/* ============================================================
 * Public API — init / reset / load
 * ============================================================*/
void iss_init(rv32im_state_t *s) {
    memset(s, 0, sizeof(*s));
    s->pc    = 0x00000000u;
    s->misa  = (1u << 30)            /* MXL=1 (RV32) */
             | (1u << ('I' - 'A'))   /* I extension  */
             | (1u << ('M' - 'A'));  /* M extension  */
    s->mtvec = 0x00000004u;          /* default trap vector */
}

void iss_reset(rv32im_state_t *s) {
    memset(s->x, 0, sizeof(s->x));
    s->pc       = 0;
    s->mstatus  = 0;
    s->mepc     = 0;
    s->mcause   = 0;
    s->halted   = 0;
    s->cycle    = 0;
    s->instret  = 0;
}

int iss_load_imem(rv32im_state_t *s, const uint8_t *data,
                  uint32_t len, uint32_t base_addr) {
    if (base_addr + len > ISS_IMEM_SIZE) return -1;
    memcpy(&s->imem[base_addr], data, len);
    return 0;
}

int iss_load_dmem(rv32im_state_t *s, const uint8_t *data,
                  uint32_t len, uint32_t base_addr) {
    if (base_addr + len > ISS_DMEM_SIZE) return -1;
    memcpy(&s->dmem[base_addr], data, len);
    return 0;
}

void iss_write_instr(rv32im_state_t *s, uint32_t addr, uint32_t word) {
    if (addr + 3 >= ISS_IMEM_SIZE) return;
    s->imem[addr]   = word & 0xFF;
    s->imem[addr+1] = (word >> 8)  & 0xFF;
    s->imem[addr+2] = (word >> 16) & 0xFF;
    s->imem[addr+3] = (word >> 24) & 0xFF;
}

/* ============================================================
 * Core step: execute one instruction
 * ============================================================*/
iss_result_t iss_step_instr(rv32im_state_t *s, uint32_t instr) {
    iss_result_t res;
    memset(&res, 0, sizeof(res));

    if (s->halted) return res;

    uint32_t pc     = s->pc;
    uint32_t opcode = OPCODE(instr);
    uint32_t rd_idx = RD(instr);
    uint32_t rs1    = RS1(instr);
    uint32_t rs2    = RS2(instr);
    uint32_t f3     = FUNCT3(instr);
    uint32_t f7     = FUNCT7(instr);

    int32_t  rs1v   = (int32_t)s->x[rs1];
    int32_t  rs2v   = (int32_t)s->x[rs2];
    uint32_t rs1u   = s->x[rs1];
    uint32_t rs2u   = s->x[rs2];

    uint32_t result = 0;
    uint32_t next_pc = pc + 4;
    int      write_rd = 1;

    /* ── Opcode decode ──────────────────────────────────────── */
    switch (opcode) {

    /* ── R-type: ADD SUB SLL SRL SRA AND OR XOR SLT SLTU ───── */
    case 0x33:
        switch (f3) {
        case 0x0: /* ADD / SUB */
            result = (f7 == 0x20) ? (uint32_t)(rs1v - rs2v)
                                  : (uint32_t)(rs1v + rs2v);
            break;
        case 0x1: /* SLL */
            result = rs1u << (rs2u & 0x1F);
            break;
        case 0x2: /* SLT */
            result = (rs1v < rs2v) ? 1 : 0;
            break;
        case 0x3: /* SLTU */
            result = (rs1u < rs2u) ? 1 : 0;
            break;
        case 0x4: /* XOR */
            result = rs1u ^ rs2u;
            break;
        case 0x5: /* SRL / SRA */
            if (f7 == 0x20)
                result = (uint32_t)(rs1v >> (rs2u & 0x1F));  /* arithmetic */
            else
                result = rs1u >> (rs2u & 0x1F);               /* logical    */
            break;
        case 0x6: /* OR  */
            result = rs1u | rs2u;
            break;
        case 0x7: /* AND */
            result = rs1u & rs2u;
            break;
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        break;

    /* M-extension (MUL/DIV/REM...) shares opcode 0x33 with f7=0x01;
     * it is decoded as an override after this switch (see below). */

    /* ── I-type ALU ─────────────────────────────────────────── */
    case 0x13: {
        int32_t  imm = imm_i(instr);
        uint32_t shamt = RS2(instr); /* bits [24:20] */
        switch (f3) {
        case 0x0: result = (uint32_t)(rs1v + imm);          break; /* ADDI  */
        case 0x1: result = rs1u << (shamt & 0x1F);          break; /* SLLI  */
        case 0x2: result = (rs1v < imm) ? 1 : 0;            break; /* SLTI  */
        case 0x3: result = (rs1u < (uint32_t)imm) ? 1 : 0;  break; /* SLTIU */
        case 0x4: result = rs1u ^ (uint32_t)imm;            break; /* XORI  */
        case 0x5:
            if (f7 == 0x20)
                result = (uint32_t)(rs1v >> (shamt & 0x1F)); /* SRAI */
            else
                result = rs1u >> (shamt & 0x1F);              /* SRLI */
            break;
        case 0x6: result = rs1u | (uint32_t)imm;            break; /* ORI   */
        case 0x7: result = rs1u & (uint32_t)imm;            break; /* ANDI  */
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        break;
    }

    /* ── LUI ─────────────────────────────────────────────────── */
    case 0x37:
        result = (uint32_t)imm_u(instr);
        break;

    /* ── AUIPC ───────────────────────────────────────────────── */
    case 0x17:
        result = pc + (uint32_t)imm_u(instr);
        break;

    /* ── JAL ─────────────────────────────────────────────────── */
    case 0x6F:
        result  = pc + 4;                   /* return address */
        next_pc = (uint32_t)(pc + imm_j(instr));
        break;

    /* ── JALR ────────────────────────────────────────────────── */
    case 0x67:
        result  = pc + 4;
        next_pc = (uint32_t)((rs1v + imm_i(instr)) & ~1);
        break;

    /* ── Branches ────────────────────────────────────────────── */
    case 0x63: {
        int taken = 0;
        switch (f3) {
        case 0x0: taken = (rs1v == rs2v);  break; /* BEQ  */
        case 0x1: taken = (rs1v != rs2v);  break; /* BNE  */
        case 0x4: taken = (rs1v <  rs2v);  break; /* BLT  */
        case 0x5: taken = (rs1v >= rs2v);  break; /* BGE  */
        case 0x6: taken = (rs1u <  rs2u);  break; /* BLTU */
        case 0x7: taken = (rs1u >= rs2u);  break; /* BGEU */
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        if (taken) {
            next_pc = (uint32_t)(pc + imm_b(instr));
            if (next_pc & 0x3) {
                take_exception(s, EXC_INSTR_MISALIGN, next_pc, &res);
                return res;
            }
        }
        write_rd = 0;
        break;
    }

    /* ── Loads ───────────────────────────────────────────────── */
    case 0x03: {
        uint32_t addr = (uint32_t)(rs1v + imm_i(instr));
        switch (f3) {
        case 0x0: /* LB  — sign-extend byte */
            result = (uint32_t)(int32_t)(int8_t)dmem_read8(s, addr);
            break;
        case 0x1: /* LH  — sign-extend halfword */
            if (addr & 1) { take_exception(s, EXC_LOAD_MISALIGN, addr, &res); return res; }
            result = (uint32_t)(int32_t)(int16_t)dmem_read16(s, addr);
            break;
        case 0x2: /* LW */
            if (addr & 3) { take_exception(s, EXC_LOAD_MISALIGN, addr, &res); return res; }
            result = dmem_read32(s, addr);
            break;
        case 0x4: /* LBU — zero-extend byte */
            result = (uint32_t)dmem_read8(s, addr);
            break;
        case 0x5: /* LHU — zero-extend halfword */
            if (addr & 1) { take_exception(s, EXC_LOAD_MISALIGN, addr, &res); return res; }
            result = (uint32_t)dmem_read16(s, addr);
            break;
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        break;
    }

    /* ── Stores ──────────────────────────────────────────────── */
    case 0x23: {
        uint32_t addr = (uint32_t)(rs1v + imm_s(instr));
        switch (f3) {
        case 0x0: /* SB */
            dmem_write8(s, addr, (uint8_t)rs2u);
            break;
        case 0x1: /* SH */
            if (addr & 1) { take_exception(s, EXC_STORE_MISALIGN, addr, &res); return res; }
            dmem_write16(s, addr, (uint16_t)rs2u);
            break;
        case 0x2: /* SW */
            if (addr & 3) { take_exception(s, EXC_STORE_MISALIGN, addr, &res); return res; }
            dmem_write32(s, addr, rs2u);
            break;
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        write_rd = 0;
        break;
    }

    /* ── CSR instructions ────────────────────────────────────── */
    case 0x73: {
        uint32_t csr_addr = BITS(instr, 31, 20);
        uint32_t uimm     = rs1;  /* zimm for *I variants */

        if (f3 == 0x0) {
            /* SYSTEM: ECALL, EBREAK, MRET, FENCE */
            uint32_t funct12 = BITS(instr, 31, 20);
            switch (funct12) {
            case 0x000: /* ECALL */
                take_exception(s, EXC_ECALL_M, 0, &res);
                return res;
            case 0x001: /* EBREAK */
                take_exception(s, EXC_BREAKPOINT, pc, &res);
                s->halted = 1;
                return res;
            case 0x302: /* MRET */
                next_pc = s->mepc;
                /* mstatus.MIE = mstatus.MPIE; mstatus.MPIE = 1 */
                s->mstatus = (s->mstatus & ~0x8u) |
                             ((s->mstatus >> 4) & 0x8u);
                s->mstatus |= 0x80u; /* MPIE=1 */
                write_rd = 0;
                break;
            default: /* FENCE, WFI — treat as NOP */
                write_rd = 0;
                break;
            }
            break;
        }

        /* CSRRW / CSRRS / CSRRC / CSRRWI / CSRRSI / CSRRCI */
        uint32_t old_csr = csr_read(s, csr_addr);
        result = old_csr;  /* all CSR instructions return old value */

        switch (f3) {
        case 0x1: /* CSRRW  */ csr_write(s, csr_addr, rs1u);              break;
        case 0x2: /* CSRRS  */ csr_write(s, csr_addr, old_csr | rs1u);    break;
        case 0x3: /* CSRRC  */ csr_write(s, csr_addr, old_csr & ~rs1u);   break;
        case 0x5: /* CSRRWI */ csr_write(s, csr_addr, uimm);              break;
        case 0x6: /* CSRRSI */ csr_write(s, csr_addr, old_csr | uimm);    break;
        case 0x7: /* CSRRCI */ csr_write(s, csr_addr, old_csr & ~uimm);   break;
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
        break;
    }

    /* ── FENCE ───────────────────────────────────────────────── */
    case 0x0F:
        write_rd = 0;   /* NOP for ISS purposes */
        break;

    default:
        take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
        return res;

    } /* end opcode switch */

    /* ── M-extension override (opcode 0x33, f7=0x01) ─────────── */
    if (opcode == 0x33 && f7 == 0x01) {
        write_rd = 1;
        int64_t  signed_a   = (int64_t)(int32_t)rs1u;
        int64_t  signed_b   = (int64_t)(int32_t)rs2u;
        uint64_t unsigned_a = (uint64_t)rs1u;
        uint64_t unsigned_b = (uint64_t)rs2u;

        switch (f3) {
        case 0x0: /* MUL — lower 32 bits of signed × signed */
            result = (uint32_t)(signed_a * signed_b);
            break;
        case 0x1: /* MULH — upper 32 bits signed × signed */
            result = (uint32_t)((signed_a * signed_b) >> 32);
            break;
        case 0x2: /* MULHSU — upper 32 bits signed × unsigned */
            result = (uint32_t)(((int64_t)signed_a * (int64_t)unsigned_b) >> 32);
            break;
        case 0x3: /* MULHU — upper 32 bits unsigned × unsigned */
            result = (uint32_t)((unsigned_a * unsigned_b) >> 32);
            break;
        case 0x4: /* DIV — signed division */
            if (rs2u == 0) {
                result = 0xFFFFFFFFu;          /* spec: -1 on div-by-zero */
            } else if (rs1u == 0x80000000u && rs2u == 0xFFFFFFFFu) {
                result = 0x80000000u;          /* spec: overflow case      */
            } else {
                result = (uint32_t)(signed_a / signed_b);
            }
            break;
        case 0x5: /* DIVU — unsigned division */
            result = (rs2u == 0) ? 0xFFFFFFFFu : rs1u / rs2u;
            break;
        case 0x6: /* REM — signed remainder */
            if (rs2u == 0) {
                result = rs1u;                 /* spec: dividend on div-by-zero */
            } else if (rs1u == 0x80000000u && rs2u == 0xFFFFFFFFu) {
                result = 0;                    /* spec: 0 on overflow           */
            } else {
                result = (uint32_t)(signed_a % signed_b);
            }
            break;
        case 0x7: /* REMU — unsigned remainder */
            result = (rs2u == 0) ? rs1u : rs1u % rs2u;
            break;
        default:
            take_exception(s, EXC_ILLEGAL_INSTR, instr, &res);
            return res;
        }
    }

    /* ── Writeback ───────────────────────────────────────────── */
    if (write_rd && rd_idx != 0) {
        s->x[rd_idx] = result;
    }
    s->x[0] = 0;   /* x0 always zero */

    s->pc = next_pc;
    s->cycle++;
    s->instret++;

    res.rd      = write_rd ? rd_idx : 0;
    res.result  = result;
    res.next_pc = next_pc;

    if (s->verbose) {
        char buf[64];
        iss_disasm(instr, pc, buf, sizeof(buf));
        if (write_rd && rd_idx != 0)
            printf("ISS [PC=%08X] %-30s =>  x%d = %08X  next_pc=%08X\n",
                   pc, buf, rd_idx, result, next_pc);
        else
            printf("ISS [PC=%08X] %-30s =>  (no rd)        next_pc=%08X\n",
                   pc, buf, next_pc);
    }

    return res;
}

/* Fetch from imem and step */
iss_result_t iss_step(rv32im_state_t *s) {
    uint32_t pc = s->pc;
    if (pc + 3 >= ISS_IMEM_SIZE) {
        iss_result_t res; memset(&res, 0, sizeof(res));
        take_exception(s, EXC_INSTR_FAULT, pc, &res);
        return res;
    }
    uint32_t instr = (uint32_t)s->imem[pc]        |
                     (uint32_t)s->imem[pc+1] << 8  |
                     (uint32_t)s->imem[pc+2] << 16 |
                     (uint32_t)s->imem[pc+3] << 24;
    return iss_step_instr(s, instr);
}

/* ============================================================
 * Disassembler (compact — for debug logging only)
 * ============================================================*/
void iss_disasm(uint32_t instr, uint32_t pc, char *buf, int buflen) {
    uint32_t op = OPCODE(instr);
    uint32_t f3 = FUNCT3(instr);
    uint32_t f7 = FUNCT7(instr);
    int rd  = (int)RD(instr);
    int rs1 = (int)RS1(instr);
    int rs2 = (int)RS2(instr);

    static const char *rname[] = {
        "zero","ra","sp","gp","tp","t0","t1","t2",
        "s0","s1","a0","a1","a2","a3","a4","a5",
        "a6","a7","s2","s3","s4","s5","s6","s7",
        "s8","s9","s10","s11","t3","t4","t5","t6"
    };

#define R(i) rname[(i) & 0x1F]
    switch (op) {
    case 0x33:
        if (f7 == 0x01) {
            const char *mn[] = {"mul","mulh","mulhsu","mulhu",
                                "div","divu","rem","remu"};
            snprintf(buf,buflen,"%s %s,%s,%s", mn[f3],R(rd),R(rs1),R(rs2));
        } else {
            const char *mn[] = {"add","sll","slt","sltu",
                                "xor","srl","or","and"};
            if (f3==0 && f7==0x20)
                snprintf(buf,buflen,"sub %s,%s,%s",R(rd),R(rs1),R(rs2));
            else if (f3==5 && f7==0x20)
                snprintf(buf,buflen,"sra %s,%s,%s",R(rd),R(rs1),R(rs2));
            else
                snprintf(buf,buflen,"%s %s,%s,%s",mn[f3],R(rd),R(rs1),R(rs2));
        }
        break;
    case 0x13: {
        const char *mn[] = {"addi","slli","slti","sltiu",
                            "xori","srli","ori","andi"};
        if (f3==5 && f7==0x20)
            snprintf(buf,buflen,"srai %s,%s,%d",R(rd),R(rs1),(int)(RS2(instr)));
        else
            snprintf(buf,buflen,"%s %s,%s,%d",mn[f3],R(rd),R(rs1),imm_i(instr));
        break;
    }
    case 0x37: snprintf(buf,buflen,"lui %s,0x%X",R(rd),(uint32_t)imm_u(instr)>>12); break;
    case 0x17: snprintf(buf,buflen,"auipc %s,0x%X",R(rd),(uint32_t)imm_u(instr)>>12); break;
    case 0x6F: snprintf(buf,buflen,"jal %s,%d",R(rd),imm_j(instr)); break;
    case 0x67: snprintf(buf,buflen,"jalr %s,%s,%d",R(rd),R(rs1),imm_i(instr)); break;
    case 0x63: {
        const char *mn[] = {"beq","bne","??","??","blt","bge","bltu","bgeu"};
        snprintf(buf,buflen,"%s %s,%s,%d",mn[f3],R(rs1),R(rs2),imm_b(instr));
        break;
    }
    case 0x03: {
        const char *mn[] = {"lb","lh","lw","??","lbu","lhu"};
        snprintf(buf,buflen,"%s %s,%d(%s)",mn[f3],R(rd),imm_i(instr),R(rs1));
        break;
    }
    case 0x23: {
        const char *mn[] = {"sb","sh","sw"};
        snprintf(buf,buflen,"%s %s,%d(%s)",mn[f3<3?f3:0],R(rs2),imm_s(instr),R(rs1));
        break;
    }
    case 0x73:
        if (f3==0) {
            uint32_t f12 = BITS(instr,31,20);
            if      (f12==0x000) snprintf(buf,buflen,"ecall");
            else if (f12==0x001) snprintf(buf,buflen,"ebreak");
            else if (f12==0x302) snprintf(buf,buflen,"mret");
            else                 snprintf(buf,buflen,"fence");
        } else {
            const char *mn[] = {"??","csrrw","csrrs","csrrc",
                                 "??","csrrwi","csrrsi","csrrci"};
            snprintf(buf,buflen,"%s %s,0x%03X,%s",
                     mn[f3],R(rd),BITS(instr,31,20),R(rs1));
        }
        break;
    default:
        snprintf(buf,buflen,"unknown(%08X)",instr);
        break;
    }
#undef R
}

/* ============================================================
 * Register file dump
 * ============================================================*/
void iss_dump_regs(const rv32im_state_t *s) {
    static const char *rn[] = {
        "zero","ra","sp","gp","tp","t0","t1","t2",
        "s0","s1","a0","a1","a2","a3","a4","a5",
        "a6","a7","s2","s3","s4","s5","s6","s7",
        "s8","s9","s10","s11","t3","t4","t5","t6"
    };
    printf("=== ISS Register File (PC=%08X) ===\n", s->pc);
    for (int i = 0; i < 32; i += 4) {
        printf("  x%02d %-4s=%08X  x%02d %-4s=%08X"
               "  x%02d %-4s=%08X  x%02d %-4s=%08X\n",
               i,   rn[i],   s->x[i],
               i+1, rn[i+1], s->x[i+1],
               i+2, rn[i+2], s->x[i+2],
               i+3, rn[i+3], s->x[i+3]);
    }
    printf("  mepc=%08X  mcause=%08X  mstatus=%08X\n",
           s->mepc, s->mcause, s->mstatus);
}
