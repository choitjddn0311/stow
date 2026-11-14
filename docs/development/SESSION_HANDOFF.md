# SESSION HANDOFF

**마지막 업데이트**: 2026-11-14

## 현재 상태
- **대기열·재생목록 구현 완료, PR 검증 중**(MVP 이후 3번, 브랜치 `feat/queue-playlist`). Sparkle(PR #14)은 병합됐지만 **배포하지 않음**(사용자 지시) — 0.3.0은 이 기능까지 넣은 뒤 배포 예정
- 로드맵 **4단계(UI·설정) 완료**: PR #6으로 병합(2026-11-14). MVP 기능(1~4단계) 완성.
- **UI 다듬기 완료**: PR #7로 병합(2026-11-14). Apple HIG 기준 A안(시스템 설정형), 사용자 확인("좋아"). 다음은 5a 배포(개발자 계정 없이)
- **5a 배포: 0.1.0 공개**(2026-11-14, 사용자 요청): PR #9 병합 후 main(`787895e`)에서 `release.sh --publish`로 초안을 만들고, 올라간 DMG 체크섬을 확인한 뒤 공개. https://github.com/choitjddn0311/stow/releases/tag/v0.1.0 . **다른 계정·기기 설치 테스트는 아직 하지 않음**(사용자가 테스트 전 공개를 선택)
- **앱 안 엔진 업데이트 완료**(MVP 이후 1번, PR #11 병합 2026-11-14). **v0.2.0 공개**(2026-11-14, PR #12, 태그 → `eb77a27`): 엔진 자동 업데이트를 포함한 첫 배포. https://github.com/choitjddn0311/stow/releases/tag/v0.2.0
- 설계와 로드맵: `PROJECT.md` 참고. MVP 이후 로드맵에 "글로벌 단축키 플로팅 패널" 추가(사용자 요청 2026-11-14, 세부 사항 미정)

## 로드맵 진행 상황
| 단계 | 상태 |
|---|---|
| 1. 기반 구축 | **완료** (2026-11-14, PR #1) |
| 2. 엔진 번들링 | **완료** (2026-11-14, PR #3) |
| 3. 추출 코어 | **완료** (2026-11-14, PR #4) |
| 4. UI·설정 | **완료** (2026-11-14, PR #6) |
| (UI 다듬기) | **완료** (2026-11-14, PR #7) |
| 5a. 배포(계정 없이) | **0.1.0 공개** (2026-11-14, PR #9). 다른 기기 설치 테스트 미완 |
| 5b. 서명·공증 | 미착수(Apple Developer 계정 준비 후) |
| (MVP 이후 1) 앱 안 엔진 업데이트 | **완료** (2026-11-14, PR #11). v0.2.0으로 공개 |
| (MVP 이후 2) 앱 자동 업데이트(Sparkle) | **완료** (2026-11-14, PR #14), 미배포 |
| (MVP 이후 3) 대기열·재생목록 | 구현 완료, PR 검증 중 |

## 대기열·재생목록 (2026-11-14, `feat/queue-playlist`)
- 사용자 결정: 한 번에 하나씩 추출, 재생목록은 목록을 보여 주고 고르기(비공개·삭제 영상 기본 제외), 재생목록 이름 하위 폴더(순번 없음), 포맷·저장 위치는 대기열에 넣을 때 고정. 설계는 PROJECT.md 5장
- `Stow/Core/Models/Playlist.swift`: `Playlist`·`PlaylistEntry`(ID 형식 검사, 주소는 ID로 생성), `FetchedMedia`(`_type`으로 영상/재생목록 구분, 잘못된 항목은 빼고 살림)
- `YtDlpClient.fetchMedia`(`AudioExtracting` 변경), 빈 재생목록 `.emptyPlaylist`, 채널은 `.channelNotSupported`(재생목록 주소는 허용)
- `Stow/Features/Queue/ExtractQueue.swift`: 순차 실행, 항목별 취소·제거·다시 시도, 완료 항목 지우기·모두 취소, 차단 시 일시 정지·`resume`, 하위 폴더 생성, 저장 위치 없으면 실패, 진행률은 보이는 값이 바뀔 때만, 대기열이 끝나면 알림 한 번, 앱 종료 시 진행 항목만 취소(`cancelAndWait`)
- `ExtractViewModel`: 주소 입력·불러오기·재생목록 선택·대기열에 추가만(추출 상태는 대기열로). 화면: "재생목록 영상"·"대기열" 섹션, 아래 바에 대기열 요약·"대기열에 추가"/"선택한 N개 추가"
- 테스트: `ExtractQueueTests`(10개), `ExtractViewModelTests` 재작성, 재생목록 해석, 네트워크 재생목록 테스트(`TEST_RUNNER_STOW_NETWORK_TEST_PLAYLIST=<URL>` 지정 시). 로컬 Debug `test` 99개 통과, 런타임 이슈 0건
- 아직 확인하지 않은 것: 실제 재생목록 URL 조회(사용자 URL 필요), 사용자 화면 점검

## 앱 자동 업데이트 Sparkle (2026-11-14, `feat/sparkle`)
- 사용자 결정: 도입, 하루 한 번 확인 후 설치 여부를 묻는다(Sparkle 기본 창), appcast는 최신 릴리스 파일(`releases/latest/download/appcast.xml`). 설계는 PROJECT.md 5장
- Sparkle 2.10.1(Swift Package, `Package.resolved` 고정, MIT·BSD·zlib), 메뉴 "업데이트 확인…", `Config/Stow-Info.plist`(SUFeedURL·SUPublicEDKey·자동 확인), 테스트 호스트에서는 시작 안 함
- **EdDSA 서명키**: 2026-11-14 이 Mac의 로그인 키체인에 생성(계정 `io.github.choitjddn0311.stow`), 공개키 `fWCstUEQ1NVBOQvE4GJPWcnjxorWPKAGqZBRMVfEN0w=`. 개인키 백업은 사용자가 해야 함(잃으면 기존 사용자에게 업데이트 불가)
- 발견·해결: ad-hoc 서명 + Hardened Runtime에서 라이브러리 검증이 Sparkle.framework 로드를 거부해 **Release 앱이 실행 즉시 종료**(프로젝트 설정은 Debug도 Hardened Runtime YES지만, Xcode가 ad-hoc 서명 Debug 빌드에서는 끈다 — 빌드 로그 "note: Disabling hardened runtime with ad-hoc codesigning", PROJECT.md 5장. 그래서 Debug 테스트·CI로는 안 잡힘) → `Config/Stow.entitlements`에 `disable-library-validation`(Release 설정에만, 5b에서 제거), `release.sh`에 앱 실제 실행 확인(5초) 추가
- 코드 리뷰(PR #14) 반영: `--publish` 시 빌드 번호가 직전 태그보다 커야 함(같으면 Sparkle이 업데이트를 알리지 않음), 실행 확인은 `STOW_DISABLE_UPDATERS=1`로 업데이터를 끄고 실행, Sparkle 도구 경로 확인, `SURequireSignedFeed`·`SUVerifyUpdateBeforeExtraction`, "업데이트 확인…"은 확인 가능할 때만 활성(`CheckForUpdatesButton`), 변경 사항 HTML 변환(링크·번호 목록, 오류 숨기지 않음), 엔타이틀먼트는 Release에만
- `release.sh`: Sparkle.framework·SUPublicEDKey 확인, 키체인 공개키와 앱 공개키 일치 확인, DMG EdDSA 서명·검증, appcast.xml 생성(변경 사항을 간단한 HTML로)·xmllint·서명·검증, 릴리스에 appcast.xml 함께 업로드. 서명키가 없으면 `--publish` 거부
- 로컬: Debug `test` 92개 통과, 런타임 이슈 0건. `release.sh`(올리지 않음)로 Release 빌드 → 실행 확인 → DMG → Sparkle 서명·appcast 생성·검증 통과
- 아직 확인하지 않은 것: 실제 업데이트(옛 버전 앱이 새 버전을 찾아 받아 설치). 피드가 공개되어야 가능 → 0.3.0 공개 후 버전을 낮춘 로컬 빌드로 확인

## 앱 안 엔진 업데이트 (2026-11-14, PR #11)
- 사용자 결정: 자동 확인 + 자동 설치(하루 한 번, 앱 시작 시), stable 채널. 설계는 PROJECT.md 5장 "엔진 업데이트"
- `Stow/Core/Engine/EngineUpdater.swift`: GitHub 최신 stable 확인, `yt-dlp`·`SHA2-256SUMS` 받기, SHA-256 대조, 번들 Python으로 `--version` 실행해 태그와 비교, 준비 폴더 → `Application Support/<번들 ID>/engine/yt-dlp/<버전>/yt-dlp`로 이동, `current` 기록, 옛 버전 정리. 버전 비교(숫자 단위), 버전 형식 검증(경로 조작 방지)
- `Stow/Core/Engine/EngineSource.swift`: 지금 쓸 엔진(잠금 보호). `YtDlpClient.engineSource`로 작업마다 시작할 때 읽음. `EngineLocator.replacingYtDlp(with:)`
- `Stow/Features/EngineUpdate/EngineUpdateCoordinator.swift`: 앱 시작 시(실행당 한 번) 받아 둔 버전이 번들보다 새롭고 실행되면 사용(아니면 삭제), 자동 확인·설치(실패는 조용히), 메뉴 "엔진 업데이트 확인…"·"앱에 들어 있는 엔진으로 되돌리기"는 결과를 NSAlert로. 테스트 호스트에서는 시작하지 않음(`XCTestConfigurationFilePath`)
- 테스트: `StowTests/EngineUpdaterTests.swift` — 버전 비교·형식, 체크섬 목록 해석, 실제 번들 yt-dlp를 가짜 응답으로 넣은 설치 성공·체크섬 불일치·버전 불일치·잘못된 릴리스 정보 거부, 옛 버전 정리, `EngineSource` 교체 반영. 네트워크 테스트(URL 지정 시): 실제 GitHub 최신 stable 읽기와 임시 폴더 설치(2026-11-14: 최신 stable 2026.10.26 = 번들 버전, 실제 받기·검증·설치 통과)
- 코드 리뷰(PR #11) 반영 9건: 활성화·옛 버전 정리는 실행당 한 번(창을 다시 열어도 추출 중 파일 삭제 없음), 확인 시각은 최신이거나 설치 성공일 때만 기록(실패하면 다음에 재시도), 앱이 켜져 있으면 1시간마다 확인 시점 점검(하루 지나면 확인), 메뉴 "앱에 들어 있는 엔진으로 되돌리기"(되돌린 버전은 자동 재설치 안 함, `rejectedEngineVersion`), 번들 버전을 모르면 받은 버전을 쓰지 않음, 받은 파일은 시작 시 실행해 보고 손상이면 번들로, 번들 버전은 `bin/yt-dlp.version`(fetch-binaries.sh가 기록, embed 스탬프에 최상위 목록 포함)에서 읽음, Accept 헤더는 API 요청에만, 버전 형식은 숫자만
- 테스트: `StowTests/EngineUpdateCoordinatorTests.swift`(활성화: 새 버전 사용·번들보다 새롭지 않으면 삭제·손상 파일 삭제·실행당 한 번, 자동 확인: 설치·실패 시 재시도 가능·최신 확인 기록, 되돌리기: 번들 복귀·같은 버전 재설치 안 함)
- 로컬 Debug `test` 92개 통과, 런타임 이슈 0건
- README에 GitHub 접속 사실 안내
- 아직 확인하지 않은 것: 실제로 새 stable이 나왔을 때 앱이 자동으로 받아 쓰는지(현재 번들 버전이 최신이라 재현 불가). 다음 yt-dlp 릴리스 후 확인

## 5a 배포 (2026-11-14, PR #9, v0.1.0)
- 번들 ID `io.github.choitjddn0311.stow`(테스트 `.tests`) 적용. 개발 중 저장한 설정은 옮겨지지 않음
- `scripts/release.sh`: 커밋된 상태만 허용 → 엔진 준비 → Release 빌드(`build/release/`) → 검증(서명 `--deep --strict`, arm64, 번들 ID·버전, 앱과 엔진 실행 파일의 Hardened Runtime, yt-dlp·deno 실행, ffmpeg GPL 구성 없음, 앱 안에 로컬 경로 없음) → DMG(앱, Applications 바로가기, "설치 안내.txt", UDZO) → SHA-256. `--publish`는 main이 origin/main과 같을 때만, 같은 태그가 없을 때만 GitHub Releases에 **초안**(태그 `v<MARKETING_VERSION>`)으로 올린다
- Release 빌드 심볼 제거: 검증 단계가 앱 실행 파일 디버그 맵에 남은 소스·빌드 경로(`/Users/...`)를 잡음 → 앱 대상 Release에 `DEPLOYMENT_POSTPROCESSING`·`STRIP_INSTALLED_PRODUCT`·`STRIP_STYLE = all`
- `README.md`(소개, 설치와 "그래도 열기" 안내, 이용 안내, 오픈소스 구성 요소·라이선스·FFmpeg/LAME 소스, 빌드 방법), `docs/release/INSTALL.txt`(DMG 안 설치 안내)
- 로컬 결과(0.1.0): DMG 63MB, `hdiutil verify` 통과, DMG 안 앱 서명 검증 통과, `spctl --assess`는 예상대로 rejected(공증 없음)
- 코드 리뷰(PR #9) 반영 9건: `--publish` 시 gh 로그인·기존 태그(로컬·원격)·릴리스 조회 실패 구분을 빌드 전에 확인, 빌드 설정을 변수로 받아 읽기(pipefail로 메시지 없이 멈추는 문제), 번들 ID를 빌드 설정에서 읽기, codesign 검사 실패 메시지, 경로 노출 검사에 홈 폴더 추가, 설치 안내를 macOS 14(Control-클릭 → 열기)와 15 이후(그래도 열기)로 구분, 릴리스 노트를 GitHub용 문구로, pbxproj 정렬. 반영 후 DMG 재생성 확인, `--publish`는 main이 아니면 아무것도 올리지 않고 멈춤 확인
- 아직 확인하지 않은 것: 인터넷에서 받은(격리 표시가 붙은) 상태로 "그래도 열기" 후 앱이 열리고, 앱 안 엔진(python·deno·ffmpeg)이 추가 경고 없이 실행되는지 → 다른 계정·기기 설치 테스트에서 확인
- 0.1.0 릴리스: DMG 65,811,856바이트, SHA-256 `1694db9fd9b739eea46e582ba68cf0ddb1aa124c307d520182ab8a470f46e05f`, 태그 `v0.1.0` → `787895e`. 업로드한 DMG를 다시 받아 체크섬·로컬 파일과 일치 확인
- 릴리스 중 발견한 버그: `release.sh`의 `"$TAG를"`처럼 변수 바로 뒤에 한글이 오면 bash가 한글까지 변수 이름으로 읽어 `set -u`에 걸림(0.1.0에서는 초안 생성 후 마지막 안내 메시지에서 실패, 릴리스에는 영향 없음. 같은 버그가 "태그가 이미 있음" 확인 메시지에도 있어, 그 경우 안내 대신 변수 오류로 멈췄다) → `${TAG}`로 수정. 재발 방지: CI "Lint scripts" 단계가 변수 바로 뒤 비ASCII 문자를 검사, `scripts/lib/common.sh` 머리말에 규칙 기록. 코드 리뷰(PR #10) 반영: `git ls-remote` 실패를 "태그 없음"으로 넘기지 않음, yt-dlp 검사도 찾은 Python 실행 파일 경로 사용

## UI 다듬기 (2026-11-14, PR #7)
- 시안 캔버스(Artifact, 비공개): https://claude.ai/artifact/8hdHa6wfW8TngvMrB9DAq2 — A 시스템 설정형, B 중앙 카드형, C 툴바 통합형, 공통 이용 고지. 디자인 시스템은 쓰지 않고 Apple HIG 기준(사용자 선택)
- 경과: B안을 먼저 구현(`5047a33`)했으나 사용자가 실제 화면을 보고 "없어 보인다"고 해 A안으로 교체(`9b5d76a`)
- A안 구현(`Stow/Features/Extract/ExtractView.swift`, 뷰만 변경, ViewModel·설정·코어는 그대로)
  - `Form` + `.formStyle(.grouped)`: "영상" 섹션(주소 칸, 상태 행: 안내/조회 중·취소/오류/썸네일·제목·채널·길이), "출력" 섹션(포맷 세그먼트, 음질 팝업 또는 "무손실", 저장 위치 경로 + "변경…")
  - 시스템 설정식 색 아이콘 배지(주소 파랑, 포맷 보라, 음질 주황, 저장 위치 하늘)
  - 하단 고정 바(`.safeAreaInset`, `.bar` 배경): 상태 문구 + 강조 추출 버튼(`.borderedProminent`, `.large`, Return), 추출 중 진행 막대·취소(Esc), 완료 시 "다른 영상 추출 / 다시 추출 / Finder에서 보기"
  - 강조색은 시스템 설정, 라이트/다크 자동, 상태 전환 애니메이션(동작 줄이기 설정이면 없음)
- 이용 고지(`Stow/App/UsageNotice.swift`): macOS 경고창 형식(아이콘·제목·본문·세로 버튼, "동의하고 시작"이 위)
- 검증: Debug `test` 73개 통과, 경고 없음, 런타임 이슈 0건. 사용자 화면 확인 완료
- 코드 리뷰(PR #7) 반영 9건: 완료 화면에서 주소 칸 Return이 다시 추출하지 않음, 이용 고지 문단을 반복 표시(문단 수 변경에 안전), 영상을 불러오기 전에는 추출 버튼 숨김, 준비 상태 문구를 "저장 위치: 폴더"로(폴더 존재는 추출 시 확인), 하단 바 오류 문구 최대 3줄 + 도움말, 영상 제목 텍스트 선택 가능, 주소 칸 왼쪽 정렬, 애니메이션 기준을 `ExtractViewModel.stage`로, 폴더 이름은 `AppSettings.outputFolderName`에 저장 위치가 바뀔 때만 계산
- 리뷰 지적 중 반영하지 않은 것 1건: "이용 고지를 실제 시트·경고창 대신 직접 그린 카드로 만들었다" — 시안에서 사용자가 본 디자인이고 동의 전 화면 전체를 대신하는 구조라 유지. 시스템 경고창 스타일 변화(고대비 등)는 따라가지 않음
- CI 실패 1회: `leftoverGrandchildDoesNotBlockTermination`이 CI 러너에서 5.48초로 5초 제한 초과(UI 변경과 무관, 병렬 실행 부하로 추정). "600초짜리 손자를 기다리지 않는다"만 확인하도록 제한을 30초로 완화

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

## 4단계 수동 시나리오 체크리스트 (완료 조건, 사용자 점검: 2026-11-14 전체 통과)
앱 실행: Xcode에서 실행하거나 `open build/DerivedData/Build/Products/Debug/Stow.app`. 첫 실행을 다시 보려면 `defaults delete io.github.choitjddn0311.stow`
- [x] 첫 실행 이용 고지가 뜨고, "종료"는 앱 종료, "동의하고 시작"은 추출 화면으로 이동. 다시 실행하면 고지가 뜨지 않음
- [x] 정상 추출 MP3(음질 선택), WAV, FLAC: 진행률 표시, 완료 알림, Finder에서 보기, 파일 재생
- [x] 주소를 붙여 넣으면 버튼 없이 자동으로 영상 정보를 불러옴. 불러오는 중 다른 주소로 바꾸면 새 주소로 다시 불러옴
- [x] 잘못된 URL(예: `https://example.com`): 주소 오류 문구
- [x] 비공개 영상, 연령 제한 영상: 각각의 오류 문구
- [x] 네트워크 끊김(Wi-Fi 끄고 불러오기·추출): 네트워크 오류 문구
- [x] 추출 중 취소: 준비 상태로 돌아가고 저장 위치에 파일이 남지 않음
- [x] 파일명 충돌: 같은 영상·같은 포맷을 두 번 추출하면 `제목 (2).확장자`
- [x] 앱 재시작 후 설정 유지: 포맷·음질·저장 위치
- [x] 추출 중 Cmd-Q(또는 창 닫기): 앱이 잠시 뒤 종료되고 yt-dlp·ffmpeg 프로세스가 남지 않음(활성 상태 보기에서 확인)
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
- 번들 ID: `io.github.choitjddn0311.stow`(사용자 결정 2026-11-14, 5a에서 적용, 테스트 대상은 `.tests`). 적용 후에는 개발 중 저장된 설정이 새 ID로 옮겨지지 않으며, 첫 실행 고지를 다시 보려면 `defaults delete io.github.choitjddn0311.stow`. Apple Developer 계정은 5b(서명·공증)에서만 필요
- 그 밖의 미정 사항은 `PROJECT.md` 8장 참고

## 다음 작업
- (완료) UI 다듬기: PR #7 병합 / 5a 배포: v0.1.0 공개
- (완료) v0.2.0 공개(2026-11-14): DMG 65840114바이트, SHA-256 `0e5c32ea94b0303f7f0468f07fbd4fe76697f3f2e00458db79a91dedb1027ed2`. 초안을 다시 받아 체크섬·로컬 파일 일치, DMG 안 앱 0.2.0·번들 yt-dlp 2026.10.26·서명 검증 확인 후 공개. 0.1.0 사용자는 새 DMG로 교체(번들 ID가 같아 설정 유지)
- 5a 남은 확인: 다른 Mac 또는 다른 사용자 계정에서 최신 DMG 설치(그래도 열기) → 추출까지 확인(사용자). 문제가 나오면 패치 버전으로 고친다
- 5b 서명·공증(계정 준비 후): Developer ID 서명·공증·stapler, Developer ID 서명에서 Python 확장 모듈 로드 확인, 앱 `disable-library-validation` 제거(Sparkle)
- MVP 이후: PROJECT.md 2장 목록(엔진 업데이트, Sparkle, 대기열, 결제, 글로벌 단축키 플로팅 패널 등). 글로벌 단축키 패널은 시작 전에 PROJECT.md 8장의 미정 사항을 사용자와 정한다
