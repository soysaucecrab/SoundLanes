# SoundLanes — 앱별 오디오 출력 라우팅 명세서

- 작성일: 2026-10-22
- 상태: v1 완성 (M0~M3 완료, M4는 이 맥 전용 범위로 완료). 공증·배포는 Developer ID 발급 후 (§11)
- 대상 환경: macOS 15.0 이상 (개발 기준: macOS 27.0.1, Apple Silicon M5, Swift 6.4)
  - Process Tap API는 14.2부터 있지만, IOProc 공유 값에 쓰는 `Synchronization.Atomic`이 15.0부터라 최소 버전을 15.0으로 정했다 (2026-10-22).

> **이름 주의**: "SoundSource"는 Rogue Amoeba의 상용 제품명이다. 디렉터리 이름으로만 쓰고,
> 배포용 앱/바이너리 이름은 **`soundlanes` (CLI) / SoundLanes (앱)** 를 사용한다.

---

## 1. 목표

앱마다 오디오 출력 장치를 따로 지정한다.

> 예: Music/Spotify → MacBook 스피커, Chrome(YouTube) → AirPods

### 1.1 해결할 문제
macOS는 모든 앱이 하나의 "기본 출력 장치"를 공유한다. 앱 자체에 출력 장치 선택 기능이 없으면
(브라우저, Music, Spotify 등) 앱별로 출력을 나눌 방법이 없다.

### 1.2 목표 (Goals)
- G1. 특정 앱(번들 ID 기준)의 오디오를 기본 출력이 아닌 지정 장치로 보낸다.
- G2. 라우팅된 앱의 소리는 원래 출력(기본 장치)에서 **들리지 않아야** 한다 (이중 재생 없음).
- G3. 커널 확장이나 HAL 오디오 드라이버를 **설치하지 않는다**. 공개 API(Core Audio Process Tap)만 쓴다.
- G4. 프로그램이 죽거나 종료되면 해당 앱의 소리는 **자동으로 원래 기본 출력으로 돌아온다**.
- G5. 앱 재실행, 장치 연결/해제(AirPods 등)에 자동으로 대응한다.
- G6. 설정을 저장하고, 로그인 시 자동 적용할 수 있다.

### 1.3 비목표 (Non-goals)
- 시스템 전체 EQ, 이펙트, 녹음 기능
- 하나의 앱을 여러 장치로 동시에 출력 (v1 범위 밖, §11 참고)
- 입력(마이크) 라우팅
- Mac App Store 배포, iOS 지원
- macOS 15.0 미만 지원

---

## 2. 사용 시나리오

| # | 시나리오 | 기대 결과 |
|---|---|---|
| S1 | 기본 출력은 스피커, Chrome만 AirPods로 지정 | YouTube 소리는 AirPods에서만, Music은 스피커에서만 들림 |
| S2 | 라우팅 중 AirPods 연결 해제 | Chrome 소리는 기본 출력(스피커)으로 자연스럽게 돌아옴. AirPods 재연결 시 자동 복귀 |
| S3 | 라우팅 중 Chrome 종료 후 재실행 | 재실행된 Chrome에도 같은 규칙이 자동 적용됨 |
| S4 | `soundlanes`가 강제 종료(kill -9)됨 | Chrome 소리는 즉시 기본 출력으로 돌아옴 (무음 상태로 남지 않음) |
| S5 | 사용자가 시스템 기본 출력을 바꿈 | 라우팅되지 않은 앱만 새 기본 출력을 따라감. 라우팅된 앱은 지정 장치 유지 |
| S6 | 지정 장치 = 현재 기본 출력 | 탭을 만들지 않음 (불필요한 처리 없음) |

---

## 3. 기술 배경: Core Audio Process Tap (macOS 14.2+)

