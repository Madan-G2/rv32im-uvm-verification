# flist.f — VCS file list for RV32IM UVM verification environment
# Usage: vcs -f flist.f ...

# ── Include paths ────────────────────────────────────────────────
+incdir+tb/env
+incdir+tb/sequences
+incdir+tb/tests
+incdir+tb/sva

# ── UVM package (VCS provides via -ntb_opts uvm-1.2) ───────────
# No explicit include needed when using -ntb_opts

# ── rv32im_pkg (must come first — defines types used everywhere) ─
tb/env/rv32im_pkg.sv

# ── ibex RTL (buggy variant for bug-finding) ─────────────────────
# Switch to rtl/ibex_clean/ for clean-RTL coverage closure runs
rtl/ibex_buggy/ibex_pkg.sv
rtl/ibex_buggy/prim_assert.sv
rtl/ibex_buggy/ibex_alu.sv
rtl/ibex_buggy/ibex_compressed_decoder.sv
rtl/ibex_buggy/ibex_controller.sv
rtl/ibex_buggy/ibex_cs_registers.sv
rtl/ibex_buggy/ibex_decoder.sv
rtl/ibex_buggy/ibex_ex_block.sv
rtl/ibex_buggy/ibex_fetch_fifo.sv
rtl/ibex_buggy/ibex_icache.sv
rtl/ibex_buggy/ibex_id_stage.sv
rtl/ibex_buggy/ibex_if_stage.sv
rtl/ibex_buggy/ibex_load_store_unit.sv
rtl/ibex_buggy/ibex_multdiv_slow.sv
rtl/ibex_buggy/ibex_multdiv_fast.sv
rtl/ibex_buggy/ibex_pmp.sv
rtl/ibex_buggy/ibex_register_file_ff.sv
rtl/ibex_buggy/ibex_wb_stage.sv
rtl/ibex_buggy/ibex_core.sv

# ── Testbench interface ──────────────────────────────────────────
tb/rv32im_if.sv

# ── UVM environment components ───────────────────────────────────
tb/env/rv32im_sequencer.sv
tb/env/rv32im_driver.sv
tb/env/rv32im_monitor.sv
tb/env/rv32im_agent.sv
tb/env/rv32im_scoreboard.sv
tb/env/rv32im_coverage.sv
tb/env/rv32im_env.sv

# ── Sequences ────────────────────────────────────────────────────
tb/sequences/rv32im_base_seq.sv
tb/sequences/rv32im_rand_seq.sv
tb/sequences/rv32im_hazard_seq.sv
tb/sequences/rv32im_branch_seq.sv
tb/sequences/rv32im_mul_div_seq.sv
tb/sequences/rv32im_exception_seq.sv

# ── Tests ────────────────────────────────────────────────────────
tb/tests/rv32im_base_test.sv
tb/tests/rv32im_smoke_test.sv
tb/tests/rv32im_rand_test.sv
tb/tests/rv32im_directed_test.sv

# ── SVA checkers ─────────────────────────────────────────────────
tb/sva/pipeline_fsm.sva
tb/sva/hazard_checks.sva

# ── tb_top ───────────────────────────────────────────────────────
tb/tb_top.sv
