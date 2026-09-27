#!/usr/bin/env python3
"""FPGA 준비 단계의 검증을 재실행하고 합성·분석용 타이밍 증거를 모은다."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / "reports/runs/fpga-prep/latest"
DEST = ROOT / "reports/evidence/fpga-prep"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot() -> dict[str, str]:
    files = [ROOT / "Makefile", ROOT / "requirements-hardware.txt", ROOT / ".github/workflows/verify.yml"]
    for pattern in ("rtl/*.sv", "fpga/rtl/*.sv", "tb/*.sv", "assertions/*.sv",
                    "scripts/*.py", "scripts/*.sh", "tests/*.py", "synth/*"):
        files.extend(ROOT.glob(pattern))
    return {path.relative_to(ROOT).as_posix(): sha(path) for path in sorted(set(files)) if path.is_file()}


def portable(text: str) -> str:
    return text.replace(str(ROOT) + "/", "").replace(str(ROOT), ".")


def copy_text(source: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(portable(source.read_text()))


def main() -> int:
    RUN.mkdir(parents=True, exist_ok=True)
    before = snapshot()
    cases = [
        ("rtl-lint", ["make", "lint"], None),
        ("core-regression", ["make", "regress"], "필수 사례 30/30개 통과"),
        ("fpga-lint", ["make", "lint-fpga"], None),
        ("fpga-wait0", ["make", "test-fpga", "WAIT_CYCLES=0"], "FPGA_DEMO_PASS wait=0 echoed=261"),
        ("fpga-wait3", ["make", "test-fpga", "WAIT_CYCLES=3"], "FPGA_DEMO_PASS wait=3 echoed=261"),
        ("host-checker", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_fpga_uart.py", "-v"], "\nOK\n"),
        ("generic-synthesis", [sys.executable, "scripts/run_synthesis.py"], "SYNTH_PASS"),
        ("generic-synthesis-depth5", [sys.executable, "scripts/run_synthesis.py", "--wait-cycles", "3", "--fifo-depth", "5"], "SYNTH_PASS"),
        ("reference-timing", [sys.executable, "scripts/run_timing_reference.py"], "TIMING_REFERENCE_PASS"),
    ]
    summary = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "RTL simulation, generic synthesis and reference FPGA place-and-route; no physical board test",
        "physical_board_test": "not_run", "board_model": None,
        "source_files": before, "cases": [], "passed": False,
    }
    for name, command, marker in cases:
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=600)
            output, code = result.stdout, result.returncode
        except subprocess.TimeoutExpired as exc:
            output = exc.stdout or b""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            output += "\nTIMEOUT\n"
            code = 124
        except OSError as exc:
            output, code = str(exc), 127
        (RUN / f"{name}.log").write_text(output)
        passed = code == 0 and (marker is None or marker in output)
        summary["cases"].append({"name": name, "command": command, "exit_code": code,
                                 "passed": passed, "seconds": round(time.monotonic() - started, 3),
                                 "log": f"logs/{name}.log"})
        print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)
        if not passed:
            summary["error"] = f"실패 로그: {RUN.relative_to(ROOT)}/{name}.log"
            break
    summary["inputs_unchanged"] = before == snapshot()
    summary["passed"] = (len(summary["cases"]) == len(cases) and
                         all(case["passed"] for case in summary["cases"]) and summary["inputs_unchanged"])
    (RUN / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    if not summary["passed"]:
        print(summary.get("error", "실행 중 소스 변경: 증거 게시를 중단했습니다"))
        return 1

    generic_dir = ROOT / "build/synth/apb_uart-wait0-depth16"
    alternate_dir = ROOT / "build/synth/apb_uart-wait3-depth5"
    timing_dir = ROOT / "build/timing-reference/latest"
    generic = json.loads((generic_dir / "summary.json").read_text())
    timing = json.loads((timing_dir / "summary.json").read_text())
    if not generic["passed"] or timing["status"] != "passed":
        raise SystemExit("합성/타이밍 결과의 통과 상태가 일치하지 않습니다")

    # Build the complete evidence in a staging directory, then replace the known destination.
    staging = RUN / "published"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    for case in summary["cases"]:
        copy_text(RUN / f"{case['name']}.log", staging / case["log"])
    for directory, folder in ((generic_dir, "synthesis"), (alternate_dir, "synthesis-depth5")):
        for name in ("summary.json", "stat.json", "yosys.log", "sv2v.log", "run.ys"):
            copy_text(directory / name, staging / folder / name)
    for name in ("summary.json", "synth-stat.json", "pnr-report.json", "synth.log", "pnr.log", "reference.pcf", "synth.ys"):
        copy_text(timing_dir / name, staging / "timing" / name)
    for name in ("package-manifest.tsv", "nextpnr-relocation.json"):
        path = ROOT / "build/synthesis-tools" / name
        if path.exists():
            copy_text(path, staging / name)

    fmax_lines = "\n".join(
        f"- `{clock}`: nextpnr 추정 최대 주파수 **{data['achieved']:.3f} MHz**, 목표 {data['constraint']:.3f} MHz."
        for clock, data in timing["fmax"].items()
    )
    test_log = (RUN / "host-checker.log").read_text()
    count = re.search(r"Ran (\d+) tests?", test_log)
    checker_count = count.group(1) if count else "로그 참고"
    cells = generic["cell_counts"]
    summary["generic_cells"] = cells
    summary["reference_fmax"] = timing["fmax"]
    readme = f"""# 합성 및 FPGA 시험 준비 증거

