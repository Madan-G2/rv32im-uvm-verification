#!/usr/bin/env python3
"""
parse_logs.py — Parse VCS simulation logs for UVM errors and mismatches.

Groups mismatches by opcode, builds a per-test failure summary,
outputs a Markdown table and results.json.

Usage:
    python scripts/parse_logs.py --dir sim/vcs/regression --report report.md
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# ── Patterns ─────────────────────────────────────────────────────────────────
RE_UVM_ERROR = re.compile(
    r"UVM_ERROR\s+@\s+[\d.]+\s+ns\s+\[([^\]]+)\]\s+(.+)")
RE_UVM_FATAL = re.compile(
    r"UVM_FATAL\s+@\s+[\d.]+\s+ns\s+\[([^\]]+)\]\s+(.+)")
RE_MISMATCH = re.compile(
    r"RESULT MISMATCH.*PC=([0-9A-Fa-f]+)\s+instr=([0-9A-Fa-f]+)\s+\(([^)]+)\)")
RE_TRAP_MISMATCH = re.compile(r"TRAP MISMATCH")
RE_MISSED_TRAP   = re.compile(r"MISSED TRAP")
RE_SB_PASS       = re.compile(r"ALL CHECKS PASSED")
RE_COMMIT_COUNT  = re.compile(r"Total checks\s*:\s*(\d+)")
RE_FAIL_COUNT    = re.compile(r"Fail\s*:\s*(\d+)")
RE_UVM_ERR_COUNT = re.compile(r"UVM_ERROR\s+:\s+(\d+)")
RE_UVM_FATAL_COUNT = re.compile(r"UVM_FATAL\s+:\s+(\d+)")


def parse_log(log_path: Path) -> dict:
    text    = log_path.read_text(errors="replace")
    lines   = text.splitlines()
    result  = {
        "log":        str(log_path),
        "passed":     bool(RE_SB_PASS.search(text)),
        "errors":     [],
        "mismatches": [],
        "opcode_err": defaultdict(int),
        "commit_count": 0,
        "fail_count":   0,
    }

    # UVM error messages
    for m in RE_UVM_ERROR.finditer(text):
        result["errors"].append({"source": m.group(1), "msg": m.group(2).strip()})
    for m in RE_UVM_FATAL.finditer(text):
        result["errors"].append({"source": m.group(1),
                                 "msg": "[FATAL] " + m.group(2).strip()})

    # Scoreboard mismatches — extract opcode
    for m in RE_MISMATCH.finditer(text):
        pc, instr_hex, opcode = m.group(1), m.group(2), m.group(3)
        result["mismatches"].append({
            "pc": pc, "instr": instr_hex, "opcode": opcode})
        result["opcode_err"][opcode] += 1

    if m := RE_COMMIT_COUNT.search(text):
        result["commit_count"] = int(m.group(1))
    if m := RE_FAIL_COUNT.search(text):
        result["fail_count"] = int(m.group(1))
    if m := RE_UVM_ERR_COUNT.search(text):
        if int(m.group(1)) > 0 and not result["errors"]:
            result["errors"].append({"source": "SIM", "msg": f"UVM_ERROR count: {m.group(1)}"})

    return result


def build_markdown(all_results: list) -> str:
    lines = ["# RV32IM Regression Log Report\n"]
    lines.append(f"Parsed {len(all_results)} log files.\n")

    # Summary table
    lines.append("## Summary\n")
    lines.append("| Log File | Status | Commits | Failures |")
    lines.append("|---|---|---|---|")
    for r in all_results:
        status = "✓ PASS" if r["passed"] and not r["errors"] else "✗ FAIL"
        name   = Path(r["log"]).name
        lines.append(f"| `{name}` | {status} | {r['commit_count']} | {r['fail_count']} |")

    # Opcode error aggregation
    opcode_totals: dict = defaultdict(int)
    for r in all_results:
        for op, cnt in r["opcode_err"].items():
            opcode_totals[op] += cnt

    if opcode_totals:
        lines.append("\n## Mismatches by Opcode\n")
        lines.append("| Opcode | Error Count |")
        lines.append("|---|---|")
        for op, cnt in sorted(opcode_totals.items(), key=lambda x: -x[1]):
            lines.append(f"| `{op}` | {cnt} |")

    # Individual failures
    failed = [r for r in all_results if r["errors"]]
    if failed:
        lines.append(f"\n## Failure Details ({len(failed)} logs with errors)\n")
        for r in failed[:20]:  # cap to 20 logs
            lines.append(f"### `{Path(r['log']).name}`\n")
            for e in r["errors"][:5]:
                lines.append(f"- **[{e['source']}]** {e['msg']}")
            lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse VCS regression logs")
    parser.add_argument("--dir",    required=True,
                        help="Directory containing .log files")
    parser.add_argument("--report", default="report.md",
                        help="Output Markdown report path")
    parser.add_argument("--json",   default=None,
                        help="Optional JSON output path")
    args = parser.parse_args()

    log_dir = Path(args.dir)
    if not log_dir.exists():
        print(f"ERROR: directory not found: {log_dir}")
        return 1

    logs = sorted(log_dir.glob("*.log"))
    if not logs:
        print(f"No .log files found in {log_dir}")
        return 0

    print(f"Parsing {len(logs)} log files from {log_dir} ...")
    all_results = [parse_log(l) for l in logs]

    # Markdown report
    report_path = Path(args.report)
    report_path.write_text(build_markdown(all_results))
    print(f"Report written to {report_path}")

    # JSON output
    if args.json:
        json_path = Path(args.json)
        with open(json_path, "w") as f:
            # Convert defaultdicts to plain dicts for JSON
            for r in all_results:
                r["opcode_err"] = dict(r["opcode_err"])
            json.dump(all_results, f, indent=2)
        print(f"JSON written to {json_path}")

    # Return non-zero if any failures
    any_fail = any(r["errors"] for r in all_results)
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())
