# Termux IR Hub (smart-home webhook → Android IR Blaster)

안드로이드 공기계를 스마트홈 IR 허브로. Termux + Termux:API의
`termux-infrared-transmit`로 추출해둔 IR 타이밍 배열을 송신하는 가벼운 Flask
웹훅 서버. 외부 서버/자동화에서 HTTP 한 번이면 에어컨 등 가전을 제어.

> 이 브랜치(`termux`)는 KernelSU 모듈 방식(`main` 브랜치)과 별개의,
> Termux 기반 독립 프로젝트입니다.

## 구성

```
server.py             # Flask 웹훅 서버
config.json           # host/port/auth_token/default_carrier/timeout
ir_codes.example.json # 코드 사본 양식 (→ ir_codes.json 에 실제 배열)
requirements.txt      # flask
setup.sh               # 의존성 부트스트랩
run.sh / stop.sh       # 백그라운드 실행(wake-lock)/정지
boot.sh                # Termux:Boot 자동시작 스크립트
```

## 설치 (안드로이드 기기)

1. **F-Droid**에서 `Termux`, `Termux:API`, (선택)`Termux:Boot` 설치. (Play스토어 버전은 업데이트가 멈춰 권장 안 함)
2. Termux 실행 후:
   ```sh
   pkg update
   pkg install termux-api python git
   git clone https://github.com/designed-re/kernelsu_remote_ir_blast -b termux ir-hub
   cd ir-hub
   pip install -r requirements.txt   # 또는 ./setup.sh
   ```
3. IR 송신 권한: 최초 1회 Termux:API 앱이 권한을 요청 → 허용.
   ```sh
   termux-infrared-transmit -f 38000 9000,4500,560,1690   # 송신 테스트
   ```

## 내 IR 코드 붙여넣기

추출한 타이밍 배열(Pastebin 데이터)을 저장:
```sh
cp ir_codes.example.json ir_codes.json
```
`ir_codes.json`에서 키=명령, 값=콤마 구분 패턴(또는 `{carrier, pattern}`):
```json
{
  "power":   { "carrier": 38000, "pattern": "9044,4498,536,1698,544,571,543,1689,..." },
  "turbo":   { "carrier": 38000, "pattern": "9017,4535,531,1703,541,567,541,1711,..." },
  "cool_24": "9044,4498,536,560,..."
}
```
`pattern` = 펄스(ON)/스페이스(OFF) 마이크로초, 펄스부터 시작.
`ir_codes.json`은 `.gitignore`에 넣어 실제 배열이 커밋되지 않게 했습니다.

## 실행

```sh
./run.sh          # 백그라운드 + termux-wake-lock (화면꺼짐 방지)
./stop.sh
tail -f logs/hub.log
```
(부팅 후 자동시작: Termux:Boot 설치 후)
```sh
mkdir -p ~/.termux/boot
cp boot.sh ~/.termux/boot/ir-hub.sh
```

## API

Full reference for humans/AI: [`API.md`](API.md). Machine-readable OpenAPI 3 spec:
[`openapi.yaml`](openapi.yaml) (import into Swagger/Postman/any AI tool).

## API

인증: `config.json`의 `auth_token`이 비어 있으면 인증 없음(편의). **외부 노출 시
반드시 토큰 설정**. 토큰은 헤더 `Authorization: Bearer <token>`, `X-Token: <token>`,
또는 `?token=<token>` 로 전달.

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET/POST | `/ac/<command>` | `ir_codes.json`의 명령 송신 |
| GET | `/ac` | 사용 가능 명령 목록 |
| POST | `/ir` | 임의 raw: `{"carrier":38000,"pattern":"9000,4500,..."}` 또는 `{"timings":[...]}` |
| POST | `/reload` | `ir_codes.json` 다시 로드(수정 후 서버 재시작 불필요) |
| GET | `/health` | 상태 |

예시:
```sh
# 토큰 있을 때 전원
curl -H 'X-Token: mytoken' http://<phone-ip>:5000/ac/power

# 토큰 없을 때
curl http://<phone-ip>:5000/ac/cool_24

# 자동화(Home Assistant RESTful 스위치) 예시
curl -X POST -H 'Content-Type: application/json' \
  http://<phone-ip>:5000/ir -d '{"carrier":38000,"pattern":"9000,4500,560,1690"}'
```

## 보안/운영 팁

- `host=0.0.0.0`이면 LAN 전체 노출. 라우터/방화벽으로 포트 제한 또는 토큰 필수.
- Android 배터리 최적화에서 Termux/Termux:API 제외 + `termux-wake-lock` 유지.
- 더 견고하게 하려면 `flask` 대신 `waitress`/`gunicorn` 사용(README 참고 가능, 요청시 추가).
- 이 허브가 켜진 폰을 에어컨이 보이는 위치에 고정.
