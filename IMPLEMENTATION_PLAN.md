# APB UART 설계·검증 포트폴리오 구현 계획

최초 작성일: 2026-09-27. 이 문서의 아래 본문은 구현 전에 작성한 제안서를 보존한 것입니다. **현재는 v0.2 구현과 로컬 검증을 완료했습니다.** 실제 구현 상태와 완료 기준은 [로드맵](docs/roadmap.md), 재실행 명령은 [README](README.md), 30/30건의 결과와 검증 범위는 [v0.2 증거 보고서](reports/evidence/v0.2/README.md)를 기준으로 확인하세요. 아래의 Windows 경로, 예정 일정, 파일 구조, 도구 버전은 최초 제안 당시의 기록입니다.

**현재 환경에서 v0.2 재실행**

복제한 저장소의 최상위 디렉터리에서 아래 명령을 실행합니다. 현재 로컬 Ubuntu 26.04 amd64 환경(WSL 포함)에는 프로젝트 내부 도구가 설치되어 있습니다. 새로 복제한 환경에서는 먼저 `bash scripts/setup-toolchain.sh`로 도구를 설치하세요. 새 터미널을 열 때마다 `source build/toolchain/env.sh`를 실행해 Verilator, GNU Make, C++ 컴파일러 경로를 현재 셸에 적용합니다.

```bash
source build/toolchain/env.sh
make lint
make test-fifo
make test TEST=all WAIT_CYCLES=0
make regress
make mutation
python3 scripts/probe_assertions.py
python3 scripts/publish_evidence.py
```

