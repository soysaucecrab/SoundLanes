# SoundLanes

앱마다 오디오 출력 장치를 따로 지정하는 macOS 메뉴 막대 앱입니다.
예를 들어 Music은 MacBook 스피커로, Chrome(YouTube)은 AirPods로 보낼 수 있습니다.

- 드라이버나 커널 확장을 설치하지 않습니다. macOS의 Core Audio Process Tap API만 사용합니다.
- 라우팅한 앱의 소리는 원래 출력에서 나지 않습니다(이중 재생 없음).
- SoundLanes가 종료되거나 강제 종료돼도 소리는 원래 기본 출력으로 돌아옵니다.
- 장치를 연결·해제하거나 앱을 다시 실행하면 자동으로 따라갑니다.

요구 사항: macOS 15 이상, Swift 6 툴체인 (Xcode 16 이상)

## 설치

```sh
scripts/bundle-app.sh release          # build/SoundLanes.app 생성
cp -R build/SoundLanes.app /Applications/
open /Applications/SoundLanes.app
```

처음 라우팅할 때 **시스템 오디오 접근 권한** 창이 뜹니다. 허용해야 동작합니다.
AirPods처럼 마이크가 달린 장치로 보낼 때는 마이크 권한 창이 뜰 수도 있습니다. SoundLanes는 마이크 소리를 쓰지 않습니다.

## 사용

메뉴 막대의 스피커 아이콘을 누르면 지금 소리를 내는 앱 목록이 나옵니다.
앱 옆에서 출력 장치를 고르면 바로 적용되고, 볼륨 슬라이더로 앱별 음량을 조절할 수 있습니다.
"기본 출력 따름"을 고르면 원래대로 돌아갑니다. "로그인 시 실행"을 켜면 로그인할 때 자동으로 시작합니다.

알려진 한계:
- 영상 앱을 지연이 큰 장치(AirPods 등)로 보내면 소리가 영상보다 늦을 수 있습니다. 이럴 때는 AirPods를 기본 출력으로 두고 음악 앱을 스피커로 보내는 편이 낫습니다.
- Safari는 공용 WebKit 프로세스로 소리를 내므로 다른 WebKit 앱의 소리도 함께 라우팅될 수 있습니다.

## 명령줄 도구

```sh
swift build
.build/debug/soundlanes devices                    # 출력 장치 목록
.build/debug/soundlanes apps [--all]               # 오디오를 쓰는 앱 목록
.build/debug/soundlanes add Chrome AirPods --volume 0.8
.build/debug/soundlanes list | remove Chrome | status
.build/debug/soundlanes run                        # 앱 없이 규칙 적용 (앱과 동시에 실행 불가)
```

CLI와 앱은 같은 설정 파일(`~/Library/Application Support/SoundLanes/routes.json`)을 씁니다.
앱이 실행 중이면 `add`/`remove`가 앱에 바로 적용됩니다.
터미널에서 `run`이나 `once`를 쓰면 오디오 권한이 터미널 앱에 귀속되므로, 일상 사용은 앱을 권장합니다.

## 개발

설계와 요구사항은 [SPEC.md](SPEC.md), 작업 규칙은 [CLAUDE.md](CLAUDE.md)를 봅니다.

```sh
swift test                 # 자동 테스트
/usr/bin/log stream --predicate 'subsystem == "com.zinu.soundlanes"' --level info
```

"SoundSource"는 Rogue Amoeba의 상용 제품명이며 이 프로젝트와 관계가 없습니다.
