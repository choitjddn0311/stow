# SESSION HANDOFF

**마지막 업데이트**: 2026-11-14

## 현재 상태
- 로드맵 **4단계(UI·설정) 구현 완료, 수동 시나리오 점검·PR 검증 중** (브랜치 `feat/ui-settings`). 수동 시나리오 전체 통과와 병합 전까지는 "완료"로 표시하지 않는다.
- 3단계(추출 코어) 완료: PR #4로 병합(2026-11-14).
- 설계와 로드맵: `PROJECT.md` 참고

## 로드맵 진행 상황
| 단계 | 상태 |
|---|---|
| 1. 기반 구축 | **완료** (2026-11-14, PR #1) |
| 2. 엔진 번들링 | **완료** (2026-11-14, PR #3) |
| 3. 추출 코어 | **완료** (2026-11-14, PR #4) |
| 4. UI·설정 | **구현 완료, 수동 점검 대기** |
| 5. 배포 | 미착수 |

## 4단계 결정 사항 (사용자 결정 2026-11-14, PROJECT.md 반영)
- 파일명 충돌: 번호를 붙인다(` (2)`). 덮어쓰기 선택 없음
- 유튜브 차단(`blockedByYouTube`): 알림창에 "다시 시도" 버튼. 그 밖의 오류는 화면 안에 문구로 표시
- 첫 실행 이용 고지: 초안 문구 사용(`Stow/App/UsageNotice.swift`, 버전 1). 동의 전에는 추출 화면 불가, "종료"는 앱 종료. 문구를 바꾸면 `version`을 올린다
- 자동 불러오기: "불러오기" 버튼 없이, 주소를 붙여 넣거나 입력을 멈추면 0.5초 뒤 자동으로 불러온다. 잘못된 주소는 그때 오류 문구. 조회 중 주소를 바꾸면 이전 조회를 버리고 새로 불러온다. Return은 바로 불러오기(불러온 뒤에는 추출)

## 4단계에서 만든 파일
- `Stow/Core/Settings/AppSettings.swift`: `@Observable` 설정(저장 위치 기본 "다운로드", 포맷 종류, MP3 음질 따로 기억, 이용 고지 동의 버전), `UserDefaults` 저장
- `Stow/Core/Engine/AudioExtracting.swift`: 조회·추출 프로토콜(`YtDlpClient`가 따름, 테스트는 가짜 엔진)
- `Stow/Features/Extract/ExtractViewModel.swift`: 상태(대기 → 조회 중 → 준비 → 추출 중 → 완료/실패), 주소를 바꾸면 처음 상태로, 취소하면 준비 상태로, 차단 시 `RetryAlert`, 완료 시 알림
- `Stow/Features/Extract/ExtractView.swift`: 주소 입력, 영상 정보(썸네일·제목·채널·길이), 포맷(세그먼트)·음질·저장 위치(`NSOpenPanel`), 진행률(다운로드 %·남은 시간, 변환·메타데이터 단계), 취소, 완료(Finder에서 보기·다른 영상 추출·다시 추출), 오류 문구, 차단 알림창
- `Stow/Features/Extract/CompletionNotifier.swift`: macOS 알림(처음 추출할 때 권한 요청, 앱이 앞에 있어도 배너, 알림을 누르면 Finder에서 표시)
- `Stow/App/UsageNotice.swift`(고지 문구·화면), `RootView.swift`(고지 → 추출 화면, 엔진 없으면 오류 문구), `StowApp.swift`(의존성 구성, 기본 창 600×540)
- 코드 리뷰 반영: 조회 중 취소 버튼, 알림 처리기를 앱 시작 시 등록(이전 알림 클릭 → Finder), 종료(Cmd-Q·창 닫기) 시 추출을 취소하고 엔진 종료를 기다린 뒤 앱 종료(`AppDelegate`), Return은 불러온 주소면 추출, 추출 전 저장 폴더 확인, 실행 ID로 이전 진행률 차단, 진행률은 퍼센트·남은 시간·단계가 바뀔 때만 갱신, 이용 고지에서 Esc로 종료되지 않음, `~` 경로 표시는 홈 폴더로 시작할 때만
- 테스트: `ExtractViewModelTests`(가짜 엔진, 자동 불러오기 포함), `AppSettingsTests`(재시작 후 유지), 스모크 테스트는 RootView를 `NSHostingView`로 렌더링(고지·추출 화면)
- 테스트 멈춤 원인과 수정: 스모크 테스트가 `ImageRenderer`로 추출 화면을 그리면 SwiftUI 런타임 이슈("Accessing FocusState's value outside of the body of a View")가 생긴다. XCTest가 이를 보고하려고 빌드 산출물을 심볼화하며 `~/Desktop` 아래 파일을 열고, 빌드마다 ad-hoc 서명이 바뀐 테스트 호스트가 데스크탑 폴더 권한 확인(TCC `kTCCServiceSystemPolicyDesktopFolder`)에 걸려 멈췄다(로그로 확인). `NSHostingView` 렌더링으로 바꾼 뒤 런타임 이슈 0건, 연속 5회 정상 종료(각 4초)

## 4단계 수동 시나리오 체크리스트 (완료 조건, 사용자 점검)
앱 실행: Xcode에서 실행하거나 `open build/DerivedData/Build/Products/Debug/Stow.app`. 첫 실행을 다시 보려면 `defaults delete com.example.stow`
- [ ] 첫 실행 이용 고지가 뜨고, "종료"는 앱 종료, "동의하고 시작"은 추출 화면으로 이동. 다시 실행하면 고지가 뜨지 않음
- [ ] 정상 추출 MP3(음질 선택), WAV, FLAC: 진행률 표시, 완료 알림, Finder에서 보기, 파일 재생
- [ ] 주소를 붙여 넣으면 버튼 없이 자동으로 영상 정보를 불러옴. 불러오는 중 다른 주소로 바꾸면 새 주소로 다시 불러옴
- [ ] 잘못된 URL(예: `https://example.com`): 주소 오류 문구
- [ ] 비공개 영상, 연령 제한 영상: 각각의 오류 문구
- [ ] 네트워크 끊김(Wi-Fi 끄고 불러오기·추출): 네트워크 오류 문구
- [ ] 추출 중 취소: 준비 상태로 돌아가고 저장 위치에 파일이 남지 않음
- [ ] 파일명 충돌: 같은 영상·같은 포맷을 두 번 추출하면 `제목 (2).확장자`
- [ ] 앱 재시작 후 설정 유지: 포맷·음질·저장 위치
- [ ] 추출 중 Cmd-Q(또는 창 닫기): 앱이 잠시 뒤 종료되고 yt-dlp·ffmpeg 프로세스가 남지 않음(활성 상태 보기에서 확인)
- [ ] (가능하면) 유튜브 차단 알림창과 "다시 시도" — 의도적으로 재현하기 어려우므로 ViewModel 테스트로 대신 확인함

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
- 4단계: Debug `test` 73개 통과(매개변수 테스트는 1개로 셈, 자동 불러오기 반영 후), 네트워크 테스트 1개는 건너뜀. 컴파일 경고 없음, 런타임 이슈 0건
  - 테스트가 끝난 뒤 앱 호스트가 종료되지 않는 멈춤이 약 10회 중 2회 있었다 → 원인 확인·수정(위 "4단계에서 만든 파일" 참고)
  - 실제 앱 화면 캡처는 터미널에 화면 녹화 권한이 없어 하지 못함 → 수동 시나리오에서 확인
- 3단계: Debug `test` 49개 통과
  - 오프라인 E2E: MP3 320/128, WAV, FLAC 각각 변환·메타데이터·이동·Core Audio 디코딩 확인, 충돌 시 `(2)`·`(3)`, 실패 시 저장 위치에 파일 없음
  - 취소: 10분 WAV를 FLAC으로 변환하는 중 취소 → `CancellationError`, 프로세스 종료 후 작업 폴더 삭제, 저장 위치 비어 있음
  - 저장 폴더가 없으면 `.outputDirectoryMissing`
- 네트워크 테스트(사용자 제공 URL `https://www.youtube.com/watch?v=B5cvbwOmfY0`, "Heya" 325초): 통과(33초)
  - MP3 320,076bps, WAV pcm_s16le, FLAC — 모두 48kHz 스테레오, 길이 325.0초, 제목·아티스트·날짜 태그 있음, Core Audio로 끝까지 디코딩됨
  - yt-dlp가 번들 deno로 유튜브 JS 챌린지 처리 확인(`-v`: `Solving JS challenges using deno`), 경고 없음
  - 사용자가 결과 파일(MP3)을 직접 들어 정상 재생 확인(2026-11-14)
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
- 유튜브가 일시적으로 403을 줄 수 있다(3단계에서 1회 관찰). 4단계에서 알림창 "다시 시도"로 대응
- 저장소가 데스크탑·문서 폴더 아래에 있으면, 테스트 중 SwiftUI 런타임 이슈가 생길 때 macOS 권한 확인 때문에 테스트가 멈출 수 있다. 런타임 이슈를 내는 코드(`ImageRenderer`로 기본 컨트롤 렌더링 등)를 테스트에 쓰지 않는다
- 저장 위치는 경로 문자열로 저장한다(샌드박스 끔). 폴더가 사라지면 추출 시 `outputDirectoryMissing` 문구
- `YtDlpErrorMapper` 문구 규칙은 yt-dlp 문구에 의존한다. 엔진을 올릴 때 4단계 수동 시나리오(비공개·연령 제한·네트워크 끊김)로 다시 확인
- 비공개·연령 제한·네트워크 끊김 오류는 실제 영상으로 확인하지 않았다(단위 테스트로 문구만 확인) → 4단계 수동 시나리오에서 확인
- WAV는 원본(유튜브 opus/AAC, 보통 48kHz)을 16비트로 저장한다. 샘플레이트·비트 깊이 옵션은 미정(PROJECT.md 8장)
- `ProcessRunner`의 파이프는 `pipe()` 뒤 `FD_CLOEXEC`를 설정한다(macOS에 `pipe2` 없음). 그 사이 다른 곳에서 fork/exec하면 fd가 샐 수 있으나 유예 시간 뒤 종료를 알리므로 멈추지는 않음
- 오픈소스 고지 표시 방법, LGPL 소스 제공 방식 미정(라이선스 원문은 번들 `bin/licenses/`에 포함)
- 번들 ID는 임시값, 5단계 전에 Apple Developer 계정 필요
- 그 밖의 미정 사항은 `PROJECT.md` 8장 참고

## 다음 작업
- 4단계 마무리: 위 수동 시나리오 체크리스트를 사용자가 점검 → 발견한 문제 수정 → PR 병합
- 이후 5단계 배포(Apple Developer 계정 필요, 번들 ID 확정, Developer ID 서명·공증·DMG)
