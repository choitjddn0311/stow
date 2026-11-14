# SESSION HANDOFF

**마지막 업데이트**: 2026-11-14

## 현재 상태
- 로드맵 **2단계(엔진 번들링) 구현 완료, PR 검증 중** (브랜치 `feat/engine-bundling`). 병합 전까지는 "완료"로 표시하지 않는다.
- 1단계(기반 구축) 완료: 빈 SwiftUI 앱이 빌드·테스트·실행됨(PR #1).
- 설계와 로드맵: `PROJECT.md` 참고

## 로드맵 진행 상황
| 단계 | 상태 |
|---|---|
| 1. 기반 구축 | **완료** (2026-11-14) |
| 2. 엔진 번들링 | **구현 완료, PR 병합 대기** |
| 3. 추출 코어 | 미착수 ← 다음 |
| 4. UI·설정 | 미착수 |
| 5. 배포 | 미착수 |

## 2단계에서 바뀐 설계 (사용자 승인 2026-11-14, PROJECT.md 반영)
- yt-dlp 공식 macOS 단독 실행 파일은 GPLv3+ 코드를 포함한다 → **zipimport 버전 + 번들 Python 런타임**으로 대체
- 유튜브 전체 지원에 JS 런타임이 필요하다 → **deno 포함**
- 엔진 원본 위치 `Stow/Resources/bin/` → **`engine/`** (폴더 동기화 그룹이 평탄화 복사하는 문제, 앱 번들 안 위치는 `Contents/Resources/bin/` 그대로)

## 2단계에서 만든 파일
- `scripts/lib/common.sh`: 경로, 체크섬 검증 다운로드, 버전 기록(`engine/.versions/`)
- `scripts/fetch-binaries.sh`: yt-dlp 2026.10.26(zipimport), Python 3.13.18(python-build-standalone 20261110, 불필요 모듈 제거·표준 라이브러리 미리 컴파일), deno 2.9.8. 버전·SHA256 고정. 로컬 경로가 배포 파일에 남지 않았는지 검사
- `scripts/build-ffmpeg.sh`: ffmpeg 9.0.2 + libmp3lame 3.100 정적 빌드(LGPL, `--disable-everything` 후 필요한 것만, `--disable-autodetect`). 빌드 후 GPL/nonfree/version3, 로컬 경로, arm64, 시스템 외 링크 검사. 로컬 빌드 약 1분
- `scripts/embed-engine.sh`: Xcode 빌드 단계 "Embed Engine". `engine/` → 번들 `Contents/Resources/bin/` 복사, Mach-O를 Hardened Runtime으로 서명. 변경 없으면 건너뜀(`.embedded` 스탬프). 엔진이 없으면 안내 메시지와 함께 빌드 실패
- `scripts/entitlements/`: `deno.entitlements`(allow-jit), `python-adhoc.entitlements`(ad-hoc일 때만 disable-library-validation)
- `Stow/Core/Engine/EngineError.swift`, `EngineLocator.swift`(구성 요소 경로·검증, `ytDlpCommand`는 `python3 -I -B yt-dlp ...`), `ProcessRunner.swift`(posix_spawn, 새 프로세스 그룹, 줄 단위 출력 스트림, 취소 시 그룹 SIGTERM → 유예 후 SIGKILL)
- `StowTests/ProcessRunnerTests.swift`(8개), `StowTests/EngineBundleTests.swift`(8개)
- Xcode: Stow 대상에 "Embed Engine" 빌드 단계, `ENABLE_USER_SCRIPT_SANDBOXING = NO`(Stow 대상만, 스크립트가 `engine/`을 읽기 때문)
- CI: 엔진 캐시(`build/engine-cache`), 스크립트 실행, Release 번들 엔진 검증 단계 추가. timeout 45분

## 빌드·테스트 명령
```bash
scripts/fetch-binaries.sh   # 처음 한 번, 또는 버전 변경 시
scripts/build-ffmpeg.sh     # 처음 한 번, 또는 구성 변경 시
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

## 테스트 결과 (2026-11-14, 로컬)
- Debug `test`: 19개 통과(스모크 3, ProcessRunner 8, 엔진 8)
  - 앱 안에서 `yt-dlp --version`(2026.10.26), `ffmpeg -version`, `ffprobe -version`, deno JS 실행, Python 확장 모듈 로드
  - ffmpeg: GPL/nonfree/version3 없음, LGPL 라이선스, libmp3lame·flac·pcm 인코더 있음
  - 취소: 자식과 손자 프로세스 모두 종료, SIGTERM 무시 프로세스도 SIGKILL로 종료
- Release 빌드: 엔진 Mach-O 5개 모두 `adhoc,runtime`, `codesign --verify --deep --strict` 통과, 번들 안에서 실행 확인. 앱 크기 약 129MB(deno 81MB, Python 39MB)
- 테스트 실행 후에도 앱 서명 유효(-B로 번들 안에 .pyc를 쓰지 않음)

## 확인된 개발 환경
- macOS 26.6.2(arm64), Xcode 27.2, Swift 6.4.2, git 2.54, Homebrew
- 시스템에 ffmpeg, yt-dlp 없음. 엔진은 `engine/`에만 있음

## CI
- `.github/workflows/ci.yml`: 러너 `macos-26`, Xcode 26.6으로 고정(로컬은 27.2). 엔진 준비 → Debug 테스트 → Release 빌드 → 바이너리·엔진 검증
- PR에서만 실행(병합 후 main 재실행 없음). 검증 범위 기준은 `CONTEXT_GUIDE.md` 5장
- 로컬과 CI의 Xcode 버전이 다르므로, 최신 SDK 기능은 CI에서 실패할 수 있음. Xcode를 올릴 때는 워크플로의 `XCODE_APP`도 함께 갱신

## 미해결 문제 / 주의
- xcodebuild 실행 시 `DVTCoreDeviceCore` 플러그인 로드 실패, `CoreSimulator is out of date` 경고가 나옴. macOS 빌드와 테스트에는 영향 없음. `xcodebuild -runFirstLaunch`로 해결될 가능성이 있음(미확인)
- Developer ID 서명에서 Python 확장 모듈 로드(라이브러리 검증 통과)와 공증은 아직 확인하지 않음 → 5단계에서 확인
- ffmpeg는 필요한 구성 요소만 켰다. 3단계 실제 추출에서 빠진 디먹서·디코더가 드러나면 `build-ffmpeg.sh`에 추가
- yt-dlp는 사용자 설정 파일(`~/.config/yt-dlp/config` 등)을 읽는다 → 3단계 인자 생성 시 `--ignore-config` 사용 필요
- 오픈소스 고지 표시 방법, LGPL 소스 제공 방식 미정(라이선스 원문은 번들 `bin/licenses/`에 포함)
- 번들 ID는 임시값. 5단계 전에 확정 필요
- 5단계 전에 Apple Developer 계정(유료) 필요
- 그 밖의 미정 사항은 `PROJECT.md` 8장 참고

## 다음 작업: 3단계 추출 코어 (2단계 PR 병합 후)
- `YtDlpClient`(메타데이터 `-J`, 추출), 인자 생성(`--ignore-config`, `--ffmpeg-location`, `--js-runtimes deno:<경로>`, `--newline`), `ProgressParser`, `EngineError` 매핑
- 완료 조건: 실제 영상으로 MP3 320, WAV, FLAC 생성·재생 확인
- 단위 테스트(픽스처), 네트워크 통합 테스트는 분리
