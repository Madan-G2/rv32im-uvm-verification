# "Did You Actually Build This?" — The Ownership Interview
### Directors ask these to separate people who built a project from people who followed a tutorial.

> A DV Director has seen hundreds of resumes with "UVM verification environment" on them.
> Half of those people copied a textbook example and changed the variable names.
> The other half actually built something.
> These questions exist to find out which one you are.
> If you read this file, you will be in the second group.

---

## THE CORE QUESTION THEY ARE REALLY ASKING

Every question in this section is a different version of the same thing:

> **"Do you understand WHY each decision was made, or did you just follow instructions?"**

Someone who followed a tutorial can tell you WHAT they built.
Someone who actually built it can tell you WHY every choice was made and what would happen if it were done differently.

---

## PART 1 — THE "WHO DESIGNED THIS" TRAP

---

### "Was this a class project? Did a professor give you the requirements or did you design this yourself?"

**Why they ask this:**
If a professor specified "plant 6 bugs, use ibex, write a C ISS," then you executed a spec — valuable, but not the same as owning the design. The interviewer wants to know if YOU made the decisions.

**Your Answer:**

The project concept came from my resume description — the bullet points describe what I wanted to demonstrate. The architecture, every component choice, every specific decision — why a C ISS instead of SystemVerilog, why ibex instead of a toy RTL, which 6 bugs to plant, how the DPI-C bridge is structured, what the 5 covergroups cover — all of those were my decisions.

There was no professor, no template, no starter code. I started from the RISC-V spec and the ibex documentation and built up from there.

**Then be ready for the follow-up immediately:**

---

### Follow-up: "Okay, so if YOU chose the 6 bugs — walk me through your exact decision process. Why those 6, in that order?"

**This is the real test. Memorize this answer.**

**Your Answer:**

I did not pick bugs randomly. I built a mental model of ibex's pipeline and asked: "Where are the failure modes that are most likely to occur in real RTL, and most likely to escape if the testbench is weak?"

I organized it by pipeline stage and by failure mode category:

**Stage 1 — The fetch unit:**
BUG-001 (branch misprediction) — The PC update logic in the controller is one of the most complex parts of any CPU. It has to handle sequential fetch, branch taken, branch not-taken, exceptions, and MRET. Wrong mux select on any of those paths causes silent corruption. I wanted a bug that corrupts control flow because that is the hardest class to catch — it does not produce a wrong ALU result, it produces correct results at the wrong address.

**Stage 2 — The execution unit (forwarding):**
BUG-002 (forwarding mux inverted) — Forwarding logic is notorious. Every pipeline CPU has it, it is hard to verify because it only matters under specific temporal patterns (back-to-back RAW), and an inverted mux select is exactly the kind of one-bit error that code review misses. I wanted a hazard-related bug specifically because it requires my hazard sequences to catch it — proving that those sequences actually work.

**Stage 3 — The ALU:**
BUG-003 (SRA logical vs arithmetic) — A one-character difference (`>>` vs `>>>` on a signed operand) with completely different semantics. This tests whether my ISS correctly implements the spec (arithmetic semantics) and whether my scoreboard is sensitive enough to catch a wrong bit pattern in the upper bits of a result.

**Stage 4 — The multiply/divide unit:**
BUG-004 (DIV by zero = 0 instead of -1) — The M extension has spec-defined corner cases that are easy to implement wrong. This tests spec compliance — not a design error in the logic, but a failure to implement the spec's exception semantics. I wanted at least one bug that tests "did you read the spec carefully" vs. "did you guess."

**Stage 5 — The load/store unit:**
BUG-005 (LB zero-extend instead of sign-extend) — Sign vs. zero extension on byte loads is a classic mistake that has appeared in real silicon. It only manifests with values ≥ 0x80, so random testing may miss it entirely if it never generates that specific data pattern.

**Stage 6 — The CSR / exception state machine:**
BUG-006 (MEPC not saved) — Exception handling is the most rarely exercised part of a CPU in normal operation. Most simulations run happy-path code. A bug here could easily survive weeks of random testing. I wanted a bug that specifically validates that my exception sequence does the full round-trip — entry AND exit from the exception handler.