### 3.1 핵심 API
| API | 용도 |
|---|---|
| `kAudioHardwarePropertyProcessObjectList` | 오디오 프로세스 객체 목록 |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` | PID → 오디오 프로세스 `AudioObjectID` |
| `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` | 프로세스 식별 |
| `kAudioProcessPropertyIsRunningOutput` | 현재 소리를 내는 중인지 |
| `CATapDescription` | 탭 정의 (대상 프로세스, 스테레오 믹스다운, 음소거 방식, private 여부) |
| `CATapMuteBehavior.mutedWhenTapped` | **탭을 읽는 동안에만** 원래 출력을 음소거 → G2, G4 충족 |
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` | 탭 생성/삭제 |
| `kAudioTapPropertyFormat` | 탭 오디오 포맷 (`AudioStreamBasicDescription`) |
| `AudioHardwareCreateAggregateDevice` / `AudioHardwareDestroyAggregateDevice` | 탭 + 출력 장치를 묶는 가상 장치 |
| `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart/Stop` | 오디오 렌더링 콜백 |

### 3.2 동작 원리
```
[Chrome 프로세스들] ──(Process Tap, mutedWhenTapped)──┐
                                                      ▼
                         Private Aggregate Device { main sub-device = AirPods,
                                                    tap list = [Chrome tap] }
                                                      │ IOProc: 입력(탭) → 출력(AirPods) 복사
                                                      ▼
                                                   AirPods
[Chrome 원래 출력 경로] → 기본 출력(스피커)  ※ 탭을 읽는 동안 음소거됨
```

### 3.3 Aggregate Device 구성 (사전)
- `kAudioAggregateDeviceUIDKey`: `com.zinu.soundlanes.<route-id>` (고유)
- `kAudioAggregateDeviceNameKey`: `SoundLanes <앱 이름> → <장치 이름>`
- `kAudioAggregateDeviceIsPrivateKey`: `true` (다른 앱의 장치 목록에 노출되지 않게, 프로세스 종료 시 자동 정리)
- `kAudioAggregateDeviceMainSubDeviceKey`: 출력 장치 UID
- `kAudioAggregateDeviceSubDeviceListKey`: `[{ kAudioSubDeviceUIDKey: 출력 장치 UID }]`
- `kAudioAggregateDeviceTapListKey`: `[{ kAudioSubTapUIDKey: tap UUID, kAudioSubTapDriftCompensationKey: true }]`
- `kAudioAggregateDeviceTapAutoStartKey`: `true`

### 3.4 권한 (TCC)
- 오디오 캡처 권한(`NSAudioCaptureUsageDescription`)이 필요하다. 최초 탭 사용 시 시스템이 허용 창을 띄운다.
- CLI도 Info.plist가 필요하다 → 링커 옵션으로 바이너리에 임베드
  (`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`).
- 터미널에서 실행하면 권한이 **터미널 앱(Ghostty/iTerm)** 에 귀속될 수 있다. 메뉴 막대 앱(M3)은 자체 번들로 권한을 받는다.
- 권한 거부 시: 명확한 오류 메시지 + 시스템 설정 경로 안내 후 종료 코드 `3`.

#### M0에서 확인한 사실 (2026-10-22, macOS 27.0.1, iTerm2)
- 터미널에서 실행하면 TCC의 책임 프로세스(responsible process)는 **터미널 앱**이다. CLI에 넣은 Info.plist는 쓰이지 않는다.
- 터미널 앱 Info.plist에 `NSAudioCaptureUsageDescription`이 없으면(iTerm2가 그렇다) tccd는 **창을 띄우지 않고 거부**한다
  (`kTCCServiceAudioCapture`, `authValue=0`, `authReason=8`).
- 거부돼도 탭·aggregate·IOProc 생성과 `AudioDeviceStart`는 모두 성공을 반환한다. IO만 돌지 않는다
  (`kAudioDevicePropertyDeviceIsRunning = 0`, coreaudiod 로그: `Client is not granted access to the tap.`).
  → CLI는 "IO 주기 0 + 정지 상태"가 2초 이어지면 권한 없음으로 보고 종료 코드 `3`으로 끝낸다.
