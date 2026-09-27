# 합성 및 FPGA 시험 준비 증거

실행 시각(UTC): 2026-09-27T13:27:11.936804+00:00

**실물 FPGA 시험은 아직 실행하지 않았습니다.** 아래 타이밍은 iCE40 HX8K / CT256을 분석용 칩으로 지정한 배치·배선 결과입니다. 실제 보드 핀을 지정하지 않아 I/O는 자동 배치됐습니다. 보드용 타이밍 승인 또는 보드 동작 결과로 사용할 수 없습니다.

| 검사 | 실행 결과 |
|---|---|
| 기존 RTL lint 및 전체 회귀 | 통과, 기존 회귀 30/30 |
| FPGA echo 회로 시뮬레이션 | APB 대기 0/3에서 각각 261바이트 핀 왕복, reset 중단·framing 오류·APB 오류 검출 |
| PC UART 검사기 | 소프트웨어 PTY/loopback 및 실패 주입 10건 통과; 실물 결과 아님 |
| 범용 합성 | 2026 Boolean/FF 셀, FF 439비트, 래치 0개 |
| 추가 파라미터 합성 | FIFO 깊이 5 / APB 대기 3도 통과 |
| 기준 FPGA 구현 | echo 회로 포함, 목표 50 MHz, seed 1에서 배치·배선 통과 |

- `clk$SB_IO_IN_$glb_clk`: nextpnr 추정 최대 주파수 **83.710 MHz**, 목표 50.000 MHz.

범용 합성 셀 수는 FPGA LUT 수와 다릅니다. FIFO 메모리가 레지스터로 펼쳐진다는 Yosys 경고는 현재 구현의 합성 결과이며 [전체 합성 로그](synthesis/yosys.log)에 보존했습니다. [합성 요약](synthesis/summary.json)과 [FPGA 타이밍 요약](timing/summary.json), [nextpnr 경로/자원 보고서](timing/pnr-report.json)를 함께 확인하세요. WNS/TNS 또는 보드의 실측 최대 주파수는 보고하지 않습니다.

[전체 실행/소스 해시](summary.json), [테스트 로그](logs/), [설치 패키지 기록](package-manifest.tsv)에 재현 근거가 있습니다. 게시한 텍스트의 로컬 경로는 상대 경로로 바꿨으며 `summary.json`의 `published_files_sha256`는 이 게시본의 해시입니다. 각 도구 요약 안의 `artifacts` 해시는 `build/`에 생성된 원본 산출물에 해당합니다.

재생성: [실행 안내](../../../docs/fpga-validation.md)를 따라 도구를 준비한 뒤 `make fpga-evidence`를 실행합니다. 이 명령은 9개 검증 단계를 새로 실행하고 모두 통과할 때 자료를 갱신합니다. 실물 완료 조건과 필요한 보드 정보도 해당 안내에 있습니다.
