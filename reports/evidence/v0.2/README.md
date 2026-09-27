# v0.2 검증 증거

생성 시각(UTC): 2026-09-27T08:15:36.501214+00:00<br>
시뮬레이터: Verilator 5.032 2025-01-01 rev (Debian 5.032-1)<br>
소스 SHA-256: `bc9bddb95d6d93553f2691c2ffe0895f8f8fd91dade267de1e4dd8debed97c4b` ([해시 입력 파일 목록](summary.json)의 `metadata.source_files` 참고)

| 검증 항목 | 측정 결과 |
|---|---|
| RTL 및 assertion 정적 검사 | `-Wall` 옵션으로 통과 (`make lint`) |
| 전체 회귀 검증 | 30/30개 통과: FIFO 1개, APB/TX/RX 지향 테스트 9개, 고정 시드 20개 |
| 무작위 APB 전송 | 20개 시드에서 완료된 전송 최소 20,000건; 대기 설정 0/1/3 사이클 |
| UART 프레임 | 핀에서 디코딩한 TX 401프레임; 올바른 정지 비트를 가진 RX 입력 247프레임(예상된 FIFO 포화 폐기 포함), 수용된 바이트는 APB로 확인 |
| FIFO 기능 조합 | empty/middle/full × push/pop 조합 12/12개 관측, 깊이 5에서 포인터 순환 확인 |
| RX 타이밍 | 분주값 4, 5, 16, 32 확인; 분주값 32일 때 비트 길이 31/33클록을 RX 지향 테스트마다 각각 확인 |
| Verilator RTL 줄 커버리지 | 270/274 (98.54%) |
| 알려진 TX 결함 | 외부 핀 모니터가 검출; 임시 RTL 복사본에서 `TX pin mismatch` 발생 |
| SVA 실행 검사 | 의도적으로 거짓인 SVA가 시뮬레이션을 실패 종료시킴 |

[사례별 기계 판독 요약](summary.json), [병합된 코드 커버리지](coverage.info), [FIFO](logs/fifo.log), [APB 대기 3사이클](logs/apb-wait3.log), [TX](logs/tx-wait0.log), [RX](logs/rx-wait0.log), [무작위 시드 예시](logs/random-seed01-wait0.log)를 확인할 수 있습니다. 30개 사례의 전체 로그는 [`logs/`](logs/)에 있습니다. [결함 주입 결과](mutation-summary.json)와 [의도적으로 실패한 TX 로그](logs/mutation-tx-bit.log)는 핀 모니터의 검출 능력을 보여 줍니다. [SVA 실행 로그](logs/assertion-probe.log)는 `--assert` 옵션에서 의도적 실패가 보고됨을 보여 줍니다. 이전 검증 보고 오류는 [디버깅 기록](../../../docs/bug-notes.md)에 정리했습니다.

공개된 로그와 JSON에서는 개인 작업 디렉터리의 절대 경로를 저장소 최상위 기준 `.` 또는 상대 경로로 바꿨습니다. 원본 실행 로그는 Git에서 제외된 `reports/runs/latest/`에 있습니다.

[TX VCD](tx.vcd)와 [TX 신호 배치](tx.gtkw), [RX VCD](rx.vcd)와 [RX 신호 배치](rx.gtkw), [APB VCD](apb.vcd)와 [APB 신호 배치](apb.gtkw)를 GTKWave에서 쌍으로 열 수 있습니다. 증거 게시 단계에서 대기 설정 0사이클로 각각 `make waves TEST=tx`, `TEST=rx`, `TEST=apb`를 실행해 새로 캡처하며, 실행 로그는 `logs/wave-*.log`에 있습니다. 나머지 대기 설정은 지향 테스트 로그에서 확인할 수 있습니다. 뷰어 설치와 열기 명령은 [도구 설치 안내](../../../docs/tool-setup.md#선택-사항-gtkwave-파형-뷰어)를 참고하세요.

기능 커버리지 항목은 테스트벤치와 회귀 스크립트가 필수 조건으로 검사합니다. 줄 커버리지는 Verilator 계측 결과입니다. 실행되지 않은 소스 줄 4개 중 APB 오류 읽기 기본 분기와 UART의 잘못된 상태 기본 분기는 정상 입력에서 도달하지 않습니다. FIFO 포인터 순환 복귀 분기는 깊이 5 스코어보드로 기능을 확인했지만 Verilator가 해당 소스 줄을 실행으로 표시하지 않았습니다. RX 속도 차이는 분주값 32에서 PCLK 1사이클 차이만 검증했습니다. 아날로그 입력 특성, 메타안정성, 다른 위상 오차, 패리티, IRQ, FPGA 실장 동작은 이 결과의 범위 밖입니다.

재생성하려면 [도구 설치 안내](../../../docs/tool-setup.md)에 따라 환경을 적용하고 `make lint`, `make regress`, `make mutation`, `python3 scripts/probe_assertions.py`, `python3 scripts/publish_evidence.py`를 순서대로 실행합니다. 원본 커버리지 `.dat` 파일은 `reports/runs/latest/`에 있으며 `make regress`가 다시 생성합니다. 게시 명령이 TX·RX·APB VCD도 새로 캡처합니다. 개별 파형만 보고 싶다면 `make waves TEST=tx`(또는 `rx`, `apb`)를 실행하고 `build/tb_top.vcd`를 엽니다.