- 우회: 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 > **시스템 오디오 녹음만**에 터미널 앱을 직접 추가한다 (미검증).
- **앱 번들(`SoundLanes.app`)은 자기 자신이 책임 프로세스다.** `open`으로 실행하면 tccd가 `subject=com.zinu.soundlanes`로
  확인 창을 띄우고, 허용 후 IO가 정상으로 돈다 (2026-10-23 확인). 그래서 일상 사용은 앱으로 하고, CLI는 설정 편집·상태 확인·실험용으로 쓴다.
- 앱은 개발 인증서(Apple Development)로 서명한다. 서명이 같으면 다시 빌드해도 권한이 유지된다. ad-hoc 서명은 빌드마다 권한을 새로 받아야 할 수 있다.
- 출력 장치에 입력 스트림이 있으면(Background Music 같은 루프백 장치, AirPods 마이크) IOProc 생성이나 스트림 사용 설정 때
  **마이크 권한(`kTCCServiceMicrophone`)** 검사가 일어난다. 처음에는 확인 창이 뜨고, 응답할 때까지 해당 Core Audio 호출이 멈춘다.

---

## 4. 아키텍처

### 4.1 패키지 구성 (Swift Package)
```
SoundSource/
├── Package.swift
├── Sources/
│   ├── RouteCore/          # 라이브러리: Core Audio 래퍼, 라우팅 엔진 (UI 의존성 없음)
│   │   ├── AudioObject.swift       # AudioObjectGetPropertyData 등 안전한 Swift 래퍼 (C API는 여기서만 호출)
│   │   ├── DeviceCatalog.swift     # 출력 장치 목록, 이름/UID 해석
│   │   ├── ProcessCatalog.swift    # 오디오 프로세스 목록, 앱 이름 해석
│   │   ├── AppMatcher.swift        # 번들 ID 규칙 → 프로세스 집합, RoutePlanner, 특수 앱 프리셋(§5.2)
│   │   ├── TapRoute.swift          # 탭 1개 + aggregate 1개 + IOProc 1개의 수명주기
│   │   ├── IORenderer.swift        # IOProc 렌더링 (실시간 스레드, 할당·락 없음)
│   │   ├── AudioSystem.swift       # 엔진이 의존하는 프로토콜 + Core Audio 구현
│   │   ├── RouteEngine.swift       # 규칙 집합을 현재 상태에 맞춰 조정 (reconcile)
│   │   ├── Config.swift            # 설정 파일 로드/저장
│   │   └── Control.swift           # 단일 인스턴스 잠금, 제어 소켓 (status/reload)
│   ├── soundlanes/         # CLI (ArgumentParser)
│   └── SoundLanesApp/      # 메뉴 막대 앱 (SwiftUI MenuBarExtra)
├── Tests/RouteCoreTests/
├── Resources/              # CLI·앱 Info.plist, 앱 entitlements, AppIcon.icns
├── scripts/                # bundle-app.sh (앱 번들 생성·서명), make-icon.swift
├── CLAUDE.md
└── SPEC.md
```

### 4.2 RouteEngine: 선언형 조정(reconcile) 방식
- 입력: 규칙 목록(설정) + 현재 상태(실행 중 프로세스, 연결된 장치, 기본 출력)
- 출력: 있어야 할 `TapRoute` 집합. 현재 집합과 비교해 생성/삭제/재구성만 수행한다.
- 조정 트리거 (Core Audio property listener):
  - `kAudioHardwarePropertyProcessObjectList` 변경 (앱 실행/종료, 헬퍼 프로세스 생성)
  - `kAudioHardwarePropertyDevices` 변경 (장치 연결/해제)
  - `kAudioHardwarePropertyDefaultOutputDevice` 변경 (S5, S6)
  - `kAudioDevicePropertyDeviceIsAlive` (사용 중 장치 소멸)
- 짧은 시간에 이벤트가 몰리므로 **200ms 디바운스** 후 한 번만 조정한다.
- 모든 조정은 단일 직렬 큐(`DispatchQueue` 또는 actor)에서 수행한다. IOProc(실시간 스레드)와 분리.

