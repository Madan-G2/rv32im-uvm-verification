# ===========================================================================
# Makefile — RV32IM UVM Verification Environment
# Targets: VCS (primary) | Icarus Verilog (free)
# ===========================================================================

# ── Directories ─────────────────────────────────────────────────────────────
TB_DIR      := tb
ENV_DIR     := $(TB_DIR)/env
SEQ_DIR     := $(TB_DIR)/sequences
TEST_DIR    := $(TB_DIR)/tests
SVA_DIR     := $(TB_DIR)/sva
ISS_DIR     := iss
RTL_DIR     := rtl/ibex_buggy
SIM_VCS     := sim/vcs
SIM_IV      := sim/iverilog
SCRIPTS     := scripts

# ── Tool settings ───────────────────────────────────────────────────────────
VCS         := vcs
IVERILOG    := iverilog
VVP         := vvp
URG         := urg
PYTHON      := python3

# ── UVM ─────────────────────────────────────────────────────────────────────
UVM_HOME    ?= $(VCS_HOME)/etc/uvm-1.2
UVM_INCDIR  := $(UVM_HOME)/src

# ── Default test ────────────────────────────────────────────────────────────
TEST        ?= rv32im_rand_test
SEED        ?= 1
VERBOSITY   ?= UVM_MEDIUM
NUM_INSTRS  ?= 200

# ── VCS compile flags ────────────────────────────────────────────────────────
VCS_CFLAGS  := -sverilog -full64 \
               -ntb_opts uvm-1.2 \
               +define+UVM_NO_DEPRECATED \
               +define+UVM_OBJECT_MUST_HAVE_CONSTRUCTOR \
               -assert enable_diag \
               -assert coverage \
               -cm line+cond+fsm+tgl+branch \
               -CFLAGS "-O2 -fPIC -Wall" \
               +incdir+$(ENV_DIR) \
               +incdir+$(SEQ_DIR) \
               +incdir+$(TEST_DIR) \
               +incdir+$(SVA_DIR) \
               -f flist.f

# ── VCS sim flags ───────────────────────────────────────────────────────────
VCS_SIMFLAGS := +UVM_TESTNAME=$(TEST) \
                +ntb_random_seed=$(SEED) \
                +UVM_VERBOSITY=$(VERBOSITY) \
                +num_instrs=$(NUM_INSTRS) \
                -cm line+cond+fsm+tgl+branch \
                -cm_dir $(SIM_VCS)/cov.vdb

# ===========================================================================
# Targets
# ===========================================================================

.PHONY: all compile sim clean regress coverage help \
        smoke rand hazard branch muldiv directed \
        iv_compile iv_sim test_iss

all: compile

# ── Standalone ISS self-test (gcc only, no VCS required) ─────────────────────
test_iss:
	gcc -O2 -Wall -I$(ISS_DIR) \
	    $(ISS_DIR)/iss_test.c \
	    $(ISS_DIR)/rv32im_iss.c \
	    -o $(ISS_DIR)/iss_test
	$(ISS_DIR)/iss_test

# ── VCS compile (elaboration) ────────────────────────────────────────────────
compile: $(SIM_VCS)
	$(VCS) $(VCS_CFLAGS) \
	    $(ISS_DIR)/rv32im_iss.c \
	    $(ISS_DIR)/rv32im_iss_dpi.c \
	    tb/tb_top.sv \
	    -o $(SIM_VCS)/simv \
	    -l $(SIM_VCS)/compile.log
	@echo "=== Compile complete. Log: $(SIM_VCS)/compile.log ==="

# ── Run one test ─────────────────────────────────────────────────────────────
sim: $(SIM_VCS)/simv
	$(SIM_VCS)/simv $(VCS_SIMFLAGS) \
	    -l $(SIM_VCS)/$(TEST)_$(SEED).log
	@echo "=== Sim complete. Log: $(SIM_VCS)/$(TEST)_$(SEED).log ==="

