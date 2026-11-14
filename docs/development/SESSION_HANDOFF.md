# SESSION HANDOFF

**마지막 업데이트**: 2026-11-14

## 현재 상태
- 로드맵 **3단계(추출 코어) 구현 완료, PR 검증 중** (브랜치 `feat/extract-core`). 병합 전까지는 "완료"로 표시하지 않는다.
- 2단계(엔진 번들링) 완료: PR #3으로 병합(2026-11-14).
- 설계와 로드맵: `PROJECT.md` 참고

## 로드맵 진행 상황
| 단계 | 상태 |
|---|---|
| 1. 기반 구축 | **완료** (2026-11-14, PR #1) |
| 2. 엔진 번들링 | **완료** (2026-11-14, PR #3) |
| 3. 추출 코어 | **구현 완료, PR 병합 대기** |
| 4. UI·설정 | 미착수 ← 다음 |
| 5. 배포 | 미착수 |

## 3단계 결정 사항 (사용자 결정 2026-11-14, PROJECT.md 반영)
- 메타데이터(제목·아티스트·날짜, MP3는 챕터 포함)를 넣는다. 썸네일(앨범 아트)은 MVP 이후
- 작업마다 임시 폴더에서 추출하고 결과만 저장 위치로 옮긴다(같은 폴더에서 포맷만 바꿔 연속 추출하면 yt-dlp가 이전 결과를 지우는 문제를 재현함)
- 파일 이름은 영상 제목, 충돌 시 ` (2)`처럼 번호를 붙이고 덮어쓰지 않는다(덮어쓰기 선택 등은 4단계에서 결정)

## 3단계에서 만든 파일
- `Stow/Core/Models/`: `AudioFormat`(MP3 128/192/320, WAV, FLAC)·`ExtractOptions`, `VideoMetadata`(`-J` 해석), `YouTubeURL`(youtube.com·youtu.be와 하위 도메인, 스킴 없으면 https, 재생목록·채널 경로 거부)
- `Stow/Core/Engine/YtDlpArguments.swift`: 공통 인자 `--ignore-config --no-playlist --color never --ffmpeg-location --js-runtimes deno:`, 추출 인자(`--embed-metadata`, `-P home:/temp:`, `-o %(id)s.%(ext)s`, 진행률·결과 경로 템플릿)
- `Stow/Core/Engine/ProgressParser.swift`: `[stow:download]`, `[stow:postprocess]`, `[stow:file]` 표식 줄만 해석 → `ExtractProgress`(downloading/converting/embeddingMetadata). 다운로드 진행은 stdout, 후처리 진행은 stderr로 나온다
- `Stow/Core/Engine/YtDlpClient.swift`: `fetchMetadata`(재생목록·라이브 거부), `extract`(임시 폴더 → `renamex_np(RENAME_EXCL)`로 원자적 이동, 취소 시 프로세스 종료를 기다린 뒤 정리하고 `CancellationError`), `FileNaming.sanitize`(`/`·`:` → `-`, 제어 문자·앞 점 제거, 200바이트 제한)
- `Stow/Core/Engine/EngineError.swift`: 사용자용 오류 22종과 한국어 문구, `YtDlpErrorMapper`(stderr `ERROR:` 줄만 분류, 403·429는 유튜브 차단, 못 하면 `.unknown(원문)`)
- `EngineLocator.ytDlpCommand`: `python3 -I -B -X utf8 yt-dlp ...`(Finder 실행 시 로케일과 무관하게 UTF-8)
- `scripts/build-ffmpeg.sh`: `ffmetadata` 디먹서 추가(챕터 삽입용)
- 테스트: `StowTests/ExtractCoreTests.swift`(URL·진행률·오류 매핑·메타데이터·인자·파일명), `StowTests/YtDlpClientTests.swift`(로컬 WAV를 `file://`로 넘기는 오프라인 E2E, 네트워크 테스트)

## 2단계 요약 (상세는 PR #3, PROJECT.md 5장)
- 엔진: yt-dlp 2026.10.26(zipimport) + Python 3.13.18(GPL `_dbm` 제거), deno 2.9.8, ffmpeg 9.0.2 + libmp3lame 3.100(LGPL 정적 빌드). 원본은 `engine/`(git 미포함), 빌드 단계 `scripts/embed-engine.sh`가 번들 `Contents/Resources/bin/`에 복사·서명
- `ProcessRunner`: posix_spawn, 새 프로세스 그룹, 줄 단위 출력(`\n`·`\r`), 취소 시 그룹 SIGTERM → 유예 후 SIGKILL

## 빌드·테스트 명령
```bash
scripts/fetch-binaries.sh   # 처음 한 번, 또는 버전 변경 시
scripts/build-ffmpeg.sh     # 처음 한 번, 또는 구성 변경 시
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test

# 네트워크 통합 테스트(실제 유튜브, 기본 test에서는 건너뜀). 결과 파일을 OUTPUT 폴더에 남긴다.
TEST_RUNNER_STOW_NETWORK_TEST_URL='<유튜브 URL>' TEST_RUNNER_STOW_NETWORK_TEST_OUTPUT=<폴더> \
  xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData test -only-testing:StowTests/YtDlpClientNetworkTests
```

## 테스트 결과 (2026-11-14, 로컬)
- Debug `test`: 49개 통과(매개변수 테스트는 1개로 셈), 네트워크 테스트 1개는 건너뜀
  - 오프라인 E2E: MP3 320/128, WAV, FLAC 각각 변환·메타데이터·이동·Core Audio 디코딩 확인, 충돌 시 `(2)`·`(3)`, 실패 시 저장 위치에 파일 없음
  - 취소: 10분 WAV를 FLAC으로 변환하는 중 취소 → `CancellationError`, 프로세스 종료 후 작업 폴더 삭제, 저장 위치 비어 있음
  - 저장 폴더가 없으면 `.outputDirectoryMissing`
- 네트워크 테스트(사용자 제공 URL `https://www.youtube.com/watch?v=B5cvbwOmfY0`, "Heya" 325초): 통과(33초)
  - MP3 320,076bps, WAV pcm_s16le, FLAC — 모두 48kHz 스테레오, 길이 325.0초, 제목·아티스트·날짜 태그 있음, Core Audio로 끝까지 디코딩됨
  - yt-dlp가 번들 deno로 유튜브 JS 챌린지 처리 확인(`-v`: `Solving JS challenges using deno`), 경고 없음
  - 사람이 직접 듣는 확인은 사용자에게 요청(결과 파일은 세션 임시 폴더에 있었음)
  - 코드 리뷰 반영 후 재실행: 첫 시도는 추출 단계에서 유튜브 HTTP 403으로 실패(`.blockedByYouTube`로 분류됨, 짧은 시간에 같은 영상을 반복 요청한 영향으로 추정), 바로 다시 실행해 통과

## 확인된 개발 환경
- macOS 26.6.2(arm64), Xcode 27.2, Swift 6.4.2, git 2.54, Homebrew
- 시스템에 ffmpeg, yt-dlp 없음. 엔진은 `engine/`에만 있음

## CI
- `.github/workflows/ci.yml`: 러너 `macos-26`, Xcode 26.6으로 고정(로컬은 27.2). 엔진 준비(캐시) → Debug 테스트 → Release 빌드 → 바이너리·엔진 검증. 네트워크 테스트는 CI에서 실행하지 않음
- PR에서만 실행(병합 후 main 재실행 없음). 검증 범위 기준은 `CONTEXT_GUIDE.md` 5장

## 미해결 문제 / 주의
- xcodebuild 실행 시 `DVTCoreDeviceCore` 플러그인 로드 실패, `CoreSimulator is out of date` 경고가 나옴. macOS 빌드와 테스트에는 영향 없음(미확인 해결책: `xcodebuild -runFirstLaunch`)
- Developer ID 서명에서 Python 확장 모듈 로드와 공증은 아직 확인하지 않음 → 5단계에서 확인
- 유튜브가 일시적으로 403을 줄 수 있다(3단계에서 1회 관찰). 4단계에서 `.blockedByYouTube`일 때 "다시 시도"를 제공할지 결정
- `YtDlpErrorMapper` 문구 규칙은 yt-dlp 문구에 의존한다. 엔진을 올릴 때 4단계 수동 시나리오(비공개·연령 제한·네트워크 끊김)로 다시 확인
- 비공개·연령 제한·네트워크 끊김 오류는 실제 영상으로 확인하지 않았다(단위 테스트로 문구만 확인) → 4단계 수동 시나리오에서 확인
- WAV는 원본(유튜브 opus/AAC, 보통 48kHz)을 16비트로 저장한다. 샘플레이트·비트 깊이 옵션은 미정(PROJECT.md 8장)
- `ProcessRunner`의 파이프는 `pipe()` 뒤 `FD_CLOEXEC`를 설정한다(macOS에 `pipe2` 없음). 그 사이 다른 곳에서 fork/exec하면 fd가 샐 수 있으나 유예 시간 뒤 종료를 알리므로 멈추지는 않음
- 오픈소스 고지 표시 방법, LGPL 소스 제공 방식 미정(라이선스 원문은 번들 `bin/licenses/`에 포함)
- 번들 ID는 임시값, 5단계 전에 Apple Developer 계정 필요
- 그 밖의 미정 사항은 `PROJECT.md` 8장 참고

## 다음 작업: 4단계 UI·설정 (3단계 PR 병합 후)
- ExtractView/ViewModel(상태: 대기 → 조회 중 → 준비 → 추출 중 → 완료/실패), 포맷·품질 선택, 저장 위치, 설정 기억(`UserDefaults`), 진행률, 취소, 완료 알림, Finder에서 보기, 파일명 충돌 처리 방식 결정, 오류 문구 표시(`EngineError.errorDescription`), 첫 실행 이용 고지
- ViewModel 테스트용 가짜 엔진이 필요하다 → `YtDlpClient`를 프로토콜로 추상화
- 완료 조건: PROJECT.md 7장 4단계 수동 시나리오 전체 통과