`make lint`는 RTL·SVA·테스트벤치를 정적 검사하고, `make test-fifo`는 FIFO 단위 동작을, `make test TEST=all WAIT_CYCLES=0`은 APB/UART 통합 동작을 빠르게 확인합니다. `make regress`가 필수 30개 사례와 커버리지 결과를 `reports/runs/latest/`에 기록합니다. `make mutation`과 SVA 검사는 각각 의도적인 내부 실패가 자동 검사에 잡히는지 확인합니다. 마지막 명령은 통과한 결과를 `reports/evidence/v0.2/`에 복사합니다. 각 명령의 성공 표시, 로그 위치, 파형 생성 방법은 [README의 실행 안내](README.md#검증-명령과-결과-확인)에 있습니다.

**목표와 진행 방식**

첨부 글의 SoC Design Verification 방향을 기준으로, 직접 만든 APB3 UART를 SystemVerilog로 검증하는 프로젝트를 제안한다. Verilog의 회로 표현을 익히면서 RTL과 테스트벤치는 `.sv` 파일로 작성한다. 처음에는 `logic`, `always_ff`, `always_comb`, module, task를 사용하고 class와 UVM은 뒤에 추가한다.

최종 설명 목표는 “APB를 통해 데이터를 쓰면 UART 핀에서 올바른 프레임이 나오며, 수신 데이터는 FIFO와 APB 읽기를 거쳐 정확히 전달됨을 자동 검증했다”이다. FPGA 보드 구매나 실제 CPU 연결은 이 프로젝트의 완료 조건에 포함하지 않는다.

완성 단위를 세 개로 나눈다.

| 결과물 | 범위 | 완료 증거 |
|---|---|---|
| v0.1 APB 레지스터 검증 | APB3 레지스터 블록 + SV 자동 검사 | 정상/오류 접근, wait state, reset 테스트와 실행 로그 |
| v0.2 APB UART 검증 | FIFO + UART TX/RX + 통합 검증 | 송수신 scoreboard, 경계 조건, 재현 가능한 regression, coverage 보고서 |
| v0.3 UVM 확장 | 기존 APB 테스트의 UVM 이식 | sequence/driver/monitor/scoreboard 연결 및 기존 테스트 결과 비교 |

**최초 제안 당시 작업 환경에서 확인한 사실 (현재 환경과 다름)**

- `C:\Verilog`에는 빈 `readme.md`만 있다.
- Windows PATH에서 Git과 `wsl.exe`를 찾았다. Verilator, Icarus, GTKWave, Yosys는 찾지 못했다. 다른 경로나 WSL 내부 설치 여부까지 확인한 것은 아니다.
- 이 실행 환경에서 `wsl --list --verbose`는 “시스템에서 파일에 액세스할 수 없습니다”로 실패했다. 따라서 WSL 배포판의 설치·실행 상태는 미확인이다.
- 도구 설치와 시스템 설정 변경은 수행하지 않았다.

**사용할 도구**

| 도구 | 역할 | 도입 시점 |
|---|---|---|
| WSL2 + Ubuntu LTS | Windows에서 Linux 개발 명령 실행 | 처음 |
| VS Code 또는 익숙한 편집기 | `.sv` 코드와 문서 편집 | 처음 |
| Verilator | RTL 문법·구조 검사(lint), 시뮬레이션, assertion·coverage 실행 | 처음 |
| GTKWave | 시뮬레이터가 저장한 VCD/FST 파형 확인 | 처음 |
| Git + Make | 변경 기록, 같은 명령으로 빌드·테스트 재실행 | 처음 |
| Python 3 | 여러 seed 실행, 결과·로그 집계 | regression 단계 |
| Accellera UVM + Z3 | UVM 검증 구조와 제약 기반 랜덤 생성 | UVM 단계 |

Verilator는 SystemVerilog에서 시뮬레이션 실행 파일을 만들 수 있으며, `--binary` 방식은 사용자가 C++ main을 직접 작성할 필요가 없다. [공식 실행 예제](https://verilator.org/guide/latest/example_binary.html)

GTKWave는 파형을 보는 프로그램이다. RTL의 정답 여부는 테스트벤치가 자동 판정하고, 실패 원인과 타이밍은 파형으로 분석한다. [GTKWave 문서](https://gtkwave.github.io/gtkwave/)

Icarus는 간단한 RTL 교차 확인이 필요할 때 추가한다. 공식 문서도 SystemVerilog 일부만 지원한다고 설명하므로 고급 검증 전체의 기본 도구로 정하지 않는다. [Icarus README](https://github.com/steveicarus/iverilog/blob/master/README.md)

cocotb는 Python으로 테스트벤치를 작성하는 유용한 선택지다. 이번 계획에서는 SystemVerilog 검증 경험을 우선하고, Python 테스트가 필요한 시점에 보조로 추가한다. [cocotb 문서](https://docs.cocotb.org/en/stable/)

**첨부 글의 도구 설명에서 보완할 부분**

2026-09-27 기준 공식 변경 기록에는 Verilator 5.052에서 UVM 2020-3.2 지원이 추가되었다고 명시되어 있다. 따라서 오픈소스 환경에서도 UVM을 시도할 수 있다. 다만 class, SVA, covergroup 등의 지원에는 제한이 있으므로 “설치하면 모든 상용 시뮬레이터 예제가 그대로 실행된다”고 가정하지 않는다. [Verilator 변경 기록](https://verilator.org/guide/latest/changes.html), [언어 지원 범위](https://verilator.org/guide/latest/languages.html), [UVM 지원 현황](https://github.com/verilator/verilator/issues/1538)

초기에는 Ubuntu 패키지로 작은 RTL을 실행한다. 고급 SV/UVM 단계에서는 **Verilator v5.052 + UVM 2020-3.2**를 첫 검증 후보로 삼고, 실제 사용할 기능의 작은 예제를 통과한 조합을 고정한다. 제약 기반 랜덤 생성에는 Z3를 함께 준비한다. 배포판 패키지는 최신 Verilator보다 오래될 수 있다. [설치 문서](https://verilator.org/guide/latest/install.html)

버전 검증 항목은 clock/reset, 의도적 `$fatal`, 의도적으로 실패하는 assertion, 기대 bin의 coverage hit, `randomize()` 성공과 제약 만족, 동일 seed 재현, UVM transaction 전달이다. 무시된 제약 등 지원 제한 경고도 확인한다. [CONSTRAINTIGN 안내](https://verilator.org/guide/latest/warnings.html#constraintign)

브라우저 체험이 필요하면 EDA Playground를 보조로 사용할 수 있다. 사용 가능한 simulator와 계정 조건을 확인하고, 장시간 regression은 로컬에서 실행한다. [로그인 안내](https://eda-playground.readthedocs.io/en/latest/login.html), [실행 제한](https://eda-playground.readthedocs.io/en/latest/faq.html#what-are-the-resource-limits-for-running-my-code)

**만들 하드웨어와 검증 구조**

```mermaid
flowchart LR
    A[SV APB driver] -->|APB 읽기·쓰기| B[APB 레지스터 블록]
    B --> C[TX FIFO]
    C --> D[UART TX]
    D -->|uart_tx| E[독립 UART monitor]
    F[독립 UART driver] -->|uart_rx| G[UART RX]
    G --> H[RX FIFO]
    H --> B
    A --> I[APB monitor]
    B --> I
    I --> J[Scoreboard: 예상값과 실제값 비교]
    E --> J
    F --> J
```

APB driver가 CPU 대신 레지스터 접근 신호를 만든다. UART monitor는 TX RTL의 내부 상태를 보지 않고 핀의 start/data/stop 비트를 해석한다. RX는 별도의 UART driver로 검증한다. TX와 RX를 단순 연결하는 loopback만 사용하면 두 블록의 같은 오류가 가려질 수 있으므로 독립 송신·수신 검사를 먼저 만든다.

프로젝트에서 정할 초기 사양은 다음과 같다. 이것은 특정 SoC나 16550 UART의 호환 구현을 의미하지 않는다.

| 항목 | 제안 사양 |
|---|---|
| APB | APB3, 32-bit 데이터, 4-byte 정렬 접근, `PREADY`와 `PSLVERR` |
| Clock/reset | 내부는 PCLK 하나, active-low reset. 분주된 새 clock 대신 clock enable 사용 |
| UART | 8 data bits, no parity, 1 stop bit(8N1), LSB first, idle high |
| Baud | 정수 분주. v1에서는 송수신 중 변경을 금지하고, 허용 분주값을 사양으로 정의 |
| FIFO | TX/RX 각각 16 entries × 8 bits, 동기식 FIFO |
| RX 입력 | 2단 동기화 후 비트 중앙 샘플링. false start와 잘못된 stop bit 처리 정의 |
| APB 대기 | `WAIT_CYCLES` 파라미터 0/1/3으로 반복 검증 |
| 범위 확장 | IRQ, parity, DMA, AXI4-Lite, FPGA 탑재는 v0.2 완료 후 별도 결정 |

APB 전송은 setup과 access 단계를 거친다. peripheral의 부작용은 `PSEL && PENABLE && PREADY`인 완료 edge에서 처리하고, 이 프로젝트의 오류 응답에서는 상태를 변경하지 않는다. wait 동안 중복 쓰기가 발생하지 않는지 검사한다. APB의 전송·대기·오류 신호 정의는 Arm 사양을 기준으로 한다. [AMBA 3 APB 공식 사양](https://documentation-service.arm.com/static/64257d8379edab6d64fb6f68)

레지스터 맵 초안은 다음과 같다. 처음에는 앞의 세 레지스터만 구현한다.

| Offset | 이름 | 접근 | 의미 |
|---|---|---|---|
| `0x00` | CTRL | RW | TX/RX enable; reset 값 0 |
| `0x04` | STATUS | RO | TX full/busy, RX empty 등 상태 |
| `0x08` | SCRATCH | RW | 32-bit readback 검증용 저장 레지스터; reset 값 0 |
| `0x0C` | BAUD_DIV | RW | UART 분주 설정; 구체 범위·reset 값은 UART 구현 전에 확정 |
| `0x10` | TXDATA | WO | 하위 8-bit를 TX FIFO에 넣기 |
| `0x14` | RXDATA | RO | RX FIFO의 가장 오래된 8-bit 읽기, 완료 시 한 번 pop |

코딩 전 결정할 정책: 미정의/비정렬 주소, RO 쓰기, WO 읽기, full TX 쓰기, empty RX 읽기는 `PSLVERR`로 응답하고 상태를 유지한다. 오류 읽기 데이터는 이 프로젝트에서 0으로 정한다. CTRL의 예약 비트는 쓰기를 무시하고 읽으면 0이다. STATUS reset 값은 FIFO empty/busy 정의에서 계산한다. APB3에는 byte strobe를 추가하지 않는다.

FIFO는 edge 직전 상태를 기준으로 full이면 push를 거절하고 empty이면 pop을 거절한다. full에서 push와 pop이 동시에 들어오면 pop만 수락한다. empty에서 동시에 들어오면 push만 수락한다. 그 밖의 동시 push/pop은 둘 다 수락하며 점유수는 유지한다. 출력은 empty가 아닐 때 가장 오래된 데이터를 미리 보여주고, 수락한 pop edge에서 다음 데이터로 넘어가는 방식으로 정한다. 처음에는 이 정책으로 단순화하고 TB의 기준 모델에도 동일한 계약을 적용한다.

RX FIFO overflow, framing error, RX disable, reset 중 수신 데이터 처리도 RX 사양에서 결정한다. v1 제안은 잘못된 프레임과 full 상태에서 완성된 새 바이트를 버리고 기존 FIFO 내용을 보존하는 것이다. overflow와 framing error는 STATUS의 sticky bit에 기록하고 초기 버전에서는 reset으로 해제한다. reset은 진행 중 APB 전송·UART 프레임을 취소하고 FIFO를 비운다.

분주값은 PCLK 수/비트로 정의한다. 동기화된 RX falling edge 이후 반 비트 시점에 start=0을 확인하고, 한 비트 간격으로 데이터와 stop을 샘플링한다. 최소 허용 분주값, 홀수 분주값의 반올림, 허용 송수신 속도 차이는 RX 구현 전에 정하고 테스트한다. 실제 baud는 `PCLK 주파수 / 분주값`으로 계산해 목표 baud와의 오차를 보고한다.

`WAIT_CYCLES`는 전송마다 새로 적용한다. PSEL을 계속 1로 유지하는 연속 전송에서도 SETUP 단계로 새 요청을 구분한다. 디지털 시뮬레이션으로 확인한 RX 타이밍 범위와 실제 핀의 아날로그·metastability 특성 검증은 구분해 보고한다.

**단계별 일정과 완료 기준**

주당 약 8~12시간을 가정한 추정이다. 기본 결과물은 약 8주, UVM까지는 추가 2~4주를 잡는다. 설치·디버깅 속도에 따라 늘어날 수 있으며 주차보다 완료 기준을 우선한다.

| 시점 | 구현 내용 | 완료 기준 |
|---|---|---|
| 1주 | 도구 설치, MUX/counter, SV TB | reset·enable·wraparound 자동 검사, 실패 종료 코드, 파형 생성 |
| 2주 | APB 레지스터 RTL, `apb_read/write` task | SCRATCH readback, reset 값, 잘못된 접근 검사 |
| 3주 | APB monitor/scoreboard, 기본 SVA | wait 0/1/3, 연속 접근, 전송 중 reset, 중복 쓰기 검사. v0.1 완료 |
| 4주 | 동기식 FIFO, SV queue 기준 모델 | full/empty, wraparound, 동시 push/pop, reset, 순서 보존 검사 |
| 5주 | UART TX, TX FIFO 연결 | `00/FF/55/AA` 및 랜덤 바이트의 비트 순서·폭·stop 검사 |
| 6주 | UART RX, RX FIFO 연결 | 독립 송신 입력으로 정상 수신, false start, framing error, overflow 검사 |
| 7주 | APB UART 통합, 랜덤 검증, coverage | APB→TX 및 RX→APB 경로 검사, 필수 기능 bin의 누락 보완 |
| 8주 | regression 자동화, CI 설정, README·디버깅 기록 | 새 환경의 실행 절차, 재현 seed, 로그·파형·coverage 증거 정리. v0.2 완료 |
| 추가 2~4주 | class 검증 구조, UVM agent/env/test | 기존 APB 요구사항을 UVM 테스트로 재검증. v0.3 완료 |

한 작업 단위는 “짧은 개념 설명 → 작은 RTL/TB 작성 → 자동 검사 → 파형 해석 → 코드 리뷰와 기록”으로 진행한다. 처음부터 전체 UART 코드를 한 번에 만들기보다 각 블록의 예상 동작을 설명하고 실패를 고치는 경험을 남긴다.

**검증에서 반드시 남길 증거**

- 요구사항별 ID, stimulus, expected result, checker, coverage 항목을 연결한 verification plan.
- 정상 동작뿐 아니라 reset 중단, 경계값, 잘못된 접근 등 실패하기 쉬운 상황의 테스트.
- 테스트 이름·seed·tool version·Git commit·설정값·종료 코드가 포함된 실행 기록.
- timeout, scoreboard mismatch, assertion 실패가 regression 실패로 전달되는 실행 구조.
- 의도적 버그를 넣었을 때 실제로 실패하는 검사. 예: wait 동안 중복 push, FIFO wrap 오류, TX bit 순서 오류. 실제 발견한 버그와 구분해서 기록한다.
- 원인, 재현 절차, 파형, 수정 내용, 재발 방지 테스트가 있는 디버깅 사례.

첨부 예제의 `full |-> !write`는 write가 “요청”인지 “실제로 수락된 쓰기”인지에 따라 의미가 다르다. full에서 write 요청을 거절하는 사양이라면 요청 자체는 오류가 아니다. 여기서는 수락 조건, 점유수 범위, 거절된 요청으로 상태가 변하지 않는지, 데이터 순서 보존을 검사한다.

Functional coverage는 “요구한 상황을 실제로 시험했는가”, code coverage는 “RTL의 어느 부분이 실행되었는가”를 보여준다. 각각 보고하고, 숫자 하나로 검증 완료를 선언하지 않는다. [Verilator coverage 문서](https://verilator.org/guide/latest/simulating.html#coverage-analysis)

coverage 초안: APB read/write × 정상/오류 × wait 길이, FIFO empty/middle/full × push/pop 조합, UART 패턴·분주값·프레임 오류·reset 시점. 의미 없는 cross 조합은 제외 이유를 기록한다. 단순 hit counter로 시작할 수 있으며 covergroup 기반 결과와 구분한다.

v0.2의 제안 완료 기준은 필수 directed test 전부 통과, 고정한 20개 seed × 1,000개 APB transaction 이상 회귀 통과, 도달 불가능한 조합을 근거와 함께 제외한 필수 functional bin 모두 hit, 코드 coverage의 미도달 부분 설명이다. **현재 이 기준을 충족한 로컬 실행 결과는 [증거 보고서](reports/evidence/v0.2/README.md)에 기록했다.** UART 바이트 수와 검증한 RX 타이밍 범위도 해당 보고서에 별도로 기록했다.

**최초 저장소 구조 제안 (기록용)**

아래는 구현 전에 제안한 구조 초안이며 실제 파일 목록과 다를 수 있다. 현재 구조는 [README](README.md)를 참고한다.

```text
apb-uart-verification/
  README.md
  Makefile
  docs/
    specification.md
    verification-plan.md
    tool-versions.md
    bug-notes.md
  labs/counter/
  rtl/
    apb_regs.sv
    sync_fifo.sv
    uart_tx.sv
    uart_rx.sv
    apb_uart.sv
  tb/
    apb_bfm.sv
    apb_monitor.sv
    uart_bfm.sv
    scoreboard.sv
    tb_top.sv
  assertions/
  tests/
    directed/
    random/
  scripts/regress.py
  reports/
  build/                 # 생성물, Git 제외
  uvm/                   # v0.3에서 추가
  .github/workflows/     # 로컬 테스트가 안정된 뒤 추가
```

당시에는 `make lint`, `make test TEST=apb_smoke`, `make regress`, `make waves TEST=uart_tx` 형태를 제안했다. 실제 구현에서는 `make test TEST=apb|tx|rx|random|all`과 `make waves TEST=tx|rx|apb`를 사용한다. 실행 가능한 전체 명령은 [README](README.md#검증-명령과-결과-확인)에 적었다. 큰 파형은 기본 회귀 검증에서 끄고 필요한 사례를 재실행해 생성한다.

**최초 제안 당시 Windows 시작 절차 (기록용)**

아래는 최초 제안 당시 작성한 Windows 안내입니다. **현재 프로젝트를 실행할 때는 위의 "현재 환경에서 v0.2 재실행"과 [도구 설치 안내](docs/tool-setup.md)를 사용하세요.**

1. 일반 PowerShell에서 기존 WSL 상태를 먼저 확인한다.

   ```powershell
   wsl --list --verbose
   ```

2. Ubuntu 배포판이 없다면 관리자 PowerShell에서 설치한다. Ubuntu 24.04 LTS를 초기 후보로 사용한다. Windows 기능 활성화와 재부팅이 필요할 수 있다. [Microsoft WSL 설치 안내](https://learn.microsoft.com/en-us/windows/wsl/install)

   ```powershell
   wsl --install -d Ubuntu-24.04
   ```

3. Ubuntu 터미널에서 기본 도구를 설치하고 버전을 확인한다.

   ```bash
   sudo apt update
   sudo apt install -y build-essential git verilator gtkwave python3
   verilator --version
   g++ --version
   gtkwave --version
   ```

4. 현재 폴더를 그대로 사용할 때 Ubuntu 경로는 `/mnt/c/Verilog`이다. 빌드가 커지면 Linux 파일시스템 안의 `~/projects/apb-uart-verification`을 주 작업 폴더로 정하는 편이 유리하다. 두 복사본을 동시에 수정하지 않는다. [WSL 파일시스템 안내](https://learn.microsoft.com/en-us/windows/wsl/filesystems)

5. 첫 코드 작업으로 `labs/counter/counter.sv`와 `counter_tb.sv`를 만든다. 8-bit counter에 reset, enable, wraparound 검사를 넣고 TB에서 `counter.vcd`를 생성한다. stimulus는 sampling edge와 겹치지 않게 구동하고 결과는 NBA 갱신 후 확인한다.

6. 위 파일을 작성한 뒤 다음과 같이 실행하도록 구성한다. 다음은 파일 작성 후의 명령 예시이며 현재 검증한 실행 결과가 아니다.

   ```bash
   cd /mnt/c/Verilog/labs/counter
   verilator --binary --timing --assert --trace -Wall --top-module counter_tb counter.sv counter_tb.sv
   ./obj_dir/Vcounter_tb
   gtkwave counter.vcd
   ```

   `--timing`, `--assert`는 실행 의도를 드러내고 구버전과의 차이를 줄이기 위해 적었다. 최신 버전에서는 일부가 기본 활성화되거나 `--binary`에 포함된다. [Verilator 실행 옵션](https://verilator.org/guide/latest/exe_verilator.html)

7. GTKWave 창이 열리지 않으면 WSL GUI 지원 상태를 확인한다. Linux 시뮬레이션으로 만든 VCD를 Windows용 GTKWave에서 열어도 된다. [WSL GUI 안내](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps), [GTKWave 문서](https://gtkwave.github.io/gtkwave/)

첫날의 완료 기준은 “8-bit counter를 자동 검증했고, reset·증가·정지·wraparound를 파형으로 설명할 수 있으며, 잘못된 기대값을 넣으면 실패한다”이다. 그 다음 작업은 APB SCRATCH 레지스터의 write/readback이다.

**공개 포트폴리오로 정리하는 방법**

README 첫 화면에는 무엇을 설계했는지, 어떤 사양을 검증했는지, 어떻게 재실행하는지를 적는다. 설계도, 검증 항목 표, 실제 실행 로그, 핵심 파형 2~3개, coverage와 미검증 범위를 함께 둔다. UVM은 실제 실행·검증한 후 기술 목록에 추가한다.

기존 RTL 참고가 필요하면 [PULP의 APB UART SystemVerilog 저장소](https://github.com/pulp-platform/apb_uart_sv)를 구조 비교용으로 볼 수 있다. 이 저장소는 보관 처리된 코드이므로 최신 기본 템플릿으로 삼지 않는다. 먼저 자신의 작은 사양을 구현하고 FIFO·TX·RX 분리를 비교한다. 가져온 코드가 있다면 출처·라이선스·직접 변경한 부분을 구분한다.

면접 설명은 “UART를 만들었다”에서 끝내지 않고 “어떤 버그가 생길 수 있다고 생각했고, 어떤 검사로 잡았고, 실패를 어떻게 재현하고 고쳤는가”까지 연결한다.
