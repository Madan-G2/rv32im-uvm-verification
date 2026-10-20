# Director-Level DV Interview — Mock Session
### Think like a hiring manager who has taped out 10 chips and is deciding if you understand WHY, not just WHAT.

> **How to use this:**
> Every question here is something a DV Director, Principal Verification Engineer, or Silicon Validation Lead would actually ask.
> They are not testing your memory. They are testing your **judgment**.
> Read the question. Try to answer out loud. Then read the answer below.

---

## ROUND 1 — WHY DID YOU PLANT BUGS?

---

### "Why did you inject RTL bugs into your own DUT? Couldn't you just run the testbench on the clean ibex and call it done?"

**This is the most important question in your entire interview. Get this right.**

**Your Answer:**

Running the testbench on clean RTL and seeing zero errors does not prove the testbench works. It might prove the DUT has no bugs — or it might prove the testbench is broken and catching nothing at all. You cannot tell the difference.

In real verification, this is called **verification completeness** — proving not just that the DUT has no bugs, but that your testbench is actually capable of *finding* bugs if they exist.

Bug injection is the industry-standard technique for this. You take a known-bad version of the DUT, run your testbench against it, and verify that your testbench reports a failure. If it does not — your testbench has a hole. Fix the testbench, not the DUT.

This is exactly what I did. I planted 6 bugs that represent real classes of silicon defects — forwarding mux errors, wrong shift direction, wrong exception return address. Then I ran the full testbench against the buggy DUT and confirmed every single one was detected. Only after all 6 were caught did I have confidence that the testbench is actually doing its job.

Think of it like this: you would not ship a smoke detector without testing it with actual smoke first.

---

### Follow-up: "What is this technique called formally? Have you heard the term 'mutation testing' or 'fault injection'?"

**Your Answer:**

Yes. What I did is a form of **fault injection** or **mutation testing**.

- **Mutation testing** (common in software) automatically inserts small changes into code — flip a `+` to `-`, change `>` to `>=`, invert a condition — and checks if the test suite catches the change. If the tests still pass with a mutation, the test suite has a gap.

- **Fault injection** (common in hardware verification) is the hardware equivalent — manually or automatically inserting RTL modifications that model real defect classes: wrong operator, wrong mux select, missing register update.

In the semiconductor industry, this is specifically called **coverage analysis of the verification plan** — you measure not just whether your tests ran, but whether your tests are *sensitive* to the specific failure modes that matter. The metric is sometimes called **defect coverage** or **fault coverage**, distinct from code coverage and functional coverage.

The IEEE 1149.1 (JTAG) standard even has formal fault models for structural testing. For functional verification like mine, it is less formal — but the principle is identical.

---

### Follow-up: "You chose 6 specific bugs. How did you decide which 6? Why not 20? Why not 2?"

**Your Answer:**

Each bug targets a specific **failure mode category** that is known to occur in real CPU designs. I did not pick randomly.

**The 6 cover these distinct categories:**

| Bug | Category | Why this category matters |
|-----|----------|--------------------------|
| BUG-001 Branch misprediction | Control flow bug | Most common class of CPU bug — PC update logic is complex |
| BUG-002 Forwarding mux inverted | Data hazard bug | Forwarding logic is a notoriously error-prone area in pipelined CPUs |
| BUG-003 SRA uses logical shift | ALU operation bug | Wrong operator (`>>` vs `>>>`) — a one-character bug that is hard to spot in review |
| BUG-004 DIV by zero wrong result | Spec compliance bug | Tests whether the design correctly implements an edge case defined only in the spec |
| BUG-005 LB missing sign extend | Load unit bug | Sign vs zero extension — a classic mistake, found in real silicon |
| BUG-006 MEPC not saved | Exception handling bug | Exception state machine — complex, rarely exercised by random tests |

