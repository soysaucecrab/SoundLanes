# CLAUDE.md

앱별 오디오 출력 라우팅 도구 (이름 **SoundLanes**, CLI `soundlanes`).
예: Music → 내장 스피커, Chrome → AirPods. **전체 요구사항과 설계는 `SPEC.md`가 기준이다.** 구현 전에 반드시 읽는다.

## 현재 상태
- v1 완성: CLI 전체 명령, `RouteEngine`, 메뉴 막대 앱. S1~S6 청취·측정 확인 완료 (SPEC §14).
- 지금은 이 맥 전용. 다른 맥 배포는 Developer ID 발급 후 `scripts/notarize.sh` (SPEC §11 M4).
- M0 결과(§13 미결정 사항)는 코드보다 먼저 `SPEC.md`에 반영한다.

## 환경
- macOS 27.0.1, Apple Silicon (M5), Swift 6.4, Swift Package Manager
- 배포 최소 버전: macOS 15.0 (`platforms: [.macOS(.v15)]`). Process Tap API는 14.2부터지만 `Synchronization.Atomic`이 15.0부터다.
- 대상 모듈: `RouteCore` (라이브러리), `soundlanes` (CLI), `SoundLanesApp` (메뉴 막대 앱)

## 명령
```sh
swift build                          # 빌드
swift test                           # 자동 테스트 (RouteCoreTests)
swift run soundlanes devices         # 실행 예
scripts/bundle-app.sh [debug|release]   # build/SoundLanes.app 생성 + 개발 인증서 서명
open build/SoundLanes.app            # 앱 실행 (반드시 open으로: 권한이 앱에 귀속됨)
open -n build/SoundLanes.app --args --capture-menu /tmp/menu.png   # 메뉴 화면을 PNG로 저장 후 종료 (UI 확인용)
open -n build/SoundLanes.app --args --demo --capture-menu "$PWD/docs/media/menu.png"   # README 스크린샷 (예시 데이터, 라우팅 안 함)
Tools/RouteCheck/run.sh [deviceUID]  # 앱 실행 중에: −60 dBFS 테스트 톤으로 라우팅을 측정 (S1, S3)
/usr/bin/log stream --predicate 'subsystem == "com.zinu.soundlanes"' --level info   # 로그 확인 (zsh 내장 `log`와 겹치므로 전체 경로)
```

## 반드시 지킬 것
- **드라이버를 만들지 않는다.** 커널 확장, HAL 플러그인(`/Library/Audio/Plug-Ins/HAL`) 금지. 공개 Core Audio Process Tap API만 쓴다.
- 탭은 `CATapMuteBehavior.mutedWhenTapped`, aggregate는 `kAudioAggregateDeviceIsPrivateKey = true`로 만든다.
  프로그램이 죽어도 소리가 원래 출력으로 돌아와야 한다 (SPEC §10).
- 생성 순서는 탭 → aggregate → IOProc → start, 해제는 정확히 그 반대 순서로 한다. 모든 종료 경로(SIGINT, SIGTERM, 오류)에서 정리한다.
- aggregate UID는 `com.zinu.soundlanes.` 접두사를 쓴다. 시작 시 이 접두사로 남은 장치를 정리한다.
- **IOProc(실시간 오디오 스레드) 안에서는** 메모리 할당, 락, 로깅, `print`, Swift 클래스 참조 획득/해제, Objective-C 메시지를 금지한다.
  공유 값은 `Synchronization.Atomic`으로 읽고, 미리 할당한 버퍼만 쓴다.
- Core Audio 호출은 모두 `OSStatus`를 검사하고, 4글자 코드(예: `'!obj'`)를 포함한 Swift 오류로 바꾼다. 실패를 무시하지 않는다.
- 라우팅 상태 변경은 하나의 직렬 실행 컨텍스트(actor)에서만 한다. property listener 콜백은 이벤트만 넘기고, 200ms 디바운스 후 reconcile한다.

## 코드 규칙
- Swift 6 strict concurrency 활성화. 경고 없이 빌드되게 유지한다.
- Core Audio의 C API는 `AudioObject.swift`의 래퍼를 통해서만 부른다. 다른 파일에서 `AudioObjectGetPropertyData`를 직접 부르지 않는다.
- 앱 종료 처리: `terminate:`는 메인 큐 블록 안에서도 불린다. `applicationShouldTerminate`에서 MainActor 작업을 기다리면 교착된다.
  정리는 `AppModel.detachForShutdown()`으로 MainActor 밖에서 하고, `reply`는 `CFRunLoopPerformBlock`으로 보낸다.
- 화면 전체를 캡처하지 않는다 (사용자 화면에 개인 내용이 있을 수 있다). UI 확인은 `--capture-menu`로 앱 창만 그린다.
- `RouteEngine`은 `AudioSystem` 프로토콜에만 의존한다. 테스트는 가짜 구현으로 하고, 실제 오디오 장치가 필요한 테스트는 만들지 않는다.
- 사용자 메시지(CLI 출력, 오류)는 한국어, 코드·식별자·로그는 영어.
- 외부 의존성은 `swift-argument-parser`만 허용한다. 추가가 필요하면 먼저 사용자에게 묻는다.

## 검증
- 오디오 동작은 자동 테스트로 확인할 수 없다. 오디오 경로를 바꿨으면 SPEC §12.2의 수동 테스트 중 해당 항목을 사용자에게 요청하고, 결과를 받기 전에는 "동작함"이라고 말하지 않는다.
- `kill -9` 복구(S4)는 탭/aggregate 생성 코드를 바꿀 때마다 다시 확인한다.
- 터미널에서 실행하면 오디오 캡처 권한은 터미널 앱에 귀속된다 (SPEC §3.4). 권한이 없으면 `once`는 종료 코드 3으로 끝난다.
- 탭 문제를 볼 때는 coreaudiod 로그를 함께 본다: `/usr/bin/log stream --predicate 'process == "coreaudiod"'`

## 주의
- "SoundSource"는 Rogue Amoeba의 상용 제품명이다. 디렉터리 이름으로만 쓰고, 바이너리·번들 ID·UI 문구에는 쓰지 않는다.
- 번들 ID 접두사: `com.zinu.soundlanes`
