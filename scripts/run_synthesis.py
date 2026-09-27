#!/usr/bin/env python3
"""sv2v와 Yosys로 범용 셀 합성 및 구조 검사를 실행하고 실제 결과를 기록한다."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCES = ["rtl/sync_fifo.sv", "rtl/uart_tx.sv", "rtl/uart_rx.sv", "rtl/apb_uart.sv"]
TEMPLATE = ROOT / "synth/generic.ys.in"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def input_hashes(paths: list[Path]) -> dict[str, str]:
    return {relative(path): sha256(path) for path in paths}


def environment() -> dict[str, str]:
    """소스 환경 적용을 잊어도 저장소의 로컬 설치본을 찾는다."""
    env = os.environ.copy()
    local = Path(env.get("VERILOG_SYNTHESIS_ROOT", ROOT / "build/synthesis-tools"))
    if (local / "env.sh").is_file():
        env["PATH"] = f"{local / 'bin'}:{local / 'root/usr/bin'}:{env.get('PATH', '')}"
        env["LD_LIBRARY_PATH"] = (
            f"{local / 'root/usr/lib/x86_64-linux-gnu'}:{local / 'root/usr/lib'}:"
            + env.get("LD_LIBRARY_PATH", "")
        )
        env["YOSYS_DATDIR"] = str(local / "root/usr/share/yosys")
    return env


def run(command: list[str], env: dict[str, str], log: Path, output: Path | None = None,
        cwd: Path = ROOT) -> None:
    with log.open("w") as errors:
        if output is None:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=errors,
                                    stderr=subprocess.STDOUT, check=False)
        else:
            with output.open("w") as converted:
                result = subprocess.run(command, cwd=cwd, env=env, stdout=converted,
                                        stderr=errors, check=False)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} 종료 코드 {result.returncode}: {relative(log)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", default="apb_uart")
    parser.add_argument("--sources", nargs="+", default=DEFAULT_SOURCES,
                        help="저장소 최상위 기준 RTL 경로")
    parser.add_argument("--wait-cycles", type=int, default=0)
    parser.add_argument("--fifo-depth", type=int, default=16)
    parser.add_argument("--parameter", action="append", default=[], metavar="NAME=INTEGER",
                        help="상위 모듈 매개변수(반복 지정 가능)")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.top):
        parser.error("--top은 단순 Verilog 모듈 이름이어야 합니다")
    if args.wait_cycles < 0 or args.fifo_depth < 1:
        parser.error("WAIT_CYCLES는 0 이상, FIFO_DEPTH는 1 이상이어야 합니다")
    parameters = {"WAIT_CYCLES": args.wait_cycles, "FIFO_DEPTH": args.fifo_depth} if args.top == "apb_uart" else {}
    for item in args.parameter:
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(-?[0-9]+)", item)
        if not match:
            parser.error("--parameter 형식은 NAME=INTEGER입니다")
        parameters[match[1]] = int(match[2])
    if args.top == "apb_uart" and (parameters["WAIT_CYCLES"] < 0 or parameters["FIFO_DEPTH"] < 1):
        parser.error("WAIT_CYCLES는 0 이상, FIFO_DEPTH는 1 이상이어야 합니다")
    sources = [(ROOT / value).resolve() for value in args.sources]
    for source in sources:
        if not source.is_file():
            parser.error(f"RTL 소스가 없습니다: {source}")

    suffix = f"-wait{parameters['WAIT_CYCLES']}-depth{parameters['FIFO_DEPTH']}" if args.top == "apb_uart" else ""
    output = (args.output_dir or ROOT / "build/synth" / (args.top + suffix)).resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary_path = output / "summary.json"
    files = [*sources, Path(__file__).resolve(), TEMPLATE]
    before = input_hashes(files)
    summary: dict = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        "passed": False,
        "flow": "sv2v -> Yosys generic synth -> check -assert -> no latches",
        "top": args.top,
        "parameters": parameters,
        "sources": input_hashes(sources),
        "inputs": before,
        "input_sha256": hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(),
        "scope": "Generic Boolean cells; no target FPGA, pin constraints, placement, routing or static timing analysis.",
        "timing": {"performed": False, "fmax_mhz": None, "slack_ns": None},
        "board_test": {"performed": False},
        "tools": {},
        "commands": [],
    }
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    generated = ["converted.v", "sv2v.log", "yosys.log", "run.ys", "stat.json", "netlist.json", "netlist.v"]
    for name in generated:
        (output / name).unlink(missing_ok=True)

    try:
        env = environment()
        executables = {}
        for name, flag in (("sv2v", "--version"), ("yosys", "-V")):
            executable = shutil.which(name, path=env["PATH"])
            if not executable:
                raise RuntimeError(f"{name}이 없습니다. bash scripts/setup-synthesis.sh를 먼저 실행하세요")
            executable_path = Path(executable).resolve()
            result = subprocess.run([executable, flag], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
            summary["tools"][name] = {
                "version": result.stdout.strip(),
                "path": relative(executable_path),
                "sha256": sha256(executable_path),
            }
            executables[name] = executable

        converted = output / "converted.v"
        command = [executables["sv2v"], "-D", "SYNTHESIS", *[str(source) for source in sources]]
        summary["commands"].append(command)
        run(command, env, output / "sv2v.log", converted)
        replacements = {
            # tee -o는 따옴표를 파일명의 일부로 처리하므로 출력 디렉터리에서
            # 고정된 상대 파일명으로 실행한다. 작업 경로에 공백이 있어도 안전하다.
            "@CONVERTED@": "converted.v",
            "@TOP@": args.top,
            "@PARAMETERS@": " ".join(f"-chparam {key} {value}" for key, value in parameters.items()),
            "@STAT@": "stat.json",
            "@NETLIST_JSON@": "netlist.json",
            "@NETLIST_VERILOG@": "netlist.v",
        }
        script = TEMPLATE.read_text()
        for key, value in replacements.items():
            script = script.replace(key, value)
        (output / "run.ys").write_text(script)
        command = [executables["yosys"], "-Q", "-T", "-s", str(output / "run.ys")]
        summary["commands"].append(command)
        run(command, env, output / "yosys.log", cwd=output)

        stats = json.loads((output / "stat.json").read_text())
        top_stats = stats["modules"]["\\" + args.top]
        cell_types = top_stats["num_cells_by_type"]
        summary["statistics"] = top_stats
        summary["cell_counts"] = {
            "total": top_stats["num_cells"],
            "flip_flops": sum(count for cell, count in cell_types.items() if "DFF" in cell.upper()),
            "latches": sum(count for cell, count in cell_types.items() if "LATCH" in cell.upper()),
        }
        summary["warnings"] = [line for line in (output / "yosys.log").read_text().splitlines()
                               if line.startswith("Warning:")]
        if summary["cell_counts"]["latches"]:
            raise RuntimeError("예상하지 않은 래치가 합성되었습니다")
        if input_hashes(files) != before:
            raise RuntimeError("합성 실행 중 입력 소스가 변경되었습니다. 다시 실행하세요")
        summary["checks"] = {"hierarchy": True, "structural_check": True, "no_latches": True,
                             "inputs_unchanged": True}
        summary["artifacts"] = {name: {"path": relative(output / name), "sha256": sha256(output / name)}
                                for name in generated}
        manifest = ROOT / "build/synthesis-tools/package-manifest.tsv"
        if manifest.is_file():
            summary["package_manifest"] = {"path": relative(manifest), "sha256": sha256(manifest)}
        summary["status"] = "passed"
        summary["passed"] = True
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
    finally:
        summary["finished_utc"] = datetime.now(timezone.utc).isoformat()
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")

    if not summary["passed"]:
        print(f"SYNTH_FAIL: {summary['error']}\n요약: {relative(summary_path)}", file=sys.stderr)
        return 1
    counts = summary["cell_counts"]
    print(f"SYNTH_PASS top={args.top} cells={counts['total']} flip_flops={counts['flip_flops']} latches=0")
    print(f"결과: {relative(summary_path)}\n범용 셀 합성 결과이며 FPGA 자원 수·타이밍·보드 동작 측정이 아닙니다.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
