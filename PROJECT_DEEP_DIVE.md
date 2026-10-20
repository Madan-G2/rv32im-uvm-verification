# RISC-V RV32IM UVM Verification — Complete Deep Dive
### Read this once and you will be able to answer any interview question about this project.

---

## PART 1 — THE BIG PICTURE

### What problem are we solving?

When a chip company designs a CPU, they write it in RTL (Register Transfer Level) — SystemVerilog or Verilog. That RTL describes digital logic: flip-flops, muxes, ALUs, state machines. Before that RTL is sent to a foundry to be etched onto silicon, you must prove it is correct.

You cannot just simulate a few instructions and say "looks good." You need a **systematic, automated, coverage-driven process** that:

1. Generates thousands of varied test programs automatically
2. Checks every single result against a known-good reference
3. Proves that every interesting scenario was actually exercised
4. Finds bugs that would survive to hardware if undetected

That process is called **functional verification**, and this project builds that entire process from scratch for a RISC-V RV32IM CPU.

---

### The three layers of this project

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 3: AUTOMATION                                                │
│  Python: run_regression.py, parse_logs.py, aggregate_coverage.py   │
│  "Run 100 simulations in parallel, collect results, report gaps"    │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 2: VERIFICATION ENVIRONMENT (this is the main work)          │
│  SystemVerilog UVM: driver, monitor, scoreboard, coverage           │
│  C ISS: golden reference model                                      │
│  SVA: concurrent assertion checkers                                 │
│  "Apply stimulus, observe results, compare against ground truth"    │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 1: THE DUT (Device Under Test)                               │
│  ibex — a real RISC-V RV32IM CPU from lowRISC                       │
│  Written in SystemVerilog, ~10,000 lines, 2-stage pipeline          │
│  "The chip we are testing"                                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## PART 2 — THE CPU WE ARE TESTING (ibex)

### What is RISC-V RV32IM?

RISC-V is an open-source Instruction Set Architecture (ISA). Unlike x86 (Intel) or ARM (which require licenses), anyone can build a RISC-V CPU.

- **RV** = RISC-V
- **32** = 32-bit — every register is 32 bits wide, addresses are 32 bits
- **I** = Base Integer instructions — arithmetic, logic, branches, loads, stores
- **M** = Multiply/Divide extension — adds 8 more instructions (MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU)

There are **47 instructions total** in RV32IM. Every single one must be verified.

### How ibex's pipeline works

ibex is a **2-stage pipeline**:

```
Stage 1: IF (Instruction Fetch)          Stage 2: ID/EX/WB (Decode + Execute + Writeback)
─────────────────────────────────────────────────────────────────────────────────────────
                                                         │
  ┌──────────┐  instr_req_o                             │
  │          │──────────────────────────────►           │
  │   IF     │  instr_addr_o (PC value)                 │
  │  Stage   │                                          │
  │          │◄─────────────────────────────            │
  │          │  instr_gnt_i (TB says "ok")              │
  │          │  instr_rdata_i (the instruction word)    │
  └──────────┘                                          │
       │                                                │
       │ instruction passes to stage 2                  │
       ▼                                                │
  ┌───────────────────────────────────────┐             │
  │            ID/EX/WB Stage            │             │
  │  Decode → Execute → Write Result     │             │
  │                                      │             │
  │  commit_valid = 1 when done          │─────────────┘
  │  commit_rd    = which register       │
  │  commit_result = what value          │
  │  commit_pc    = which instruction    │
  └───────────────────────────────────────┘
```

**Key insight**: The testbench does NOT interact with the inside of the pipeline. It interacts at two clean interfaces:
1. **Input interface** (OBI bus): Feed instructions to the DUT
2. **Output interface** (commit port): Observe what the DUT did

This is called **black-box verification** — we treat the DUT as a box and only look at inputs and outputs.

---

## PART 3 — THE GOLDEN REFERENCE MODEL (C ISS)

### What is an ISS?

An **Instruction Set Simulator** is a software program that executes RISC-V instructions exactly as the specification defines. It is the ground truth — when the real hardware runs `ADD x1, x2, x3`, we run the same instruction in the ISS and check if the hardware got the same answer.

### The ISS state — what the CPU knows at any moment

```c
typedef struct {
    uint32_t x[32];      // 32 registers: x0 through x31
                         // x0 is always 0 (hardwired by spec)
    uint32_t pc;         // Program Counter — address of current instruction

    // CSRs (Control and Status Registers) — machine mode
    uint32_t mstatus;    // machine status (interrupt enable bits)
    uint32_t misa;       // ISA features (says "I support RV32IM")
    uint32_t mie;        // machine interrupt enable
    uint32_t mtvec;      // address of the exception handler
    uint32_t mepc;       // saved PC when exception happens
    uint32_t mcause;     // why the exception happened (code 0-11)
    uint32_t mtval;      // additional exception info (faulting address)
    uint32_t mip;        // pending interrupt bits
    uint64_t cycle;      // cycle counter
    uint64_t instret;    // instructions retired counter

    uint8_t  imem[256*1024];  // 256 KB instruction memory
    uint8_t  dmem[256*1024];  // 256 KB data memory
    int      halted;          // 1 after EBREAK
    int      verbose;         // 1 = print every instruction
} rv32im_state_t;
```

Every time the hardware commits an instruction, we call the ISS to "execute" that same instruction. If the ISS says `x1 = 0x0000000A` and the hardware says `x1 = 0x0000000B`, that is a bug.

### How the ISS decodes an instruction

Every 32-bit RISC-V instruction has fields at fixed bit positions:

```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│  funct7  │  rs2  │  rs1  │funct3│  rd   │ opcode │
│  [7 bits]│[5bits]│[5bits]│[3bit]│[5bits]│[7 bits]│
└──────────┴───────┴───────┴──────┴───────┴────────┘

opcode  = instr[6:0]   → what class of instruction (ADD, LOAD, BRANCH...)
rd      = instr[11:7]  → destination register (which x-register gets the result)
funct3  = instr[14:12] → variant within the class (ADD vs SUB, BEQ vs BNE)
rs1     = instr[19:15] → first source register
rs2     = instr[24:20] → second source register
funct7  = instr[31:25] → further qualifier (ADD vs MUL, SRL vs SRA)
```