### 4.3 TapRoute 수명주기
```
idle → creatingTap → creatingAggregate → running → (stopping) → destroyed
                 ↘ failed (오류 기록, 다음 조정 때 재시도: 1s, 2s, 4s… 최대 30s)
```
- 생성 순서: 탭 → aggregate → IOProc → start
- 해제 순서는 반대: stop → IOProc 삭제 → aggregate 삭제 → 탭 삭제
- 대상 프로세스 집합이 바뀌면(헬퍼 추가 등) 탭을 **재생성**한다. (탭의 프로세스 목록 변경이 실행 중 가능한지는 검증 필요 — 가능하면 재생성 대신 갱신)

### 4.4 IOProc (실시간 스레드) 규칙
- 메모리 할당, 락, Swift 클래스 참조 카운팅, 로깅, Objective-C 메시지 금지.
- 하는 일: 입력 버퍼(탭) → 출력 버퍼 복사, 채널 수가 다르면 단순 매핑(모노→스테레오 복제, 다채널→앞 2채널), 볼륨 게인 곱하기.
- 볼륨 값은 원자 변수(`Atomic<Float>`, Swift Synchronization)로 읽는다.
- 입력이 없으면 출력 버퍼를 0으로 채운다.

---

## 5. 앱 매칭 규칙

### 5.1 기본 규칙
- 규칙은 **번들 ID**로 지정한다 (예: `com.google.Chrome`).
- 해당 번들 ID와 **같거나 `<번들 ID>.` 로 시작하는** 오디오 프로세스를 모두 포함한다.
  - Chrome: 실제 소리는 `com.google.Chrome.helper` 계열 헬퍼 프로세스에서 난다.
- 번들 ID가 없는 프로세스는 v1에서 매칭하지 않는다 (CLI에서 PID 직접 지정은 디버그용으로만 제공).

### 5.2 알려진 특수 케이스
| 앱 | 문제 | v1 처리 |
|---|---|---|
| Safari | 소리가 `com.apple.WebKit.GPU` 등 공용 WebKit 프로세스에서 남. 다른 WebKit 앱과 섞일 수 있음 | 규칙에 `extraBundleIDs`로 명시 지정 가능. 기본 프리셋 제공 + "다른 WebKit 앱도 함께 라우팅될 수 있음" 경고 |
| Electron 앱 (Slack, Notion, VS Code 등) | 헬퍼 번들 ID가 `<id>.helper` 형태 | 기본 규칙으로 처리됨 |
| Zoom/FaceTime 등 통화 앱 | 음성 처리(에코 제거)가 출력 장치를 기준으로 동작 | 경고만 표시, 막지 않음 |

> 헬퍼 프로세스를 번들 ID 접두사로 찾는 방식이 실제 앱들에서 충분한지는 M0에서 검증한다.
> 부족하면 "responsible process"(앱을 실행한 부모 앱) 기준 매칭을 추가 검토한다 (비공개 API 사용 여부는 별도 결정).

---

## 6. 장치 처리

- 장치는 **UID**로 저장하고, 표시와 검색은 이름으로 한다. AirPods의 UID는 재연결해도 유지되는 것으로 예상하지만 검증 필요.
- 출력 스트림이 있는 장치만 대상으로 한다.
- 지정 장치가 없으면(연결 해제) 해당 규칙은 **비활성**: 탭을 해제해서 소리가 기본 출력으로 돌아가게 한다 (S2).
- 지정 장치가 현재 기본 출력과 같으면 탭을 만들지 않는다 (S6).
- **Bluetooth 주의 (검증 필요)**: aggregate에 AirPods를 넣을 때 입력 스트림까지 활성화되면
  AirPods가 통화용 저음질 모드(HFP)로 전환될 수 있다. **출력 스트림만** 사용하도록 구성하고, M0에서 음질을 확인한다.

---

## 7. 오디오 포맷과 동기화