Why 6 and not 20? Because each additional bug must correspond to a unique gap in your verification plan. If 2 bugs test the same component and the same detection mechanism, the second one adds no value — it just confirms what you already know. 6 bugs that cover 6 distinct components and 6 distinct detection paths is better than 20 bugs in the ALU.

Why not 2? Because 2 bugs would leave the forwarding logic, exception handling, and load unit untested. Bug injection only gives you confidence for the specific failure modes you test.

---

### Follow-up: "One of your bugs — BUG-002, the inverted forwarding mux — would only be caught by a specific instruction sequence with a RAW dependency. What if your random test never generates that sequence?"

**Your Answer:**

That is exactly why I have both random tests AND directed tests, and why functional coverage drives the decision of what to test.

The `cg_instr_mix` covergroup tracks which instructions were executed. But a covergroup alone does not track **combinations** of instructions. A back-to-back RAW hazard is a temporal pattern — instruction N writes register X, instruction N+1 reads register X. Random testing might generate that pattern by chance, but there is no guarantee.

That is why I have `rv32im_hazard_seq` — a directed sequence that explicitly constructs back-to-back RAW patterns with known register values and known expected results. This sequence is not left to chance.

The broader answer is: **directed tests exist precisely because random tests are not guaranteed to hit specific structural patterns**. If you relied only on random tests, bugs like BUG-002 could survive a 10,000-simulation regression because the hazard pattern never occurred in the right way. The combination of random (breadth) + directed (depth) is the standard industry approach — called **constrained-random with directed coverage closure**.

---

## ROUND 2 — YOUR VERIFICATION PLAN

---

### "Walk me through how you wrote the verification plan. What did you look at first?"

**Your Answer:**

A verification plan starts with the specification, not the RTL. You do not open a single line of SystemVerilog when writing the plan.

I started with the RISC-V ISA spec (the "RISC-V Unprivileged ISA" and "Privileged Architecture" documents from riscv.org). From these I extracted:

1. **Feature list** — every instruction that must execute correctly (47 for RV32IM + Zicsr)
2. **Corner cases defined by spec** — things the spec explicitly calls out: DIV by zero = -1, INT_MIN÷-1 = INT_MIN, x0 always zero, MRET restores PC from mepc, misaligned accesses cause exceptions
3. **Protocol** — OBI bus handshake rules (req/gnt timing, data valid)
4. **State machine** — machine-mode exception handling: save mepc, jump to mtvec, return with MRET

From this I built the verification plan as a table: feature → test scenario → pass criterion → coverage bin. Each row answers: "How do I know this feature works?"