# ── Convenience targets for each test ───────────────────────────────────────
smoke:    compile
	$(MAKE) sim TEST=rv32im_smoke_test    SEED=$(SEED)

rand:     compile
	$(MAKE) sim TEST=rv32im_rand_test     SEED=$(SEED)

hazard:   compile
	$(MAKE) sim TEST=rv32im_rand_test     SEED=$(SEED) \
	    VCS_SIMFLAGS="$(VCS_SIMFLAGS) +UVM_TESTNAME=rv32im_rand_test"

branch:   compile
	$(MAKE) sim TEST=rv32im_rand_test     SEED=$(SEED)

muldiv:   compile
	$(MAKE) sim TEST=rv32im_rand_test     SEED=$(SEED)

directed: compile
	$(MAKE) sim TEST=rv32im_directed_test SEED=$(SEED)

# ── Full regression (Python-driven) ─────────────────────────────────────────
regress: compile
	$(PYTHON) $(SCRIPTS)/run_regression.py \
	    --simv $(SIM_VCS)/simv \
	    --tests rand hazard branch muldiv directed \
	    --seeds 20 \
	    --parallel 4 \
	    --outdir $(SIM_VCS)/regression \
	    --verbosity $(VERBOSITY)

# ── Coverage merge and report ────────────────────────────────────────────────
coverage:
	$(URG) -dir $(SIM_VCS)/cov.vdb \
	       -format text \
	       -report $(SIM_VCS)/coverage_report
	$(PYTHON) $(SCRIPTS)/aggregate_coverage.py \
	    --urg-report $(SIM_VCS)/coverage_report \
	    --threshold 95
	@echo "=== Coverage report: $(SIM_VCS)/coverage_report ==="

# ── Parse logs ───────────────────────────────────────────────────────────────
parse:
	$(PYTHON) $(SCRIPTS)/parse_logs.py \
	    --dir $(SIM_VCS)/regression \
	    --report $(SIM_VCS)/regression/report.md

# ── Icarus Verilog (free, limited — no UVM) ──────────────────────────────────
iv_compile: $(SIM_IV)
	$(IVERILOG) -g2012 \
	    -s tb_top \
	    -o $(SIM_IV)/simv \
	    -I$(ENV_DIR) -I$(SEQ_DIR) -I$(TEST_DIR) -I$(SVA_DIR) \
	    $$(cat flist_iv.f) \
	    tb/tb_top.sv \
	    2>&1 | tee $(SIM_IV)/compile.log
	@echo "=== iverilog compile done ==="

iv_sim: $(SIM_IV)/simv
	$(VVP) $(SIM_IV)/simv +vcd_dump \
	    2>&1 | tee $(SIM_IV)/sim.log

# ── Directory creation ───────────────────────────────────────────────────────
$(SIM_VCS) $(SIM_IV):
	mkdir -p $@

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(SIM_VCS)/simv $(SIM_VCS)/*.log \
	       $(SIM_VCS)/cov.vdb $(SIM_VCS)/coverage_report \
	       $(SIM_VCS)/csrc $(SIM_VCS)/simv.daidir \
	       $(SIM_IV)/simv $(SIM_IV)/*.log \
	       ucli.key vc_hdrs.h novas.rc

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "RV32IM UVM Verification — Makefile targets"
	@echo "-------------------------------------------"
	@echo "  make test_iss         Build and run standalone C ISS self-test (gcc only)
  make compile          VCS compile (mandatory first step)"
	@echo "  make smoke            Run smoke test (10 ADDI instructions)"
	@echo "  make rand SEED=42     Run random test, seed 42"
	@echo "  make directed         Run coverage-closure directed test"
	@echo "  make regress          Full regression (20 seeds, 4 parallel)"
	@echo "  make coverage         Merge VDB and print coverage report"
	@echo "  make parse            Parse regression logs to Markdown"
	@echo "  make clean            Remove sim outputs"
	@echo ""
	@echo "Override defaults:"
	@echo "  TEST=rv32im_smoke_test  SEED=1  VERBOSITY=UVM_HIGH"
	@echo ""
