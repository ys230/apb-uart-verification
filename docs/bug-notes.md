# 디버깅 기록

## TX 테스트는 통과했지만 회귀 테스트에서 reset bin 누락을 보고한 사례

첫 번째 전체 v0.2 회귀 테스트에서 FIFO와 APB 사례는 통과했습니다. 이어서 TX 시뮬레이터도 `TEST_PASS`를 출력하며 정상 종료했지만, 회귀 테스트 실행기는 필요한 `reset_abort` 기능 커버리지 bin이 0이라며 해당 사례를 `FAIL`로 표시했습니다. 당시의 [TX 로그](../reports/evidence/debug-first-tx-failure.log)와 [회귀 테스트 JSON](../reports/evidence/debug-first-regression-summary.json)에 이 불일치가 남아 있습니다.

공개한 두 기록에서는 개인 작업 디렉터리의 절대 경로만 저장소 최상위 기준 `.`로 바꿨습니다. 시험 결과와 오류 메시지는 그대로입니다.

TX 지향 테스트는 이미 프레임 전송 중 DUT를 리셋하고, 출력 핀이 high로 돌아가며 완성된 프레임이 나타나지 않는지 검사하고 있었습니다. 다만 테스트벤치가 그 사건을 `reset_aborts` 커버리지 카운터에 반영하지 않았습니다. 대응하는 RX 리셋 사례에도 카운터 증가가 빠져 있었습니다. 실제 전송 또는 수신 진행 중에 리셋하는 두 위치에 카운터 증가를 추가했고, 설계와 통과·실패 판정 검사는 변경하지 않았습니다.

원래 문제를 재현하려면 이전 버전 `tb/tb_top.sv`의 임시 복사본에서 그 두 카운터 증가를 생략하고 `python3 scripts/regress.py --seeds 1 --transactions 100`을 실행합니다. 이때 TX 시뮬레이션은 `TEST_PASS`를 출력하지만 회귀 테스트 JSON에는 `Missing reset_abort functional bin`이 기록됩니다. 카운터 증가를 적용하면 전체 30개 사례가 통과하고 리셋 bin에도 0이 아닌 값이 기록됩니다. 이 사례는 UART RTL에서 발견한 결함이 아니라 **검증 결과 보고의 결함**이었습니다.

별도의 [변이 검사](../reports/evidence/v0.2/mutation-summary.json)는 임시 RTL 복사본에서 첫 번째 TX 데이터 비트를 의도적으로 바꿉니다. 그 결과 TX 핀 검사에 나타나는 실패는 의도적으로 주입한 결함이며, 위 디버깅 사례와 별도로 기록했습니다.