**Why not more?** Each additional bug should cover a new failure mode. After these 6, the remaining components (the decoder, the branch comparator, the WB mux) are already exercised by the existing checks. Adding a 7th bug in the ALU would confirm what BUG-003 already confirmed — redundant.

---

### Follow-up: "You said BUG-001 corrupts control flow and is 'hardest to catch.' But your scoreboard caught it immediately on the first branch. So it wasn't hard at all — why did you say that?"

**This is a trap. They want to see if you understand the nuance.**

**Your Answer:**

It was easy to catch in my testbench because my testbench was designed to catch it. The scoreboard compares every committed instruction against the ISS. When the DUT starts executing from address 0x00000000 after a branch, the ISS's PC and the DUT's PC immediately diverge — that is an obvious mismatch.

What I meant by "hardest class to catch" is that control flow bugs are hard to catch with **simple** testbenches — ones that only check final register values without tracking PC. Imagine a testbench that just checks "at the end of the program, is x1 equal to expected_value?" If the branch bug causes the DUT to take a different code path that happens to produce the same final value in x1 by coincidence, that testbench misses the bug entirely.

My scoreboard catches it because it checks every committed instruction, not just the final state. That design decision — checking every commit, not just program outputs — was specifically motivated by wanting to catch this class of bug. The bug being easy to catch is evidence that the testbench design decision was correct, not that the bug was trivial.

---

## PART 2 — THE "WHY THAT SPECIFIC DESIGN" QUESTIONS

---

### "Why did you use ibex as the DUT? You could have written a simple 5-stage pipeline yourself and had full control."

**Your Answer:**

Three reasons, and I thought about this explicitly before choosing.

**Reason 1: Authenticity.** ibex has been taped out in real silicon as part of OpenTitan. It has real bugs that were found and fixed in production. It has the complexity that real commercial CPUs have — OBI protocol, parameterized configuration, exception state machine, multiply-divide unit. Verifying it is meaningfully harder than verifying a toy RTL I wrote in a weekend, and the skills I demonstrate are directly transferable to industrial verification.

**Reason 2: Credibility on a resume.** If an interviewer asks "what did you verify?" and I say "a simple 5-stage pipeline I wrote myself," the follow-up is "but you know your own RTL, of course you found bugs in it." With ibex, I am verifying code I did not write — which is what verification engineers do in industry. I had no special knowledge of ibex's internals. I treated it as a black box.

**Reason 3: Protocol complexity.** ibex uses OBI for both instruction fetch and data memory. Implementing a real protocol driver is a more realistic skill demonstration than a single-cycle request-response.

**The trade-off I accepted:** I cannot modify ibex's ports arbitrarily. The commit port observation points are ibex-specific hierarchical signal taps that need to be maintained when ibex is updated. A custom DUT would have given me more control over the observation interface.

---

### Follow-up: "You said you treated ibex as a black box. But in tb_top.sv you tap internal signals with hierarchical paths like `ibex_core_i.rf_we_wb`. That is not black-box — that is white-box testing. Which is it?"

**Your Answer:**

That is a fair challenge. The precise answer is: the **correctness checking** is black-box, but the **observation** is white-box.

Black-box means: the pass/fail criteria come from the specification, not from reading the DUT's source code. I did not open `ibex_alu.sv` and write the scoreboard to match what ibex's ALU does. I wrote the ISS from the RISC-V spec independently, and the scoreboard compares against that independent reference.

White-box means: to observe the DUT's output, I had to read ibex's source to find where the register-file write signals live (`rf_we_wb`, `rf_waddr_wb_o`, etc.) and tap them hierarchically. This is unavoidable — ibex does not have a standard "commit port" in its public interface, so I had to reach inside.

In industry this is called **gray-box verification** — the checking logic is derived from the spec (black-box), but the observation points are derived from the implementation (white-box). This is normal and accepted. You cannot verify a CPU without observing something from inside the pipeline.

The risk of gray-box is that if ibex's internal signal names change between versions, the `assign dut_if.commit_valid = ibex_core_i.rf_we_wb` line breaks. That is a maintenance cost I documented in the tb_top.sv comment.

