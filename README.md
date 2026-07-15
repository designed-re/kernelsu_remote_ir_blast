<h1 align="center">⚠️ DO NOT USE ⚠️</h1>

<h1 align="center">This module can make your phone UNBOOTABLE (brick it)</h1>

<h2 align="center"><b>Do NOT install or use it.</b> It may permanently brick your device, and you alone bear all responsibility.</h2>

<h2 align="center">🚫 You have been warned. 🚫</h2>

---

# Remote IR Blaster (KernelSU module)

HTTP 요청으로 raw IR timings(pulse/space 마이크로초)를 송신하는 KernelSU 모듈.
헤더 인증이 필수이며, KernelSU WebUI에서 모든 설정을 변경할 수 있다.

## 구조

```
module.prop            # 모듈 메타데이터
service.sh             # 부팅 후 데몬 시작 (late_start service)
customize.sh           # 설치 스크립트 (권한/설정 보존)
uninstall.sh           # 제거 시 데몬 정지 + 정리
action.sh              # KernelSU 앱 Action 버튼: 상태 표시 + 재시작
sepolicy.rule          # TCP 바인드 / 디바이스 접근 정책
skip_mount             # system 오버레이 마운트 안 함
ir_blast/
  ir_blastd.py         # HTTP 데몬 (Python stdlib only)
  transmit.sh          # 송신 백엔드 디스패처 (command / ir-ctl / gpio)
  ctl.sh               # start/stop/restart/status/test/set-config
  config.json          # 설정 (WebUI가 편집)
webroot/               # KernelSU WebUI (index.html + app.js + style.css + icon.svg)
```

## 요구사항

- KernelSU (또는 Magisk 호환) 가 설치된 Android 기기
- **Python 3** — 기본값은 Termux 경로(`/data/data/com.termux/files/usr/bin/python3`).
  WebUI의 "데몬 > Python 경로"에서 실제 경로로 변경. (시스템 python3가 있으면 customize.sh가 자동 감지)
- 송신 하드웨어: `command` 백엔드로 외부 블래스터(ESP8266/ESP32 등) HTTP API 호출이 가장 유연.
  또는 `ir-ctl`(v4l-utils) + `/dev/lirc0`, 또는 GPIO sysfs.

## 설치

```sh
cd magisk_remote_ir_blast
zip -r ../ir_blast.zip . -x '.git/*'
# KernelSU 매니저 → 모듈 → zip 설치
```

## HTTP API

인증: 설정한 헤더(기본 `X-IR-Token`)의 값이 정확히 일치해야 함.

```sh
curl -X POST http://<device-ip>:8424/ir \
  -H 'X-IR-Token: change-me-please' \
  -H 'Content-Type: application/json' \
  -d '{"carrier":38000,"repeat":1,"timings":[9000,4500,560,560,560,1680,560,560]}'
```

- `timings` (필수): pulse(ON)/space(OFF) 마이크로초 배열. **짝수 개**, 첫 값은 pulse.
- `carrier` (선택, 기본 config의 `ir.carrier`)
- `repeat` (선택, 기본 config의 `ir.repeat`)
- `GET /health` — 인증 필요, 서버 상태.

응답: `{"ok":true,"carrier":38000,"repeat":1,"count":8,"elapsed_ms":189}`

## 백엔드

### command (기본)
`ir.command` 문자열을 `sh -c`로 실행. 환경변수로 값 전달:
- `$IR_CARRIER` `$IR_REPEAT` `$IR_TIMINGS`(공백구분) `$IR_TIMINGS_CSV`(콤마구분) `$IR_RAWFILE`(한 줄에 한 timing)

외부 ESP 블래스터 예:
```
curl -s "http://192.168.1.50/ir?carrier=$IR_CARRIER&t=$IR_TIMINGS_CSV"
```

### ir-ctl (LIRC)
`ir-ctl -d /dev/lirc0 --carrier=38000 --send=<rawfile>` 실행.
`ir.irctl_path`와 `ir.lirc_device` 설정. v4l-utils 필요.

### ir_spi (/dev/ir_spi)
커스텀 캐릭터 디바이스(`/dev/ir_spi`)에 직접 송신. 인터페이스를 모를 때:

1. `sh /data/adb/modules/ir_blast/ir_blast/ctl.sh probe`
   - `ls -l`, major:minor, `/sys/dev/char/M:m` 드라이버, `ir-ctl --features` 출력
2. 위 결과로 `ir.ir_spi_mode` 선택:
   - `ir-ctl` — rc-core TX 디바이스일 때(`ir-ctl --features`에 TX 표시)
   - `write-text` — µs 타이밍을 한 줄에 하나씩 write
   - `write-bin-u32` — 펄스/스페이스 µs를 little-endian u32 배열로 write
   - `write-bin-u32-cycles` — µs×carrier/1e6 사이클 수를 LE u32로 write
   - `auto` — ir-ctl → write-text → write-bin-u32 순차 시도(첫 성공 사용)
3. `ir.ir_spi_carrier_sysfs`에 캐리어 sysfs 노드 경로를 넣으면 송신 전 캐리어 설정 시도(선택).
4. WebUI "ir_spi 조사" 버튼 = `ctl.sh probe` 결과를 로그 영역에 표시.

### gpio
`/sys/class/gpio/gpioN/value`를 토글. 38kHz 서브캐리어는 쉘에서 생성 불가하므로
단순 ON/OFF 엔벨로프만 가능(외부 캐리어 하드웨어 필요). `ir.gpio`, `ir.active_high`.

## KernelSU WebUI

KernelSU 매니저에서 모듈 페이지를 열면 설정 UI 표시. 저장 후 "재시작".
"테스트"는 백엔드로 샘플 NEC 신호를 직접 송신해 백엔드 연결을 검증.

## 로그

`/data/adb/modules/ir_blast/logs/server.log` (데몬), `transmit.log` (송신).
제어: `sh /data/adb/modules/ir_blast/ir_blast/ctl.sh {start|stop|restart|status|test}`

## 보안 주의

- 기본 토큰(`change-me-please`)을 반드시 WebUI에서 변경.
- `host=0.0.0.0`이면 LAN 전체에 노출. 외부 노출 시 방화벽/인증 토큰 관리 철저.