- 탭 포맷은 `kAudioTapPropertyFormat`으로 읽는다 (보통 Float32, 스테레오 믹스다운 사용 시 2채널).
- aggregate의 클럭은 출력 장치(main sub-device)를 따르고, 탭에는 drift compensation을 켠다.
- **검증 필요**: 탭 샘플레이트와 출력 장치 샘플레이트가 다를 때 aggregate가 자동 변환하는지.
  자동 변환되지 않으면 IOProc 밖의 링 버퍼 + `AVAudioConverter` 경로를 추가한다 (설계 변경 사항으로 SPEC 갱신).
- 목표 추가 지연: 유선/내장 장치 기준 **20ms 이하** (Bluetooth 자체 지연은 제외).

### 7.1 알려진 한계: 영상 립싱크
영상 앱은 자신이 **기본 출력(스피커)** 으로 재생한다고 생각하고 그 장치의 지연을 기준으로 영상을 맞춘다.
실제로는 AirPods(약 150~250ms 지연)로 나가므로 **소리가 영상보다 늦게** 들릴 수 있다.
- v1: 한계로 문서화하고, `status`에 예상 추가 지연(출력 장치 latency − 원래 장치 latency)을 표시한다.
- 앱 쪽 영상을 늦출 방법은 없다. 대안으로 "AirPods를 기본 출력으로, 음악 앱을 스피커로 라우팅"하는 방식을 안내한다 (영상 앱이 실제 장치 지연을 알게 됨).

---

## 8. 설정

### 8.1 위치와 형식
`~/Library/Application Support/SoundLanes/routes.json`

```json
{
  "version": 1,
  "routes": [
    {
      "id": "8C1F…",
      "enabled": true,
      "app": { "bundleID": "com.google.Chrome", "extraBundleIDs": [] },
      "device": { "uid": "AA-BB-CC-DD-EE-FF:output", "name": "AirPods Pro" },
      "volume": 1.0
    }
  ]
}
```
- 같은 앱에 규칙이 여러 개면 오류 (v1은 앱당 출력 1개).
- `device.uid`가 빈 문자열이면 **시스템 기본 출력을 따른다** (2026-10-23 추가). 음량만 바꾸고 싶은 앱에 쓴다.
  음량이 100%이면 탭을 만들지 않고(S6과 같음), 100% 미만이면 현재 기본 출력으로 탭을 만들어 음량을 적용하며 기본 출력이 바뀌면 따라간다.
  지정 장치가 기본 출력과 같아도 음량이 100% 미만이면 같은 이유로 탭을 만든다.
- 알 수 없는 `version`이면 읽기 전용으로 동작하고 경고한다.
- 쓰기는 임시 파일에 쓴 뒤 원자적으로 교체한다.

---

## 9. CLI 명세 (`soundlanes`)

| 명령 | 설명 |
|---|---|
| `soundlanes devices` | 출력 장치 목록 (이름, UID, 기본 출력 여부, 샘플레이트, 지연) |
| `soundlanes apps [--all]` | 오디오 프로세스 목록 (앱 이름, 번들 ID, PID, 현재 재생 중 여부). 기본은 재생 중인 것만 |
| `soundlanes add <app> <device> [--volume 0.0-1.0]` | 규칙 추가/수정. `<app>`은 번들 ID 또는 앱 이름, `<device>`는 UID 또는 이름 일부 |
| `soundlanes remove <app>` | 규칙 삭제 |
| `soundlanes list` | 저장된 규칙 |
| `soundlanes run` | 포그라운드에서 규칙 적용 (Ctrl+C로 정리 후 종료) |
| `soundlanes status` | `run` 중인 인스턴스의 활성 라우트, 상태, 오류, 예상 추가 지연 |
| `soundlanes once <app> <device>` | 설정 저장 없이 즉시 라우팅 (실험용) |