**Real example — ADD x3, x1, x2:**
- opcode = 0x33 (R-type integer)
- rd = 3 (write to x3)
- funct3 = 0 (ADD)
- rs1 = 1 (read x1)
- rs2 = 2 (read x2)
- funct7 = 0x00 (not M-extension, not SUB)
- Encoding = `0000000_00010_00001_000_00011_0110011` = `0x00208133`

### How the ISS step function works

```
iss_step_instr(state, 0x00208133):
  1. Extract opcode = 0x33
  2. Switch on opcode → R-type arithmetic
  3. Extract rs1=1, rs2=2, rd=3, funct3=0, funct7=0
  4. Check funct7: 0x00 → ADD (not MUL which would be funct7=0x01)
  5. result = state->x[1] + state->x[2]   // read both sources
  6. state->x[3] = result                 // write destination
  7. state->x[0] = 0                      // x0 ALWAYS stays 0
  8. state->pc += 4                       // advance to next instruction
  9. Return: {rd=3, result=<value>, next_pc=pc+4, trap=0}
```

The returned struct is exactly what the scoreboard needs to compare against the DUT.

### The standalone self-test

Before trusting the ISS as a reference, we verify it independently:

```bash
make test_iss
# Compiles with gcc only — no VCS, no simulator needed
# Runs 23 hand-crafted test cases
# Expected output: 23/23 PASS
```

The self-test covers the exact corner cases that correspond to the 6 bugs planted in the DUT — SRA with negative operand, DIV by zero, LB sign extension, INT_MIN÷-1. If these pass in the ISS, when the DUT fails them, we know the ISS is right.

---

## PART 4 — THE DPI-C BRIDGE

### The problem: How does C code talk to SystemVerilog?

The ISS is written in C. The scoreboard is written in SystemVerilog. They run in the same simulation process, but they are different languages. The solution is **DPI-C** (Direct Programming Interface for C) — an IEEE standard (part of IEEE 1800) that lets SystemVerilog call C functions at runtime.

### How it works

**Step 1: Declare the functions in C with `__attribute__` linkage**

File: `iss/rv32im_iss_dpi.c`

```c
// A single ISS state shared across the entire simulation
static rv32im_state_t g_iss;

// Called once at simulation start (from scoreboard build_phase)
void iss_dpi_init() {
    iss_init(&g_iss);
}

// Called for every committed instruction
void iss_dpi_step(
    unsigned int  instr,      // the instruction that was committed
    unsigned int  pc,         // the PC of that instruction
    unsigned int *rd_out,     // ← ISS says: this register was written
    unsigned int *res_out,    // ← ISS says: this value was written
    unsigned int *npc_out,    // ← ISS says: next PC should be this
    int          *trap_out,   // ← ISS says: was an exception taken?
    unsigned int *mcause_out, // ← ISS says: exception cause
    unsigned int *mepc_out    // ← ISS says: exception PC
) {
    // Sync PC in case DUT diverged
    if (g_iss.pc != pc) g_iss.pc = pc;

    // Execute the instruction in the ISS
    iss_result_t r = iss_step_instr(&g_iss, instr);

    // Return results to SystemVerilog
    *rd_out     = r.rd;
    *res_out    = r.result;
    *npc_out    = r.next_pc;
    *trap_out   = r.trap;
    *mcause_out = r.mcause;
    *mepc_out   = r.mepc;
}
```

**Step 2: Import the functions in SystemVerilog**

File: `tb/env/rv32im_pkg.sv`

```systemverilog
import "DPI-C" function void iss_dpi_init();

import "DPI-C" function void iss_dpi_step(
    input  logic [31:0] instr,
    input  logic [31:0] pc,
    output logic [31:0] rd_out,
    output logic [31:0] res_out,
    output logic [31:0] npc_out,
    output int          trap_out,
    output logic [31:0] mcause_out,
    output logic [31:0] mepc_out
);
```

**Step 3: VCS compiles both together**

```bash
vcs ... rv32im_iss.c rv32im_iss_dpi.c tb/tb_top.sv -o sim/vcs/simv
```

VCS uses gcc internally to compile the C files (with `-CFLAGS "-O2 -fPIC -Wall"`) and links the resulting object into the simulation binary. At runtime, calling `iss_dpi_step(...)` in SystemVerilog directly calls the C function — no overhead, no message passing.

### The PC sync logic — why it matters

If the DUT has a bug in instruction N, the scoreboard reports a mismatch and the ISS's PC is now at the wrong address for instruction N+1. Without correction, every subsequent instruction would also mismatch — creating a flood of false errors that drowns the real bug. The PC sync in `iss_dpi_step()` prevents this: before executing, it checks if the DUT's observed PC matches the ISS's PC. If not, it forces the ISS to use the DUT's PC. This means after each real bug, only one error is reported, keeping the log readable.

---

## PART 5 — THE UVM ENVIRONMENT

### UVM at 30,000 feet

UVM (Universal Verification Methodology) is a standardized way to structure testbenches. It provides:
- A class hierarchy (every component extends a base class)
- A phase system (build → connect → run → report in the right order)
- A factory system (swap one component for another without rewriting code)
- Analysis ports (publish-subscribe: monitor broadcasts, multiple subscribers receive)
- A configuration database (pass interface handles down the hierarchy without global variables)

The goal of UVM is **reuse and structure** — verification components written for one project can be reused in another.

### The complete architecture

