#!/usr/bin/env python3
"""설정된 Verilator가 실패하는 SVA를 실제로 실행하는지 확인한다."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "reports" / "runs" / "latest" / "assertion-probe.log"
PROBE = """module assertion_probe;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 1'b0;
    logic ok = 1'b1;
    always #5 clk <= ~clk;
    must_remain_ok: assert property (@(posedge clk) ok)
        else $fatal(1, "EXPECTED_SVA_FAILURE");
    initial begin
        @(negedge clk);
        ok = 1'b0;
        repeat (2) @(posedge clk);
        $finish;
    end
endmodule
"""


def main() -> int:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="apb-uart-sva-probe-") as temporary:
        work = Path(temporary)
        source = work / "assertion_probe.sv"
        source.write_text(PROBE)
        compile_result = subprocess.run(
            ["verilator", "--binary", "--timing", "--assert", "-Wall",
             "--top-module", "assertion_probe", "--Mdir", str(work / "obj"), str(source)],
            cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=180, check=False,
        )
        log = compile_result.stdout
        if compile_result.returncode != 0:
            LOG.write_text(log)
            print(f"SVA_PROBE_FAIL: 컴파일에 실패했습니다. 로그: {LOG}")
            return 1
        run_result = subprocess.run([str(work / "obj" / "Vassertion_probe")], cwd=work,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=30, check=False)
        log += run_result.stdout
    LOG.write_text(log)
    detected = run_result.returncode != 0 and "EXPECTED_SVA_FAILURE" in log
    print("SVA_PROBE_PASS: 의도적으로 거짓인 assertion이 예상대로 실패했습니다" if detected
          else f"SVA_PROBE_FAIL: assertion이 실패하지 않았습니다. 로그: {LOG}")
    return 0 if detected else 1


if __name__ == "__main__":
    raise SystemExit(main())
