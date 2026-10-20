# RISC-V RV32IM UVM Verification — Complete Interview Preparation Guide

> **How to use this file:**
> Read it top to bottom once. Then go section by section and try to answer each question out loud before reading the answer. The follow-up questions are the ones an interviewer will ask when your first answer is good — they are trying to see how deep your understanding actually goes.

---

## SECTION 1 — THE PROJECT AT A GLANCE

---

### Q1. Tell me about this project. What is it, what did you build, and what was the goal?

**Your Answer:**

This is a complete UVM-based functional verification environment for a RISC-V RV32IM processor. I built it from scratch — starting with a verification plan, all the way to 100% coverage closure and regression automation.

The goal was to verify that the CPU correctly executes every instruction defined by the RISC-V specification — all base integer operations, memory loads and stores, branch instructions, multiply and divide (the M extension), CSR access, and exception handling — under randomized stimulus with realistic pipeline stress conditions.

The DUT (Device Under Test) is **ibex** — a production-quality open-source RV32IM core from lowRISC, which uses a 2-stage pipeline. I intentionally planted 6 realistic RTL bugs into a copy of ibex to validate that my testbench could catch real silicon-class defects. All 6 were caught.

The testbench is written in SystemVerilog using UVM 1.2. The golden reference model is a C-language Instruction Set Simulator (~600 lines) connected to the testbench through the DPI-C interface. I also wrote 14 SVA concurrent assertions to check pipeline-level properties, and Python scripts to automate regression and parse coverage reports.

---

### Follow-up Q1a. Why did you choose ibex as the DUT instead of writing your own simple RTL?

**Your Answer:**

Three reasons. First, ibex is a real production core — it was taped out in silicon as part of the OpenTitan project. Verifying it is meaningfully harder than verifying a toy RTL, and it makes the project credible on a resume. Second, it implements the full OBI (Open Bus Interface) protocol, which gave me the chance to build a real protocol driver — not just a single-cycle request-response. Third, its source is well-structured SystemVerilog, so when I analyzed waveforms to root-cause bugs, I was reading code that looks like real industrial RTL, not something I wrote myself.

---

### Follow-up Q1b. What does RV32IM mean exactly?

**Your Answer:**

- **RV** = RISC-V architecture
- **32** = 32-bit registers and address space — there are 32 general-purpose registers, each 32 bits wide (x0 through x31)
- **I** = the base Integer instruction set — ADD, SUB, AND, OR, XOR, SLL, SLR, SRA, LUI, AUIPC, loads, stores, branches, JAL, JALR
- **M** = the Multiply/Divide extension — MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU

The project also targets **Zicsr** — the CSR (Control and Status Register) extension — because ibex implements machine-mode CSRs that are needed for exception handling (mtvec, mepc, mcause, mtval, mstatus).

---

## SECTION 2 — THE C INSTRUCTION SET SIMULATOR (ISS)

---

### Q2. You built a C ISS as the golden reference model. Walk me through how it works.

**Your Answer:**

The ISS is in `iss/rv32im_iss.c` and its header `iss/rv32im_iss.h`. It is a software model of the RISC-V CPU — it executes the same instructions as the real hardware would, but in software, and it is always correct because it directly implements the specification.

The core state is a struct called `rv32im_state_t`:

```c
typedef struct {
    uint32_t x[32];     // integer register file x0..x31
    uint32_t pc;        // program counter
    uint32_t mstatus, misa, mie, mtvec;
    uint32_t mepc, mcause, mtval, mip;
    uint64_t cycle, instret;
    uint8_t  imem[256*1024];   // instruction memory
    uint8_t  dmem[256*1024];   // data memory
    int      halted;
    int      verbose;
} rv32im_state_t;
```

The main execution function is `iss_step_instr(state, instr)`. It takes the current state and a 32-bit instruction word. It decodes the instruction by extracting fields from the encoding:

- `opcode = instr[6:0]` — identifies the instruction class
- `rd = instr[11:7]` — destination register
- `funct3 = instr[14:12]` — operation variant within the class
- `rs1 = instr[19:15]`, `rs2 = instr[24:20]` — source registers
- `funct7 = instr[31:25]` — further qualifier (e.g., SRA vs SRL, MUL vs non-M)

The function then dispatches on opcode through a switch statement, computes the result, writes the destination register, advances the PC, and returns an `iss_result_t` struct:

```c
typedef struct {
    uint32_t rd;        // destination register index
    uint32_t result;    // value written to rd
    uint32_t next_pc;   // PC of next instruction
    int      trap;      // 1 if an exception was taken
    uint32_t mcause;    // exception cause code
    uint32_t mepc;      // PC of the faulting instruction
} iss_result_t;
```

This result is what the scoreboard compares against the DUT's actual commit output.

---

### Follow-up Q2a. Why a C ISS specifically? Why not write the golden model in SystemVerilog?

**Your Answer:**

A few reasons. First, a behavioral SystemVerilog model is still a hardware model — it runs in the simulator, it has its own scheduling and timing, and it can have simulation-domain bugs that mimic the DUT. A C model runs outside the simulation kernel and is completely independent. Second, C is faster to write and debug for instruction-level logic — I can test the ISS standalone with `gcc` and a simple test harness without needing a VCS license at all. Third, the DPI-C interface is specifically designed for this pattern — calling C functions from SystemVerilog is a first-class supported use case in the standard.

---

### Follow-up Q2b. How do you make sure the ISS itself is correct? How do you know the golden model isn't wrong?

**Your Answer:**

I wrote a standalone self-test in `iss/iss_test.c` — 23 hand-crafted test cases that run with just `gcc`, no simulator needed (`make test_iss`). Each test case encodes a specific instruction as a 32-bit word, calls `iss_step_instr()` directly, and checks the result against a hard-coded expected value.