```
tb_top.sv (SystemVerilog module — not a class)
│
│  Creates: clock, reset, ibex DUT, rv32im_if
│  Calls: run_test() which starts UVM
│
├── ibex_core_i  ←── DUT (the CPU we are testing)
│
├── rv32im_if    ←── SystemVerilog Interface (signals shared between DUT and TB)
│     ├── OBI instruction fetch signals (instr_req, gnt, rdata, addr...)
│     ├── OBI data memory signals (data_req, gnt, rdata, wdata, we, be...)
│     ├── Commit port (commit_valid, commit_rd, commit_result, commit_pc, commit_instr)
│     └── Trap port (trap_valid, trap_cause, trap_pc)
│
├── pipeline_fsm_checker   ←── SVA checker module (8 pipeline assertions)
├── hazard_checks_checker  ←── SVA checker module (6 hazard assertions)
│
└── uvm_test_top  ←── Created by run_test(+UVM_TESTNAME=rv32im_rand_test)
      │
      └── rv32im_rand_test  extends rv32im_base_test
            │
            └── rv32im_env  (the UVM environment)
                  │
                  ├── rv32im_agent  (the active agent)
                  │     ├── rv32im_sequencer  (arbitrates sequences)
                  │     ├── rv32im_driver     (drives OBI bus)
                  │     └── rv32im_monitor    (observes commit port)
                  │           │
                  │           ├── ap_commit ──────────► rv32im_scoreboard
                  │           └── ap_coverage ─────────► rv32im_coverage
                  │
                  ├── rv32im_scoreboard  (calls ISS, compares results)
                  └── rv32im_coverage    (samples 5 covergroups)
```

### How everything connects — the flow of data

```
STIMULUS SIDE (left → right)                    CHECKING SIDE (right → left)
─────────────────────────────                   ──────────────────────────────

Test                                            Monitor
  │ create txn                                    │ sees commit_valid
  │ start_item(txn)                               │ samples all signals
  ▼                                               │ creates rv32im_txn
Sequencer                                         │ calls ap_commit.write(txn)
  │ arbitrates                                    │                │
  │ get_next_item(txn)                            ▼                ▼
  ▼                                          Scoreboard       Coverage
Driver                                          │                │
  │ encode instruction                          │ iss_dpi_step() │ sample all
  │ write to imem_q                             │                │ 5 covergroups
  │ iss_dpi_write_instr()                       │ compare        │
  │ wait for DUT instr_req_o                    │ DUT vs ISS     │
  │ apply grant latency                         │                │
  │ assert instr_gnt_i                          │ PASS or        │
  │ drive instr_rdata_i                         │ UVM_ERROR      │
  ▼                                             │                │
ibex DUT                                   ISS (C golden model)
  │ fetches instruction                         │
  │ executes it                           called from iss_dpi_step()
  │ writes result to register file              runs same instruction
  │ asserts commit_valid                        returns expected values
  │
  ▼
commit_valid, commit_rd, commit_result,
commit_pc, commit_instr
  (signals on rv32im_if)
```

---

## PART 6 — THE DRIVER IN DETAIL

### What the driver does

The driver is the component that puts instructions into the DUT. It is the only "active" component — everything else just observes.

**The driver owns two memory arrays:**

```systemverilog
logic [31:0] imem_q [0 : 65535];   // 64K words = 256KB instruction memory
logic [31:0] dmem_q [0 : 65535];   // 64K words = 256KB data memory
```

At startup these are filled with `0x00000013` (which is `ADDI x0, x0, 0` — the canonical NOP). This means if the DUT fetches beyond what was programmed, it gets NOPs instead of garbage.

**The OBI protocol the driver implements:**

```
Time →    T0    T1    T2    T3    T4    T5
         ──────────────────────────────────
clk       ↑     ↑     ↑     ↑     ↑     ↑
                │
instr_req_o  ──1─────────────────────────  DUT says "I want instruction"
instr_addr_o ──addr──────────────────────  DUT says "at this address"

                      │  ← driver waits 2 cycles (latency=2)
instr_gnt_i     ──────2─────1            Driver says "OK, here it is"
instr_rdata_i   ──────inst──────────────  Driver drives the instruction word

                            │
instr_rvalid_i        ──────1────────    Data is valid (one cycle after gnt)
```

**Why configurable latency?**

Real memory (SRAM, DRAM) does not respond in 0 cycles. The DUT must correctly handle back-pressure — it must hold `req` stable until it receives `gnt`, then wait for `rvalid`. The driver tests this by randomly varying the grant latency from 0 to 3 cycles per instruction. If the DUT drops `req` early or reads `rdata` on the wrong cycle, it would get a wrong instruction — which the scoreboard would immediately catch.

SVA property P7 checks this too:
```
P7: instr_req_o && !instr_gnt_i |=> instr_req_o
// "If req is high but no grant yet, req must still be high next cycle"
```

**The data memory bus:**

When the DUT executes a load (`LW`, `LH`, `LB`) or store (`SW`, `SH`, `SB`), it uses the `data_*` signals. The driver handles those in `respond_to_data_req()`. For stores, it applies byte-enable masks to `dmem_q`. For loads, it returns the stored word. This is how memory persistence works — a `SW` followed by a `LW` from the same address returns the stored value.

---

## PART 7 — THE MONITOR IN DETAIL

### What the monitor watches

The monitor is completely passive — it drives nothing. It watches the **commit port**, which is ibex's register-file write port. When ibex finishes executing an instruction and writes the result to a register, it asserts `commit_valid` for one cycle with all the information:

```systemverilog
// From tb_top.sv — these are internal ibex signals tapped hierarchically
assign dut_if.commit_valid  = ibex_core_i.rf_we_wb;          // write enable
assign dut_if.commit_rd     = ibex_core_i.rf_waddr_wb_o;     // destination register
assign dut_if.commit_result = ibex_core_i.rf_wdata_fwd_wb_o; // result value
assign dut_if.commit_pc     = ibex_core_i.pc_wb_o;           // PC of this instruction
assign dut_if.commit_instr  = ibex_core_i.instr_rdata_id_i;  // instruction word
```

The monitor's `run_phase` loops forever, sampling every clock:

```systemverilog
forever begin
    @(vif.mon_cb);  // wait for clock edge (via clocking block — no race condition)

    if (vif.mon_cb.commit_valid) begin
        txn = new();
        txn.pc      = vif.mon_cb.commit_pc;
        txn.instr   = vif.mon_cb.commit_instr;
        txn.rd      = vif.mon_cb.commit_rd;
        txn.result  = vif.mon_cb.commit_result;
        txn.is_trap = 0;

        ap_commit.write(txn);    // → scoreboard
        ap_coverage.write(txn);  // → coverage collector
    end

    if (vif.mon_cb.trap_valid) begin
        // Same but with is_trap=1, mcause, mepc
        ...
    end
end
```