Then I looked at the DUT architecture (ibex's 2-stage pipeline documentation) to identify where bugs are most likely to hide — the forwarding unit, the branch resolution path, the exception state machine. These became the priority areas for directed tests.

**The key discipline:** the plan is written before the testbench. If you write the testbench first and then the plan, you are describing what you built, not what you needed to build. The plan drives the testbench, not the other way around.

---

### Follow-up: "You said the plan comes before the RTL. But you used ibex as the DUT — you knew what ibex looks like. Didn't that bias your verification plan toward ibex's implementation rather than the spec?"

**Your Answer:**

That is an excellent challenge and a real risk in any verification project.

I used the ibex architecture documentation for two specific and legitimate purposes:
1. To identify the **commit port** — the signals I need to observe (register file write port, PC, etc.)
2. To understand the **OBI interface** — the bus protocol the driver must implement

But the **pass/fail criteria** — what results are correct — come entirely from the RISC-V spec, not from ibex. When the ISS computes that `SRA 0xFFFFFFF0, 2 = 0xFFFFFFFC`, that is from the spec. When the scoreboard flags a mismatch, it is comparing against the spec, not against what ibex's code happens to do.

The danger you are pointing at — **model bias** — is when the golden reference model is derived from the DUT's code rather than the spec. If I had read ibex's ALU code and written my ISS to match ibex's behavior, I would have replicated BUG-003 (the wrong logical shift) in the ISS too, and the scoreboard would have never caught it. The entire value of an independent C ISS comes from it being derived from the spec, independently of the RTL.

This is also why I wrote a standalone ISS self-test (23 test cases) before running the full simulation. Those tests verify the ISS against hand-calculated expected values from the spec — not against ibex.

---

### Follow-up: "How do you know your verification plan is complete? What if there is a bug in ibex that none of your 45 test cases can find?"

**Your Answer:**

Completeness of a verification plan is never 100% provable — that is a fundamental truth of functional verification. What you can do is **measure and reduce the risk** systematically.

The evidence I have that my plan is reasonably complete:

1. **Every instruction has a bin in `cg_instr_mix`** — if an instruction was never executed, coverage tells me.

2. **Every architectural exception cause has a bin in `cg_exception`** — if a fault type was never triggered, coverage tells me.

3. **6 known bugs were all detected** — this means the scoreboard, monitor, and sequences are working for the specific failure modes I targeted.

4. **Code coverage >95%** — most RTL lines were executed. Uncovered lines are explicitly identified and analyzed.

What could still hide:

- A bug that only manifests with a specific 3-instruction sequence that none of my sequences generate
- A bug in interrupt handling (I did not implement interrupt injection)
- A bug that only appears with a specific memory alignment pattern I did not cover
- A corner case in a CSR interaction I did not think to test

The honest answer is: no verification plan is complete. The goal is to reduce residual risk to an acceptable level based on the cost of the chip and the consequences of a bug escaping. For a research project, 95%+ coverage with 6/6 bug detection is strong. For a safety-critical automotive chip, you would add formal verification on top of this.

---

## ROUND 3 — METHODOLOGY AND TRADE-OFFS

---

### "Why UVM? It's a lot of infrastructure. Couldn't you have written a simpler testbench that does the same job in half the code?"

**Your Answer:**

Yes, technically. A flat testbench with hardcoded stimulus would work for a fixed set of tests.

But UVM solves specific problems that become real costs as the project grows:

**Problem 1: Reusability.** In a real project, the same driver and monitor need to work across dozens of tests. UVM's component hierarchy and factory allow you to swap components without rewriting tests. Without UVM, every new test requires manual plumbing.

**Problem 2: Constrained-random scaling.** The `rand` keyword and constraint solver are UVM-adjacent features. Generating 200 pseudo-random instructions that meet timing constraints (word-aligned addresses, valid register indices, correct instruction encodings) would require a custom random generator in a flat testbench. With UVM transactions and SystemVerilog constraints, the solver handles this.

**Problem 3: Coverage integration.** UVM covergroups integrate naturally with VCS's coverage infrastructure. `urg` can merge UVM functional coverage with code coverage automatically.

**Problem 4: Industry standard.** Every ASIC company doing serious verification uses UVM. If you write a custom framework and then join Qualcomm or Apple Silicon, you start from scratch. UVM knowledge transfers directly.

The infrastructure cost is a one-time investment. The benefit compounds over the life of the project and carries over to future projects.

---

### Follow-up: "The ibex DUT has maybe 10,000 lines of RTL. Your testbench probably has 3,000 lines. That's a 30% overhead. Is that typical? Is it too much?"

**Your Answer:**

30% is actually quite low. In industry, the ratio is typically inverted — verification code is often **3x to 10x the size of the RTL**. A complex SoC might have 500,000 lines of RTL and 3-5 million lines of verification code across all testbenches, coverage models, formal property checks, and simulation infrastructure.

For this project, the ratio is low because:
- ibex is a mature, well-defined CPU (most of the complexity is in the specification, not in novel features)
- The testbench is a single-agent environment (no AHB, AXI, PCIe, USB buses to model)
- No formal verification, no emulation bring-up scripts, no gate-level simulation setup

The "right" ratio is not a fixed number — it depends on the DUT's complexity, the failure cost, and the schedule. A safety-critical medical device CPU might justify 20x verification code. A simple SPI controller might not.

---

### Follow-up: "You wrote a custom C ISS. Companies like ARM and Google use Spike (the official RISC-V ISS) or their own internal models. Why write your own instead of using Spike?"

**Your Answer:**

Spike is the right answer for production verification at a company. It is maintained by the RISC-V Foundation, tested against every RISC-V compliance test suite, and handles all the extensions and privilege levels.

I wrote a custom ISS for specific reasons relevant to this project:

**Reason 1: Learning depth.** Writing your own ISS forces you to understand every instruction encoding, every CSR interaction, and every exception path at the bit level. Using Spike, I would integrate a black box. My own ISS means I can answer any question about how the reference model works.

**Reason 2: DPI-C integration control.** Spike has its own memory model, privilege modes, and execution flow. Adapting it to call `iss_dpi_step()` per committed instruction — with PC sync, with the scoreboard's calling convention — requires either significant wrapper code or modifying Spike itself. My custom ISS is designed from the start to be called in lockstep with the scoreboard.

**Reason 3: Scope match.** Spike models the full RISC-V spec including hypervisor mode, vector extension, debug, etc. My project targets RV32IM + machine-mode Zicsr only. A ~600-line C file that exactly matches my scope is simpler to understand, debug, and trust than a 100,000-line system.

**Trade-off I accept:** My ISS could have bugs in it. Spike almost certainly does not. That is why I wrote the 23-case standalone self-test — to validate the ISS itself before trusting it as a reference.

In a production environment, I would use Spike (or OVPSIM) and spend the integration effort. For this project, writing the ISS was the right educational choice.

---

## ROUND 4 — FINDING AND DEBUGGING BUGS

---

### "Walk me through your actual debug process when you saw a scoreboard mismatch. Step by step."

**Your Answer:**

When the scoreboard fires `UVM_ERROR`, the log message gives me:
- PC of the failing instruction
- The instruction word (32-bit hex)
- DUT's rd and result
- ISS's expected rd and result
- The XOR diff (which specific bits were wrong)

**Step 1: Decode the instruction.** Take the instruction word (e.g., `0x40205113`) and extract the fields manually or with a disassembler. For `0x40205113`: opcode=0x13 (I-type arithmetic), rd=x2, funct3=5, rs1=x0, imm=0x402 → but wait, funct3=5 and imm[11:5]=0x20 means `SRAI` (shift right arithmetic immediate). Shift amount = imm[4:0] = 2.

**Step 2: Check if the result pattern makes sense.** If the DUT result is `0x3FFFFFFC` and ISS says `0xFFFFFFFC`, the diff is `0xC0000000` — the top 2 bits are wrong. For an arithmetic right shift, those bits should be 1 (sign extension). The DUT produced 0s. This immediately points to: wrong shift type (logical vs arithmetic).

**Step 3: Open the waveform in Verdi.** Search for the failing PC in `commit_pc`. Find the clock cycle where `commit_valid=1` and `commit_pc=0x00000018`. Zoom in on the ALU input/output signals: `operand_a_i`, `shift_amt`, `result_o`. Verify that `operand_a_i` is indeed negative (bit 31 = 1) and that `result_o` has 0s in the top bits instead of 1s.

**Step 4: Trace the signal back.** In Verdi's schematic view, trace `result_o` back through the ALU mux to find which case statement handled the SRA operation. Open `ibex_alu.sv`, search for `SRA:`. Find the buggy line.

**Step 5: Confirm the fix.** Make the one-line change, rerun `make smoke`, verify the scoreboard passes.

**The key discipline:** Never guess at the root cause. Always follow the signal from the output (wrong result) backward through the logic to the first point of divergence. Guessing wastes time and can lead you to fix the symptom instead of the cause.

---

### Follow-up: "The scoreboard dumps the ISS register file on mismatch. Why does that help? The bug is in the DUT's registers, not the ISS's."

**Your Answer:**

Because after a mismatch, the ISS's register file is the ground truth for what the register file *should* look like at that point in the program. If I see:

```
=== ISS Register File ===
x1 = 0xFFFFFFF0   (correct value: -16)
x2 = 0x00000002   (correct: shift amount)
x3 = 0xFFFFFFFC   (correct: -4, what x3 should be)
```

And the DUT committed `x3 = 0x3FFFFFFC`, I can immediately see:
- The inputs to the operation were correct (x1 and x2 have the right values in ISS)
- The output is wrong in one specific way (top 2 bits)
- This narrows the bug to the computation itself, not to any prior instruction corrupting x1 or x2

Without the ISS dump, I would have to manually track all register values backward through the simulation log. The dump collapses that work to zero — I see the full expected state at the moment of failure.

The ISS dump also helps when bugs cause cascading failures. If BUG-002 (forwarding) corrupts x1 in instruction 5, and then x1 is used in instructions 8, 12, and 17, I get failures at all four points. The ISS dump at failure 1 (instruction 5) shows me x1 is wrong there — which immediately identifies the root cause rather than making me chase the symptom at instruction 17.

---

### Follow-up: "Your testbench found BUG-006 — MEPC not saved. But BUG-006 would only show up if the exception handler actually uses MRET to return. What if your sequence just ecalled and never returned?"

**Your Answer:**

That is exactly right — and it is why the exception sequence is structured the way it is.

The `rv32im_exception_seq` does the full round-trip:

1. Setup: Write a known value into a CSR (CSRW mtvec, handler_address)
2. Execute: ECALL — takes an exception, PC jumps to mtvec, mepc should hold the ECALL's PC
3. In handler: Read back mepc (CSRR x1, mepc) — ISS knows the expected mepc value
4. Execute: MRET — returns to the address in mepc
5. Observe: The next commit's PC must equal the original ECALL PC

If MEPC was not saved (BUG-006), step 3 reads the wrong value, step 5 lands at the wrong address, and the scoreboard catches the mismatch when the next committed instruction's PC is wrong.

This is an important point about test design: **a test that only exercises the entry path of an exceptional case but not the exit path is not a complete test.** Exception handling has two halves — saving state correctly (mepc, mcause, mstatus) and restoring state correctly (MRET reading back the saved values). You need to test both.

The `cg_exception` covergroup only covers the entry (mcause values). In a more complete environment, I would add a separate coverage point for "MRET was executed at least once per exception type" to ensure the return path is exercised.

---

## ROUND 5 — THINGS YOU DIDN'T DO (THE DIRECTOR'S TRAP)

---

### "Your testbench has no interrupt injection. Ibex supports external interrupts, timer interrupts, fast interrupts. What happens if there is a bug in interrupt handling?"

**Your Answer:**

It would not be caught by my testbench. This is a known gap.

Here is why I did not implement it for this project, and what I would do in a production environment:

**Why I didn't:** Interrupt handling requires a more complex test infrastructure — you need to control the timing of `irq_external_i`, ensure the DUT saves context correctly (mepc, mstatus.MIE gets cleared), handle nested interrupts, verify the return from interrupt handler. This is a significant scope addition. The project was scoped to exceptions (synchronous) rather than interrupts (asynchronous).

**What the gap means concretely:** If ibex has a bug where `mstatus.MIE` (machine interrupt enable) is not cleared when entering an interrupt handler — allowing nested interrupts that corrupt the stack — my testbench would never find it.

**What I would do in production:**
1. Add an interrupt agent — a separate driver that asserts `irq_external_i` with configurable timing
2. Add interrupt-aware sequences that verify: interrupt taken → mepc saved → mstatus.MIE cleared → handler executes → MRET restores mstatus → return to interrupted code
3. Add coverage bins for: interrupt taken during normal execution, interrupt taken during another interrupt's handler (nested), interrupt taken immediately after MRET

**The general lesson:** Every "I didn't test X" answer must have three parts: acknowledge the gap honestly, explain why it was out of scope, and describe concretely what would be needed to close it. A director is not expecting you to have tested everything — they are testing whether you know what you tested and what you did not.

---

### Follow-up: "You have no gate-level simulation. Your testbench runs on RTL. How confident are you that a gate-level bug would be caught?"

**Your Answer:**

Not very confident, and that is the honest answer.

RTL simulation verifies the **architectural intent** — does the design do what the spec says at the register-transfer level? Gate-level simulation (GLS) verifies **implementation correctness** after synthesis and place-and-route — does the actual gate netlist match the RTL behavior?

Bugs that GLS catches but RTL simulation does not:

1. **Timing violations:** A combinational path that is too long for the target clock frequency — the signal does not settle before the next clock edge. The RTL simulator assumes zero-delay logic; GLS uses real gate delays (SDF annotation).

2. **X-propagation:** Uninitialized flip-flops that power up in an unknown state. RTL simulation often treats X as a specific value and masks this. GLS with proper X-semantics exposes initialization bugs.

3. **Synthesis mismatches:** A synthesis tool that misinterprets an RTL construct and generates a gate-level circuit that has different behavior. Rare but real.

4. **Clock domain crossing bugs:** Setup/hold violations at CDC boundaries that only appear with real timing numbers.

**What I would add for production:**
- GLS smoke test: take the synthesis netlist, run the same smoke test with SDF annotation
- Formal equivalence checking: prove the gate netlist is logically equivalent to the RTL (this does not catch timing bugs but catches synthesis mismatches)
- Static timing analysis: proves all paths meet timing without simulation

---

### Follow-up: "If I asked you to double your coverage from 50% to 100% in one week, what would you do first?"

**Your Answer:**

First, I would look at the coverage report, not write more tests.

Coverage closure is a triage problem, not a "write more tests" problem. The right first action is always:

**Step 1: Read the uncovered bins.** Which specific bins are below target? Are they in `cg_instr_mix` (specific instructions never executed), `cg_exception` (specific fault types never triggered), or code coverage (specific RTL lines never reached)?

**Step 2: Categorize the gaps.**
- Easy wins: bins that are uncovered because the random stimulus never happened to hit them. Add a targeted sequence — 1 hour of work, closes the bin.
- Hard coverage: bins that are architecturally unreachable in this testbench configuration. For example, if you cannot inject interrupts, interrupt-related exception bins cannot be hit — no amount of directed tests will close them.
- Dead code: RTL lines that cannot be reached because they are gated by a configuration parameter that is tied off (e.g., `PMPEnable=0` disables the PMP unit). Acknowledge them, waive them with justification.

**Step 3: Work the easy wins first.** Each directed test closes 3-5 bins. One week of directed tests is 20-30 tests, which can close most functional coverage gaps.

**Step 4: For remaining hard gaps, escalate.** If bins require interrupt injection and that infrastructure does not exist, that is a scoping decision for the team — not something one engineer can fix in a week. Surface it with a clear explanation and a work estimate.

The mistake junior engineers make: writing 20 random tests hoping they accidentally hit the uncovered bins. That is the worst use of time. Coverage reports exist precisely to guide targeted effort.

---

## ROUND 6 — ARCHITECTURE AND DESIGN DECISIONS

---

### "Why did you put the scoreboard outside the agent? In some UVM environments the scoreboard is inside the agent."

**Your Answer:**

The agent's job is **protocol-level reuse** — it knows how to drive and observe the OBI bus. It should not know anything about whether the instructions are correct. That is a higher-level concern.

Putting the scoreboard inside the agent would couple the scoreboard's checking logic to the OBI protocol driver. If I later reuse this agent for a different CPU that also uses OBI (say, a microcontroller with a different ISA), I would have to strip out the scoreboard — or carry a RISC-V-specific checker into a non-RISC-V project.

By keeping the scoreboard outside the agent, I have:
- **Agent**: knows OBI protocol, knows nothing about RISC-V correctness
- **Scoreboard**: knows RISC-V correctness, knows nothing about OBI

This is the **separation of concerns** principle applied to UVM architecture. The monitor sends generic transactions via analysis port. The scoreboard and coverage subscribe to those transactions and apply their own domain-specific logic. Neither needs to know about the other's internals.

In practice, this also means I can test the driver and monitor independently of the scoreboard — useful for bring-up debugging where you want to verify the bus protocol is working before adding correctness checking.

---

### Follow-up: "Your monitor fires on `commit_valid`. What if ibex had a speculative execution feature and sometimes committed instructions that were later squashed? Would your scoreboard overclaim?"

**Your Answer:**

Excellent question — and this is exactly the kind of thing you must know about your DUT before designing the monitor.

ibex does **not** have speculative execution. It is a simple in-order pipeline. `rf_we_wb` (the signal I tap for `commit_valid`) is the actual register-file write enable — it only pulses when an instruction's result is being permanently written. There is no "speculative commit" in ibex.

If ibex had out-of-order or speculative execution, tapping the register-file write port would not be sufficient. I would need to tap the **retirement** point — the moment an instruction is guaranteed to have committed with no possibility of rollback. In modern OOO processors (like those based on the RISC-V BOOM design), the commitment happens at the head of the reorder buffer (ROB). The monitor would need to tap the ROB retirement signals, not the execution result.

The important principle: **the monitor's observation point must correspond to architectural state change, not micro-architectural transient state.** For ibex, the register-file write is architectural (no speculation). For an OOO CPU, the ROB retirement is architectural. Getting this wrong produces either missed detections (if you tap too early, before commitment) or false positives (if you tap too late or at a speculative point).

---

### Follow-up: "You mentioned the scoreboard calls `iss_dpi_dump_regs()` on mismatch. Is there a risk of that dump hiding a second bug that appears in the same cycle?"

**Your Answer:**

No, because the dump is called as a SystemVerilog `function` (zero simulation time) via DPI-C. It executes inside the same delta cycle as the `write_commit()` call — no simulation time advances, no other events fire. The dump is purely a side effect: it prints to stdout and returns. The simulation continues normally on the next clock edge.

The more important risk is the one you might be alluding to: the scoreboard calls `return` after a mismatch (to avoid cascading false errors from the same instruction). This means if both `rd` and `result` are wrong, only the `rd` mismatch is reported. I chose this design deliberately — if the destination register is wrong, reporting a result mismatch for that same instruction is noise.

But yes, if two different instructions commit in the same cycle (which ibex does not do — it is in-order single-commit), there could be an issue. With ibex, `commit_valid` is a single bit, so at most one instruction commits per cycle. This design assumption is safe for this DUT.

---

## ROUND 7 — PROFESSIONAL JUDGMENT

---

### "If the chip had a tapeout deadline in 3 weeks and your coverage was at 75%, what would you do?"

**Your Answer:**

Three actions simultaneously:

**Action 1: Escalate immediately — do not wait.** A 3-week deadline with 25% coverage gap is a risk that the program manager, design lead, and management must know about. Do not hide it hoping you can close it. The decision of whether to slip the schedule, reduce scope, or accept the risk is not yours alone to make.

**Action 2: Triage the 25% gap.** Not all uncovered bins carry the same risk. Some uncovered bins might be:
- Instructions that the chip's firmware will never use (e.g., EBREAK in a production device)
- Exception types that the memory map makes physically impossible
- Code coverage lines that are for debug features disabled by chip configuration

Waivable coverage — coverage that is unreachable for a documented reason — should be formally waived in the coverage report with justification. This can quickly turn 25% gap into 10% real gap.

**Action 3: Focus directed tests on high-risk uncovered areas.** Not the easiest-to-hit bins — the most dangerous ones. If interrupt handling is uncovered and the chip uses interrupts in production, that is the one to close. If a rarely-used CSR is uncovered and it is never accessed by the firmware, that is lower priority.

**What I would NOT do:** run more random tests hoping coverage magically improves. By week 3, random tests have had their chance. If something is still uncovered, it requires targeted effort.

---

### Follow-up: "Management says 'the schedule cannot slip, ship it.' But you have a known uncovered area in exception handling. What do you do?"

**Your Answer:**

Document it formally, in writing, and get sign-off.

The engineering answer and the business answer are different here. As a verification engineer, my job is to accurately communicate risk, not to unilaterally decide whether a chip ships.

I would write a coverage waiver document that states:
- What is not covered: exception handling for store-misalign and load-fault fault types
- Why it is uncovered: test infrastructure for these sequences was not completed within schedule
- What scenarios trigger these faults: specific memory address patterns
- Estimated probability of encountering this in production: [assessment based on firmware usage]
- Consequence if a bug exists here: [describe the failure mode and severity]
- Mitigation: silicon validation plan to test this post-tapeout; firmware workaround if needed

This goes to the design lead and program manager with my signature. If they sign off on shipping with this risk documented, that is their decision as business owners. My job was to make the risk visible and quantified.

What I never do: ship without documenting the gap, hoping nobody notices. If a bug from that uncovered area escapes to silicon, and the gap was known but undocumented, that is a professional and potentially legal problem.

---

### "How do you know when you are done with verification? What is the exit criteria for this project?"

**Your Answer:**

Exit criteria must be defined at the start, in the verification plan — not at the end when you are hoping you are done. My exit criteria for this project were:

**Functional coverage:** All 5 covergroups ≥ 98%. Each bin hit with minimum 10 observations (not just once — once could be a fluke).

**Code coverage:** Line ≥ 95%, branch ≥ 90%, toggle ≥ 85% (toggle is hardest for outputs that rarely toggle), FSM ≥ 90%.

**Assertion coverage:** All 8 SVA cover properties triggered at least once. All 14 assert properties passing with zero violations.

**Regression:** Zero UVM_ERROR, zero UVM_FATAL in the final 100-run regression. "Final" means the regression run after all directed tests and bug fixes — not a cherry-picked run.

**Bug injection:** All 6 known-bug variants detected and root-caused. Each bug found by at least one specific test/seed combination that is documented.

**Review:** Verification plan reviewed and signed off by at least one peer. All waived coverage items documented with justification.

When all of these are green, verification is done. Not when you "feel like" it is thorough, and not just because the deadline arrived — those are how bugs escape to silicon.

---

## SUMMARY — WHAT A DIRECTOR IS REALLY ASKING

Every question in this interview is testing one of these things:

| What they ask | What they are really checking |
|--------------|------------------------------|
| "Why did you inject bugs?" | Do you understand verification completeness, or do you just run tests? |
| "How did you write the plan?" | Do you start from spec or from RTL? Do you understand the difference? |
| "Why UVM and not something simpler?" | Can you justify architectural decisions with trade-offs, not just "that's what we use"? |
| "Walk me through your debug process" | Do you have a systematic approach or do you guess? |
| "What didn't you test?" | Are you honest about gaps, or do you claim you tested everything? |
| "3 weeks to tapeout, 75% coverage — what do you do?" | Can you operate under real pressure with sound judgment, or do you panic? |
| "Management says ship it — what do you do?" | Do you understand your role: communicate risk, not make business decisions unilaterally? |
| "How do you know you're done?" | Did you define exit criteria upfront, or are you just hoping to be done? |

**The one thing that separates a junior from a senior verification engineer:**

A junior says "I ran 100 simulations and got zero errors."

A senior says "I ran 100 simulations, got zero errors, and here is the evidence that my testbench is actually capable of finding the class of bugs that matters for this design — and here is what I know I did not test and why."

Know the difference. Own it in the interview.
