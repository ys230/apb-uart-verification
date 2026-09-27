#!/usr/bin/env python3
"""FPGA UART echo를 검사한다. PASS만으로 실제 FPGA 연결을 증명하지는 않는다."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXED_PATTERN = bytes((0x00, 0xFF, 0x55, 0xAA)) + bytes(range(256)) + bytes(reversed(range(256)))


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("0보다 큰 정수가 필요합니다")
    return number


def positive_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("0보다 큰 유한한 수가 필요합니다")
    return number


def nonnegative_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("0 이상의 유한한 수가 필요합니다")
    return number


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="실제 장치 경로, 예: /dev/ttyUSB0 또는 COM3")
    parser.add_argument("--baud", type=positive_int, default=115200)
    parser.add_argument("--bytes", dest="byte_count", type=positive_int, default=4096,
                        help="전체 시험 바이트 수 (기본 4096)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--chunk-size", type=positive_int, default=16,
                        help="한 블록을 보내고 echo를 모두 받은 뒤 다음 블록 전송 (기본 16)")
    parser.add_argument("--timeout", type=positive_float, default=2.0,
                        help="블록별 송신+수신 제한 시간, 초 (기본 2)")
    parser.add_argument("--startup-delay", type=nonnegative_float, default=0.1,
                        help="포트 개방 후 초기화 대기, 초 (기본 0.1)")
    parser.add_argument("--quiet-time", type=positive_float, default=0.1,
                        help="마지막 수신 뒤 추가 데이터 검사 시간, 초 (기본 0.1)")
    parser.add_argument("--board-id", help="작업자가 입력하는 보드 식별자; 자동 검증되지 않음")
    parser.add_argument("--bitstream", type=Path, help="프로그래밍에 사용한 파일; SHA256 기록용")
    parser.add_argument("--output", type=Path, default=ROOT / "reports/runs/hardware/uart_echo.json")
    parser.add_argument("--software-loopback", action="store_true",
                        help="loop:// 소프트웨어 자기 검사용; FPGA 실물 증거가 아님")
    args = parser.parse_args(argv)
    if args.port == "loop://" and not args.software_loopback:
        parser.error("loop:// 는 --software-loopback 명시가 필요합니다")
    if args.software_loopback and args.port != "loop://":
        parser.error("--software-loopback 은 --port loop:// 와 함께 사용합니다")
    if "://" in args.port and args.port != "loop://":
        parser.error("로컬 직렬 포트와 명시적인 loop:// 자기 검사만 지원합니다")
    return args


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def git_output(*args: str) -> str | None:
    try:
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True,
                                text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def source_snapshot() -> dict:
    paths = {Path(__file__).resolve(), *ROOT.glob("rtl/*.sv"), *ROOT.glob("fpga/**/*.sv")}
    requirements = ROOT / "requirements-hardware.txt"
    if requirements.is_file():
        paths.add(requirements)
    files = {str(path.relative_to(ROOT)): sha256(path) for path in sorted(paths)}
    manifest = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    status = git_output("status", "--porcelain")
    return {"git_commit": git_output("rev-parse", "HEAD"),
            "git_dirty": status != "" if status is not None else None,
            "files_sha256": files, "manifest_sha256": hashlib.sha256(manifest).hexdigest()}


def payload_chunks(count: int, size: int, seed: int):
    rng = random.Random(seed)
    for offset in range(0, count, size):
        yield offset, bytes(FIXED_PATTERN[i] if i < len(FIXED_PATTERN) else rng.randrange(256)
                            for i in range(offset, min(count, offset + size)))


def backend_kind(port: str) -> str:
    if port == "loop://":
        return "software_loopback"
    if str(Path(port).resolve()).startswith("/dev/pts/"):
        return "software_pty"
    return "serial_port_identity_unverified"


def initial_report(args: argparse.Namespace) -> dict:
    return {
        "schema_version": 1, "test": "fpga_uart_echo", "started_utc": datetime.now(timezone.utc).isoformat(),
        "result": "FAIL", "serial_echo_verified": False, "physical_verified": False,
        "verification_scope": "chunked_serial_echo_only",
        "physical_verification_note": "echo 성공은 FPGA 연결/프로그램 이미지의 신원을 증명하지 않음; 별도 배선·프로그래밍 기록 필요",
        "backend": backend_kind(args.port),
        "operator_metadata": {"board_id": args.board_id, "bitstream_path": str(args.bitstream) if args.bitstream else None,
                              "bitstream_sha256": None, "programmed_image_verified": False},
        "host": {"platform": platform.platform(), "python": platform.python_version()},
        "configuration": {"port": args.port, "baud": args.baud, "data_bits": 8, "parity": "N", "stop_bits": 1,
                          "rtscts": False, "xonxoff": False, "dsrdtr": False, "seed": args.seed,
                          "requested_bytes": args.byte_count, "chunk_size": args.chunk_size,
                          "chunk_timeout_seconds": args.timeout, "startup_delay_seconds": args.startup_delay,
                          "extra_data_observation_seconds": args.quiet_time,
                          "pattern": "00 ff 55 aa; ascending 00..ff; descending ff..00; seeded Random.randrange(256)",
                          "load_model": "stop_and_wait; continuous full-rate stress is not tested"},
        "counts": {"bytes_sent": 0, "bytes_received": 0, "bytes_matched": 0, "chunks_passed": 0,
                   "mismatched_bytes_observed": 0, "extra_bytes_observed": 0, "startup_bytes_discarded": 0,
                   "tx_count_is_lower_bound": False},
        "errors": [],
    }


def transfer(port, args: argparse.Namespace, report: dict, serial_module) -> None:
    counts = report["counts"]
    payload_digest = hashlib.sha256()
    received_digest = hashlib.sha256()
    for offset, expected in payload_chunks(args.byte_count, args.chunk_size, args.seed):
        payload_digest.update(expected)
        deadline = time.monotonic() + args.timeout
        written = 0
        while written < len(expected):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                report["errors"].append({"kind": "write_timeout", "offset": offset + written})
                return
            port.write_timeout = remaining
            try:
                progress = port.write(expected[written:])
            except serial_module.SerialTimeoutException:
                counts["tx_count_is_lower_bound"] = True
                report["errors"].append({"kind": "write_timeout", "offset": offset + written})
                return
            written += progress
            counts["bytes_sent"] += progress
            if not progress:
                time.sleep(min(0.001, max(0, deadline - time.monotonic())))
        # flush() can wait indefinitely on some backends; receiving the echo is the completion check.
        actual = bytearray()
        while len(actual) < len(expected):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            port.timeout = min(remaining, 0.05)
            block = port.read(len(expected) - len(actual))
            actual.extend(block)
            counts["bytes_received"] += len(block)
        received_digest.update(actual)
        mismatches = [(i, a, b) for i, (a, b) in enumerate(zip(expected, actual)) if a != b]
        counts["mismatched_bytes_observed"] += len(mismatches)
        counts["bytes_matched"] += len(actual) - len(mismatches)
        if mismatches:
            first, wanted, observed = mismatches[0]
            report["errors"].append({"kind": "data_mismatch", "offset": offset + first,
                                     "expected_hex": f"{wanted:02x}", "actual_hex": f"{observed:02x}",
                                     "mismatches_in_chunk": len(mismatches)})
        if len(actual) != len(expected):
            report["errors"].append({"kind": "read_timeout", "chunk_offset": offset,
                                     "expected_bytes": len(expected), "received_bytes": len(actual),
                                     "missing_bytes": len(expected) - len(actual)})
        if report["errors"]:
            return
        counts["chunks_passed"] += 1
    report["payload_sha256"] = payload_digest.hexdigest()
    report["received_sha256"] = received_digest.hexdigest()
    # Observe for one bounded window. This cannot exclude bytes arriving after that window.
    port.timeout = args.quiet_time
    extra = port.read(1)
    if extra:
        available = min(port.in_waiting, 4095)
        port.timeout = 0
        extra += port.read(available)
        counts["bytes_received"] += len(extra)
        counts["extra_bytes_observed"] += len(extra)
        report["errors"].append({"kind": "extra_data", "observed_bytes_at_least": len(extra),
                                 "first_bytes_hex": extra[:16].hex()})


def run(args: argparse.Namespace) -> dict:
    report = initial_report(args)
    started = time.monotonic()
    try:
        import serial

        report["software"] = {"pyserial_version": serial.VERSION,
                              "tester_sha256": sha256(Path(__file__)),
                              "pyserial_init_sha256": sha256(Path(serial.__file__))}
        report["source_snapshot"] = source_snapshot()
        if args.bitstream:
            report["operator_metadata"]["bitstream_sha256"] = sha256(args.bitstream)
        # Hardware flow control is disabled; opening a USB serial adapter may still toggle DTR/RTS.
        with serial.serial_for_url(args.port, baudrate=args.baud, bytesize=serial.EIGHTBITS,
                                   parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                                   timeout=args.timeout, write_timeout=args.timeout,
                                   xonxoff=False, rtscts=False, dsrdtr=False) as port:
            time.sleep(args.startup_delay)
            report["counts"]["startup_bytes_discarded"] = port.in_waiting
            port.reset_input_buffer()
            transfer(port, args, report, serial)
        if not report["errors"]:
            report["result"] = "PASS"
            report["serial_echo_verified"] = True
    except ImportError as exc:
        report["errors"].append({"kind": "dependency_missing", "message": str(exc)})
    except (OSError, ValueError) as exc:
        report["errors"].append({"kind": "io_or_configuration_error", "message": str(exc)})
    except KeyboardInterrupt:
        report["errors"].append({"kind": "interrupted"})
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    report["elapsed_seconds"] = round(time.monotonic() - started, 6)
    return report


def main(argv: list[str] | None = None) -> int:
    args = arguments(argv)
    report = run(args)
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(args.output.name + ".tmp")
        temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(args.output)
    except OSError as exc:
        print(f"UART_ECHO_FAIL: 결과 파일 저장 실패: {exc}", file=sys.stderr)
        return 2
    counts = report["counts"]
    print(f"UART_ECHO_{report['result']}: sent={counts['bytes_sent']} received={counts['bytes_received']} "
          f"matched={counts['bytes_matched']} backend={report['backend']}")
    print(f"결과: {args.output}")
    print("physical_verified=false: 실제 FPGA 연결과 프로그래밍은 별도 기록으로 확인해야 합니다.")
    for error in report["errors"]:
        print(json.dumps(error, ensure_ascii=False), file=sys.stderr)
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