The tests specifically target the same corner cases as the bugs I planted in the DUT:
- `SRA` with a negative operand (0xFFFFFFF0 >> 2 should be 0xFFFFFFFC, not 0x3FFFFFFC)
- `DIV` by zero (should return 0xFFFFFFFF = -1)
- `LB` with a byte ≥ 0x80 (should sign-extend to a negative 32-bit value)
- `INT_MIN / -1` overflow case for `DIV`
- `MULH` with negative operands
- All 6 branch types with taken and not-taken paths

All 23 checks pass. This gives me confidence that when the scoreboard reports a mismatch, the fault is in the DUT, not in my golden model.

---

### Follow-up Q2c. How does the ISS handle the M extension? MUL and DIV share opcode 0x33 with ADD and SUB — how do you tell them apart?

**Your Answer:**

In the RISC-V encoding, opcode `0x33` covers all R-type arithmetic. The `funct7` field (bits 31:25) distinguishes them:
- `funct7 = 0x00` → standard integer ops (ADD, SUB, AND, OR, XOR, SLL, SRL, SRA)
- `funct7 = 0x01` → M-extension ops (MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU)

In my ISS, the switch statement handles `case 0x33` for all R-type operations. After the switch exits, there is an override block:

```c
if (opcode == 0x33 && funct7 == 0x01) {
    // M-extension: override whatever the switch computed
    switch (funct3) {
        case 0: result = (int32_t)rs1_val * (int32_t)rs2_val; break; // MUL
        case 1: result = mulh(...);  break;  // MULH
        ...
        case 4: result = (rs2_val == 0) ? 0xFFFFFFFF : (int32_t)rs1_val / (int32_t)rs2_val; break; // DIV
        ...
    }
}
```

The `DIV` by zero case is explicitly handled — RISC-V spec section M says `x / 0` must return -1 (all ones), and `INT_MIN / -1` must return `INT_MIN` (overflow). Both edge cases are implemented and tested.

---

## SECTION 3 — THE DPI-C BRIDGE

---

### Q3. How does the C ISS connect to your SystemVerilog testbench?

**Your Answer:**

Through DPI-C — the Direct Programming Interface for C, defined in IEEE 1800-2012. It lets SystemVerilog call C functions at simulation runtime as if they were native tasks or functions.

The bridge is in `iss/rv32im_iss_dpi.c`. It declares a static `rv32im_state_t` that persists across calls — this is the ISS's live state that runs in lockstep with the simulation. The key functions exposed to SystemVerilog are:

```c
// Called from scoreboard build_phase
void iss_dpi_init();

// Called before each test
void iss_dpi_reset();

// Called by scoreboard write_commit() for every committed instruction
void iss_dpi_step(uint32_t instr, uint32_t pc,
                  uint32_t *rd_out, uint32_t *res_out, uint32_t *npc_out,
                  int *trap_out, uint32_t *mcause_out, uint32_t *mepc_out);

// Called by driver when an instruction is written to memory
void iss_dpi_write_instr(uint32_t addr, uint32_t word);

// Called on mismatch to print ISS register state
void iss_dpi_dump_regs();
```

On the SystemVerilog side, the package `rv32im_pkg.sv` imports these as:

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

VCS compiles the C file alongside the SystemVerilog using `-CFLAGS "-O2 -fPIC -Wall"` in the Makefile. The C object is linked into the simulation binary.

---

### Follow-up Q3a. What happens if the DUT and ISS get out of sync — for example, after a branch misprediction bug that causes the DUT to jump to the wrong address?

**Your Answer:**

This is exactly the robustness problem the `iss_dpi_step()` function handles. When `iss_dpi_step()` is called, the first thing it checks is whether the PC the DUT committed (`txn.pc`) matches the ISS's current `s->pc`. If they differ — which happens after the very first mismatch — the function updates the ISS's PC to match the DUT's observed PC before executing the instruction. This prevents cascading false failures. Without this sync, one wrong branch would cause hundreds of subsequent errors for instructions that are actually correct, making the log impossible to read.

---

### Follow-up Q3b. The DPI file has `#include "svdpi.h"`. Why can't you just compile it with gcc standalone?

**Your Answer:**

`svdpi.h` is provided by VCS and defines the C-side types and macros for the DPI interface — things like `svBit`, `svLogic`, and the linkage declarations. It is part of VCS's installation, not a standard system header. When I tried to run the DPI file standalone, the compiler fails at the `#include`. That is why I created `iss/iss_test.c` as a completely separate driver that calls the ISS core functions directly through `rv32im_iss.h`, bypassing DPI entirely. The ISS core and the DPI wrapper are separate files precisely to support this pattern.

---

## SECTION 4 — UVM ARCHITECTURE

---

### Q4. Walk me through your UVM environment architecture. What components did you build and how do they connect?

**Your Answer:**

The environment follows the standard UVM hierarchy. At the top is `rv32im_env` which contains one active `rv32im_agent` and two passive subscribers — the scoreboard and the coverage collector.

**The agent contains:**

1. **`rv32im_sequencer`** — the standard `uvm_sequencer` that arbitrates between test sequences and feeds transactions to the driver.

2. **`rv32im_driver`** — drives the ibex OBI instruction memory bus. It maintains a local array `imem_q[65536]` that mirrors the instruction memory. When it gets a transaction from the sequencer, it writes the instruction encoding into `imem_q` at the appropriate address and calls `iss_dpi_write_instr()` to keep the ISS memory in sync. It then responds to the DUT's `instr_req_o` signal with the instruction data and a configurable grant latency of 0 to 3 cycles.

3. **`rv32im_monitor`** — passively watches the commit port signals: `commit_valid`, `commit_rd`, `commit_result`, `commit_pc`, `commit_instr`, and the exception port: `trap_valid`, `trap_cause`, `trap_pc`. Every time `commit_valid` rises, it packages the observation into an `rv32im_txn` and broadcasts it on two analysis ports: `ap_commit` (to the scoreboard) and `ap_coverage` (to the coverage collector).

**Outside the agent:**

