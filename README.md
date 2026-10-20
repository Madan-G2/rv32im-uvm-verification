# RISC-V RV32IM CPU Verification — UVM Testbench

A complete constrained-random UVM verification environment for a RISC-V RV32IM processor. Built from scratch — verification plan, testbench infrastructure, golden reference model, SVA checkers, and a Python regression framework — all targeting the **ibex** core from lowRISC as the DUT.

---

## What This Project Does

The goal was to verify that a RISC-V RV32IM CPU correctly executes all instructions defined by the spec — integer arithmetic, memory accesses, branches, multiply/divide, CSR operations, and exception handling — under randomized stimulus with realistic pipeline hazards.

The testbench drives constrained-random instruction streams into the CPU, observes every committed instruction through a register-file monitor, and checks each result against a C-based golden reference model (Instruction Set Simulator) connected via DPI-C. Six realistic RTL bugs were intentionally planted in the DUT to validate that the environment could catch real silicon issues. All six were successfully detected.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                      UVM Environment                     │
│                                                          │
│  ┌─────────────┐    ┌────────────┐    ┌───────────────┐ │
│  │   Sequencer  │───▶│   Driver   │    │    Monitor    │ │
│  │             │    │ (OBI Bus)  │    │ (Commit Port) │ │
│  └─────────────┘    └─────┬──────┘    └──────┬────────┘ │
│                           │                  │           │
│                     ┌─────▼──────────────────▼────────┐ │
│                     │          ibex DUT (RTL)          │ │
│                     │       RV32IM, 2-stage pipe       │ │
│                     └──────────────────────────────────┘ │
│                                          │               │
│                           ┌──────────────▼─────────┐    │
│                           │      Scoreboard         │    │
│                           │  DUT result vs ISS ref  │    │
│                           └──────────────┬──────────┘    │
│                                          │               │
│                           ┌──────────────▼─────────┐    │
│                           │   C ISS (DPI-C bridge)  │    │
│                           │   rv32im_iss.c / .h     │    │
│                           └─────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

**Key components:**

| File | Role |
|------|------|
| `iss/rv32im_iss.c` | ~600-line C ISS — executes every RV32IM instruction, handles CSRs and exceptions |
| `iss/rv32im_iss_dpi.c` | DPI-C wrapper — exposes ISS to SystemVerilog via `iss_dpi_step()` |
| `tb/env/rv32im_driver.sv` | OBI protocol driver with configurable grant latency (0–3 cycles) |
| `tb/env/rv32im_monitor.sv` | Passively samples the commit port; fires a transaction per committed instruction |
| `tb/env/rv32im_scoreboard.sv` | Calls ISS in lockstep; reports `UVM_ERROR` on any mismatch |
| `tb/env/rv32im_coverage.sv` | 5 covergroups: instruction mix, branches, M-extension, exceptions, load/store |
| `tb/sva/pipeline_fsm.sva` | 8 concurrent assertions: fetch timing, OBI protocol, x0 invariant |
| `tb/sva/hazard_checks.sva` | 6 assertions: load-use stalls, branch flush, post-trap behavior |
| `scripts/run_regression.py` | Parallel regression runner using Python `ThreadPoolExecutor` |
| `scripts/aggregate_coverage.py` | Parses URG text reports; prints coverage bar chart + HTML dashboard |

---

## Project Layout

```
rv32im_uvm_tb/
├── iss/                        Golden reference model (C)
│   ├── rv32im_iss.h            Public API header
│   ├── rv32im_iss.c            Full RV32IM ISS (~600 lines)
│   ├── rv32im_iss_dpi.c        DPI-C bridge (requires VCS svdpi.h)
│   └── iss_test.c              Standalone self-test (23 checks, gcc only)
├── tb/
│   ├── rv32im_if.sv            SystemVerilog OBI interface
│   ├── tb_top.sv               Testbench top — DUT + clock/reset + UVM kickoff
│   ├── env/                    UVM env components (agent, driver, monitor, ...)
│   ├── sequences/              45+ instruction sequences across 6 categories
│   ├── tests/                  3 test classes (smoke, rand, directed)
│   └── sva/                    SVA property checkers (14 assertions total)
├── rtl/
│   ├── ibex_clean/             Unmodified ibex (clone separately — see below)
│   └── ibex_buggy/             6-bug-injected DUT (apply patches after cloning)
├── scripts/
│   ├── run_regression.py       Parallel VCS regression runner
│   ├── parse_logs.py           Groups mismatches by opcode → Markdown report
│   └── aggregate_coverage.py   URG coverage parser + HTML dashboard generator
├── Makefile                    All build/sim/coverage targets
└── flist.f                     VCS file list
```

