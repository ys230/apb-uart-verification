# APB3 UART RTL 및 검증

SystemVerilog로 설계한 APB3 UART와 결과를 스스로 판정하는 SystemVerilog 테스트벤치입니다. APB 쓰기로 입력한 데이터는 `uart_tx`에서 8N1 파형으로 송신됩니다. 독립적인 직렬 입력으로 받은 데이터는 RX FIFO를 거쳐 APB에서 읽을 수 있습니다.

**현재 상태: v0.2 로컬 검증 완료.** 고정된 seed 20개에서 각각 랜덤 APB 동작 1,000건을 실행한 것을 포함해 회귀 시험 30건을 모두 통과했습니다. [검증 증거](reports/evidence/v0.2/README.md)에 로그, 커버리지, 파형, TX 핀 모니터가 발견한 의도적 결함이 있습니다. 구현 범위는 [v0.2 로드맵](docs/roadmap.md), [사양](docs/specification.md), [검증 계획](docs/verification-plan.md)에 정리했습니다. [최초 제안서](IMPLEMENTATION_PLAN.md)도 참고용으로 보관합니다.

## 설계 구성

```text
APB3 마스터 -> 레지스터 -> TX FIFO -> UART TX -> 외부 핀 모니터
독립 직렬 입력 -> UART RX -> RX FIFO -> 레지스터 -> APB3 마스터
```

설계는 하나의 `PCLK`, 2단 RX 동기화기, 설정 가능한 APB 대기 사이클, 명시적인 오류 응답을 사용합니다. 레지스터 맵은 `CTRL`, `STATUS`, `SCRATCH`, `BAUD_DIV`, `TXDATA`, `RXDATA`로 구성됩니다. 정확한 주소와 경계 조건은 [사양](docs/specification.md)을 참고하세요.

## 처음 실행하기

복제한 저장소의 최상위 디렉터리로 이동한 뒤 아래 명령을 순서대로 실행하세요. 이 저장소에서 사용한 Ubuntu 26.04 amd64 환경(WSL 포함)에서는 다음 설치 스크립트를 사용할 수 있습니다. 다른 환경에서는 Verilator, C++ 컴파일러, GNU Make, Python 3을 준비해야 합니다. 설치 조건과 다른 설치 위치를 지정하는 방법은 [도구 설치 안내](docs/tool-setup.md)에 있습니다.

```sh
bash scripts/setup-toolchain.sh
source build/toolchain/env.sh
verilator --version
make --version
g++ --version
```

[`scripts/setup-toolchain.sh`](scripts/setup-toolchain.sh)는 Ubuntu 패키지를 다운로드해 `build/toolchain/` 아래에 풀고, 사용할 실행 파일과 라이브러리 경로를 담은 `env.sh`를 만듭니다. 시스템 패키지를 변경하거나 `sudo`를 요구하지 않습니다. 설치에 네트워크와 약 500 MB의 빈 공간이 필요합니다. 설치한 패키지의 버전과 SHA-256은 `build/toolchain/package-manifest.tsv`에 기록됩니다. 설치는 처음 한 번이면 되지만, **새 터미널을 열 때마다** `source build/toolchain/env.sh`를 다시 실행해야 합니다. `source`가 현재 셸의 `PATH`, `VERILATOR_ROOT`, 라이브러리 경로를 설정하며, 이 설정은 새 셸로 자동 전달되지 않습니다. 세 버전 명령으로 현재 셸에서 도구를 찾을 수 있는지 확인할 수 있습니다.

## 검증 명령과 결과 확인

다음 명령은 위 환경을 불러온 셸에서, 저장소 최상위 디렉터리에서 실행합니다. 앞의 명령이 성공한 뒤 다음 명령으로 진행하세요.

```sh
make lint
make test-fifo
make test TEST=all WAIT_CYCLES=0
make test TEST=tx WAIT_CYCLES=3 SEED=1
make regress
make mutation
python3 scripts/probe_assertions.py
python3 scripts/publish_evidence.py
```

