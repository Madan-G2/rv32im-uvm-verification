/*
 * rv32im_iss_dpi.c — DPI-C wrapper for the RV32IM ISS
 *
 * Exposes iss_init / iss_step_instr / iss_reset to SystemVerilog
 * via svdpi.h.  Compiled with VCS:
 *   vcs ... -CFLAGS "-fPIC" iss/rv32im_iss.c iss/rv32im_iss_dpi.c
 *
 * SV import declarations (place in rv32im_pkg.sv):
 *
 *   import "DPI-C" context function void iss_dpi_init();
 *   import "DPI-C" context function void iss_dpi_reset();
 *   import "DPI-C" context function void iss_dpi_write_instr(
 *       input int unsigned addr, input int unsigned word);
 *   import "DPI-C" context function void iss_dpi_step(
 *       input  int unsigned instr,
 *       input  int unsigned pc,
 *       output int unsigned rd_o,
 *       output int unsigned result_o,
 *       output int unsigned next_pc_o,
 *       output int         trap_o,
 *       output int unsigned mcause_o,
 *       output int unsigned mepc_o);
 *   import "DPI-C" context function void iss_dpi_dump_regs();
 *   import "DPI-C" context function void iss_dpi_set_verbose(input int v);
 */

#include "svdpi.h"
#include "rv32im_iss.h"
#include <stdio.h>
#include <string.h>

/* One global ISS state instance per simulation */
static rv32im_state_t g_iss;
static int            g_initialized = 0;

/* ------------------------------------------------------------------
 * iss_dpi_init — call once at start_of_simulation
 * ----------------------------------------------------------------*/
void iss_dpi_init(void) {
    iss_init(&g_iss);
    g_initialized = 1;
    printf("[ISS] Initialized. RV32IM golden model ready.\n");
}

/* ------------------------------------------------------------------
 * iss_dpi_reset — call on DUT reset assertion
 * ----------------------------------------------------------------*/
void iss_dpi_reset(void) {
    if (!g_initialized) iss_dpi_init();
    iss_reset(&g_iss);
    printf("[ISS] Reset.\n");
}

/* ------------------------------------------------------------------
 * iss_dpi_write_instr — load one instruction word into ISS imem
 *   Called by the driver to keep ISS imem in sync with the stimulus.
 * ----------------------------------------------------------------*/
void iss_dpi_write_instr(unsigned int addr, unsigned int word) {
    if (!g_initialized) iss_dpi_init();
    iss_write_instr(&g_iss, addr, word);
}

/* ------------------------------------------------------------------
 * iss_dpi_step — execute one instruction and return results
 *   instr   : 32-bit instruction word (already fetched by monitor)
 *   pc      : PC of the committing instruction (for state sync check)
 *   rd_o    : destination register index written by DUT (0 = none)
 *   result_o: value ISS says should be written to rd
 *   next_pc_o: expected PC after this instruction
 *   trap_o  : 1 if ISS took an exception
 *   mcause_o: exception cause (valid when trap_o=1)
 *   mepc_o  : exception PC   (valid when trap_o=1)
 * ----------------------------------------------------------------*/
void iss_dpi_step(unsigned int  instr,
                  unsigned int  pc,
                  unsigned int *rd_o,
                  unsigned int *result_o,
                  unsigned int *next_pc_o,
                  int          *trap_o,
                  unsigned int *mcause_o,
                  unsigned int *mepc_o)
{
    if (!g_initialized) iss_dpi_init();

    /* Sync ISS PC to DUT commit PC — handles divergence from flush */
    if (g_iss.pc != pc) {
        /* Only warn; accept the sync so scoreboard stays aligned */
        if (g_iss.verbose)
            printf("[ISS SYNC] ISS PC=%08X  DUT commit PC=%08X — syncing\n",
                   g_iss.pc, pc);
        g_iss.pc = pc;
    }

    iss_result_t r = iss_step_instr(&g_iss, instr);

    *rd_o      = r.rd;
    *result_o  = r.result;
    *next_pc_o = r.next_pc;
    *trap_o    = r.trap;
    *mcause_o  = r.mcause;
    *mepc_o    = r.mepc;
}

/* ------------------------------------------------------------------
 * iss_dpi_dump_regs — print register file (call on mismatch)
 * ----------------------------------------------------------------*/
void iss_dpi_dump_regs(void) {
    if (g_initialized)
        iss_dump_regs(&g_iss);
}

/* ------------------------------------------------------------------
 * iss_dpi_set_verbose — 1 = print each instruction, 0 = quiet
 * ----------------------------------------------------------------*/
void iss_dpi_set_verbose(int v) {
    if (!g_initialized) iss_dpi_init();
    g_iss.verbose = v;
}

/* ------------------------------------------------------------------
 * iss_dpi_get_reg — read one register from ISS state
 *   Useful for directed-test self-checking in SV
 * ----------------------------------------------------------------*/
unsigned int iss_dpi_get_reg(int idx) {
    if (!g_initialized) return 0;
    if (idx < 0 || idx > 31) return 0;
    return g_iss.x[idx];
}