---

### "Why a C ISS specifically? Why not a SystemVerilog behavioral model in the testbench?"

**Your Answer:**

I made this choice deliberately after thinking through four concerns:

**Concern 1: Independence.** A SystemVerilog behavioral model runs in the VCS simulation kernel alongside the DUT. It participates in the same event scheduling. A C function called via DPI runs outside the simulation kernel entirely — it is a foreign function call. This gives the ISS true independence from the simulation environment. Any bug in the SV simulation infrastructure (delta cycles, race conditions, nonblocking assignment semantics) cannot affect the C ISS's results.

**Concern 2: Testability.** I can compile and run the C ISS with just `gcc`. No simulator license needed. I ran 23 self-tests before writing a single line of testbench code. You cannot do that with a SystemVerilog behavioral model — it requires a simulator to execute. The ability to validate the golden model independently is critical.

**Concern 3: Debug speed.** When the ISS produces a wrong reference value, I add a `printf` and recompile with gcc in 2 seconds. Debugging a SystemVerilog reference model requires re-elaborating the full design and re-running the simulation.

**Concern 4: Industry norm.** In production environments, the golden reference model is almost always a C/C++ ISS (Spike for RISC-V, OVPsim, proprietary internal models). Designing my DPI-C bridge to call a C function is the same pattern I would use at an employer.

---

### "Your DPI bridge has a `g_iss` static global variable. Globals are generally bad practice. Why did you do it that way?"

**Your Answer:**

It is intentional and the correct choice for this use case — but I understand why the question is worth asking.

DPI-C functions are called from SystemVerilog as if they were tasks or functions — there is no persistent object context. The C side has no equivalent of a UVM component that persists across calls. The ISS state (`rv32im_state_t`) must persist between calls to `iss_dpi_step()` — it is the running CPU state that accumulates instruction by instruction.

The options were:
1. **Static global** — simple, efficient, works correctly for single-CPU simulation
2. **Pass state pointer as argument** — but DPI-C types are limited; passing a pointer to a struct requires `chandle` type which adds complexity
3. **Allocate on heap, return handle** — cleaner in principle but requires the SV side to manage a `chandle`, adding error paths

For a testbench that runs one CPU simulation at a time (which this always is — one ibex instance per simulation), the static global is correct. There is no concurrency risk.

The global becomes a problem if you ever want to run two ibex instances in the same simulation (multi-core). For this single-core project, it is the simplest correct solution and I chose it deliberately.

---

## PART 3 — THE "WOULD YOU DO IT DIFFERENTLY" TEST

---

### "If you were starting this project over today, what would you change?"

**Why they ask this:**
Someone who truly built the project has strong opinions about what they would do differently. Someone who copied a template has no opinions — they did not experience the trade-offs.

**Your Answer:**

Three things:

**1. I would add interrupt injection from day one, not as an afterthought.**

Exception handling (synchronous) and interrupt handling (asynchronous) are different code paths in ibex. I covered exceptions but not interrupts. In hindsight, the interrupt agent is not much harder to build than the exception sequences — it is a few extra signals on the interface and a timing-aware stimulus generator. Skipping it was a scope decision I would revisit.

**2. I would use SVA cover properties more aggressively for directed test closure.**

I have 8 SVA cover properties, but I did not use them as primary coverage closure indicators. I used the 5 UVM functional covergroups. In a production environment, SVA cover properties are often the more precise tool — they capture exact temporal patterns (load followed by dependent instruction) that covergroups cannot express. I would wire the SVA cover results into the coverage closure report explicitly.

**3. The scoreboard's PC sync is a bandage, not a fix.**

When the ISS and DUT PCs diverge, I force the ISS to match the DUT's PC. This prevents cascading false errors but it means after BUG-001 fires, the ISS is blindly following the DUT's wrong execution path — potentially missing a second, different bug that would have been visible if the ISS had stayed on the correct path. A better design would be: on mismatch, log the error, reset the ISS to the correct state (what should have happened), and continue from there. Harder to implement, but more rigorous.

---