**Why clocking blocks matter here:**

ibex drives `commit_result` at `posedge clk`. If the monitor sampled it at the same `posedge clk`, there could be a race — which happens first, the DUT writing the signal or the monitor reading it? The clocking block's input skew (default: 1 step before the edge) guarantees the monitor reads the signal's value from just before the edge — the stable settled value from the previous cycle. No race, no ambiguity.

### Why branches and stores don't show commit_valid

Not every instruction writes a register. Branches (`BEQ`, `BNE`, etc.) compare two registers and change the PC — they write no register. Stores (`SW`, `SH`, `SB`) write to memory — they write no register. For these, `commit_valid` / `rf_we_wb` is 0. The monitor only fires when `commit_valid` is 1, so branches and stores are observed differently (through their effect on subsequent PC values). This is an intentional simplification — the scoreboard's main check is register-file correctness.

---

## PART 8 — THE SCOREBOARD IN DETAIL

### The scoreboard's job

The scoreboard is the most important component. For every instruction the DUT commits, the scoreboard:
1. Calls the C ISS to get the expected result
2. Compares expected vs actual
3. Reports any mismatch with a full diagnostic

### The complete check flow

```
write_commit(txn) is called by monitor's ap_commit.write()
│
├── Is this a trap?
│     YES → call iss_dpi_step(), verify ISS also took a trap,
│           verify mcause matches, report PASS or UVM_ERROR
│
└── Normal commit:
      │
      ├── Call iss_dpi_step(txn.instr, txn.pc, ...)
      │   Returns: rd_exp, res_exp, npc_exp, trap_exp, mcause_exp, mepc_exp
      │
      ├── Check 1: txn.rd == rd_exp?
      │   Fail → UVM_ERROR "RD MISMATCH: DUT: rd=x2  ISS: rd=x3"
      │           + dump ISS register file
      │           + return (don't bother checking result)
      │
      ├── Check 2: (txn.rd != 0) && (txn.result != res_exp)?
      │   Fail → UVM_ERROR "RESULT MISMATCH: DUT: x2=3FFFFFFC  ISS: x2=FFFFFFFC  diff=C0000000"
      │           + dump ISS register file
      │           + return
      │
      ├── Check 3: ISS expected trap but DUT committed normally?
      │   Fail → UVM_ERROR "MISSED TRAP: ISS expects trap mcause=2 but DUT committed"
      │
      └── All good → pass_count++
                     Log: "PASS #42 PC=00000020 ADD x3=0000000A"
```

### The check_phase final summary

At the end of simulation, the scoreboard's `check_phase` prints:

```
=== Scoreboard Final Report ===
  Total checks : 200
  Pass         : 194
  Fail         : 6
  Traps caught : 5
[UVM_ERROR] TEST FAILED: 6 scoreboard mismatches
```