| 명령 | 확인하는 내용 | 성공 표시와 결과 위치 |
|---|---|---|
| `make lint` | RTL과 연결된 SVA 및 테스트벤치의 Verilator `-Wall` 문법·경고 검사 | 오류 없이 종료되면 성공입니다. |
| `make test-fifo` | FIFO의 비어 있음·가득 참·동시 push/pop·포인터 순환 동작 | 출력에 `FIFO_TEST_PASS`가 표시됩니다. 실행 파일은 `build/fifo/`에 생성됩니다. |
| `make test TEST=all WAIT_CYCLES=0` | APB, TX, RX, 랜덤 시험을 한 번에 실행하며 APB 대기 사이클은 0으로 설정 | 출력의 `TEST_PASS test=all`을 확인합니다. 기본 랜덤 APB 목표는 1,000건입니다. |
| `make test TEST=tx WAIT_CYCLES=3 SEED=1` | APB 대기 사이클 3, seed 1에서 TX 지정 시험 실행 | 출력의 `TEST_PASS test=tx`를 확인합니다. `TEST`에는 `apb`, `tx`, `rx`, `random`, `all`을 지정할 수 있습니다. |
| `make regress` | FIFO 1건, 대기 사이클 0/1/3의 APB·TX·RX 지정 시험 9건, 고정 seed 20개의 랜덤 시험을 실행 | 마지막 줄의 `PASS: 필수 사례 30/30개 통과`를 확인합니다. 개별 로그와 `summary.json`, `summary.md`, 합친 `coverage.info`는 `reports/runs/latest/`에 있습니다. |
| `make mutation` | 임시 RTL 복사본의 TX 데이터 비트 하나를 바꾸어 핀 모니터의 결함 검출 능력을 확인 | 원본 시험은 통과하고 변경된 복사본의 시험은 `TX pin mismatch`로 실패해야 전체 결과가 `MUTATION_PASS`입니다. 로그와 `mutation-summary.json`은 `reports/runs/latest/`에 있습니다. 프로젝트 RTL은 변경하지 않습니다. |
| `python3 scripts/probe_assertions.py` | 일부러 거짓으로 만든 SVA가 실제로 시뮬레이션을 실패시키는지 확인 | 내부 시뮬레이션의 실패가 기대 결과입니다. 최종 출력 `SVA_PROBE_PASS`와 `reports/runs/latest/assertion-probe.log`를 확인합니다. |
| `python3 scripts/publish_evidence.py` | 통과한 전체 회귀 시험, 결함 검출, SVA 검사 결과를 검토용 자료로 모음 | `검증 증거를 다음 위치에 저장했습니다`가 출력되고 `reports/evidence/v0.2/`에 요약과 로그가 복사됩니다. 전체 30건이 통과했고 검증 당시의 소스가 그대로여야 실행됩니다. |

`make regress`는 각 랜덤 seed에서 APB 완료 전송을 최소 1,000건 수행하고 실패가 발생하면 다음 시험으로 넘어가지 않습니다. 먼저 짧게 확인하려면 `python3 scripts/regress.py --seeds 2 --transactions 100`을 사용할 수 있습니다. 이 명령도 `reports/runs/latest/`를 사용하지만 2개 seed만 검사하므로 **30건짜리 v0.2 증거를 게시하기 전에는** `make regress`를 다시 실행해야 합니다. `summary.json`에는 각 시험의 통과 여부와 로그 경로가 기록됩니다.

명령이 실패하면 셸에서 0이 아닌 종료 코드가 반환되고, 시뮬레이션 오류는 보통 `$fatal` 메시지로 표시됩니다. `regress`가 `FAIL`을 출력하면 `reports/runs/latest/summary.md`와 해당 `.log`를 확인하세요. `mutation`과 SVA probe는 내부의 의도적인 실패를 확인한 후 **최종 명령은 성공**해야 합니다.