### Follow-up: "You said the PC sync is a bandage. What SHOULD happen after a mismatch ideally?"

**Your Answer:**

Ideally, after a mismatch, the scoreboard should:

1. Record the first error with full context
2. Reset the ISS to what the **correct** register and PC state should be (based on the ISS's own history, not the DUT's corrupted state)
3. Continue stepping the ISS on the correct path
4. Compare subsequent DUT commits against the correct expected state

This way, after BUG-001 (branch to wrong address), the ISS stays on the correct path. The DUT executes instructions at 0x00000000. The ISS executes instructions at the correct branch target. Every subsequent DUT commit differs from the ISS — you get a flood of errors, all of which trace back to the one root cause. This is actually useful information: "every error after cycle T points to the branch misprediction at cycle T."

My current implementation does the opposite — after a mismatch, the ISS follows the DUT into its incorrect execution path. This prevents the flood of false errors (useful for a readable log), but it also means the scoreboard is no longer checking against the spec after the first mismatch. For a production environment where you want maximum bug sensitivity, the "stay on correct path" approach is better.

The reason I chose the sync approach: readable logs during initial bring-up. When you have 6 bugs simultaneously, a flood of 200 cascading errors per bug makes the log unreadable. For a mature project where most bugs are fixed and you are hunting the last few, the "stay correct" approach is better.

---

### "You said your testbench uses `$signed` in the ISS for arithmetic right shift. How do you know the DUT uses signed arithmetic and not just a bit manipulation trick that produces the same result?"

**Your Answer:**

I do not need to know what the DUT does internally. That is the whole point of black-box verification.

The spec says: `SRA rd, rs1, rs2` — "shift right arithmetic." The RISC-V spec defines this as: shift the bit pattern in rs1 right by the shift amount, filling the vacated bits with the sign bit (bit 31). The ISS implements that definition.

The DUT can implement it however it wants — with `$signed` and `>>>`, or with a conditional fill of the upper bits, or with a multiplexer between the shifted bits and the sign bit replicated. As long as the result matches the spec, the scoreboard passes.

If the DUT uses a bit manipulation trick that produces a wrong result for a specific input (say, it forgets to handle the case where shift amount = 0), the scoreboard will catch that mismatch regardless of how the DUT internally computed the value.

This is the fundamental principle: the scoreboard checks **what** the DUT produces, not **how** it was produced. The ISS defines the correct **what** from the spec.

---

## PART 4 — THE "YOU ARE MAKING THIS UP" TEST

---

### "In your `tb_top.sv` you assign `dut_if.commit_result = ibex_core_i.rf_wdata_fwd_wb_o`. Why that specific signal and not `rf_wdata_wb_o`? What is the difference?"

**This question is designed to see if you actually read the code.**

**Your Answer:**

`rf_wdata_fwd_wb_o` is the forwarded write-back data — it includes the forwarding mux output, which selects between the normal WB result and results from earlier pipeline stages that are being forwarded. `rf_wdata_wb_o` is the raw WB stage data before forwarding is applied.

In ibex's 2-stage pipeline, the write-back data goes through the forwarding logic before it reaches the register file. The signal that represents "what actually gets written to the register file" is `rf_wdata_fwd_wb_o` — the post-forwarding value. If I tapped `rf_wdata_wb_o`, I would be reading the pre-forwarding value, which would be wrong for any instruction that benefits from forwarding — the scoreboard would see what the WB stage computed before forwarding, not what the register file actually received.

For the specific case of BUG-002 (forwarding mux inverted), tapping `rf_wdata_fwd_wb_o` is exactly the right signal — it shows me what the register file received, which is the corrupted value (the stale value instead of the forwarded value). That is the observable effect of BUG-002.

---

### "How does the OBI data memory bus work for a store instruction? Specifically, what is `data_be_o` and why does your driver apply it the way it does?"

**Your Answer:**

`data_be_o` is the **byte enable** signal — a 4-bit mask that indicates which bytes of the 32-bit data word are valid for this memory transaction.