If `fail_count > 0`, the test fails. If `check_count == 0`, something is wrong with the monitor connection (warns you, doesn't fail).

---

## PART 9 — THE SVA ASSERTIONS IN DETAIL

### What SVA is and why it exists alongside the scoreboard

The scoreboard checks instruction-level correctness: "did this instruction produce the right value?" SVA checks **structural** and **protocol** correctness: "is the pipeline behaving correctly as a state machine?"

SVA runs in parallel with simulation — every property is checked on every clock cycle automatically. You cannot forget to call it. If a property fails, VCS tells you the exact clock cycle, the signal values, and which property failed.

### The interface — how signals reach the SVA checkers

From `tb_top.sv`:
```systemverilog
pipeline_fsm_checker u_pipeline_sva (
    .clk          (clk),
    .rst_n        (rst_n),
    .instr_req_o  (dut_if.instr_req_o),
    .instr_gnt_i  (dut_if.instr_gnt_i),
    .instr_addr_o (dut_if.instr_addr_o),
    .commit_valid (dut_if.commit_valid),
    .commit_rd    (dut_if.commit_rd),
    .commit_result(dut_if.commit_result),
    .commit_pc    (dut_if.commit_pc),
    .trap_valid   (dut_if.trap_valid)
);
```

The SVA checkers are separate modules that receive signals from the interface. They do not modify anything — they only observe.

### All 8 pipeline properties explained

**P1 — First fetch after reset:**
```systemverilog
$rose(rst_n) |-> ##[1:4] instr_req_o;
```
Translation: "When reset goes from 0 to 1 (`$rose`), within 1 to 4 clock cycles after that (`##[1:4]`), the DUT must assert `instr_req_o`."
Catches: DUT stuck in reset, clock not running, fetch unit broken.

**P2 — Grant latency:**
```systemverilog
instr_req_o |-> ##[0:3] instr_gnt_i;
```
Translation: "If req is asserted, grant must come within 0 to 3 cycles."
Note: This actually checks the driver-controlled grant too. Since the driver's max latency is 3 cycles, this is always true when the driver is working correctly. If a driver bug causes it to never assert grant, this fires.

**P3 — No commit during reset:**
```systemverilog
@(posedge clk) !rst_n |-> !commit_valid;
```
Translation: "Any clock where reset is active, commit_valid must be 0."
Note: This property deliberately does NOT use `default disable iff (!rst_n)` because we want it active during reset.
Catches: DUT spuriously committing instructions before reset releases.

**P4 — x0 always zero:**
```systemverilog
commit_valid && (commit_rd == 5'd0) |-> (commit_result == 32'd0);
```
Translation: "Any commit that writes register x0 must write the value 0."
Why: x0 in RISC-V is hardwired to zero. Any instruction that nominally writes x0 (like `ADD x0, x1, x2`) must discard the result. If the DUT writes a non-zero value to x0, the register file is corrupted.
Bug this catches: BUG-001 (branch misprediction) causes the DUT to fetch from the wrong address. The instructions at the wrong address may write non-zero values to x0.

**P5 — Mutual exclusion:**
```systemverilog
!(commit_valid && trap_valid);
```
Translation: "commit_valid and trap_valid can never both be 1 in the same cycle."
Why: An instruction either commits normally (writes register) OR causes an exception (takes trap). It cannot do both.
Catches: Exception handling logic bug where both paths are activated simultaneously.

**P6 — Fetch alignment:**
```systemverilog
instr_req_o |-> (instr_addr_o[1:0] == 2'b00);
```
Translation: "Any instruction fetch address must have its bottom 2 bits = 0 (i.e., divisible by 4)."
Why: RISC-V instructions are 4 bytes wide and must be word-aligned. Fetching from address 0x00000001 or 0x00000002 is illegal.
Catches: PC update bug where address increment logic is wrong.

**P7 — OBI req stable:**
```systemverilog
instr_req_o && !instr_gnt_i |=> instr_req_o;
```
Translation: "If req is high and grant has not yet arrived, req must remain high next cycle."
Why: OBI protocol requires the master to hold req stable until it receives gnt.
Catches: DUT prematurely drops req before getting an acknowledgement.

**P8 — Grant needs request:**
```systemverilog
instr_gnt_i |-> instr_req_o;
```
Translation: "The slave (driver) can only assert grant when the master (DUT) has an active request."
Why: This is an OBI protocol rule. Granting when nobody requested is nonsensical.
Catches: Driver bug — though in this project the driver controls both signals, so this mainly validates driver correctness.

### All 6 hazard properties explained

**H1 — Load-use stall observation:**
The property checks that after a load instruction that writes register Rx, if the very next committed instruction reads Rx, the load-use hazard pattern was correctly handled (with a 1-cycle stall). The SVA cover property on this ensures the pattern was actually observed — if the cover is never hit, the hazard sequence didn't work.

**H2 — Flush after branch:**
Checks that after a branch commit, the next fetch comes from the branch target, not from the sequential address. If the DUT flushes incorrectly, the wrong instructions would execute.

**H3 — No commit after trap:**
```systemverilog
trap_valid |=> !commit_valid;
```
Translation: "The cycle after a trap is signaled, commit_valid must be 0."
Why: When an exception is taken, the pipeline must be flushed. The instruction behind the faulting one in the pipeline must be squashed. If commit_valid is high the next cycle, the flushed instruction was incorrectly committed.
Bug this catches: BUG-006 (mepc not updated). When mepc isn't saved correctly, the pipeline's exception handling is broken — and H3 helps identify that the post-trap state is wrong.

**H4 — Sequential PC:**
```systemverilog
(commit_valid && prev_commit_valid && !prev_was_branch && !prev_was_jump && !trap_valid)
|-> (commit_pc == prev_commit_pc + 4);
```
Translation: "For two consecutive non-branch commits, the second PC must equal the first PC plus 4."
Why: Sequential code increments the PC by 4 (one word) per instruction. If PC jumps unexpectedly, an instruction was either skipped or the wrong instruction was fetched.
Bug this catches: BUG-002 (forwarding mux inverted). If the forwarding bug corrupts a branch condition operand, the branch may be unexpectedly taken or not taken, causing a non-sequential PC that this property catches.

---

## PART 10 — THE 6 RTL BUGS

### Why we plant bugs

A testbench that never finds bugs might be correct, or it might be doing nothing. Planting known bugs and verifying they are detected is the industry-standard way to validate that a verification environment is actually working.

The 6 bugs are planted in `rtl/ibex_buggy/` (a copy of the clean ibex). Each is a realistic one-line change that mirrors a real class of silicon bug.

---

### BUG-001: Branch misprediction (`ibex_controller.sv`)

**The change:**
```diff
- pc_mux_sel_o = PC_BOOT;   // wrong: resets to address 0
+ pc_mux_sel_o = PC_JUMP;   // correct: jumps to branch target
```

**What happens:** When the DUT evaluates a branch (e.g., `BEQ x0, x0, +8`) and the branch is taken, the controller's PC mux should select the branch target address. With the bug, it selects `PC_BOOT` — the reset vector (address 0x00000000). The DUT restarts from the beginning of memory.

**How it's detected:**
1. The scoreboard: Immediately after the branch, the DUT's next committed PC is 0x00000000. The ISS computed the correct branch target. Every subsequent instruction is a mismatch.
2. SVA P4: Instructions fetched from address 0 may write non-zero values to x0 if the code there happens to do so.
3. SVA P1: Looks like a reset — the DUT starts fetching from address 0 mid-simulation.

**Waveform analysis:** `instr_addr_o` drops to `0x00000000` one cycle after the BEQ commit. In ibex's controller (`ibex_controller.sv`), the signal `pc_mux_sel_o` is driven to `PC_BOOT` instead of `PC_JUMP` in the branch-taken case.

---

### BUG-002: Forwarding mux inverted (`ibex_ex_block.sv`)

**The change:**
```diff
- rf_rdata_a_fwd = (forward_a_sel == 2'b00) ? rf_rdata_a_i : result_ex_i;
+ rf_rdata_a_fwd = (forward_a_sel == 2'b01) ? rf_rdata_a_i : result_ex_i;
```

**What happens:** The select condition is inverted. When `forward_a_sel == 2'b01` (meaning "use forwarded value"), the mux uses the register file's stale value. When `forward_a_sel == 2'b00` (meaning "use register file"), the mux uses the forwarded (new) value. The behavior is backwards.

**The scenario that catches it:**
```
Instruction 1: ADD x1, x2, x3     → x1 = x2 + x3 = 5 + 3 = 8
Instruction 2: ADD x4, x1, x5     → should be: x4 = x1(new=8) + x5 = 8 + 2 = 10
                                     with bug:  x4 = x1(old=0) + x5 = 0 + 2 = 2
```

**How it's detected:** The hazard sequence generates exactly this back-to-back RAW pattern with known register values. The scoreboard sees DUT reports x4=2 while ISS reports x4=10. One-line diff.

---

### BUG-003: Arithmetic right shift (`ibex_alu.sv`)

**The change:**
```diff
- SRA: result = $unsigned(operand_a_i) >> shift_amt;   // logical shift
+ SRA: result = $signed(operand_a_i)   >>> shift_amt;  // arithmetic shift
```

**What this means:**
- `>>` is logical right shift: fills vacated bits with 0
- `>>>` on a `$signed` value is arithmetic right shift: fills with the sign bit

For negative numbers (bit 31 = 1), the results are completely different:
```
0xFFFFFFF0 >> 2  = 0x3FFFFFFC  (wrong — positive result for negative input)
0xFFFFFFF0 >>> 2 = 0xFFFFFFFC  (correct — -16 >> 2 = -4)
```

**How it's detected:** Directed test: load -16 into x1, execute `SRA x2, x1, 2`. ISS returns 0xFFFFFFFC. DUT returns 0x3FFFFFFC. The scoreboard's diff field shows `0xC0000000` (the bits that differ) — immediately obvious which bits were wrong.

---

### BUG-004: DIV by zero returns 0 (`ibex_multdiv_slow.sv`)

**The change:**
```diff
- if (div_en && divisor == '0) quotient_o = '0;    // returns 0
+ if (div_en && divisor == '0) quotient_o = '1;    // returns -1 (all 1s)
```

**The spec:** RISC-V spec section M explicitly states: "Division by zero is defined to produce specific results rather than trap. For DIV: the result is −1 (all 1s). For REM: the result is the dividend unchanged."

**How it's detected:** The mul_div_seq generates `DIV x3, x1, x2` where `x2 = 0`. ISS returns 0xFFFFFFFF (-1). DUT returns 0x00000000. Immediate scoreboard mismatch.

---

### BUG-005: LB missing sign extension (`ibex_load_store_unit.sv`)

**The change:**
```diff
- LB: rdata_o = {24'h0,               data_rdata_i[7:0]};  // zero-extend
+ LB: rdata_o = {{24{data_rdata_i[7]}}, data_rdata_i[7:0]}; // sign-extend
```

**What this means:**
- `LB` (Load Byte, signed) must sign-extend the 8-bit byte to 32 bits
- If the byte's bit 7 (MSB) is 1 (value ≥ 128), the 24 upper bits should all be 1s
- The bug zero-extends instead: upper 24 bits are always 0

**Example:**
```
Memory at address 0: 0xAB (1010 1011 in binary, bit7 = 1)
Correct: LB x1, 0(x0) → x1 = 0xFFFFFFAB (negative number: -85)
With bug: LB x1, 0(x0) → x1 = 0x000000AB (positive number: 171 — completely wrong)
```

**How it's detected:** Directed test: store 0xAB to address 0, execute `LB x1, 0(x0)`. ISS returns 0xFFFFFFAB. DUT returns 0x000000AB.

---

### BUG-006: MEPC not updated on exception (`ibex_cs_registers.sv`)

**The change:**
```diff
- // mepc not assigned in exception path (the line was simply missing)
+ if (csr_save_cause_i) mepc_q <= exception_pc_i;
```

**What happens:** When an exception occurs (ECALL, illegal instruction, misaligned access), the hardware must save the PC of the faulting instruction into the `mepc` CSR. The exception handler can then use `MRET` (Machine Return) to resume at the saved address. With the bug, `mepc` retains whatever value it had before the exception — so `MRET` returns to the wrong address.

**How it's detected:**
1. The exception sequence: executes `ECALL`, the handler executes `MRET`, the next instruction's PC is wrong. Scoreboard catches the PC mismatch.
2. SVA H3: The cycle after `trap_valid`, `commit_valid` appears sooner than expected because the MRET lands at the wrong address and executes garbage code.

---

## PART 11 — FUNCTIONAL COVERAGE IN DETAIL

### Why coverage matters

After running 100 simulations, how do you know you tested everything important? You might have executed `ADD` a thousand times but never executed `SRA`. You might have tested forward branches but never backward branches. Coverage tells you what you missed.

### The 5 covergroups

**Covergroup 1: `cg_instr_mix` — did every instruction execute?**

```systemverilog
covergroup cg_instr_mix;
    cp_opcode: coverpoint txn.instr[6:0] {
        bins add  = {7'h33} iff (txn.instr[14:12]==3'h0 && txn.instr[31:25]==7'h00);
        bins sub  = {7'h33} iff (txn.instr[14:12]==3'h0 && txn.instr[31:25]==7'h20);
        bins sra  = {7'h33} iff (txn.instr[14:12]==3'h5 && txn.instr[31:25]==7'h20);
        bins mul  = {7'h33} iff (txn.instr[31:25]==7'h01 && txn.instr[14:12]==3'h0);
        // ... 47 bins total, one per instruction
    }
    cp_rd_zero: coverpoint txn.rd {
        bins x0_write = {5'd0};   // writes to x0
        bins nonzero  = {[1:31]}; // writes to x1..x31
    }
    cx_opcode_rd: cross cp_opcode, cp_rd_zero; // every instruction × write-to-x0
endgroup
```

Why cross with x0? Writing to x0 must silently discard the result. If any instruction writes a non-zero value that "sticks" to x0, the register file is corrupted — and SVA P4 catches it.

**Covergroup 2: `cg_branch` — all branches, all directions**

```
6 branch types × 2 directions (forward/backward) = 12 cross bins

forward branch  = positive immediate (instr[31] = 0)  → jumps forward in memory
backward branch = negative immediate (instr[31] = 1)  → loops backward (loops!)
```

Random testing easily gets forward branches. Backward branches require the PC to be above the target address, which means the sequence must have run at least some instructions first.

**Covergroup 3: `cg_mul_div` — M-extension corner cases**

```
8 M-extension operations × corner cases:
- div_by_zero: rs2 field is x0 (guarantees divisor = 0)
- overflow: result == 0x80000000 (INT_MIN ÷ -1 overflow)
- zero_product: MUL result is 0 (one operand is 0)
```

These corner cases are defined by the spec. If they are never tested, bugs in their handling (like BUG-004) would never be found.

**Covergroup 4: `cg_exception` — all exception types**

```
9 bins, one per mcause value:
  mcause=0  → instruction address misalignment
  mcause=1  → instruction access fault
  mcause=2  → illegal instruction (undefined opcode)
  mcause=3  → breakpoint (EBREAK instruction)
  mcause=4  → load address misalignment (LW at odd address)
  mcause=5  → load access fault
  mcause=6  → store address misalignment
  mcause=7  → store access fault
  mcause=11 → ECALL in machine mode
```

Sampled only when `txn.is_trap == 1`.

**Covergroup 5: `cg_load_store` — memory access patterns**

```
5 access sizes × 2 directions (load/store) = 10 cross bins:
  LB (byte signed) × load
  LH (halfword signed) × load
  LW (word) × load
  LBU (byte unsigned) × load
  LHU (halfword unsigned) × load
  SB (byte) × store
  SH (halfword) × store
  SW (word) × store
  (LBU/LHU have no store equivalents)
```

---

## PART 12 — THE REGRESSION FLOW

### The complete flow from zero to coverage closed

```
STEP 1: Compile (one time)
  make compile
  → VCS compiles all SV + C files together
  → Output: sim/vcs/simv (simulation binary)

STEP 2: Run regression (100 simulations in parallel)
  make regress
  → Python run_regression.py spawns 4 VCS jobs at a time
  → 5 test types × 20 seeds = 100 runs
  → Each run: sim/vcs/simv +UVM_TESTNAME=<test> +ntb_random_seed=<N>
  → Each run writes: sim/vcs/regression/<test>_<seed>.log
  → Each run writes: coverage data into sim/vcs/cov.vdb/

STEP 3: Merge coverage
  make coverage
  → urg -dir sim/vcs/cov.vdb -format text -report sim/vcs/coverage_report
  → Merges 100 separate coverage databases into one

STEP 4: Analyze gaps
  python scripts/aggregate_coverage.py --urg-report sim/vcs/coverage_report
  → Prints: coverage table with bar chart
  → Prints: list of uncovered bins
  → Example output:
     ================================================================
       Covergroup                           Coverage    Status
       --------------------------------  ----------    --------
       cg_exception                          72.2%     BELOW TARGET
       cg_mul_div                            81.3%     BELOW TARGET
       cg_branch                             91.7%     BELOW TARGET
       cg_load_store                         95.0%     OK
       cg_instr_mix                          97.1%     OK
     ================================================================
     Uncovered bins:
       cg_exception    load_misalign    → add directed test
       cg_exception    store_misalign   → add directed test
       cg_mul_div      div_by_zero      → add directed test

STEP 5: Write directed tests
  → Add targeted instruction sequences to rv32im_directed_test.sv
  → Each uncovered bin gets a specific sequence that guarantees hitting it

STEP 6: Iterate (typically 2 passes)
  → After directed tests, all 5 covergroups reach ≥ 98%
  → Code coverage (line + branch + toggle + FSM) exceeds 95%
```

### How `run_regression.py` works

```python
from concurrent.futures import ThreadPoolExecutor
import subprocess, re, json

def run_one(test, seed):
    cmd = f"sim/vcs/simv +UVM_TESTNAME={test} +ntb_random_seed={seed} ..."
    result = subprocess.run(cmd, capture_output=True, text=True)

    # Detect pass/fail from log
    log = result.stdout
    fail = bool(re.search(r'UVM_ERROR\s+:\s+[1-9]', log))
    return {"test": test, "seed": seed, "pass": not fail}

# Run all 100 combinations in parallel (4 at a time)
jobs = [(t, s) for t in tests for s in range(20)]
with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(lambda j: run_one(*j), jobs))

json.dump(results, open("results.json", "w"))
```

---

## PART 13 — THE INTERFACE AND CLOCKING BLOCKS

### Why a separate interface file?

The `rv32im_if.sv` interface bundles all signals between the DUT and the testbench into one object. Instead of passing 30 individual `logic` signals between modules, the interface is passed as a single virtual interface handle.

This enables:
- **Portability**: Change the DUT's port list in one place (the interface), not in driver, monitor, scoreboard, etc.
- **No race conditions**: Clocking blocks define when signals are sampled and driven
- **Modports**: Restrict which components can drive which signals

### The clocking blocks in detail

```systemverilog
interface rv32im_if (input logic clk, rst_n);

    // OBI instruction fetch signals
    logic        instr_req_o;      // DUT drives this
    logic        instr_gnt_i;      // Testbench drives this
    logic [31:0] instr_addr_o;     // DUT drives this
    logic [31:0] instr_rdata_i;    // Testbench drives this
    logic        instr_rvalid_i;   // Testbench drives this

    // Commit observation port
    logic        commit_valid;     // ibex internal signal (tapped in tb_top)
    logic [4:0]  commit_rd;
    logic [31:0] commit_result;
    logic [31:0] commit_pc;
    logic [31:0] commit_instr;

    // ────────────────────────────────────────────────────────────
    // DRIVER clocking block — driver reads/writes these
    // Input skew: sample 1 step BEFORE posedge clk
    // Output skew: drive 1 step AFTER posedge clk
    clocking drv_cb @(posedge clk);
        input  instr_req_o, instr_addr_o, data_req_o, data_addr_o;
        output instr_gnt_i, instr_rdata_i, instr_rvalid_i;
        output data_gnt_i, data_rdata_i, data_rvalid_i;
    endclocking

    // MONITOR clocking block — monitor reads these
    clocking mon_cb @(posedge clk);
        input commit_valid, commit_rd, commit_result, commit_pc, commit_instr;
        input trap_valid, trap_cause, trap_pc;
    endclocking

endinterface
```

**The race condition the clocking block prevents:**

Without clocking blocks:
```
Time T: DUT writes commit_result on posedge clk
Time T: Monitor reads commit_result on posedge clk  ← RACE: who wins?
```

With clocking blocks:
```
Time T-ε: Monitor samples commit_result (input skew = before edge)
           → guaranteed to read the stable value from time T-1
Time T: DUT writes commit_result  (this is the NEW value for next cycle)
Time T+ε: Driver drives instr_gnt_i (output skew = after edge)
           → DUT sees the new value at its next posedge
```

No race, deterministic behavior.

---

## PART 14 — THE MAKEFILE DECODED

Every command you need and what it does internally:

```makefile
# ── What VCS does during compile ──────────────────────────────────────
vcs
  -sverilog          → enable SystemVerilog (not just Verilog)
  -full64            → 64-bit simulation binary
  -ntb_opts uvm-1.2  → link UVM 1.2 library from VCS installation
  +define+UVM_NO_DEPRECATED          → suppress UVM deprecated warnings
  +define+UVM_OBJECT_MUST_HAVE_CONSTRUCTOR → UVM 1.2 strict mode
  -assert enable_diag  → show signal values in assertion failures
  -assert coverage     → instrument assertions for coverage collection
  -cm line+cond+fsm+tgl+branch  → enable 5 types of code coverage
  -CFLAGS "-O2 -fPIC -Wall"  → C compiler flags for ISS and DPI files
  +incdir+tb/env     → search path for `include files
  -f flist.f         → read list of all SV source files
  iss/rv32im_iss.c   → compile C ISS
  iss/rv32im_iss_dpi.c  → compile C DPI wrapper
  tb/tb_top.sv       → top-level SV file
  -o sim/vcs/simv    → output binary name
  -l sim/vcs/compile.log → write compile log

# ── What VCS does during simulation ──────────────────────────────────
sim/vcs/simv
  +UVM_TESTNAME=rv32im_rand_test  → which test class to run
  +ntb_random_seed=42             → reproducible random seed
  +UVM_VERBOSITY=UVM_MEDIUM       → how much to print
  +num_instrs=200                 → passed to test via plusarg
  -cm line+cond+fsm+tgl+branch    → collect coverage this run
  -cm_dir sim/vcs/cov.vdb         → where to write coverage database
  -l sim/vcs/rv32im_rand_test_42.log  → simulation log
```

**The make targets:**

| Command | What it does |
|---------|-------------|
| `make test_iss` | gcc only — proves ISS is correct before touching VCS |
| `make compile` | VCS elaboration — builds simv binary |
| `make smoke` | 10 ADDI instructions — sanity check |
| `make rand SEED=42` | 200 random instructions, seed 42 |
| `make directed` | Directed coverage-closure test |
| `make regress` | 100 runs in parallel via Python |
| `make coverage` | Merge VDB + print coverage table |
| `make parse` | Group failures by opcode → Markdown |
| `make clean` | Delete all sim outputs |

---

## PART 15 — THE COMPLETE TRANSACTION LIFECYCLE

This is the single most important thing to understand. Trace one instruction from creation to check:

```
Test (rv32im_hazard_seq):
  Creates txn with instr = 0x00208133 (ADD x3, x1, x2)
  seq.start_item(txn)
  seq.finish_item(txn)
         │
         │  [UVM sequencer arbitration]
         ▼
Driver.run_phase loop:
  seq_item_port.get_next_item(txn)  ← unblocks, receives txn
  
  imem_q[0] = 0x00208133           ← stores instruction at word address 0
  iss_dpi_write_instr(0, 0x00208133) ← syncs ISS memory
  next_load_addr = 4                ← next instruction goes at address 4
  
  handle_fetch_requests(latency=1):
    Wait for instr_req_o...
    [DUT asserts instr_req_o, drives instr_addr_o = 0x00000000]
    Wait 1 cycle (latency)
    Assert instr_gnt_i = 1
    Drive instr_rdata_i = 0x00208133
    Next cycle: instr_rvalid_i = 1, instr_rdata_i = 0x00208133
  
  seq_item_port.item_done()         ← tells sequencer this txn is done
         │
         │  [DUT pipeline: fetch → decode → execute → writeback]
         │  [DUT: reads x1=5, x2=3, adds them, gets 8]
         │  [DUT: asserts commit_valid with rd=3, result=8, pc=0]
         ▼
Monitor.run_phase loop:
  @(mon_cb)
  commit_valid == 1 → create txn
  txn.pc     = 0x00000000
  txn.instr  = 0x00208133
  txn.rd     = 3
  txn.result = 0x00000008
  txn.is_trap = 0
  ap_commit.write(txn)    ← broadcasts to scoreboard
  ap_coverage.write(txn)  ← broadcasts to coverage
         │                         │
         ▼                         ▼
Scoreboard.write_commit(txn):   Coverage.write(txn):
  iss_dpi_step(               txn = t;
    instr=0x00208133,         cg_instr_mix.sample();  ← hits "add" bin
    pc=0x00000000,            cg_branch.sample();     ← no match (not branch)
    &rd_exp,                  cg_mul_div.sample();    ← no match
    &res_exp,                 ...
    ...
  )
  → C ISS executes: x1=5, x2=3 → x3=8
  → Returns: rd_exp=3, res_exp=8

  Check: txn.rd(3) == rd_exp(3)  ✓
  Check: txn.result(8) == res_exp(8)  ✓
  pass_count++
  Log: "PASS #1 PC=00000000 ADD x3=00000008"
```

---

## KEY NUMBERS TO KNOW BY HEART

| Item | Number |
|------|--------|
| C ISS lines | ~600 |
| ISS standalone tests | 23 / 23 PASS |
| RV32IM instructions | 47 |
| CSRs modeled in ISS | 9 |
| UVM components | 7 (driver, monitor, scoreboard, coverage, sequencer, agent, env) |
| Test classes | 3 (smoke, rand, directed) |
| Sequence classes | 6 |
| Total test cases | 45+ |
| Functional covergroups | 5 |
| SVA assertions | 14 (8 pipeline + 6 hazard) |
| SVA cover properties | 8 |
| RTL bugs planted | 6 |
| RTL bugs found | 6 / 6 (100%) |
| Regression matrix | 5 tests × 20 seeds = 100 runs |
| Parallel jobs | 4 |
| Primary simulator | Synopsys VCS + UVM 1.2 |
| Code coverage types | 5 (line, condition, FSM, toggle, branch) |
| Clock frequency | 100 MHz (10 ns period) |
| Reset duration | 20 cycles |
| Simulation timeout | 1,000,000 cycles (configurable) |
| Instruction memory size | 256 KB |
| Data memory size | 256 KB |
| Max grant latency | 3 cycles |
