#!/usr/bin/env python3
"""분석용 iCE40 HX8K에 합성·배치·배선을 실행한다. 실물 보드용 핀맵은 아니다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "rtl/sync_fifo.sv", "rtl/uart_tx.sv", "rtl/uart_rx.sv", "rtl/apb_uart.sv",
    "fpga/rtl/apb_uart_echo_master.sv", "fpga/rtl/fpga_uart_demo.sv",
]
OUTPUT = ROOT / "build/timing-reference/latest"
LIMITATIONS = [
    "분석 기준 칩 iCE40 HX8K-CT256의 nextpnr 배치·배선 결과입니다.",
    "실제 보드가 지정되지 않아 I/O 핀을 자동 배치했습니다. 실물용 핀맵이 아닙니다.",
    "내부 클록 경로에 대한 도구의 타이밍 추정입니다. 비동기 UART 입력의 전기 특성/메타안정성을 검증하지 않습니다.",
    "보드 클록/핀/전압/리셋 조건을 확정한 뒤 해당 장치용 구현 및 타이밍 검토를 다시 수행해야 합니다.",
    "프로그래밍용 bitstream 생성 및 FPGA 다운로드, 실물 시험은 수행하지 않습니다.",
]


def digest_files(names: list[str]) -> dict[str, str]:
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in names}


def tool_environment() -> dict[str, str]:
    env = os.environ.copy()
    local = Path(env.get("VERILOG_SYNTHESIS_ROOT", ROOT / "build/synthesis-tools"))
    env["PATH"] = os.pathsep.join([str(local / "bin"), str(local / "root/usr/bin"), env.get("PATH", "")])
    env["LD_LIBRARY_PATH"] = os.pathsep.join([
        str(local / "root/usr/lib/x86_64-linux-gnu"), str(local / "root/usr/lib"),
        env.get("LD_LIBRARY_PATH", ""),
    ])
    if (local / "root/usr/share/yosys").is_dir():
        env["YOSYS_DATDIR"] = str(local / "root/usr/share/yosys")
    return env


def version(command: list[str], env: dict[str, str]) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=20, check=True)
    return (result.stdout + result.stderr).strip()


def run(command: list[str], log: Path, env: dict[str, str], timeout: int = 300) -> None:
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout)
        log.write_text(result.stdout)
    except subprocess.TimeoutExpired as exc:
        contents = exc.stdout or b""
        if isinstance(contents, bytes):
            contents = contents.decode(errors="replace")
        log.write_text(contents + "\nTIMEOUT\n")
        raise RuntimeError(f"제한 시간 초과: {log.relative_to(ROOT)}") from exc
    if result.returncode:
        raise RuntimeError(f"명령 실패(exit={result.returncode}): {log.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clock-hz", type=int, default=50_000_000)
    parser.add_argument("--baud", type=int, default=115_200)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    if args.clock_hz <= 0 or args.baud <= 0 or args.seed < 0:
        parser.error("클록/baud는 양수, seed는 0 이상이어야 합니다")
    if args.clock_hz + args.baud // 2 > 2**31 - 1:
        parser.error("CLK_HZ/BAUD_RATE 계산은 32비트 signed 파라미터 범위여야 합니다")
    divider = (args.clock_hz + args.baud // 2) // args.baud
    if not 4 <= divider <= 65535:
        parser.error("UART 분주값은 4..65535 범위여야 합니다")
    if abs(args.clock_hz / divider / args.baud - 1) > 0.02:
        parser.error("정수 분주 후 baud 오차가 2%를 초과합니다")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in ("summary.json", "README.md", "converted.v", "netlist.json", "routed.asc",
                 "pnr-report.json", "synth-stat.json", "sv2v.log", "synth.log", "pnr.log"):
        (OUTPUT / name).unlink(missing_ok=True)
    start = time.monotonic()
    summary = {
        "status": "failed", "stage": "reference_place_and_route",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "top": "fpga_uart_demo", "device": "iCE40HX8K", "package": "CT256",
        "clock_hz": args.clock_hz, "baud": args.baud, "seed": args.seed,
        "board": None, "pin_assignment": "automatic_reference_only",
        "physical_verified": False, "programming_bitstream_generated": False,
        "limitations": LIMITATIONS,
        "source_files": digest_files(SOURCES + ["scripts/run_timing_reference.py"]),
        "tools": {}, "commands": [], "fmax": {},
    }
    env = tool_environment()
    try:
        for name in ("sv2v", "yosys", "nextpnr-ice40"):
            if not shutil.which(name, path=env["PATH"]):
                raise RuntimeError(f"{name}가 없습니다. bash scripts/setup-synthesis.sh를 실행하세요")
        summary["tools"] = {
            "sv2v": version(["sv2v", "--version"], env),
            "yosys": version(["yosys", "-V"], env),
            "nextpnr": version(["nextpnr-ice40", "--version"], env),
        }
        summary["tool_files_sha256"] = {
            name: hashlib.sha256(Path(shutil.which(name, path=env["PATH"])).read_bytes()).hexdigest()
            for name in ("sv2v", "yosys", "nextpnr-ice40")
        }
        prefix = OUTPUT.relative_to(ROOT).as_posix()
        convert = ["sv2v", "--define=SYNTHESIS", *SOURCES]
        summary["commands"].append(convert)
        result = subprocess.run(convert, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        (OUTPUT / "sv2v.log").write_text(result.stderr)
        if result.returncode or not result.stdout.strip():
            raise RuntimeError("sv2v 변환 실패: build/timing-reference/latest/sv2v.log")
        (OUTPUT / "converted.v").write_text(result.stdout)
        script = "\n".join([
            f"read_verilog {prefix}/converted.v",
            f"chparam -set CLK_HZ {args.clock_hz} -set BAUD_RATE {args.baud} fpga_uart_demo",
            "hierarchy -check -top fpga_uart_demo",
            f"synth_ice40 -top fpga_uart_demo -json {prefix}/netlist.json",
            "check -assert",
            f"tee -o {prefix}/synth-stat.json stat -json",
            "",
        ])
        (OUTPUT / "synth.ys").write_text(script)
        synth = ["yosys", "-Q", "-T", "-s", f"{prefix}/synth.ys"]
        summary["commands"].append(synth)
        run(synth, OUTPUT / "synth.log", env)
        # No connector pins are guessed: the result is solely a reference device analysis.
        (OUTPUT / "reference.pcf").write_text(
            "# Analysis only: no physical board pin assignment.\n"
            f"set_frequency clk {args.clock_hz / 1e6:.6f}\n"
        )
        pnr = [
            "nextpnr-ice40", "--hx8k", "--package", "ct256",
            "--json", f"{prefix}/netlist.json", "--asc", f"{prefix}/routed.asc",
            "--pcf", f"{prefix}/reference.pcf", "--pcf-allow-unconstrained",
            "--freq", f"{args.clock_hz / 1e6:.6f}", "--seed", str(args.seed),
            "--report", f"{prefix}/pnr-report.json", "--detailed-timing-report",
        ]
        summary["commands"].append(pnr)
        run(pnr, OUTPUT / "pnr.log", env)
        report = json.loads((OUTPUT / "pnr-report.json").read_text())
        clocks = report.get("fmax", {})
        summary["fmax"] = clocks
        summary["utilization"] = report.get("utilization", {})
        if not clocks:
            raise RuntimeError("클록 타이밍 결과가 비어 있습니다")
        if not all(v["achieved"] >= v["constraint"] > 0 for v in clocks.values()):
            raise RuntimeError("내부 클록 목표 주파수를 만족하지 못했습니다")
        if digest_files(list(summary["source_files"])) != summary["source_files"]:
            raise RuntimeError("실행 중 RTL/스크립트가 변경되었습니다. 다시 실행하세요")
        summary["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        summary["error"] = str(exc)
    summary["elapsed_seconds"] = round(time.monotonic() - start, 3)
    summary["artifacts"] = {
        name: hashlib.sha256((OUTPUT / name).read_bytes()).hexdigest()
        for name in ("converted.v", "synth.ys", "reference.pcf", "netlist.json", "routed.asc",
                     "synth-stat.json", "pnr-report.json", "sv2v.log", "synth.log", "pnr.log")
        if (OUTPUT / name).exists()
    }
    (OUTPUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    lines = ["# 분석용 FPGA 배치·배선 결과", "", f"결과: **{summary['status']}**", "",
             f"iCE40 HX8K / CT256, 목표 {args.clock_hz / 1e6:g} MHz, seed {args.seed}.", ""]
    for clock, data in summary["fmax"].items():
        lines.append(f"- `{clock}`: nextpnr 추정 최대 주파수 {data['achieved']:.3f} MHz / 목표 {data['constraint']:.3f} MHz")
    lines += ["", *[f"- {item}" for item in LIMITATIONS], ""]
    if summary.get("error"):
        lines += [f"오류: {summary['error']}", ""]
    (OUTPUT / "README.md").write_text("\n".join(lines))
    print(f"TIMING_REFERENCE_{'PASS' if summary['status'] == 'passed' else 'FAIL'}: {OUTPUT.relative_to(ROOT)}/summary.json")
    if summary.get("error"):
        print(summary["error"])
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