- 이름 매칭이 여러 개면 후보를 보여주고 종료 코드 `2`.
- 종료 코드: `0` 성공, `1` 일반 오류, `2` 잘못된 인자/모호한 이름, `3` 권한 없음, `4` 지원하지 않는 macOS.
- `run`은 단일 인스턴스만 허용 (`~/Library/Application Support/SoundLanes/run.lock`).
- `status`는 `run`과 Unix 도메인 소켓으로 통신한다 (JSON 한 줄 요청/응답). 소켓: `~/Library/Application Support/SoundLanes/run.sock`
  - 요청 `{"command":"status"}` → 응답 `{"ok":true,"owner":"…","routes":[RouteStatus…]}`
  - 요청 `{"command":"reload"}`: `add`/`remove`가 설정을 저장한 뒤 보내서 실행 중인 인스턴스가 바로 적용하게 한다.
- 메뉴 막대 앱도 같은 잠금과 소켓을 쓴다. 앱이 실행 중이면 `soundlanes run`은 거부되고, `status`·`add`·`remove`는 앱에 그대로 적용된다.
- `SIGINT`, `SIGTERM`에서 모든 라우트를 정리한다. `SIGKILL`은 §10의 안전장치로 대응한다.

---

## 10. 안전성과 복구

- **mutedWhenTapped + private aggregate**: 프로세스가 비정상 종료돼도 탭 읽기가 멈추면서 원래 출력 음소거가 풀리고,
  private aggregate는 시스템이 정리한다 → S4 충족. M0에서 `kill -9`로 반드시 확인한다.
- 시작 시 이전 실행이 남긴 aggregate(UID 접두사 `com.zinu.soundlanes.`)가 있으면 삭제한다.
- 탭/장치 생성 실패는 해당 규칙만 `failed`로 두고 다른 규칙은 계속 동작한다.
- 오류는 `os_log` (subsystem `com.zinu.soundlanes`)로 기록한다. 확인: `log stream --predicate 'subsystem == "com.zinu.soundlanes"'`

---

## 11. 단계별 계획 (Milestones)

| 단계 | 상태 (2026-10-23) |
|---|---|
| M0 | 완료. 샘플레이트 불일치(§13-2)만 미확인 (§14) |
| M1, M2 | 완료. S1~S6 통과 (청취·측정·자동 테스트, §14) |
| M3 | 구현 완료: 메뉴 막대 앱, 앱별 장치·볼륨, 로그인 시 실행 |
| M4 | 앱 아이콘·오류 알림 완료. 지금은 이 맥 전용으로 쓴다(2026-10-23 결정). 공증은 Developer ID를 받은 뒤 `scripts/notarize.sh`로 한다 |

| 단계 | 범위 | 완료 조건 |
|---|---|---|
| **M0 기술 검증** | 하드코딩된 한 앱 → 한 장치. §3, §5, §6, §7의 "검증 필요" 항목 확인 | 검증 결과를 SPEC에 반영 (특히 샘플레이트 변환, AirPods 음질, kill -9 복구, 헬퍼 매칭) |
| **M1 CLI 단일 라우트** | `devices`, `apps`, `once` | S1 통과 |
| **M2 엔진** | 설정 파일, `add/remove/list/run/status`, reconcile, 장치·프로세스 감시 | S1~S6 통과 |
| **M3 메뉴 막대 앱** | SwiftUI `MenuBarExtra`: 재생 중인 앱 목록 + 앱별 출력 장치 선택 + 볼륨 슬라이더, 로그인 시 실행 (`SMAppService`) | CLI와 같은 설정 파일 공유, 동시에 둘 중 하나만 `run` |
| **M4 다듬기** | 앱 아이콘, 오류 알림, 코드 서명 + 공증(notarization) | 다른 맥에서 설치해 S1 통과 |
| (이후 검토) | 앱 하나를 여러 장치로 동시 출력, 앱별 EQ | v1 범위 밖 |

---

## 12. 테스트