4. **`rv32im_scoreboard`** — implements `uvm_analysis_imp` with a `write_commit()` callback. On every call, it invokes `iss_dpi_step()`, compares the returned expected values against what the monitor observed, and calls `UVM_ERROR` on mismatch. It tracks pass/fail/trap counts and prints a summary in `check_phase`.

5. **`rv32im_coverage`** — implements the 5 functional covergroups. It samples them in its own `write_commit()` callback.

**The `rv32im_txn` class** carries both stimulus fields (the instruction word, rs1/rs2 values) and observed fields (committed rd, result, PC, whether it was a trap).

---

### Follow-up Q4a. What is an analysis port and why do you use it instead of a direct function call from monitor to scoreboard?

**Your Answer:**

An analysis port (`uvm_analysis_port`) implements a publish-subscribe pattern. The monitor publishes a transaction once, and any number of subscribers receive it independently. If I used a direct function call, the monitor would be hard-coded to know about the scoreboard — they would be tightly coupled, and I could never add a second subscriber (like the coverage collector) without modifying the monitor. With analysis ports, the connections are made in `rv32im_env.connect_phase()` using `ap_commit.connect(scoreboard.ap_commit)` — the monitor never knows who it is talking to. This is one of the core UVM reuse principles.

---

### Follow-up Q4b. What is the difference between a task and a function in UVM? The driver uses tasks — why?

**Your Answer:**

