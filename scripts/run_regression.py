#!/usr/bin/env python3
"""
run_regression.py — RV32IM UVM Regression Runner

Spawns VCS simulation runs in parallel across multiple seeds and tests.
Detects PASS/FAIL per run, writes results.json, exits non-zero on failure.

Usage:
    python scripts/run_regression.py \
        --simv sim/vcs/simv \
        --tests rand hazard branch muldiv directed \
        --seeds 20 \
        --parallel 4 \
        --outdir sim/vcs/regression \
        --verbosity UVM_MEDIUM
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional

# ── Test name map ────────────────────────────────────────────────────────────
TEST_NAMES = {
    "smoke"    : "rv32im_smoke_test",
    "rand"     : "rv32im_rand_test",
    "hazard"   : "rv32im_rand_test",   # hazard sequences run inside rand_test
    "branch"   : "rv32im_rand_test",
    "muldiv"   : "rv32im_rand_test",
    "directed" : "rv32im_directed_test",
}

# ── Patterns to detect pass/fail ─────────────────────────────────────────────
FAIL_PATTERNS = [
    re.compile(r"UVM_ERROR\s+@"),
    re.compile(r"UVM_FATAL\s+@"),
    re.compile(r"\[SB\].*MISMATCH"),
    re.compile(r"Assertion violation"),
    re.compile(r"\$error"),
    re.compile(r"TEST FAILED"),
]
PASS_PATTERNS = [
    re.compile(r"ALL CHECKS PASSED"),
    re.compile(r"UVM_ERROR\s+:\s+0"),
]

@dataclass
class RunResult:
    test:    str
    seed:    int
    status:  str          # "PASS" | "FAIL" | "TIMEOUT" | "ERROR"
    errors:  List[str] = field(default_factory=list)
    log:     str       = ""
    elapsed: float     = 0.0


def run_one(simv: str, test_sv: str, seed: int, outdir: Path,
            verbosity: str, timeout: int) -> RunResult:
    """Execute one VCS simulation run and return a RunResult."""
    log_path = outdir / f"{test_sv}_seed{seed}.log"
    start    = time.time()

    cmd = [
        simv,
        f"+UVM_TESTNAME={test_sv}",
        f"+ntb_random_seed={seed}",
        f"+UVM_VERBOSITY={verbosity}",
        f"-l", str(log_path),
        "-cm", "line+cond+fsm+tgl+branch",
        f"-cm_dir", str(outdir / f"cov_seed{seed}.vdb"),
    ]

    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return RunResult(test=test_sv, seed=seed, status="TIMEOUT",
                         log=str(log_path), elapsed=time.time()-start)
    except Exception as e:
        return RunResult(test=test_sv, seed=seed, status="ERROR",
                         errors=[str(e)], log=str(log_path),
                         elapsed=time.time()-start)

    elapsed = time.time() - start

    # Parse log
    log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
    errors   = []
    for pat in FAIL_PATTERNS:
        for m in pat.finditer(log_text):
            line = log_text.splitlines()[log_text[:m.start()].count("\n")]
            errors.append(line.strip())

    passed = any(p.search(log_text) for p in PASS_PATTERNS)
    failed = bool(errors)

    if not failed and passed:
        status = "PASS"
    elif failed:
        status = "FAIL"
    else:
        # No explicit PASS marker — check return code
        status = "PASS" if proc.returncode == 0 else "FAIL"

    return RunResult(test=test_sv, seed=seed, status=status,
                     errors=errors[:5],   # cap to first 5 errors
                     log=str(log_path), elapsed=elapsed)


def print_result(r: RunResult) -> None:
    icon = "✓" if r.status == "PASS" else "✗"
    color = "\033[32m" if r.status == "PASS" else "\033[31m"
    reset = "\033[0m"
    print(f"  {color}{icon}{reset} {r.test:<35} seed={r.seed:<6} "
          f"{r.elapsed:5.1f}s  {r.status}")
    for e in r.errors[:2]:
        print(f"      └─ {e[:100]}")


def main() -> int:
    parser = argparse.ArgumentParser(description="RV32IM UVM Regression Runner")
    parser.add_argument("--simv",      default="sim/vcs/simv",
                        help="Path to compiled VCS simv binary")
    parser.add_argument("--tests",     nargs="+",
                        default=["rand"],
                        choices=list(TEST_NAMES.keys()),
                        help="Test names to run")
    parser.add_argument("--seeds",     type=int, default=10,
                        help="Number of random seeds per test")
    parser.add_argument("--parallel",  type=int, default=4,
                        help="Max parallel simulation jobs")
    parser.add_argument("--outdir",    default="sim/vcs/regression",
                        help="Output directory for logs and results")
    parser.add_argument("--verbosity", default="UVM_MEDIUM",
                        choices=["UVM_NONE","UVM_LOW","UVM_MEDIUM",
                                 "UVM_HIGH","UVM_FULL","UVM_DEBUG"])
    parser.add_argument("--timeout",   type=int, default=300,
                        help="Per-run timeout in seconds")
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    simv = Path(args.simv)
    if not simv.exists():
        print(f"ERROR: simv not found at {simv}. Run 'make compile' first.")
        return 1

    # Build job list
    jobs = []
    for test_short in args.tests:
        test_sv = TEST_NAMES[test_short]
        for seed in range(1, args.seeds + 1):
            jobs.append((str(simv), test_sv, seed))

    total   = len(jobs)
    results = []

    print(f"\n{'='*65}")
    print(f"  RV32IM UVM Regression  —  {datetime.now():%Y-%m-%d %H:%M}")
    print(f"  Tests: {args.tests}  |  Seeds: {args.seeds}  |  "
          f"Jobs: {total}  |  Parallel: {args.parallel}")
    print(f"{'='*65}\n")

    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        future_map = {
            pool.submit(run_one, sv, tv, seed, outdir,
                        args.verbosity, args.timeout): (tv, seed)
            for sv, tv, seed in jobs
        }
        for future in as_completed(future_map):
            r = future.result()
            results.append(r)
            print_result(r)

    # Summary
    passed  = sum(1 for r in results if r.status == "PASS")
    failed  = sum(1 for r in results if r.status == "FAIL")
    timeout = sum(1 for r in results if r.status == "TIMEOUT")
    error   = sum(1 for r in results if r.status == "ERROR")

    print(f"\n{'='*65}")
    print(f"  SUMMARY:  {passed}/{total} PASS  |  "
          f"{failed} FAIL  |  {timeout} TIMEOUT  |  {error} ERROR")
    print(f"{'='*65}\n")

    # Write JSON results
    result_file = outdir / "results.json"
    with open(result_file, "w") as f:
        json.dump(
            [{"test": r.test, "seed": r.seed, "status": r.status,
              "errors": r.errors, "log": r.log, "elapsed": r.elapsed}
             for r in results],
            f, indent=2
        )
    print(f"  Results written to {result_file}")

    return 0 if failed == 0 and timeout == 0 and error == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