### 12.1 자동 테스트 (`swift test`)
- `AppMatcher`: 번들 ID 접두사 규칙, extraBundleIDs, 번들 ID 없는 프로세스 제외
- `Config`: 직렬화/역직렬화, 버전 처리, 중복 규칙 오류, 원자적 저장
- `RouteEngine` 조정 로직: Core Audio를 프로토콜(`AudioSystem`)로 추상화하고 가짜 구현으로
  "장치 해제 → 라우트 삭제", "헬퍼 추가 → 탭 재생성", "지정 장치 = 기본 출력 → 탭 없음" 등을 검증

### 12.2 수동 테스트 매트릭스 (M2 이후 매 릴리스)
| 앱 | 출력 | 확인 |
|---|---|---|
| Chrome (YouTube) | AirPods | S1, S2, S3 |
| Safari (YouTube) | AirPods | 매칭, WebKit 경고 |
| Music, Spotify | 내장 스피커 / 외장 DAC | S1, 음질 |
| 아무 앱 | 라우팅 중 `kill -9` | S4 |
| 시스템 기본 출력 변경 | — | S5, S6 |

### 12.3 성능·품질 기준
- 30분 연속 재생 중 끊김·잡음 없음
- CPU 사용률: 라우트 1개당 평균 3% 미만 (M5 기준)
- 추가 지연: 유선/내장 장치 20ms 이하
- 메모리: 상주 50MB 미만

---

## 13. 미결정 사항 (Open Questions)
1. ~~헬퍼 프로세스 매칭~~ → 번들 ID 접두사로 충분함 (Chrome 확인, §14)
2. 샘플레이트 불일치 시 aggregate 자동 변환 여부 (§7)
3. ~~AirPods 고음질 유지~~ → 마이크 스트림을 끈 구성에서 유지됨 (§14)
4. ~~탭 대상 갱신~~ → macOS 27.0.1에서 실행 중 갱신 가능. 거부 시 재생성 경로 유지 (§14)
5. ~~CLI TCC 귀속~~ → 터미널 앱에 귀속. 앱 번들은 자기 권한을 받으므로 일상 사용은 앱으로 (§3.4)
6. ~~배포 이름 확정~~ → **SoundLanes** (CLI `soundlanes`, 번들 ID `com.zinu.soundlanes`)로 확정
7. CLI가 터미널 앱 대신 자기 자신으로 TCC 권한을 받게 할지. 방법은 `responsibility_spawnattrs_setdisclaim`(비공개 API)으로 자기 자신을 다시 실행하거나,
   CLI를 `.app` 번들에 넣는 것. 결정 전까지는 터미널 앱에 권한을 주는 방식으로 쓴다 (§3.4).
8. macOS 26에 추가된 `CATapDescription.bundleIDs`, `processRestoreEnabled`를 쓸지. 번들 ID로 탭을 지정하고 앱 재실행 시 자동 복원돼
   §5 헬퍼 매칭과 S3를 단순하게 만들 수 있지만, 최소 버전(15.0)에서는 쓸 수 없어 분기가 필요하다.

---

## 14. M0 검증 기록

검증 도구: `soundlanes once <app> <device> [--meter] [--keep-device-input]`. 시작 시 탭 포맷, 샘플레이트, aggregate 스트림 구성을 출력하고,
`--meter`는 1초마다 입력 레벨·IO 주기를 표시한다. 터미널 권한 문제(§3.4) 때문에 청취 검증은 앱으로 하는 편이 쉽다.