---

## Getting Started

### Prerequisites

- **Synopsys VCS** with UVM 1.2 (primary simulator)
- **Icarus Verilog** (free, limited — no UVM; works for syntax checks)
- **gcc** (for standalone ISS self-test)
- **Python 3.8+** (no external packages needed)
- Linux environment

### 1. Clone the ibex RTL

The RTL is not included in this repo. Clone it separately:

```bash
git clone https://github.com/lowRISC/ibex.git rtl/ibex_clean
cp -r rtl/ibex_clean rtl/ibex_buggy
```

### 2. Apply the bug patches

```bash
cd rtl/ibex_buggy
patch -p1 < ../../patches/bug001_branch_misprediction.patch
patch -p1 < ../../patches/bug002_forwarding_mux.patch
patch -p1 < ../../patches/bug003_sra_logical.patch
patch -p1 < ../../patches/bug004_div_by_zero.patch
patch -p1 < ../../patches/bug005_lb_sign_ext.patch
patch -p1 < ../../patches/bug006_mepc_not_updated.patch
cd ../..
```

### 3. Verify the ISS (no VCS needed)

Before touching the simulator, confirm the golden reference model is correct:

```bash
make test_iss
```

All 23 checks should pass. This covers ALU ops, branches, load/store with sign extension, M-extension corner cases (divide-by-zero, INT\_MIN÷−1), and SRA arithmetic shift behavior.

### 4. Compile

```bash
make compile
```

### 5. Smoke test

```bash
make smoke
```

Runs 10 ADDI instructions. If this passes, the basic pipeline and DPI bridge are working.

### 6. Full regression

```bash
make regress
```

Runs 20 random seeds × 5 test types = 100 simulation runs in parallel (4 jobs). Results go to `sim/vcs/regression/`.

### 7. Coverage report

```bash
make coverage
```

Merges all VDB files with `urg` and prints a coverage table. Add `--html` to get a dashboard:

```bash
python scripts/aggregate_coverage.py \
    --urg-report sim/vcs/coverage_report \
    --threshold 95 \
    --html sim/vcs/coverage_dashboard.html
```

---

## Test Sequences

| Sequence | Count | What it covers |
|----------|-------|----------------|
| `rv32im_rand_seq` | 200+ instrs | Constrained-random mix of all RV32IM opcodes with weighted distributions |
| `rv32im_hazard_seq` | 8 directed | Back-to-back RAW hazards (EX→EX, MEM→EX, WB→EX), load-use stalls |
| `rv32im_branch_seq` | 8 directed | All 6 branch types, forward and backward, taken and not-taken |
| `rv32im_mul_div_seq` | 7 directed | MUL, MULH variants, DIV/REM, divide-by-zero, INT\_MIN÷−1 overflow |
| `rv32im_exception_seq` | 5 directed | ECALL, illegal instruction, misaligned fetch, CSR read/write, MRET |

---

## RTL Bugs

Six bugs were planted in `rtl/ibex_buggy` to mimic real silicon defects. All six are detected by the testbench.

