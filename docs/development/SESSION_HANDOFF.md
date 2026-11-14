# SESSION HANDOFF

**마지막 업데이트**: 2026-11-14

## 현재 상태
- 로드맵 **1단계(기반 구축) 완료.** 빈 SwiftUI 앱이 빌드·테스트·실행됨.
- 설계와 로드맵: `PROJECT.md` 참고

## 로드맵 진행 상황
| 단계 | 상태 |
|---|---|
| 1. 기반 구축 | **완료** (2026-11-14) |
| 2. 엔진 번들링 | 미착수 ← 다음 |
| 3. 추출 코어 | 미착수 |
| 4. UI·설정 | 미착수 |
| 5. 배포 | 미착수 |

## 1단계에서 만든 파일
- `Stow.xcodeproj/project.pbxproj`: 직접 작성(objectVersion 77, 폴더 동기화 그룹)
- `Stow.xcodeproj/xcshareddata/xcschemes/Stow.xcscheme`: 공유 스킴(빌드, 테스트, 실행)
- `Stow/App/StowApp.swift`, `Stow/App/RootView.swift`(임시 화면, 4단계에서 교체)
- `Stow/Assets.xcassets`: AppIcon 빈 슬롯, AccentColor
- `StowTests/StowSmokeTests.swift`: 스모크 테스트 3개
- `.gitignore`: Xcode 항목, 개인 가이드 파일(`00_`, `01_`) 제외
- `.github/workflows/ci.yml`, `.github/pull_request_template.md`: PR 검증 CI와 템플릿
- GitHub 저장소 `choitjddn0311/stow`(Public), `main` 브랜치 보호. 1단계는 PR #1로 병합

## 빌드·테스트 명령
```bash
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

## 테스트 결과 (2026-11-14)
- Debug·Release 빌드 성공
- `test`: 3개 테스트 통과(앱 호스팅 실행, 최소 OS 14 파싱 비교, RootView 실제 렌더링 픽셀 확인). 번들 ID 값 자체는 테스트하지 않음
- 바이너리 아키텍처: `arm64`만
- `LSMinimumSystemVersion` 14.0
- 샌드박스 엔타이틀먼트 없음
- Release 빌드 서명 플래그 `adhoc,runtime`(Hardened Runtime 적용). Debug는 Xcode가 자동으로 끔(PROJECT.md 5장). arm64·runtime·샌드박스 없음은 CI `Verify Release binary` 단계에서 자동 확인
- 앱 실행 시 창 표시 확인(스크린샷)
- Xcode GUI에서 앱 실행: 사용자 확인 완료(2026-11-14, "앱 잘 뜸")

## 확인된 개발 환경
- macOS 26.6.2(arm64), Xcode 27.2, Swift 6.4.2, git 2.54, Homebrew
- ffmpeg, yt-dlp는 시스템에 없음(2단계에서 앱 번들용으로 확보)

## CI
- `.github/workflows/ci.yml`: 러너 `macos-26`, Xcode 26.6으로 고정(로컬은 27.2). Debug 테스트와 Release 빌드를 실행함
- PR에서만 실행(병합 후 main 재실행 없음). 검증 범위 기준은 `CONTEXT_GUIDE.md` 5장
- 로컬과 CI의 Xcode 버전이 다르므로, 최신 SDK 기능은 CI에서 실패할 수 있음. Xcode를 올릴 때는 워크플로의 `XCODE_APP`도 함께 갱신

## 미해결 문제 / 주의
- xcodebuild 실행 시 `DVTCoreDeviceCore` 플러그인 로드 실패, `CoreSimulator is out of date` 경고가 나옴. macOS 빌드와 테스트에는 영향 없음. Xcode 구성 요소 불일치로 보이며 `xcodebuild -runFirstLaunch`로 해결될 가능성이 있음(미확인)
- 번들 ID는 임시값. 5단계 전에 확정 필요
- 5단계 전에 Apple Developer 계정(유료) 필요
- 그 밖의 미정 사항은 `PROJECT.md` 8장 참고

## 다음 작업: 2단계 엔진 번들링
- `scripts/fetch-binaries.sh`: yt-dlp macOS 단독 실행 파일 확보, 버전 고정과 체크섬 검증
- `scripts/build-ffmpeg.sh`: ffmpeg/ffprobe를 arm64, LGPL 구성으로 빌드(libmp3lame 포함, MP3·WAV·FLAC에 필요한 기능만)
- `Stow/Resources/bin/`에 넣고 앱 번들 복사와 서명 구성
- `Stow/Core/Engine/EngineLocator.swift`, `ProcessRunner.swift`(비동기, 줄 단위 출력, 취소 시 프로세스 종료)
- **완료 조건**: 앱에서 `yt-dlp --version`과 `ffmpeg -version`이 실행됨, 취소 후 남은 프로세스 없음, `ffmpeg -buildconf`에 GPL 구성 없음
- 결정됨: 실행 파일은 git에 넣지 않고 스크립트로만 받는다(`Stow/Resources/bin/`은 `.gitignore`). CI에서도 스크립트를 실행해야 하므로, ffmpeg 빌드 시간이 길면 CI 캐시(`actions/cache`)가 필요할 수 있음