| # | 항목 | 상태 | 결과 |
|---|---|---|---|
| 1 | 탭 → aggregate → IOProc → start 생성과 역순 정리 | 확인 | HDMI 장치, Background Music 가상 장치에서 생성·SIGINT 정리 성공. 정리 후 남은 aggregate 없음 |
| 2 | CLI의 TCC 권한 귀속 (§13-5) | 확인 | 터미널 앱에 귀속. 사용 설명 문자열이 없는 터미널은 창 없이 거부 (§3.4) |
| 3 | 앱 번들의 권한 | 확인 | `SoundLanes.app`이 자기 이름으로 권한 창을 띄움. 허용 후 Music → 내장 스피커에서 IO 약 95주기/초, 탭 신호 수신, 탭 버퍼 누락 0. 실제로 들리는지는 미확인 |
| 4 | 헬퍼 매칭 (§13-1) | 확인 | Chrome(YouTube) 소리가 `com.google.Chrome.helper`에서 나고, 번들 ID 접두사 규칙으로 라우팅됨 (청취 확인). responsible process 매칭은 필요 없음 |
| 5 | aggregate 입력 스트림 순서 (장치 입력 다음에 탭) | 미확인 | 구현은 이 순서를 가정하고 앞쪽 장치 입력 스트림을 끈다. 틀리면 `--meter`에 "탭 버퍼 없음"이 늘어난다 |
| 6 | AirPods 고음질 유지 (§13-3) | 확인 | 장치 입력(마이크) 스트림을 IOProc 사용 목록에서 끈 구성에서 AirPods 음질 정상 (청취 확인) |
| 7 | 샘플레이트 불일치 자동 변환 (§13-2) | 미확인 | |
| 8 | 실행 중 탭 대상 프로세스 갱신 (§13-4) | 확인 | `kAudioTapPropertyDescription` 쓰기가 받아들여짐 (로그 `tap … updated in place`). 갱신 후 새 프로세스의 소리가 같은 레벨로 탭에 들어오고 IO 주기도 끊기지 않음. 거부되면 재생성하는 경로는 유지 |
| 10 | 앱 소리가 탭을 거쳐 지정 장치까지 가는지 (S1, 측정) | 확인 | `Tools/RouteCheck/run.sh`: −60 dBFS 톤을 내는 테스트 프로세스를 기본 출력(AirPods)이 아닌 내장 스피커로 라우팅. 탭 입력 −60.0 dBFS(재생 진폭과 일치), 스피커 IO 약 95주기/초 |
| 11 | 프로세스 재실행 시 자동 재적용 (S3, 측정) | 확인 | 같은 도구로 프로세스를 다시 실행하면 같은 레벨로 다시 측정되고, 종료 후에는 "재생 대기"로 돌아가 라우트가 정리됨 |
| 9 | `kill -9` 복구 (S4) | 확인 | 라우팅 중 `pkill -9 SoundLanes` → Chrome 소리가 바로 기본 출력으로 돌아옴 (청취 확인) |

### 청취 확인 (2026-10-23, 사용자, 앱 `/Applications/SoundLanes.app`, 기본 출력 AirPods Pro)
| 시나리오 | 결과 |
|---|---|
| S1 + G2: Chrome(YouTube) → MacBook 스피커 | 통과. 스피커에서만 들림, AirPods에서는 안 들림, 음질 정상 |
| S5: 라우팅 중 기본 출력 변경 | 통과. Chrome은 지정 장치에 남고 다른 앱만 따라감 |
| S2: Chrome → AirPods, AirPods 뺐다 끼우기 | 통과. 빼면 스피커로, 끼우면 AirPods로 자동 복귀. 음질 정상 |
| S4: 라우팅 중 `kill -9` | 통과. 바로 기본 출력으로 돌아옴 |
| S3 | 측정으로 확인 (항목 11) |
| S6 | 실제 장치에서 "기본 출력과 같음"으로 탭을 만들지 않는 것 확인 (M1 probe 로그), 자동 테스트 통과 |

남은 미확인: 샘플레이트 불일치 자동 변환(항목 7), "시스템 오디오 녹음만"에 터미널 추가(항목 3의 CLI 우회). 둘 다 앱 사용에는 영향 없다.

Background Music 드라이버는 BGMApp 없이는 루프백이 동작하지 않는다 (출력 중에는 입력 IO가 돌지 않고, 쉬는 중에는 0만 나옴).
그래서 루프백 녹음 대신 앱이 직접 잰 탭 입력 레벨과 IO 주기(`soundlanes status`)를 근거로 쓴다.

참고: 개발 맥에는 Rogue Amoeba ARK(`com.rogueamoeba.arkaudiod`)와 Background Music이 설치돼 있다. 결과가 이상하면 이 둘의 영향도 의심한다.
