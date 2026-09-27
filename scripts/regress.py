#!/usr/bin/env python3
"""APB UART 지향 테스트와 재현 가능한 무작위 시드 회귀를 실행한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    *sorted((ROOT / "rtl").glob("*.sv")),
    *sorted((ROOT / "assertions").glob("*.sv")),
    *sorted((ROOT / "tb").glob("*.sv")),
    ROOT / "Makefile",
    *sorted((ROOT / "scripts").glob("*.py")),
    *sorted((ROOT / "scripts").glob("*.sh")),
]
PASS_RE = re.compile(r"TEST_PASS\s+test=(\S+)\s+seed=(\d+)\s+apb_transactions=(\d+)\s+tx_frames=(\d+)\s+rx_frames=(\d+)")
FIFO_PASS_RE = re.compile(r"\bFIFO_TEST_PASS\b")
APB_BIN_RE = re.compile(r"COVERAGE apb write=(\d+) error=(\d+) wait_bucket=(\d+) count=(\d+)")
UART_RE = re.compile(
    r"COVERAGE uart tx_frames=(\d+) rx_frames=(\d+) bad_stop=(\d+) "
    r"false_start=(\d+) overflow=(\d+) rx_period_31=(\d+) rx_period_33=(\d+) tx_full_reject=(\d+) "
    r"rx_empty_reject=(\d+) reset_abort=(\d+) baud_min=(\d+) baud_max=(\d+)"
)
UART_FIELDS = ("tx_frames", "rx_frames", "bad_stop", "false_start", "overflow",
               "rx_period_31", "rx_period_33", "tx_full_reject", "rx_empty_reject",
               "reset_abort", "baud_min", "baud_max")


def command_output(command: list[str]) -> str:
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
    except OSError as exc:
        return f"사용할 수 없음: {exc}"
    return (result.stdout or result.stderr).strip() if result.returncode == 0 else f"사용할 수 없음 (종료 코드 {result.returncode}): {(result.stderr or result.stdout).strip()}"


def git_commit() -> str:
    try:
        result = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=ROOT,
                                text=True, capture_output=True, check=False)
    except OSError:
        return "Git 명령을 사용할 수 없음"
    return result.stdout.strip() if result.returncode == 0 else "아직 커밋 없음"


def source_digest() -> str:
    digest = hashlib.sha256()
    for source in SOURCES:
        digest.update(str(source.relative_to(ROOT)).encode())
        digest.update(source.read_bytes())
    return digest.hexdigest()


def run_case(test: str, seed: int, wait_cycles: int, transactions: int,
             timeout_seconds: int, output: Path) -> dict:
    coverage_file = output.with_suffix(".dat")
    coverage_file.unlink(missing_ok=True)
    coverage_arg = coverage_file.relative_to(ROOT) if coverage_file.is_relative_to(ROOT) else coverage_file
    command = [
        "make", "test", f"TEST={test}", f"SEED={seed}",
        f"WAIT_CYCLES={wait_cycles}", f"N_TRANSACTIONS={transactions}",
        f"COVERAGE_FILE={coverage_arg}",
    ]
    start = time.monotonic()
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout_seconds, check=False)
        log = result.stdout
        return_code = result.returncode
    except subprocess.TimeoutExpired as exc:
        captured = exc.stdout or b""
        log = captured.decode(errors="replace") if isinstance(captured, bytes) else captured
        log += f"\n제한 시간 초과: {timeout_seconds}초\n"
        return_code = 124
    except OSError as exc:
        log = f"명령 실행 실패: {' '.join(command)}: {exc}\n"
        return_code = 127
    elapsed = round(time.monotonic() - start, 3)
    output.write_text(log)
    matches = PASS_RE.findall(log)
    observed = None
    if matches:
        matched_test, matched_seed, apb, tx, rx = matches[-1]
        observed = {
            "test": matched_test, "seed": int(matched_seed),
            "apb_transactions": int(apb), "tx_frames": int(tx), "rx_frames": int(rx),
        }
    uart_matches = UART_RE.findall(log)
    uart_coverage = dict(zip(UART_FIELDS, map(int, uart_matches[-1]))) if uart_matches else None
    apb_bins = {(int(write), int(error), int(wait)): int(count)
                for write, error, wait, count in APB_BIN_RE.findall(log)}
    functional_errors = []
    passed = return_code == 0 and observed is not None and coverage_file.is_file() and coverage_file.stat().st_size > 0
    if passed:
        passed = observed["test"] == test and observed["seed"] == seed
    if passed and test == "random":
        passed = observed["apb_transactions"] >= transactions
    if uart_coverage is None:
        functional_errors.append("UART 기능 커버리지 계수가 없음")
    else:
        required = {
            "apb": ("reset_abort",),
            "tx": ("tx_frames", "tx_full_reject", "reset_abort"),
            "rx": ("rx_frames", "bad_stop", "false_start", "overflow", "rx_period_31", "rx_period_33",
                   "rx_empty_reject", "reset_abort"),
            "random": ("tx_frames", "rx_frames"),
        }[test]
        for name in required:
            if uart_coverage[name] == 0:
                functional_errors.append(f"기능 커버리지 항목 {name}이(가) 관측되지 않음")
        if test == "tx" and (uart_coverage["baud_min"] > 4 or uart_coverage["baud_max"] < 17):
            functional_errors.append("TX 분주값 4/17 범위가 관측되지 않음")
        if test == "rx" and (uart_coverage["baud_min"] > 4 or uart_coverage["baud_max"] < 32):
            functional_errors.append("RX 분주값 4/32 범위가 관측되지 않음")
    if test == "apb":
        wait_bucket = {0: 0, 1: 1, 3: 2}[wait_cycles]
        for write in (0, 1):
            for error in (0, 1):
                if apb_bins.get((write, error, wait_bucket), 0) == 0:
                    functional_errors.append(f"APB 커버리지 항목 누락: write={write} error={error} wait={wait_cycles}")
    if functional_errors:
        passed = False
    return {
        "test": test, "seed": seed, "wait_cycles": wait_cycles,
        "requested_transactions": transactions if test == "random" else None,
        "elapsed_seconds": elapsed, "exit_code": return_code,
        "pass": passed, "observed": observed,
        "functional_coverage": uart_coverage,
        "functional_errors": functional_errors,
        "log": str(output.relative_to(ROOT)),
        "coverage_data": str(coverage_file.relative_to(ROOT)) if coverage_file.is_file() else None,
        "command": command,
    }


def run_fifo(timeout_seconds: int, output: Path) -> dict:
    coverage_file = output.with_suffix(".dat")
    coverage_file.unlink(missing_ok=True)
    coverage_arg = coverage_file.relative_to(ROOT) if coverage_file.is_relative_to(ROOT) else coverage_file
    command = ["make", "test-fifo", f"COVERAGE_FILE={coverage_arg}"]
    start = time.monotonic()
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout_seconds, check=False)
        log = result.stdout
        return_code = result.returncode
    except subprocess.TimeoutExpired as exc:
        captured = exc.stdout or b""
        log = captured.decode(errors="replace") if isinstance(captured, bytes) else captured
        log += f"\n제한 시간 초과: {timeout_seconds}초\n"
        return_code = 124
    except OSError as exc:
        log = f"명령 실행 실패: {' '.join(command)}: {exc}\n"
        return_code = 127
    output.write_text(log)
    return {"test": "fifo", "seed": None, "wait_cycles": None,
            "requested_transactions": None,
            "elapsed_seconds": round(time.monotonic() - start, 3),
            "exit_code": return_code,
            "pass": return_code == 0 and bool(FIFO_PASS_RE.search(log)) and coverage_file.is_file() and coverage_file.stat().st_size > 0,
            "observed": None, "log": str(output.relative_to(ROOT)),
            "coverage_data": str(coverage_file.relative_to(ROOT)) if coverage_file.is_file() else None,
            "command": command}


def summarize_line_coverage(info_file: Path) -> dict:
    """Verilator가 기록한 RTL 소스별 실행 줄 수를 계산한다."""
    counts: dict[str, dict[str, int]] = {}
    current_source = None
    for line in info_file.read_text().splitlines():
        if line.startswith("SF:"):
            current_source = line[3:]
            if current_source.startswith("rtl/"):
                counts.setdefault(current_source, {"hit": 0, "total": 0})
        elif line.startswith("DA:") and current_source in counts:
            _, count, *_ = line[3:].split(",")
            counts[current_source]["total"] += 1
            counts[current_source]["hit"] += int(count) > 0
    total = sum(item["total"] for item in counts.values())
    hit = sum(item["hit"] for item in counts.values())
    return {"rtl_lines_hit": hit, "rtl_lines_total": total,
            "rtl_line_percent": round(hit * 100 / total, 2) if total else None,
            "by_file": counts}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seeds", type=int, default=20, help="무작위 검증에 사용할 시드 수")
    parser.add_argument("--transactions", type=int, default=1000, help="시드마다 완료할 최소 APB 전송 수")
    parser.add_argument("--timeout-seconds", type=int, default=600, help="각 빌드 및 시뮬레이션의 제한 시간(초)")
    parser.add_argument("--output", type=Path, default=Path("reports/runs/latest"))
    args = parser.parse_args()
    if args.seeds < 1 or args.transactions < 1 or args.timeout_seconds < 1:
        parser.error("시드 수, 전송 수, 제한 시간은 모두 양수여야 합니다")
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.mkdir(parents=True, exist_ok=True)

    metadata = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "python": sys.version.split()[0],
        "verilator": command_output(["verilator", "--version"]),
        "git_commit": git_commit(),
        "source_sha256": source_digest(),
        "source_files": [str(source.relative_to(ROOT)) for source in SOURCES],
        "seed_count": args.seeds, "transactions_per_seed": args.transactions,
    }
    cases = [run_fifo(args.timeout_seconds, output / "fifo.log")]
    print(f"{'PASS' if cases[0]['pass'] else 'FAIL'} fifo ({cases[0]['elapsed_seconds']}초)", flush=True)
    for wait in (0, 1, 3) if cases[0]["pass"] else ():
        for test in ("apb", "tx", "rx"):
            log = output / f"{test}-wait{wait}.log"
            case = run_case(test, 1, wait, args.transactions, args.timeout_seconds, log)
            cases.append(case)
            print(f"{'PASS' if case['pass'] else 'FAIL'} {test} wait={wait} seed=1 ({case['elapsed_seconds']}초)", flush=True)
            if not case["pass"]:
                break
        if cases and not cases[-1]["pass"]:
            break
    if all(case["pass"] for case in cases):
        for seed in range(1, args.seeds + 1):
            wait = (0, 1, 3)[(seed - 1) % 3]
            log = output / f"random-seed{seed:02d}-wait{wait}.log"
            case = run_case("random", seed, wait, args.transactions, args.timeout_seconds, log)
            cases.append(case)
            print(f"{'PASS' if case['pass'] else 'FAIL'} random wait={wait} seed={seed} ({case['elapsed_seconds']}초)", flush=True)
            if not case["pass"]:
                break

    coverage = {"merged": False, "error": None}
    if len(cases) == 10 + args.seeds and all(case["pass"] for case in cases):
        data_files = [ROOT / case["coverage_data"] for case in cases]
        info_file = output / "coverage.info"
        info_file.unlink(missing_ok=True)
        try:
            merge = subprocess.run(["verilator_coverage", "--write-info", str(info_file),
                                    *map(str, data_files)], cwd=ROOT, text=True,
                                   capture_output=True, check=False)
            if merge.returncode == 0 and info_file.is_file():
                coverage = {"merged": True, "info": str(info_file.relative_to(ROOT)),
                            **summarize_line_coverage(info_file)}
            else:
                coverage = {"merged": False, "error": (merge.stderr or merge.stdout).strip()}
        except OSError as exc:
            coverage = {"merged": False, "error": str(exc)}

    summary = {"metadata": metadata, "passed": sum(case["pass"] for case in cases),
               "total": len(cases), "cases": cases, "code_coverage": coverage}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    required_cases = 10 + args.seeds
    verdict = "PASS" if summary["passed"] == summary["total"] and summary["total"] == required_cases and coverage["merged"] else "FAIL"
    (output / "summary.md").write_text(
        f"# APB UART 회귀 검증: {verdict}\n\n"
        f"생성 시각(UTC): {metadata['generated_utc']}  \n"
        f"Verilator: {metadata['verilator']}  \n"
        f"Git 커밋: {metadata['git_commit']}  \n"
        f"소스 SHA-256: `{metadata['source_sha256']}`  \n"
        f"통과 사례: {summary['passed']}/{required_cases}  \n"
        f"무작위 검증: {args.seeds}개 시드, 시드당 APB 전송 최소 {args.transactions}건.  \n"
        f"Verilator RTL 줄 커버리지: {coverage.get('rtl_lines_hit', '집계 불가')}/{coverage.get('rtl_lines_total', '집계 불가')} ({coverage.get('rtl_line_percent', '집계 불가')}%).\n\n"
        "사례별 결과와 로그 경로는 `summary.json`을 확인하세요.\n"
    )
    print(f"{verdict}: 필수 사례 {summary['passed']}/{required_cases}개 통과. 결과 위치: {output}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
