#!/usr/bin/env python3
"""PTY와 loop:// 로 호스트 검사기를 검증한다. 실제 FPGA를 시험하지 않는다."""

from __future__ import annotations

import importlib.util
import json
import os
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

try:
    import pty
except ImportError:
    pty = None


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/test_fpga_uart.py"
HAS_SERIAL = importlib.util.find_spec("serial") is not None


class SerialPeer:
    """OS 직렬 포트 API를 통과하는 소프트웨어 상대 장치."""

    def __init__(self, mode: str = "echo"):
        self.mode = mode
        self.master, self.slave = pty.openpty()
        self.port = os.ttyname(self.slave)
        self.stopped = threading.Event()
        self.errors = []
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def serve(self):
        first = True
        try:
            while not self.stopped.is_set():
                if not select.select([self.master], [], [], 0.05)[0]:
                    continue
                data = os.read(self.master, 65536)
                if self.mode == "silent":
                    continue
                if self.mode == "mismatch" and first:
                    data = bytes((data[0] ^ 1,)) + data[1:]
                elif self.mode == "missing" and first:
                    data = data[:-1]
                elif self.mode == "extra" and first:
                    data += b"\x99"
                if self.mode == "fragmented" and len(data) > 1:
                    os.write(self.master, data[:1])
                    # Longer than the tester's read poll, shorter than the block deadline.
                    time.sleep(0.07)
                    os.write(self.master, data[1:])
                elif data:
                    os.write(self.master, data)
                first = False
        except OSError as exc:
            if not self.stopped.is_set():
                self.errors.append(exc)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join(timeout=1)
        os.close(self.master)
        os.close(self.slave)
        if self.thread.is_alive():
            raise AssertionError("PTY peer did not stop")
        if self.errors:
            raise AssertionError(self.errors)


@unittest.skipUnless(HAS_SERIAL, "requirements-hardware.txt 설치 필요")
class TesterTests(unittest.TestCase):
    def invoke(self, port: str, *extra: str):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "evidence.json"
            command = [sys.executable, str(SCRIPT), "--port", port, "--bytes", "64",
                       "--chunk-size", "16", "--timeout", "0.5", "--startup-delay", "0",
                       "--quiet-time", "0.02", "--output", str(output), *extra]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                    timeout=8, check=False)
            report = json.loads(output.read_text()) if output.is_file() else None
            return result, report

    def assert_failure(self, result, report, kind: str):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(report["result"], "FAIL")
        self.assertFalse(report["serial_echo_verified"])
        self.assertFalse(report["physical_verified"])
        self.assertIn(kind, [item["kind"] for item in report["errors"]])

    def test_loopback_requires_explicit_software_mode(self):
        result, report = self.invoke("loop://")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(report)

    def test_loopback_has_no_physical_claim_even_with_board_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder) / "dummy.bit"
            artifact.write_bytes(b"software test; not a bitstream")
            result, report = self.invoke("loop://", "--software-loopback", "--bytes", "1024",
                                         "--board-id", "test-board", "--bitstream", str(artifact))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["result"], "PASS")
        self.assertFalse(report["physical_verified"])
        self.assertFalse(report["operator_metadata"]["programmed_image_verified"])
        self.assertEqual(report["backend"], "software_loopback")
        self.assertEqual(report["payload_sha256"], report["received_sha256"])
        self.assertEqual(report["counts"]["bytes_matched"], 1024)
        self.assertEqual(len(report["operator_metadata"]["bitstream_sha256"]), 64)
        self.assertIn("scripts/test_fpga_uart.py", report["source_snapshot"]["files_sha256"])

    def test_open_failure_writes_failure_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            result, report = self.invoke(str(Path(folder) / "nonexistent-port"))
        self.assert_failure(result, report, "io_or_configuration_error")
        self.assertEqual(report["counts"]["bytes_sent"], 0)

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_binary_payload_and_chunk_independent_pattern(self):
        with SerialPeer() as peer:
            result, report = self.invoke(peer.port, "--bytes", "1024", "--seed", "19", "--chunk-size", "7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["backend"], "software_pty")
        self.assertEqual(report["counts"]["bytes_matched"], 1024)
        self.assertFalse(report["physical_verified"])
        second, other = self.invoke("loop://", "--software-loopback", "--bytes", "1024", "--seed", "19")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(report["payload_sha256"], other["payload_sha256"])

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_partial_reads_are_reassembled(self):
        with SerialPeer("fragmented") as peer:
            result, report = self.invoke(peer.port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["counts"]["bytes_matched"], 64)

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_wrong_byte_fails(self):
        with SerialPeer("mismatch") as peer:
            result, report = self.invoke(peer.port)
        self.assert_failure(result, report, "data_mismatch")
        self.assertEqual(report["errors"][0]["offset"], 0)
        self.assertEqual(report["errors"][0]["expected_hex"], "00")
        self.assertEqual(report["errors"][0]["actual_hex"], "01")

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_missing_byte_fails_with_exact_missing_count(self):
        with SerialPeer("missing") as peer:
            result, report = self.invoke(peer.port)
        self.assert_failure(result, report, "read_timeout")
        self.assertEqual(report["errors"][0]["missing_bytes"], 1)

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_silent_peer_times_out(self):
        with SerialPeer("silent") as peer:
            result, report = self.invoke(peer.port, "--timeout", "0.15")
        self.assert_failure(result, report, "read_timeout")
        self.assertEqual(report["counts"]["bytes_received"], 0)

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_extra_byte_fails_after_last_chunk(self):
        with SerialPeer("extra") as peer:
            result, report = self.invoke(peer.port, "--bytes", "16")
        self.assert_failure(result, report, "extra_data")
        self.assertEqual(report["counts"]["extra_bytes_observed"], 1)

    @unittest.skipUnless(pty is not None, "POSIX PTY 필요")
    def test_pty_blocked_write_is_bounded(self):
        master, slave = pty.openpty()
        try:
            result, report = self.invoke(os.ttyname(slave), "--bytes", "65536", "--chunk-size", "65536",
                                         "--timeout", "0.15")
        finally:
            os.close(master)
            os.close(slave)
        self.assert_failure(result, report, "write_timeout")
        self.assertTrue(report["counts"]["tx_count_is_lower_bound"])


if __name__ == "__main__":
    unittest.main()