For a `SW` (store word): `data_be_o = 4'b1111` — all 4 bytes are valid
For a `SH` (store halfword) at a halfword-aligned address: `data_be_o = 4'b0011` (lower half) or `4'b1100` (upper half) depending on alignment
For a `SB` (store byte) at byte address 0: `data_be_o = 4'b0001` — only the lowest byte

The driver applies byte enables with:

```systemverilog
if (be[0]) dmem_q[word_addr][ 7: 0] = wdata[ 7: 0];
if (be[1]) dmem_q[word_addr][15: 8] = wdata[15: 8];
if (be[2]) dmem_q[word_addr][23:16] = wdata[23:16];
if (be[3]) dmem_q[word_addr][31:24] = wdata[31:24];
```

This is necessary because the driver's memory is word-addressed (`dmem_q[word_addr]` is 32 bits) but stores can be byte-granular. If the driver ignored `data_be_o` and always wrote all 4 bytes, a `SB` would corrupt the 3 adjacent bytes in memory. A subsequent `LW` from the same address would return the wrong value, causing a false scoreboard mismatch that has nothing to do with any DUT bug.

---

### "Your ISS has a 256KB instruction memory. ibex's PC is 32 bits — it can address 4GB. What happens if a test tries to fetch an instruction above address 0x3FFFF?"

**Your Answer:**

The driver returns `0x00000013` — which is `ADDI x0, x0, 0`, a NOP. From `rv32im_driver.sv`:

```systemverilog
rdata = (word_addr < 65536) ? imem_q[word_addr] : 32'h0000_0013;
```

`65536` word addresses × 4 bytes = 256KB = address range `0x00000` to `0x3FFFF`.

Above that, every fetch gets a NOP. The DUT would execute an infinite loop of NOPs, eventually hitting the simulation timeout (`repeat(1_000_000) @(posedge clk)`).

The ISS has the same 256KB limit (`ISS_IMEM_SIZE = 256 * 1024`). If the PC goes above that, `iss_step_instr` would execute whatever happens to be in `imem[addr]` — likely zeros, which encode `ADDI x0, x0, 0` (also a NOP, since the zero encoding is `0x00000000` which is valid). So both DUT and ISS would execute NOPs and agree — no false mismatch.

In a production environment, you would want to model a full memory map: ROM at 0x0, SRAM at 0x100000, peripherals at 0x40000000, etc. The 256KB flat model is a simplification that is sufficient for the instruction sequences in this project (which never exceed 200 instructions × 4 bytes = 800 bytes).

---

## PART 5 — THE FINAL KILLER QUESTION

---

### "I can tell you understand this project. Let me ask you one last thing: what is the most important thing you learned from building it — not technically, professionally?"

**Why they ask this:**
This is a character question. They want to see if you can reflect, synthesize, and communicate at a human level. A junior says "I learned UVM." A strong candidate says something genuine.

**Your Answer:**

The most important thing I learned is the difference between **testing** and **verification**.

Testing is checking that things work. Verification is building a system that gives you evidence — measurable, documented evidence — that things work and that your checking is actually capable of catching failures.

Before this project, I thought "run some tests and see if they pass" was verification. Now I understand that the hard part is not writing the tests — it is building the infrastructure that makes the tests trustworthy:

- The ISS self-test proves the reference model is correct before you trust it
- The bug injection proves the testbench is sensitive before you trust zero errors
- The coverage report proves the test suite is complete before you claim closure
- The exit criteria defined upfront prove you know what "done" means before you declare done

Every one of those steps is about **trusting your own process** — not just the DUT. That shift in thinking — from "did the tests pass?" to "is my verification plan trustworthy?" — is what this project taught me.

---

## THE ONE TABLE YOU MUST MEMORIZE

Every "why did you" question maps to one of these three answers:

| Question type | The underlying answer |
|--------------|----------------------|
| "Why did you inject bugs?" | To prove the testbench works, not just that the DUT looks clean |
| "Why did you choose X over Y?" | Because X solves a specific problem that Y does not — I evaluated the trade-off |
| "Why did you do it this way?" | Because I derived it from the spec / the DUT architecture / a known industry practice — not because it was in a tutorial |

If you can answer every "why" with one of those three patterns, you will pass any interview.