| ID | File | Bug | How It's Caught |
|----|------|-----|-----------------|
| BUG-001 | `ibex_controller.sv` | Branch taken sends PC to boot vector instead of branch target | Scoreboard sees wrong fetch addresses immediately after any taken branch |
| BUG-002 | `ibex_ex_block.sv` | Forwarding mux select is inverted — stale register used when forwarded value should be used | Scoreboard mismatch on back-to-back RAW hazard sequences |
| BUG-003 | `ibex_alu.sv` | `SRA` uses `>>` (logical shift) instead of `>>>` (arithmetic shift) | Directed test: `0xFFFFFFF0 >> 2` returns `0x3FFFFFFC` instead of `0xFFFFFFFC` |
| BUG-004 | `ibex_multdiv_slow.sv` | `DIV x, 0` returns 0 instead of −1 (0xFFFFFFFF) as required by RISC-V spec §M | `test_div_by_zero` in mul/div sequence |
| BUG-005 | `ibex_load_store_unit.sv` | `LB` zero-extends the byte instead of sign-extending | Directed test: load byte 0xAB gets `0x000000AB` instead of `0xFFFFFFAB` |
| BUG-006 | `ibex_cs_registers.sv` | `mepc` not updated on exception — MRET returns to wrong address | Exception sequence + SVA property H3 |

---

## SVA Properties

**`pipeline_fsm.sva`** — pipeline-level correctness:

```
P1: First instruction fetch happens within 4 cycles of reset de-assertion
P2: OBI grant follows request within 3 cycles
P3: No commit_valid during active reset
P4: Register x0 result is always zero after any commit
P5: commit_valid and trap_valid are mutually exclusive in same cycle
P6: Instruction fetch address is always 4-byte aligned
P7: OBI req stays stable until grant is received
P8: Grant can only be asserted when a prior request is pending
```

**`hazard_checks.sva`** — datapath and control hazard correctness:

```
H1: Load-use stall is visible as a one-cycle bubble on the commit port
H2: Branch misprediction causes a pipeline flush (no spurious commits)
H3: No commit_valid in the cycle immediately after a trap
H4: Sequential (non-branch) instructions advance PC by exactly 4
```

---

## Makefile Reference

```
make test_iss              Run standalone ISS self-test (gcc, no VCS needed)
make compile               VCS elaboration — always run first
make smoke                 10-instruction sanity check
make rand SEED=42          Random test with specific seed
make directed              Directed coverage-closure test
make regress               Full parallel regression (20 seeds, 4 jobs)
make coverage              Merge VDB + print coverage table
make parse                 Parse regression logs → Markdown failure report
make clean                 Remove all sim outputs
```

Override defaults:

```bash
make rand SEED=99 VERBOSITY=UVM_HIGH NUM_INSTRS=500
```

---

## Coverage Closure Strategy

1. Run `make regress` — 100 simulation runs across all test types
2. Run `make coverage` — identify uncovered bins from the urg report
3. Run `python scripts/aggregate_coverage.py --urg-report sim/vcs/coverage_report` — see per-bin breakdown
4. Write directed tests in `tb/tests/rv32im_directed_test.sv` targeting uncovered bins
5. Iterate until all 5 covergroups reach ≥ 98%

Typical uncovered bins after random regression: writes to x0, SRA with negative operand, `LB` with byte ≥ 0x80, CSR read-modify-write sequences, exception with non-zero faulting address.

---

## Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Synopsys VCS | 2023.03+ | Simulation, code coverage, SVA |
| UVM | 1.2 | Testbench methodology |
| urg | (with VCS) | Coverage database merge and report |
| gcc | 11+ | Standalone ISS self-test |
| Python | 3.8+ | Regression automation, log parsing, coverage dashboard |
| Icarus Verilog | 11+ | Free simulator for syntax checks (no UVM) |

---

## Notes on the ISS

The C ISS (`iss/rv32im_iss.c`) is a self-contained ~600-line interpreter that handles all 47 RV32IM instructions, 9 CSRs (mstatus, misa, mie, mtvec, mepc, mcause, mtval, mip, cycle/instret), and exception dispatch. It is the ground truth the scoreboard compares against.

The DPI-C wrapper (`iss/rv32im_iss_dpi.c`) exposes `iss_dpi_step(instr, pc)` to SystemVerilog. It syncs the ISS program counter if the DUT diverges (e.g., after a mispredicted branch is corrected), which prevents cascading false failures after a single mismatch.

To test the ISS independently without VCS:

```bash
make test_iss
# Expected: 23/23 PASS
```
