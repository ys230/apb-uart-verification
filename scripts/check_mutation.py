#!/usr/bin/env python3
"""외부 TX 검사기가 알려진 비트 오류 한 가지를 검출하는지 확인한다."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports" / "runs" / "latest"
ORIGINAL = "tx <= frame_data[0];"
MUTATED = "tx <= frame_data[7];"


def run(command: list[str], directory: Path) -> tuple[int, str]:
    try:
        result = subprocess.run(command, cwd=directory, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=600, check=False)
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired as exc:
        captured = exc.stdout or b""
        log = captured.decode(errors="replace") if isinstance(captured, bytes) else captured
        return 124, log + "\n제한 시간 초과: 600초\n"


def main() -> int:
    REPORTS.mkdir(parents=True, exist_ok=True)
    baseline_code, baseline_log = run(["make", "test", "TEST=tx", "WAIT_CYCLES=0"], ROOT)
    (REPORTS / "mutation-baseline.log").write_text(baseline_log)
    if baseline_code != 0 or "TEST_PASS test=tx" not in baseline_log:
        print("기준 TX 테스트가 실패하여 결함 검출 여부를 확인할 수 없습니다.")
        return 1

    with tempfile.TemporaryDirectory(prefix="apb-uart-mutation-") as temporary:
        work = Path(temporary)
        shutil.copy2(ROOT / "Makefile", work / "Makefile")
        for folder in ("rtl", "assertions", "tb"):
            (work / folder).mkdir()
            for source in (ROOT / folder).glob("*.sv"):
                shutil.copy2(source, work / folder / source.name)
        tx_path = work / "rtl" / "uart_tx.sv"
        source = tx_path.read_text()
        if source.count(ORIGINAL) != 1:
            print(f"변경할 TX 비트 대입문이 1개여야 하지만 {source.count(ORIGINAL)}개입니다.")
            return 1
        tx_path.write_text(source.replace(ORIGINAL, MUTATED, 1))
        mutant_code, mutant_log = run(["make", "test", "TEST=tx", "WAIT_CYCLES=0"], work)
    (REPORTS / "mutation-tx-bit.log").write_text(mutant_log)
    detected = mutant_code != 0 and "TX pin mismatch" in mutant_log
    report = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "mutation": {"file": "rtl/uart_tx.sv", "from": ORIGINAL, "to": MUTATED},
        "baseline_exit_code": baseline_code,
        "mutant_exit_code": mutant_code,
        "expected_checker_message": "TX pin mismatch",
        "detected": detected,
    }
    (REPORTS / "mutation-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("MUTATION_PASS: TX 핀 모니터가 잘못된 비트를 검출했습니다" if detected
          else "MUTATION_FAIL: 예상한 TX pin mismatch가 관측되지 않았습니다")
    return 0 if detected else 1


if __name__ == "__main__":
    raise SystemExit(main())
