#!/usr/bin/env python3
"""Ubuntu nextpnr의 고정 chipdb 경로를 로컬 복사본에서만 재배치한다.

설치 시 build/synthesis-tools/bin/nextpnr-ice40로 복사된다. 공식 패키지
바이너리는 변경하지 않는다. 호출자의 작업 디렉터리/인수/종료 코드를 보존한다.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    tools_root = Path(__file__).resolve().parents[1]
    original = tools_root / "root/usr/bin/nextpnr-ice40"
    database = tools_root / "root/usr/share/nextpnr"
    if not (database / "ice40/chipdb-8k.bin").is_file():
        raise RuntimeError(f"nextpnr 칩 데이터베이스가 없습니다: {database}")

    # Ubuntu 빌드의 EXTERNAL_CHIPDB_ROOT는 환경 변수로 바꿀 수 없다.
    # 원본 19바이트 경로를 동일 길이의 /tmp 링크로 바꾼 실행 복사본을 쓴다.
    # 고정 길이 치환이므로 ELF의 오프셋과 코드/데이터 배치는 유지된다.
    old_prefix = b"/usr/share/nextpnr/"
    identifier = digest(str(database).encode())[:10]
    link = Path("/tmp") / f"np-{identifier}"
    new_prefix = (str(link) + "/").encode()
    if len(new_prefix) != len(old_prefix):
        raise RuntimeError("nextpnr 재배치 경로 길이가 예상과 다릅니다")
    data = original.read_bytes()
    if data.count(old_prefix) != 1:
        raise RuntimeError("nextpnr 원본 경로가 정확히 한 번 나타나지 않습니다. 도구 버전을 확인하세요")
    relocated_data = data.replace(old_prefix, new_prefix)

    try:
        link.symlink_to(database, target_is_directory=True)
    except FileExistsError:
        if not link.is_symlink() or link.resolve() != database.resolve():
            raise RuntimeError(f"기존 경로와 충돌합니다. 재배치 링크를 확인하세요: {link}") from None

    executable = tools_root / "bin/nextpnr-ice40.local"
    if not executable.is_file() or executable.read_bytes() != relocated_data:
        temporary = executable.with_name(f"{executable.name}.{os.getpid()}.tmp")
        temporary.write_bytes(relocated_data)
        temporary.chmod(0o755)
        temporary.replace(executable)
    metadata = {
        "method": "one equal-length ELF string replacement in a local executable copy",
        "original_binary": str(original),
        "original_sha256": digest(data),
        "relocated_binary": str(executable),
        "relocated_sha256": digest(relocated_data),
        "old_prefix": old_prefix.decode(),
        "new_prefix": new_prefix.decode(),
        "replacement_count": 1,
        "database_link": str(link),
        "database_directory": str(database),
    }
    (tools_root / "nextpnr-relocation.json").write_text(json.dumps(metadata, indent=2) + "\n")
    os.execv(executable, [str(executable), *sys.argv[1:]])


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"nextpnr 로컬 실행 준비 실패: {error}", file=sys.stderr)
        raise SystemExit(1)