파형이 필요하면 `make waves TEST=tx`를 실행하세요. `TEST=rx` 또는 `TEST=apb`도 사용할 수 있습니다. 이 명령은 파형 지원 빌드로 시험을 실행해 `build/tb_top.vcd`를 생성합니다. 새 실행은 같은 파일을 덮어쓰므로 보관하려면 다른 이름으로 복사하세요. `python3 scripts/publish_evidence.py`는 TX·RX·APB 파형을 각각 새로 캡처해 [증거 디렉터리](reports/evidence/v0.2/README.md)에 저장합니다.

## GTKWave로 파형 보기

Ubuntu 26.04 amd64(WSL 포함)에서는 프로젝트 내부에 GTKWave를 한 번 설치할 수 있습니다. `sudo`는 필요하지 않습니다. 설치 후 아래 명령으로 저장된 파형과 미리 선택한 신호 배치를 함께 엽니다.

```sh
bash scripts/setup-gtkwave.sh
build/viewer/bin/gtkwave reports/evidence/v0.2/tx.vcd reports/evidence/v0.2/tx.gtkw
```

RX와 APB는 명령의 `tx` 두 곳을 각각 `rx`, `apb`로 바꾸면 됩니다. 두 번째 `.gtkw` 파일에는 볼 신호 목록이 저장되어 있습니다. GUI 창에서 마우스 휠이나 확대 버튼으로 시간을 확대하고, 커서를 이동해 신호의 변화 시각을 비교할 수 있습니다. TX에서는 `uart_tx`가 높은 유휴 상태에서 낮은 시작 비트, 데이터 비트 8개, 높은 정지 비트로 이어지는지 살펴보세요. RX에서는 `uart_rx` 입력 뒤 `rx_valid`와 `rx_data`를, APB에서는 `PSEL=1, PENABLE=0` 설정 단계와 `PSEL=1, PENABLE=1, PREADY=1` 완료 단계를 살펴보세요. 파형은 동작을 눈으로 이해하는 자료이고, 통과 판정은 위의 자동 검사 결과가 담당합니다.

[GitHub CI 워크플로](.github/workflows/verify.yml)는 Ubuntu 26.04에서 lint, 전체 회귀 시험, mutation, SVA probe를 실행하고 로그를 업로드하도록 준비되어 있습니다. 이 저장소가 GitHub에 게시되면 워크플로가 동작합니다.

## 확인된 v0.2 결과

| 증거 | 측정 결과 |
|---|---|
| Lint | RTL과 연결된 SVA가 Verilator 5.032 `-Wall` 통과 |
| 지정·랜덤 회귀 시험 | 30/30건 통과: FIFO, 대기 사이클 0/1/3의 APB/TX/RX, 20 seed × 랜덤 APB 동작 1,000건 |
| 기능 커버리지 | FIFO 경계 상태·동작 조합 12/12, 필수 APB 및 UART 오류·리셋·타이밍 항목 충족 |
| UART 프레임 | 핀에서 TX 프레임 401개 해독, 정상 정지 비트의 RX 프레임 247개 입력(예상된 overflow 폐기 3개 포함), FIFO 내용을 APB로 확인 |
| 코드 커버리지 | Verilator RTL line coverage 270/274(98.54%); 실행되지 않은 4줄은 증거 보고서에서 설명 |
| 디버깅과 결함 검출 | 실제 테스트벤치 커버리지 보고 결함 기록; 임시 TX 비트 오류를 자동 검출 |

[v0.2 증거 보고서](reports/evidence/v0.2/README.md)에 소스 해시, 도구 버전, 개별 로그, VCD 파형 3개, 시험한 baud 범위와 검증 범위가 있습니다. 이 결과는 UART의 디지털 시뮬레이션을 대상으로 하며 아날로그 입력·메타안정성 검증이나 16550 호환성을 주장하지 않습니다.

## 라이선스

이 프로젝트는 [MIT 라이선스](LICENSE)로 공개합니다.
