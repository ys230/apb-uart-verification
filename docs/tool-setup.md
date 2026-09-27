# 로컬 시뮬레이션 도구 설치

합성 및 분석용 FPGA 배치·배선 도구는 [별도 실행 안내](fpga-validation.md#2-지금-pc에서-실행하기)에 따라 `bash scripts/setup-synthesis.sh`로 설치합니다. 이 문서는 Verilator와 파형 뷰어 설치를 설명합니다.

이 프로젝트는 Verilator, GNU Make, C++ 컴파일러를 사용합니다. Ubuntu 26.04 amd64 환경(WSL2 포함)에서는 다음 명령으로 `sudo` 없이 프로젝트 내부에 도구를 설치할 수 있습니다.

```bash
bash scripts/setup-toolchain.sh
source build/toolchain/env.sh
verilator --version
make --version
g++ --version
```

설치에는 `apt-get`, `dpkg-deb`, `python3`, Ubuntu 저장소 서명 키, 공식 Ubuntu 저장소에 접속할 인터넷 연결, 약 500 MB의 여유 공간이 필요합니다. 스크립트는 Ubuntu 패키지를 `build/toolchain/apt`에 내려받고, APT를 통해 저장소 서명과 패키지 해시를 검증한 뒤 필요한 도구를 `build/toolchain/root`에 압축 해제합니다. 내려받은 패키지의 정확한 버전과 SHA-256 해시는 `build/toolchain/package-manifest.tsv`에 기록됩니다. 시스템에 설치된 패키지는 변경하지 않습니다.

다른 쓰기 가능 경로에 설치하려면 첫 번째 인수로 그 경로를 전달하세요.

```bash
bash scripts/setup-toolchain.sh /path/to/toolchain
source /path/to/toolchain/env.sh
```

`env.sh`는 **현재 셸**의 `PATH`, `VERILATOR_ROOT`, `LD_LIBRARY_PATH`, `LIBRARY_PATH`를 설정합니다. 새 터미널이나 셸을 열면 이 설정이 이어지지 않으므로, 프로젝트 빌드 명령을 실행하기 전에 `source build/toolchain/env.sh`를 다시 실행하세요. 설치 스크립트를 재실행하면 패키지 목록을 갱신하고 그때의 패키지 버전을 내려받습니다.

이 스크립트는 Ubuntu 26.04 amd64와 설치된 Ubuntu 저장소 키링을 대상으로 합니다. 다른 배포판이나 CPU 아키텍처에서는 해당 환경에 맞는 패키지 저장소와 도구 모음이 필요합니다. 이전의 `/tmp/verilog-toolchain`은 임시 시험 설치였고, 위 절차는 도구를 지속적으로 사용할 수 있는 쓰기 가능 경로에 설치합니다.

## 선택 사항: GTKWave 파형 뷰어

GUI가 준비된 Ubuntu/WSL 환경에서는 다음 명령으로 GTKWave를 프로젝트의 `build/viewer/` 아래에 설치하고 TX 파형을 열 수 있습니다. 이 설치도 `sudo` 없이 서명된 Ubuntu 패키지를 사용합니다. 기본 도구 설치를 먼저 마쳐야 합니다.

```bash
bash scripts/setup-gtkwave.sh
build/viewer/bin/gtkwave reports/evidence/v0.2/tx.vcd reports/evidence/v0.2/tx.gtkw
```

설치 버전과 패키지 해시는 `build/viewer/package-manifest.tsv`에 남습니다. `rx.vcd`/`rx.gtkw`와 `apb.vcd`/`apb.gtkw`도 같은 방식으로 열 수 있습니다. `.gtkw` 파일은 파형 파일이 아니라 GTKWave에서 표시할 신호와 처음 보여 줄 시간 구간을 저장합니다. 화면이 평평하면 상단 눈금이 ps 단위로 지나치게 확대되어 있는지 확인하고, 붙여넣기 다음 `+` 왼쪽의 **Zoom Fit** 아이콘 또는 `Ctrl+0`으로 전체 시간을 표시하세요. `DISPLAY`가 설정된 GUI 터미널에서 실행해야 창이 보입니다. 원본 VCD를 새로 생성하려면 저장소 최상위 디렉터리에서 `make waves TEST=tx`를 실행하세요.