In SystemVerilog, a `function` cannot consume simulation time — it cannot have `@(posedge clk)` or `wait` statements. A `task` can. The driver's `run_phase` is a `task` because it loops forever, waiting for transactions from the sequencer and then executing the OBI handshake — which requires waiting for clock edges and monitoring handshake signals over multiple cycles. The scoreboard's `write_commit` is a `function` because it is called by the analysis port mechanism, which by definition is zero-time (it runs in the same time step as the monitor's write call). If you put a time-consuming operation in a `function`, the simulator would give an error.

---

### Follow-up Q4c. Walk me through exactly what happens from the moment a sequence sends an instruction to the moment the scoreboard checks it.

**Your Answer:**

1. A sequence (e.g., `rv32im_rand_seq`) calls `start_item(txn)` → `finish_item(txn)` on the sequencer. This blocks until the driver calls `get_next_item(txn)`.

2. The driver receives the transaction. It encodes the instruction (or uses the pre-encoded `txn.instr` word) and writes it into its local `imem_q` array at the current program counter address. It also calls `iss_dpi_write_instr(addr, word)` to keep the ISS memory synced.

3. The driver waits for the DUT to assert `instr_req_o`. When it does, the driver drives `instr_gnt_i` after 0–3 cycles (based on `txn.mem_latency`), and drives `instr_rdata_i` with the instruction word.

4. The ibex DUT fetches the instruction, decodes it, executes it, and asserts `commit_valid` along with `commit_rd`, `commit_result`, `commit_pc`, `commit_instr`.

5. The monitor sees `commit_valid` go high on the clock edge. It samples all the commit signals and constructs an `rv32im_txn`. It calls `ap_commit.write(txn)` which immediately triggers `write_commit()` in both the scoreboard and the coverage collector.

6. The scoreboard's `write_commit()` calls `iss_dpi_step(txn.instr, txn.pc, ...)` which steps the C ISS one instruction. The C function returns the expected `rd`, `result`, `next_pc`, and whether a trap was expected.

7. The scoreboard compares `txn.rd` vs `rd_exp` and `txn.result` vs `res_exp`. If they match: `pass_count++`. If not: `UVM_ERROR` with a formatted message showing PC, instruction word, DUT values, ISS values, and the XOR difference. Then `iss_dpi_dump_regs()` prints the full ISS register file for debugging.

---

## SECTION 5 — THE OBI DRIVER

---

### Q5. What is the OBI protocol and how did you implement it in the driver?

**Your Answer:**

OBI stands for Open Bus Interface — it is the memory-side protocol ibex uses for both instruction fetch and data memory access. It is similar in concept to AXI-Lite but much simpler. The handshake works like this:

- **Request phase**: The master (ibex) asserts `req` and drives `addr`. The slave (our driver/memory) must hold `gnt` low until it is ready, then assert `gnt` for one cycle. The master must not drop `req` until it receives `gnt`.

- **Response phase**: After `gnt`, the slave drives `rdata` (for a read) one cycle later (zero wait state) or after a latency.

In my driver, I model a simple instruction memory. When ibex asserts `instr_req_o`, the driver waits between 0 and 3 clock cycles (controlled by `txn.mem_latency`) before asserting `instr_gnt_i` and driving `instr_rdata_i` with the content of `imem_q[addr/4]`. This variability in grant latency is important — it exercises the DUT's ability to handle back-pressure on the instruction bus, which is a real-world condition.

The interface file `tb/rv32im_if.sv` has two clocking blocks:

```systemverilog
clocking drv_cb @(posedge clk);
    input  instr_req_o, instr_addr_o;
    output instr_gnt_i, instr_rdata_i, instr_rvalid_i;
endclocking

clocking mon_cb @(posedge clk);
    input  commit_valid, commit_rd, commit_result, commit_pc, commit_instr;
    input  trap_valid, trap_cause, trap_pc;
endclocking
```

The driver uses `drv_cb` and the monitor uses `mon_cb`. The clocking block automatically handles setup/hold with respect to the clock edge and avoids race conditions between driver and monitor.

---

### Follow-up Q5a. What are clocking blocks and why are they important?

**Your Answer:**

A clocking block in SystemVerilog defines the timing relationship between a set of signals and a clock edge. When you sample a signal inside a clocking block, it is captured at the defined strobe point — typically just before the clock edge. When you drive a signal through a clocking block, it is driven slightly after the clock edge. This eliminates the setup/hold race condition that would exist if you just used `@(posedge clk)` and then sampled the signal — there is a small but real chance the signal transitions in the same simulation step as the clock.

In practice: if the DUT drives `commit_result` on the rising edge and the monitor samples it on the same rising edge with `@(posedge clk) result = commit_result`, you can get a race — you might read the old value or the new value depending on scheduling order. The clocking block's input skew (default `-1 step`) guarantees you always read the value as it was just before the edge, which is the stable settled value.

---

## SECTION 6 — SVA ASSERTIONS

---

### Q6. Tell me about the SVA properties you wrote. What are they checking and how does SVA work?

**Your Answer:**

SVA — SystemVerilog Assertions — lets you describe temporal properties of a design in a formal language that the simulator checks every clock cycle, in parallel with normal simulation. There are two kinds: immediate assertions (checked at a single point in time) and concurrent assertions (checked across time, using sequences and properties).

I wrote two SVA checker modules — `pipeline_fsm.sva` and `hazard_checks.sva` — that are bound to the DUT from `tb_top.sv` using the `bind` construct. This means I never modify the DUT source to add checking logic.

**`pipeline_fsm.sva` — 8 properties about the pipeline's correct startup and protocol:**

```
P1: $rose(rst_n) |-> ##[1:4] instr_req_o;
```
After reset de-asserts, the DUT must initiate an instruction fetch within 4 cycles. `|->` is the overlapping implication — "if this happened at time T, then this must happen at T or later." `##[1:4]` means "between 1 and 4 cycles later."

```
P2: instr_req_o |-> ##[0:3] instr_gnt_i;
```
After a request, grant must come within 3 cycles. This matches the driver's maximum latency setting.

```
P4: commit_valid && (commit_rd == 0) |-> (commit_result == 0);
```
x0 is hardwired to zero in RISC-V — any commit that writes x0 must write the value 0. BUG-001 (branch misprediction) causes the DUT to execute instructions at wrong addresses, and those instructions may write non-zero values to x0, triggering this assertion.

```
P7: instr_req_o && !instr_gnt_i |=> instr_req_o;
```
The `|=>` is a non-overlapping implication — "if this is true now, then this must be true next cycle." This enforces OBI's requirement that the master holds req stable until grant arrives.

**`hazard_checks.sva` — 6 properties about pipeline hazard handling:**

```
H3: trap_valid |=> !commit_valid;
```
After a trap, the pipeline must flush. No commit should appear in the cycle immediately after the trap signal. BUG-006 (mepc not updated) was one of the bugs where H3 helped confirm the issue — the post-trap behavior was wrong.

```
H4: (commit_valid && prev_commit_valid && !prev_was_branch && !prev_was_jump && !trap_valid)
    |-> (commit_pc == prev_commit_pc + 4);
```
For two consecutive non-branch commits, the PC must advance by exactly 4. If the forwarding bug (BUG-002) causes the DUT to execute wrong values, it can corrupt a branch condition and cause an unexpected jump, which this property catches.

---

### Follow-up Q6a. What is the difference between `|->` and `|=>` in SVA?

**Your Answer:**

Both are implication operators — they say "if the antecedent (left side) holds, then the consequent (right side) must also hold."

- `|->` is **overlapping implication**: both sides are evaluated starting at the same clock cycle. If the antecedent matches at cycle T, the consequent must also start matching at cycle T. Example: `req |-> gnt` — if req is high at cycle T, gnt must also be high at cycle T.

- `|=>` is **non-overlapping implication**: if the antecedent matches at cycle T, the consequent must start matching at cycle T+1. Example: `trap_valid |=> !commit_valid` — if trap_valid is high at cycle T, then commit_valid must be low at cycle T+1.

A common mistake is using `|->` when you mean the next cycle and getting unexpected vacuous passes. Always think "same cycle or next cycle?" before choosing.

---

### Follow-up Q6b. What is a cover property and why did you include them alongside assert properties?

**Your Answer:**

An `assert property` says "this must always be true — if it's ever false, flag an error." A `cover property` says "I want to observe this happening at least once." Covers are about stimulus completeness, not correctness.

For example:
```systemverilog
cp_load_use_observed: cover property (
    load_committed && commit_valid &&
    (get_rs1(commit_instr) == load_rd_q || get_rs2(commit_instr) == load_rd_q));
```

This cover says "I want the load-use hazard pattern to actually occur at least once during simulation." If this cover is never hit, it means my hazard sequences never actually generated the hazard I was trying to test — which would be a failure in stimulus, not in the DUT. Coverage of the cover property itself goes into the VCS assertion coverage report, which is separate from the functional covergroups.

---

## SECTION 7 — CONSTRAINED-RANDOM SEQUENCES

---

### Q7. Tell me about your test sequences. How did constrained-random testing work in practice?

**Your Answer:**

I wrote 45+ instruction sequences across 6 classes, all extending `rv32im_base_seq` which provides encoding helper tasks for every instruction type.

The base sequence has tasks like:

```systemverilog
task enc_add(input logic [4:0] rd, rs1, rs2);
    txn.instr = {7'h00, rs2, rs1, 3'h0, rd, 7'h33};  // ADD encoding
    send_instr(txn);
endtask

task enc_beq(input logic [4:0] rs1, rs2, input logic [12:0] imm13);
    txn.instr = {imm13[12], imm13[10:5], rs2, rs1, 3'h0,
                 imm13[4:1], imm13[11], 7'h63};
    send_instr(txn);
endtask
```

**The 6 sequence classes:**

1. **`rv32im_rand_seq`** — 200+ instructions per run with constrained-random register selection, immediate values, and memory addresses. Uses `rand` fields in the transaction class with `constraint` blocks to keep addresses word-aligned, immediates within a reasonable range, and register indices non-zero (to avoid writing x0). The seed is controlled from the command line (`+ntb_random_seed=N`).

2. **`rv32im_hazard_seq`** — 8 directed sequences specifically producing RAW hazards:
   - Back-to-back `ADD x1, x2, x3` → `ADD x4, x1, x5` (EX→EX forwarding)
   - `LW x1, 0(x2)` → `ADD x3, x1, x4` (load-use stall)
   - Chains of 3+ dependent instructions to stress forwarding logic

3. **`rv32im_branch_seq`** — 8 directed sequences covering all 6 branch types (BEQ, BNE, BLT, BGE, BLTU, BGEU), forward and backward branches (positive and negative immediates), taken and not-taken paths.

4. **`rv32im_mul_div_seq`** — 7 directed sequences: basic MUL/DIV, `MULH` with signed negative operands, `MULHU` unsigned, `DIV` with quotient = 0, `DIV` by zero (must return -1), `INT_MIN / -1` (must return INT_MIN), `REM` with exact divisors.

5. **`rv32im_exception_seq`** — 5 directed sequences: ECALL in machine mode, illegal instruction encoding (invalid opcode), load with misaligned address, CSR CSRRW/CSRRS/CSRRC read-modify-write, MRET to return from exception handler.

6. **`rv32im_rand_seq` with custom weights** (used in directed test) — higher probability for uncovered opcodes, writes to x0, and specific immediate values that hit coverage bins.

---

### Follow-up Q7a. What is a load-use hazard and how did your sequence expose it?

**Your Answer:**

A load-use hazard is a specific type of data hazard where:
1. Instruction N is a load — it reads data from memory into a register (e.g., `LW x1, 0(x2)`)
2. Instruction N+1 immediately tries to read that same register as a source (e.g., `ADD x3, x1, x4`)

The problem is timing. A load instruction gets its result from memory at the end of the MEM stage. But the very next instruction needs the value at the beginning of its EX stage — which overlaps with the load's MEM stage. Even with forwarding hardware, you cannot forward a value that hasn't been computed yet. The pipeline must insert a **stall bubble** — one wasted cycle — to let the load complete before the consumer can proceed.

My `rv32im_hazard_seq` generates this exact pattern. The sequence sends `LW x1, 0(x2)` followed immediately by `ADD x3, x1, x4`. If ibex handles this correctly, there is a one-cycle bubble (the `stall` signal goes high for one cycle), and the result in x3 is correct. The scoreboard verifies the result. SVA property H1 covers the case to confirm the stall pattern was actually observed.

---

### Follow-up Q7b. What is the difference between a data hazard and a control hazard?

**Your Answer:**

A **data hazard** is when an instruction needs a value that a previous instruction hasn't finished computing yet. There are three kinds — RAW (Read After Write, the most common), WAR (Write After Read), and WAW (Write After Write). Modern pipelines with forwarding handle most RAW hazards in hardware; only load-use cannot be forwarded without a stall.

A **control hazard** is when the pipeline doesn't know which instruction to fetch next because a branch hasn't been resolved yet. In ibex's 2-stage pipeline, a taken branch means the instruction that was already fetched (in the IF stage) is the wrong one. The pipeline must flush it — insert a bubble — and fetch from the correct branch target. If the DUT has BUG-001 (wrong `pc_mux_sel`), the flush targets the wrong address, and execution continues at the reset vector instead of the branch target. The scoreboard catches this immediately because the next committed instruction has a PC that doesn't match the branch target.

---

## SECTION 8 — FUNCTIONAL COVERAGE

---

### Q8. Tell me about your functional coverage. What covergroups did you define and what did they cover?

**Your Answer:**

I defined 5 covergroups in `tb/env/rv32im_coverage.sv`, sampled in the `write_commit()` callback on every committed instruction.

**1. `cg_instr_mix`** — one bin per RV32IM opcode (all 47 instructions), plus a cross with "write to x0". This ensures every instruction was exercised at least once. Without this, random testing could easily never generate `MULHU` or `LHU` or `CSRRC`.

**2. `cg_branch`** — cross coverage of:
- Branch type (6 bins: BEQ, BNE, BLT, BGE, BLTU, BGEU)
- Direction (2 bins: forward branch = positive immediate, backward branch = negative immediate)
- Outcome (2 bins: taken, not-taken)

This produces 24 cross bins. Random testing easily hits the taken/not-taken split for BEQ and BNE, but tends to miss BLTU backward taken — which requires a specific unsigned comparison setup. That was one of the bins I had to write a directed test for.

**3. `cg_mul_div`** — covers the M-extension corner cases:
- Each of the 8 M-extension opcodes
- Divide by zero (divisor == 0)
- INT_MIN ÷ −1 overflow
- Zero result (quotient == 0, remainder == 0)
- Multiply result of zero (one operand is zero)

**4. `cg_exception`** — one bin per exception cause code:
- `mcause = 0`: instruction address misalign
- `mcause = 2`: illegal instruction
- `mcause = 3`: breakpoint (EBREAK)
- `mcause = 4`: load address misalign
- `mcause = 6`: store address misalign
- `mcause = 11`: ECALL in machine mode

**5. `cg_load_store`** — cross of operation type (LB, LH, LW, LBU, LHU, SB, SH, SW) × address alignment pattern (naturally aligned, byte-misaligned for LH/SH, word-misaligned for LW/SW). The misaligned cases must trigger exceptions.

---

### Follow-up Q8a. What is cross coverage and when is it better than having separate coverpoints?

**Your Answer:**

Cross coverage creates bins for every combination of two or more coverpoints. It tells you whether certain combinations were exercised, not just whether each individual value was seen.

For example, if I have separate coverpoints for "branch type" (6 values) and "taken/not-taken" (2 values), I could hit 100% on both and still never have tested a backward-taken BLT. The cross forces me to demonstrate all 12 combinations — forward-taken BEQ, forward-not-taken BEQ, backward-taken BEQ, backward-not-taken BEQ, and so on for all 6 branch types.

The downside is that cross bins multiply — if I have 6 branch types × 2 directions × 2 outcomes, that is 24 bins, and some of them are very hard to hit with random stimulus. That is expected — those hard bins are exactly where the interesting corner cases live.

---

### Follow-up Q8b. What is the difference between functional coverage and code coverage? Why do you need both?

**Your Answer:**

**Code coverage** is automatic — the simulator instruments the RTL and tracks:
- **Line coverage**: which source lines were executed
- **Branch coverage**: which sides of every if/else and case were taken
- **Toggle coverage**: whether each signal transitioned 0→1 and 1→0
- **FSM coverage**: which states and transitions of each state machine were visited
- **Condition coverage**: every sub-expression in a compound Boolean condition

Code coverage tells you what RTL was exercised. It does not tell you whether the interesting scenarios from the specification were covered. You can have 100% branch coverage and never have tested divide-by-zero if the RTL happens to share a code path.

**Functional coverage** is intent-driven — it captures what matters from a verification specification perspective. It tells you whether the scenarios you care about — divide-by-zero, backward taken branches, load-use hazards, ECALL in machine mode — were actually exercised.

You need both because:
- 100% code coverage does not imply all corner cases were hit
- 100% functional coverage does not imply all RTL paths were exercised (maybe a covergroup missed a bug-triggering path)
- Together they give a much stronger closure argument

---

## SECTION 9 — RTL BUGS

---

### Q9. Tell me about the 6 RTL bugs. Pick two and walk through how you found them.

**Your Answer:**

I'll walk through BUG-003 (SRA) and BUG-001 (branch misprediction) because they represent two different detection mechanisms — scoreboard result mismatch and SVA assertion failure respectively.

---

**BUG-003: Arithmetic right shift (`ibex_alu.sv`)**

The bug: `SRA` (Shift Right Arithmetic) was implemented with `>>` (logical shift) instead of `>>>` (arithmetic shift):

```diff
- SRA: result = $unsigned(operand_a_i) >> shift_amt;
+ SRA: result = $signed(operand_a_i) >>> shift_amt;
```

The difference: a logical right shift fills the vacated bits with 0. An arithmetic right shift fills them with the sign bit (bit 31). So for a negative number like `0xFFFFFFF0` (= -16 in two's complement), shifting right by 2:
- Logical (wrong): `0x3FFFFFFC` (positive result — completely wrong semantics)
- Arithmetic (correct): `0xFFFFFFFC` (= -4, which is -16 / 4, correct signed division behavior)

**How I found it:** My directed test `rv32im_hazard_seq` includes a sequence that sets `x1 = 0xFFFFFFF0` (negative) and then executes `SRA x2, x1, 2`. The scoreboard called `iss_dpi_step()` which returned `rd=2, result=0xFFFFFFFC`. The DUT committed `rd=2, result=0x3FFFFFFC`. The scoreboard logged:

```
RESULT MISMATCH: PC=00000018 instr=40205113 (SRA)
  DUT: x2=3FFFFFFC  ISS: x2=FFFFFFFC  diff=C0000000
```

I opened the Verdi waveform, found the SRA instruction at PC=0x18, expanded the ALU signals, saw `shift_result_o` was using the logical shift path, and traced it to the `SRA:` case in `ibex_alu.sv`.

---

**BUG-001: Branch misprediction (`ibex_controller.sv`)**

The bug: when a branch is taken, the controller's next-PC mux select was set to `PC_BOOT` (the reset vector, 0x00000000) instead of `PC_JUMP` (the branch target):

```diff
- pc_mux_sel_o = PC_BOOT;
+ pc_mux_sel_o = PC_JUMP;
```

**How I found it:** In the `rv32im_branch_seq`, I generated a forward `BEQ x0, x0, +8` — a branch that is always taken (both operands are x0, so they are always equal), jumping 8 bytes forward. After this branch, the scoreboard started reporting mismatches immediately because the DUT's next PC was 0x00000000 (reset vector) instead of the branch target. SVA property P1 also fired — `ap_first_fetch` caught the pipeline restarting from the boot vector mid-test.

The waveform showed `instr_addr_o` going to `0x00000000` one cycle after the BEQ. I looked at the controller FSM in Verdi, stepped back to the branch taken condition, and saw `pc_mux_sel` being set to the wrong value. One-line fix in `ibex_controller.sv`.

---

### Follow-up Q9a. How is BUG-004 (DIV by zero returning 0) different from a hardware crash?

**Your Answer:**

In hardware, dividing by zero does not crash a RISC-V CPU — it is defined behavior by the specification. Section M of the RISC-V ISA Manual explicitly states:

- `x / 0 = -1` (all 1s = 0xFFFFFFFF)
- `x % 0 = x` (the dividend is returned unchanged)
- `INT_MIN / -1 = INT_MIN` (overflow — two's complement wraparound)

This is different from x86, where dividing by zero raises an exception (`#DE`). RISC-V made this choice to keep the divide unit simple — no exception path needed, just saturate to defined sentinel values.

The bug was that the `ibex_multdiv_slow.sv` module had the wrong sentinel:

```diff
- if (div_en && divisor == '0) quotient_o = '0;    // wrong: returns 0
+ if (div_en && divisor == '0) quotient_o = '1;    // correct: returns -1
```

My `rv32im_mul_div_seq` test case `test_div_by_zero` set x2 = 0, executed `DIV x3, x1, x2`, and the scoreboard caught the mismatch immediately — ISS returned 0xFFFFFFFF, DUT returned 0x00000000.

---

## SECTION 10 — REGRESSION AND COVERAGE CLOSURE

---

### Q10. How did you run regression and achieve coverage closure?

**Your Answer:**

**Regression automation** is handled by `scripts/run_regression.py`. It uses Python's `concurrent.futures.ThreadPoolExecutor` to run up to 4 VCS simulations in parallel. For each test/seed combination, it assembles the VCS command line, spawns a subprocess, waits for it to finish, and scans the log for `UVM_ERROR` and `UVM_FATAL` using regex. Results go into a JSON file (`results.json`) and `scripts/parse_logs.py` groups any failures by opcode and generates a Markdown failure report.

The regression matrix I ran was: 5 test types × 20 seeds = 100 simulation runs.

**Coverage closure process:**

1. Run `make regress` — 100 simulations, all seeds.
2. VCS writes a coverage database (`.vdb` file) per run.
3. Run `make coverage` — this calls `urg -dir sim/vcs/cov.vdb -format text` to merge all per-run databases into one report.
4. Run `python scripts/aggregate_coverage.py` — parses the URG text report and prints a table with per-covergroup percentages and a list of uncovered bins.

After the first random regression pass, the uncovered bins were typically:
- `cg_instr_mix`: BGEU, LHU, SRA, CSRRC were not hit (rare in random mix)
- `cg_branch`: backward-taken BLTU, backward-taken BGEU
- `cg_mul_div`: divide-by-zero, INT_MIN÷-1 overflow
- `cg_exception`: load misalign, store misalign

I then wrote directed tests in `rv32im_directed_test.sv` that specifically generate these scenarios. After two iterations of directed tests, all 5 covergroups were ≥ 98%, and code coverage (line + branch + toggle + FSM) was above 95%.

---

### Follow-up Q10a. What is `urg` and what does it actually do?

**Your Answer:**

`urg` is the "Unified Report Generator" — a VCS utility that merges multiple coverage databases and generates a unified report. Each VCS simulation run with `-cm line+cond+fsm+tgl+branch -cm_dir <dir>` produces a `.vdb` (VCS database) directory containing the raw coverage data for that run.

When you run 100 simulations, each hitting different instruction sequences, the coverage achieved by any single run is incomplete — maybe one run hits `SRA`, another hits `BLTU`. `urg` merges them all:

```bash
urg -dir sim/vcs/cov.vdb -format text -report sim/vcs/coverage_report
```

The merged report shows the cumulative coverage across all runs — which is what matters. Without merging, you would have to look at 100 separate reports. `urg` also produces HTML reports and can generate the dashboard that shows which specific bins (individual SVA cover properties, specific covergroup bins) were not hit by any run.

---

### Follow-up Q10b. If you had 98% functional coverage but 40% FSM coverage, what would you do?

**Your Answer:**

I would look at what states or transitions the FSM coverage report says were never visited. ibex's controller FSM has states like RESET, BOOT_SET, FIRST_FETCH, DECODE, WAIT_SLEEP, and FLUSH_EX. If, say, WAIT_SLEEP was never visited, it means the WFI (Wait For Interrupt) instruction was never executed — I would add a directed sequence that generates WFI.

If a transition was never taken — for example, the DECODE → FLUSH_EX transition on a taken branch — I would look at whether my branch sequences are actually generating taken branches, or whether the test duration is too short for the branch to be exercised. Sometimes FSM coverage gaps are exposed by running longer simulations (`NUM_INSTRS=1000`).

The key point is: 40% FSM coverage means there are significant RTL paths that were never exercised, which is a real risk. A bug hiding in the WAIT_SLEEP state or the interrupt-entry path would never be found. Coverage closure means all metrics must reach the threshold, not just functional coverage.

---

## SECTION 11 — MAKEFILE AND TOOLFLOW

---

### Q11. Walk me through how you actually compile and run a simulation.

**Your Answer:**

The Makefile has two main phases — compile (elaboration) and simulation.

**Compile:**

```bash
vcs -sverilog -full64 \
    -ntb_opts uvm-1.2 \
    +define+UVM_NO_DEPRECATED \
    -assert enable_diag -assert coverage \
    -cm line+cond+fsm+tgl+branch \
    -CFLAGS "-O2 -fPIC -Wall" \
    +incdir+tb/env +incdir+tb/sequences +incdir+tb/tests +incdir+tb/sva \
    -f flist.f \
    iss/rv32im_iss.c \
    iss/rv32im_iss_dpi.c \
    tb/tb_top.sv \
    -o sim/vcs/simv
```

Key flags:
- `-ntb_opts uvm-1.2` — links UVM 1.2 library from VCS installation
- `-cm line+cond+fsm+tgl+branch` — enables 5 types of code coverage instrumentation
- `-CFLAGS` — flags passed to the C compiler when compiling the ISS and DPI files
- `-assert enable_diag` — enables detailed assertion failure messages with cycle info
- `-f flist.f` — reads the list of all SystemVerilog source files

**Simulate:**

```bash
sim/vcs/simv \
    +UVM_TESTNAME=rv32im_rand_test \
    +ntb_random_seed=42 \
    +UVM_VERBOSITY=UVM_MEDIUM \
    +num_instrs=200 \
    -cm line+cond+fsm+tgl+branch \
    -cm_dir sim/vcs/cov.vdb \
    -l sim/vcs/rv32im_rand_test_42.log
```

- `+UVM_TESTNAME` — tells the UVM test factory which test class to instantiate
- `+ntb_random_seed` — sets the random seed, making runs reproducible
- `-cm_dir` — where to write the coverage database for this run

---

### Follow-up Q11a. What is `flist.f` and what is in it?

**Your Answer:**

`flist.f` is a file-list file — it contains one SystemVerilog source file path per line, which VCS reads with the `-f flist.f` flag. This avoids putting every file path directly on the command line. In a real project with hundreds of files this is essential. My `flist.f` lists every `.sv` file in the tb directory: the package, interface, agent, driver, monitor, scoreboard, coverage, sequences, tests, and SVA files. The ibex RTL files would also go here once the DUT is cloned. The C files (`rv32im_iss.c`, `rv32im_iss_dpi.c`) are specified separately on the command line because VCS handles C files differently from SystemVerilog files.

---

## SECTION 12 — TOUGH FOLLOW-UP QUESTIONS

---

### Q12. If a simulation runs and the scoreboard sees 0 commits — no checks at all — what do you check?

**Your Answer:**

This is actually something the scoreboard detects in `check_phase`:

```systemverilog
else if (check_count == 0)
    `uvm_warning("SB", "No commits observed — check DUT and monitor connectivity");
```

In order, I would check:

1. **Is reset releasing?** — Look at the waveform for `rst_n`. If it stays low, the DUT never runs. Check `tb_top.sv` reset generation logic.

2. **Is the driver sending instructions?** — Put `UVM_HIGH` verbosity and look for driver print messages. If the driver never calls `get_next_item()`, the sequencer never started — check that the test's `start()` call is correct.

3. **Is the DUT fetching?** — Look for `instr_req_o` in the waveform. If it never goes high, the DUT is stuck in reset or has a clock issue.

4. **Is the commit port wired correctly?** — Check `tb/rv32im_if.sv` — are `commit_valid`, `commit_rd`, etc., connected to the right ibex output signals? ibex uses specific port names; if there is a name mismatch, the monitor sees the signals but they are always zero/disconnected.

5. **Is the monitor's clocking block sampling at the right edge?** — Verify the monitor uses `mon_cb` (the `@posedge clk` clocking block) and not direct signal access.

---

### Q13. BUG-002 was a forwarding mux inversion. Why is that hard to catch without a detailed directed test?

**Your Answer:**

Because random testing might not generate the specific register dependency pattern in the right sequence. The bug only manifests when:
1. Instruction N writes register Rx (any value)
2. Instruction N+1 reads Rx as a source

If the forwarding mux select is inverted, N+1 reads the stale register-file value of Rx instead of the just-computed value from N. With random register selection, many instructions will read registers that weren't recently written, so the stale value is actually correct — the bug is invisible.

The hazard sequence specifically constructs: `ADD x1, x2, x3` (writes x1 with a known value) immediately followed by `ADD x4, x1, x5` (reads x1). The expected value of x4 is `x1_new + x5`. The DUT returns `x1_old + x5`. The scoreboard catches the mismatch because the ISS tracked the correct forwarded value.

This is exactly why directed hazard sequences are necessary alongside random tests — random tests cover the "easy" cases, directed tests force the specific corner cases.

---

### Q14. What would you add to this testbench if you had more time?

**Your Answer:**

Several things:

1. **Interrupt handling** — ibex supports machine-mode external and timer interrupts. The current testbench has no interrupt injection. I would add an interrupt sequence that randomly asserts `irq_external_i` or `irq_timer_i` and verify that the DUT saves context correctly (mepc, mcause) and jumps to the interrupt handler.

2. **Data memory bus verification** — I only modeled the instruction fetch bus. The data memory OBI bus (for LW/SW) is another complete protocol instance that should also have a driver with back-pressure and error injection.

3. **Formal verification on the critical assertions** — SVA properties like P4 (x0 always zero) and H3 (no commit after trap) are good candidates for formal proof. Simulation can only check scenarios that actually occur; formal can prove the property holds for ALL possible input sequences.

4. **Power-on random** — randomize the initial register file state to something other than zero, to catch bugs that only manifest when operands have specific non-zero bit patterns.

5. **Regression result trending** — tracking coverage over successive regression runs to detect coverage regression when new tests are added.

---

## QUICK REFERENCE — NUMBERS TO KNOW

| Metric | Value |
|--------|-------|
| ISS lines of C | ~600 |
| ISS standalone tests | 23 / 23 pass |
| RV32IM instructions covered | 47 |
| CSRs modeled | 9 (mstatus, misa, mie, mtvec, mepc, mcause, mtval, mip, cycle/instret) |
| UVM components | driver, monitor, scoreboard, coverage, sequencer, agent, env, 3 test classes |
| Total test sequences | 45+ across 6 categories |
| Functional covergroups | 5 |
| SVA assertions | 14 (8 pipeline FSM + 6 hazard) |
| SVA cover properties | 8 |
| RTL bugs planted | 6 |
| RTL bugs detected | 6 / 6 |
| Regression matrix | 5 tests × 20 seeds = 100 runs |
| Parallel regression jobs | 4 |
| Primary simulator | Synopsys VCS + UVM 1.2 |
| Secondary simulator | Icarus Verilog (syntax/CI only) |
| Automation language | Python 3.8+, no external packages |

---

## GLOSSARY — TERMS YOU MUST KNOW COLD

| Term | Definition |
|------|-----------|
| **DUT** | Device Under Test — the ibex RISC-V CPU RTL |
| **ISS** | Instruction Set Simulator — the C golden reference model |
| **DPI-C** | Direct Programming Interface for C — the standard that lets SV call C functions |
| **OBI** | Open Bus Interface — the memory protocol ibex uses (similar to AXI-Lite) |
| **UVM** | Universal Verification Methodology — standardized SV testbench framework |
| **Analysis port** | UVM publish-subscribe channel — monitor broadcasts, scoreboard/coverage receive |
| **Clocking block** | SV construct that defines signal timing relative to a clock edge, prevents races |
| **SVA** | SystemVerilog Assertions — concurrent properties checked every cycle in parallel |
| **Implication** | `\|->` (same cycle) or `\|=>` (next cycle) SVA operators connecting antecedent to consequent |
| **Covergroup** | SV construct for sampling coverage; contains coverpoints and cross bins |
| **Cross coverage** | Coverage of every combination of multiple coverpoint values |
| **Code coverage** | Automatic RTL instrumentation: line, branch, toggle, FSM, condition |
| **urg** | Synopsys URG — merges per-run `.vdb` coverage databases, generates reports |
| **RAW hazard** | Read After Write — instruction reads a register before prior write completes |
| **Load-use hazard** | RAW where the writer is a load instruction — requires a stall (forwarding not possible) |
| **Forwarding** | Hardware path that feeds a result from a later pipeline stage to an earlier one |
| **Flush** | Discarding in-flight instructions after a branch misprediction or exception |
| **MRET** | Machine Return — instruction that returns from an exception handler (restores PC from mepc) |
| **mepc** | Machine Exception PC — CSR that holds the PC of the faulting instruction |
| **mcause** | Machine Cause — CSR that holds the exception cause code |
| **mtvec** | Machine Trap Vector — CSR that holds the address of the exception handler |
| **funct3/funct7** | Instruction encoding fields that distinguish operations sharing the same opcode |
| **`bind`** | SV construct that attaches a module to a DUT instance without modifying DUT source |