실행 시각(UTC): {summary['generated_utc']}

**실물 FPGA 시험은 아직 실행하지 않았습니다.** 아래 타이밍은 iCE40 HX8K / CT256을 분석용 칩으로 지정한 배치·배선 결과입니다. 실제 보드 핀을 지정하지 않아 I/O는 자동 배치됐습니다. 보드용 타이밍 승인 또는 보드 동작 결과로 사용할 수 없습니다.

| 검사 | 실행 결과 |
|---|---|
| 기존 RTL lint 및 전체 회귀 | 통과, 기존 회귀 30/30 |
| FPGA echo 회로 시뮬레이션 | APB 대기 0/3에서 각각 261바이트 핀 왕복, reset 중단·framing 오류·APB 오류 검출 |
| PC UART 검사기 | 소프트웨어 PTY/loopback 및 실패 주입 {checker_count}건 통과; 실물 결과 아님 |
| 범용 합성 | {cells['total']} Boolean/FF 셀, FF {cells['flip_flops']}비트, 래치 {cells['latches']}개 |
| 추가 파라미터 합성 | FIFO 깊이 5 / APB 대기 3도 통과 |
| 기준 FPGA 구현 | echo 회로 포함, 목표 {timing['clock_hz'] / 1e6:g} MHz, seed {timing['seed']}에서 배치·배선 통과 |

{fmax_lines}

범용 합성 셀 수는 FPGA LUT 수와 다릅니다. FIFO 메모리가 레지스터로 펼쳐진다는 Yosys 경고는 현재 구현의 합성 결과이며 [전체 합성 로그](synthesis/yosys.log)에 보존했습니다. [합성 요약](synthesis/summary.json)과 [FPGA 타이밍 요약](timing/summary.json), [nextpnr 경로/자원 보고서](timing/pnr-report.json)를 함께 확인하세요. WNS/TNS 또는 보드의 실측 최대 주파수는 보고하지 않습니다.

[전체 실행/소스 해시](summary.json), [테스트 로그](logs/), [설치 패키지 기록](package-manifest.tsv)에 재현 근거가 있습니다. 게시한 텍스트의 로컬 경로는 상대 경로로 바꿨으며 `summary.json`의 `published_files_sha256`는 이 게시본의 해시입니다. 각 도구 요약 안의 `artifacts` 해시는 `build/`에 생성된 원본 산출물에 해당합니다.

재생성: [실행 안내](../../../docs/fpga-validation.md)를 따라 도구를 준비한 뒤 `make fpga-evidence`를 실행합니다. 이 명령은 9개 검증 단계를 새로 실행하고 모두 통과할 때 자료를 갱신합니다. 실물 완료 조건과 필요한 보드 정보도 해당 안내에 있습니다.
"""
    (staging / "README.md").write_text(readme)
    summary["published_files_sha256"] = {path.relative_to(staging).as_posix(): sha(path)
                                         for path in sorted(staging.rglob("*")) if path.is_file()}
    (staging / "summary.json").write_text(portable(json.dumps(summary, ensure_ascii=False, indent=2)) + "\n")
    DEST.parent.mkdir(parents=True, exist_ok=True)
    if DEST.exists():
        shutil.rmtree(DEST)
    shutil.copytree(staging, DEST)
    print(f"FPGA_PREP_EVIDENCE_PASS: {DEST.relative_to(ROOT)}/README.md (실물 시험 미실행)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
