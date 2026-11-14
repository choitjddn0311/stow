# PROJECT — Stow

> 오래 유지되는 정보(목적, 설계, 로드맵)를 기록한다. 진행 상황은 SESSION_HANDOFF.md에 기록한다.

## 1. 목적
- **문제**: 유튜브 오디오 추출 사이트는 찾기 어렵고 도메인이 자주 바뀌어 꾸준히 쓸 수 없다.
- **해결**: 웹사이트에 의존하지 않는 로컬 macOS 앱. 링크를 붙여넣으면 원하는 품질과 위치로 오디오를 추출한다.
- **대상 사용자**: 일반 공개. 주 타깃은 크리에이터와 영상 편집자다.
- **성격**: 개인 프로젝트이면서 상용 서비스. MVP는 무료로 배포하고 수익 모델은 미정이다.

## 2. 기능 범위

### MVP
- 단일 유튜브 URL 입력(붙여넣기)과 검증
- 메타데이터 표시(제목, 길이, 썸네일)
- 포맷 선택: MP3(128, 192, 320kbps), WAV, FLAC
  - WAV, FLAC의 샘플레이트·비트 깊이 옵션은 미정. 기본값은 원본 유지.
- 저장 위치 선택, 기본값 기억
- 진행률 표시, 취소, 완료 알림, Finder에서 보기
- 파일명 충돌 처리(같은 이름이 있으면 ` (2)`처럼 번호를 붙인다, 2026-11-14 확정), 사용자용 오류 메시지. 유튜브가 요청을 막으면(`blockedByYouTube`) 알림창에 "다시 시도" 버튼을 띄운다(2026-11-14 확정)
- 첫 실행 이용 고지("권리가 있는 콘텐츠에만 사용"). MVP 문구는 초안으로 확정(2026-11-14, `Stow/App/UsageNotice.swift`), 법률 검토는 사용자가 진행한다. 동의 전에는 추출 화면을 쓸 수 없고, "종료"를 누르면 앱을 끈다. 문구 버전을 저장해 문구가 바뀌면 다시 보여 준다.
- UI 언어: 한국어만 지원

### MVP 이후 (우선순위 순)
1. 앱 안에서 엔진(yt-dlp) 업데이트
2. 앱 자동 업데이트(Sparkle): **도입**(2026-11-14 사용자 결정, 5장 참고)
3. 여러 URL 대기열, 재생목록 추출(2026-11-14 구현, 5장 "대기열·재생목록")
4. 결제와 라이선스: **미정**
5. 글로벌 단축키 플로팅 패널(2026-11-14 추가, 순서는 미정): 어느 앱에서든 전역 단축키를 누르면 Stow의 작은 플로팅 패널이 다른 창 위에 뜬다. 주소를 붙여 넣고(또는 클립보드의 유튜브 주소를 채우고) 저장된 설정으로 바로 추출한다. 메인 창을 열지 않고 쓰는 빠른 진입점이다.
   - 세부 사항(단축키 기본값·변경 기능, 클립보드 자동 입력 여부, 패널 크기·위치, 추출 중 동작, 구현 방식)은 미정(8장)
6. 기타 후보: 다른 사이트 지원, 구간 자르기, 메뉴바 실행, 다국어 지원, Intel/Windows 지원

## 3. 기술 스택

| 영역 | 결정 |
|---|---|
| 언어/UI | Swift, SwiftUI(필요한 부분만 AppKit) |
| 최소 OS | macOS 14 Sonoma (`@Observable` 사용) |
| 아키텍처 | Apple Silicon(arm64) 전용 |
| 프로젝트 관리 | Xcode 프로젝트(`.xcodeproj`) 직접 사용, 폴더 동기화 그룹 사용(파일 추가 시 pbxproj 수정 불필요), 공유 스킴 `Stow` |
| Swift 언어 모드 | Swift 6 (엄격한 동시성) |
| 테스트 | Swift Testing (`@Test`, `#expect`), 앱 호스트 테스트 대상 `StowTests` |
| 번들 ID | `io.github.choitjddn0311.stow` (2026-11-14 확정, 도메인이 없어 GitHub 아이디를 거꾸로 씀, 5a에서 적용). 테스트 대상은 `.tests` |
| 서명(개발) | 로컬 실행용 ad-hoc 서명(`-`), 팀 미지정 |
| 추출 엔진 | yt-dlp **zipimport 버전**(Unlicense) + 번들한 Python 런타임(python-build-standalone, CPython 3.13)으로 실행. 공식 macOS 단독 실행 파일은 GPLv3+ 코드를 포함해 쓰지 않음(2026-11-14 변경) |
| JS 런타임 | deno(MIT), 앱 번들에 포함. yt-dlp의 유튜브 전체 지원(yt-dlp-ejs)에 필요(2026-11-14 추가) |
| 프로세스 실행 | `posix_spawn`으로 새 프로세스 그룹에서 실행(`ProcessRunner`). 취소 시 그룹 전체 종료 |
| 변환 | ffmpeg/ffprobe **LGPL 구성으로 직접 빌드**(arm64, MP3·WAV·FLAC에 필요한 기능만, libmp3lame 포함) |
| 설정 저장 | `UserDefaults` |
| 서버/DB/인증 | 없음(모든 처리 로컬) |
| 배포 | GitHub Releases에 DMG로 배포. Mac App Store에는 배포하지 않음. **1차(5a)**: 개발자 계정 없이 ad-hoc 서명(사용자가 처음 실행할 때 "그래도 열기" 필요). **정식(5b)**: 계정 준비 후 Developer ID 서명 → notarytool 공증 → stapler (2026-11-14 변경) |
| 샌드박스 | 끔. Hardened Runtime은 켬 |

## 4. 아키텍처

### 디렉터리 구조 (예정)
```
Stow.xcodeproj
Stow/
├── App/                 # StowApp, 창 설정
├── Features/Extract/    # ExtractView, ExtractViewModel
├── Core/Engine/         # EngineLocator, ProcessRunner, YtDlpClient, ProgressParser, EngineError
├── Core/Models/         # VideoMetadata, ExtractOptions 등
└── Core/Settings/       # AppSettings (UserDefaults)
StowTests/
engine/                  # 엔진 원본: python/, yt-dlp, deno, ffmpeg, ffprobe, licenses/ (git 미포함·스크립트로 생성)
                         # 빌드 시 앱 번들 Contents/Resources/bin/으로 복사·서명
scripts/                 # fetch-binaries.sh, build-ffmpeg.sh, embed-engine.sh, entitlements/, release.sh
```

### 데이터 흐름
1. URL을 검증한다(호스트가 youtube.com 또는 youtu.be인지).
2. `yt-dlp -J`로 메타데이터를 조회한다 → `VideoMetadata`
3. 작업마다 만든 임시 폴더에서 `yt-dlp -x --audio-format <fmt> [--audio-quality <q>K] --embed-metadata --ffmpeg-location <bundle> --js-runtimes deno:<bundle> --ignore-config --no-playlist -o "%(id)s.%(ext)s"`로 추출한다(`YtDlpArguments`).
4. 진행률은 `--progress-template`으로 정한 표식(`[stow:download]`, `[stow:postprocess]`)을 붙여 출력하게 하고 `ProgressParser`로 파싱한다. 최종 경로는 `--print after_move:[stow:file] ...`로 받는다.
5. 결과 파일을 저장 위치로 옮긴다. 이름은 영상 제목(경로 문자 치환, 200바이트 제한), 같은 이름이 있으면 ` (2)`처럼 번호를 붙이고 덮어쓰지 않는다. 임시 폴더는 성공·실패·취소 모두 지운다.
   - 임시 폴더를 쓰는 이유: 같은 폴더에서 같은 영상을 다른 포맷으로 추출하면 yt-dlp의 중간 파일 이름이 이전 결과와 겹쳐 변환 후 "원본 삭제" 단계가 이전 결과를 지운다(3단계에서 재현).
6. 완료되면 알림을 띄우고 Finder에서 보기를 제공한다. 취소하면 자식 프로세스를 종료한다.
7. (MVP 이후 3번) 추출은 대기열(`ExtractQueue`)이 한 번에 하나씩 한다. 2~5단계를 항목마다 반복하고, 재생목록은 2단계에서 영상 목록(`--flat-playlist`)을 받아 고른 영상을 항목으로 넣는다.

### 상태
- 화면(`ExtractViewModel`): 대기 → 조회 중 → 영상 / 재생목록 선택 → (대기열에 추가하면) 대기, 또는 실패
- 대기열 항목(`ExtractQueue.Item`): 대기 → 추출 중 → 완료 / 실패 / 취소

### 데이터 모델
- **설정**: 기본 저장 위치, 기본 포맷·품질
- **작업**: URL, 메타데이터, 옵션, 진행률, 결과 경로, 오류

## 5. 주요 설계 결정
- **yt-dlp 사용**: 유튜브가 바뀌어도 커뮤니티가 가장 빨리 고친다. Swift 자체 파서는 자주 고장 나서 배제했다.
- **대기열·재생목록(2026-11-14 사용자 결정)**: 한 번에 하나씩 추출한다(유튜브 차단 위험을 줄이려고). 포맷·음질·저장 위치는 대기열에 넣을 때 항목에 고정한다. 재생목록 주소는 영상 목록을 보여 주고 고르게 하며(비공개·삭제 영상은 기본 제외), 저장 위치 아래 재생목록 이름의 하위 폴더에 저장한다(순번 없음). 채널 주소는 받지 않는다. 유튜브가 막으면(403·429) 대기열을 일시 정지하고 "다시 시도"를 띄운다. 완료 알림은 대기열이 끝날 때 한 번
- **앱 자동 업데이트(Sparkle 2, 2026-11-14 사용자 결정)**: 하루 한 번 확인하고, 새 버전이 있으면 변경 사항과 함께 설치 여부를 묻는다(Sparkle 기본 창). 메뉴 "업데이트 확인…".
  - 업데이트 목록 `appcast.xml`은 최신 릴리스에 함께 올리고 앱은 `releases/latest/download/appcast.xml`을 읽는다(`Config/Stow-Info.plist`의 `SUFeedURL`). `release.sh`가 DMG에 EdDSA 서명을 하고 appcast를 만들어 서명·검증한다
  - EdDSA 개인키는 릴리스하는 Mac의 키체인(계정 `io.github.choitjddn0311.stow`)에, 공개키는 `SUPublicEDKey`에. **개인키를 잃으면 기존 사용자에게 업데이트를 보낼 수 없으므로 반드시 백업한다**(`generate_keys --account io.github.choitjddn0311.stow -x <파일>`)
  - Sparkle로 설치한 업데이트에는 격리 표시가 붙지 않아 "그래도 열기"를 다시 하지 않아도 된다. 이미 공개된 0.1.0·0.2.0에는 Sparkle이 없어 Sparkle이 든 버전까지는 한 번 직접 바꿔 설치해야 한다
  - ad-hoc 서명에서는 라이브러리 검증이 Sparkle.framework 로드를 거부해 실행 즉시 종료되므로 앱에 `disable-library-validation`(`Config/Stow.entitlements`)을 준다. 5b(Developer ID)에서 뺀다
- **엔진 업데이트**: 앱 릴리스 때 번들 yt-dlp를 갱신하고, 앱 안에서도 yt-dlp를 업데이트한다(MVP 이후 1번, 2026-11-14 구현).
  - 사용자 결정: **자동 확인 + 자동 설치**(앱 시작 시 하루 한 번), **stable 채널**. 앱 메뉴 "엔진 업데이트 확인…"으로 바로 확인
  - 대상은 yt-dlp(zipimport) 하나. Python·deno·ffmpeg는 앱 릴리스로만 갱신한다
  - GitHub API(`repos/yt-dlp/yt-dlp/releases/latest`)로 확인하고, `yt-dlp`와 `SHA2-256SUMS`를 받아 SHA-256 대조 → 번들 Python으로 `--version`을 실행해 태그와 같을 때만 설치
  - 설치 위치는 앱 번들 밖 `~/Library/Application Support/<번들 ID>/engine/yt-dlp/<버전>/yt-dlp`(Python이 읽는 zip이라 서명·Gatekeeper 무관), 쓰는 버전은 같은 폴더의 `current`에 기록
  - 다음 추출부터 새 엔진을 쓴다(`EngineSource`). 진행 중인 추출은 그대로. 옛 버전은 실행 중 삭제를 피하려고 다음 앱 시작 때 지운다. 앱 업데이트로 번들 버전이 같거나 더 새로우면 받아 둔 것을 지운다
  - 릴리스 노트 = 제목 + `docs/release/notes/<버전>.md`(변경 사항, `--publish`에 필수) + 설치 안내. `scripts/release.sh --notes`로 미리보기
  - GPG 서명(`SHA2-256SUMS.sig`)은 검증하지 않는다(HTTPS + 같은 릴리스의 체크섬 목록). 자동 확인 실패는 조용히 넘기고 다음 확인 때 다시 시도(앱이 켜져 있으면 1시간마다 확인 시점 점검)
  - 받은 버전에 문제가 있으면 메뉴 "앱에 들어 있는 엔진으로 되돌리기". 되돌린 버전은 자동으로 다시 설치하지 않는다. 받은 파일이 실행되지 않으면 자동으로 번들 엔진을 쓴다
- **직접 배포**: 유튜브 다운로드 앱은 App Store 심사(가이드라인 5.2.3)에서 거절될 위험이 높다.
- **서명은 나중에(2026-11-14 사용자 결정)**: Developer ID 서명과 공증은 App Store와 별개로 유료 Apple Developer Program(연 $99)이 필요하다. 먼저 계정 없이 ad-hoc 서명 DMG로 배포하고(5a), 정식 배포 때 계정을 만들어 같은 배포 스크립트에 서명·공증 단계를 추가한다(5b). 서명·공증이 없으면 macOS가 처음 실행을 막고, macOS 15부터는 우클릭 → 열기로도 넘어갈 수 없어 시스템 설정 → 개인정보 보호 및 보안에서 "그래도 열기"를 눌러야 한다. 이 절차는 README·배포 안내에 적는다.
- **샌드박스 끔**: 포함한 실행 파일을 띄우고 임의 폴더에 저장하기 쉽게 하기 위해서다.
- **Hardened Runtime**: 프로젝트 설정은 YES. 단, Xcode가 Debug 빌드(`ENABLE_DEBUG_DYLIB=YES`)에서는 자동으로 끄므로, 런타임 플래그 확인은 Release 빌드로 한다.
- **LGPL ffmpeg**: 상용 배포 시 GPL 의무를 피하기 위해서다.
- **yt-dlp는 zipimport + 번들 Python**: 공식 PyInstaller 단독 실행 파일(`yt-dlp_macos`)은 GPLv3+ 코드를 포함해 결합물 전체가 GPLv3+이다(yt-dlp README). GPL 구성 요소 미포함 규칙을 지키기 위해 Unlicense(+MIT/ISC) 코드만 담긴 zipimport 버전을 번들한 Python으로 실행한다(`python3 -I -B yt-dlp ...`). 번들 크기가 약 40MB 늘어난다.
- **deno 포함**: yt-dlp는 유튜브 전체 지원에 JS 런타임을 요구하며 deno를 권장한다. 3단계에서 `--js-runtimes deno:<경로>`로 지정한다.
- **메타데이터 삽입**: `--embed-metadata`로 제목·아티스트·날짜 등을 넣는다(사용자 결정 2026-11-14). 챕터는 MP3만 들어간다(ffmpeg의 FLAC·WAV 출력은 챕터 미지원). 썸네일(앨범 아트) 삽입은 MVP 이후. 챕터 입력용으로 ffmpeg에 `ffmetadata` 디먹서를 켰다.
- **포함 실행 파일 엔타이틀먼트**: deno는 V8 JIT 때문에 `allow-jit`가 필요하다. Python은 ad-hoc 서명일 때만 `disable-library-validation`을 쓴다(ad-hoc은 Team ID가 없어 확장 모듈 로드가 거부됨). Developer ID 서명에서는 쓰지 않는다(`scripts/entitlements/`).
- **엔진 원본은 `engine/`**: `Stow/` 아래에 두면 폴더 동기화 그룹이 모든 파일을 `Resources/`에 평탄화해 복사하고, 폴더 단위 예외로도 막히지 않는다. 그래서 동기화 그룹 밖에 두고 빌드 단계(`embed-engine.sh`)에서 복사·서명한다.
- **실행 파일은 git에 넣지 않음**: 엔진 실행 파일은 `scripts/`로 받거나 빌드해 `engine/`에 둔다(버전 고정, 체크섬 검증). 저장소 용량과 라이선스 관리를 위해서다. CI도 같은 스크립트를 실행한다.
- **보안**: 프로세스 인자는 배열로 전달한다. 포함한 실행 파일도 Hardened Runtime으로 서명한다.

## 6. 리스크
- **법적 리스크**: 유튜브 약관은 공식 기능이 아닌 다운로드를 금지한다. 상용화 전에 법률 검토가 필요하다(사용자 담당).
- **엔진 고장**: 유튜브 측 변경으로 yt-dlp가 고장 날 수 있다. 엔진 업데이트 기능으로 대응한다.
- **실행 지연**: 번들 Python으로 yt-dlp를 시작하는 데 약 0.7초 걸린다(2단계 측정, `--version`). 표준 라이브러리는 미리 컴파일해 둔다.

## 7. 개발 로드맵

| 단계 | 목표 | 주요 구현 | 선행 작업 | 완료 조건 | 테스트 |
|---|---|---|---|---|---|
| 1. 기반 구축 | 빌드되는 빈 앱 | Xcode 프로젝트(macOS 14, arm64, Hardened Runtime, 샌드박스 끔), 테스트 대상, git 초기화 | 없음 | `xcodebuild build/test` 성공, 앱 실행 시 빈 창 | CLI 빌드·테스트, 실행 확인 |
| 2. 엔진 번들링 | 포함한 엔진을 안전하게 실행 | yt-dlp 확보 스크립트(체크섬), ffmpeg LGPL 빌드 스크립트, `EngineLocator`, `ProcessRunner`(비동기, 줄 단위 출력, 취소) | 1 | 앱에서 `yt-dlp --version`과 `ffmpeg -version` 실행, 취소 후 남은 프로세스 없음, ffmpeg 구성에 GPL 없음 | ProcessRunner 단위 테스트, `ffmpeg -buildconf` 확인 |
| 3. 추출 코어 | UI 없이 추출 | `YtDlpClient`(메타데이터, 추출), 인자 생성, `ProgressParser`, `EngineError` 매핑 | 2 | 실제 영상으로 MP3 320, WAV, FLAC 생성·재생 확인 | 단위 테스트(픽스처), 네트워크 통합 테스트는 분리 |
| 4. UI·설정 | MVP 기능 완성 | ExtractView/ViewModel, 포맷·품질 선택, 저장 위치, 설정 기억, 진행률, 취소, 알림, Finder에서 보기, 충돌 처리, 오류 문구, 이용 고지 | 3 | 수동 시나리오 체크리스트 전체 통과 | 가짜 엔진으로 ViewModel 테스트, 수동 테스트 |
| 5a. 배포(계정 없이) | 다른 Mac에서 설치·실행 | Release 빌드, DMG, `release.sh`, GitHub Releases 업로드, 설치 안내("그래도 열기") | 4 | 깨끗한 계정에서 안내대로 설치해 추출 성공 | 다른 계정이나 기기에서 설치 테스트 |
| 5b. 서명·공증 | 경고 없이 실행 | 포함한 실행 파일까지 Developer ID 서명, 공증, stapler를 `release.sh`에 추가 | 5a, Apple Developer 계정 | `spctl --assess` 통과, 경고 없이 설치·추출 성공 | 다른 계정이나 기기에서 설치 테스트 |

**4단계 수동 시나리오**: 정상 추출(3개 포맷), 잘못된 URL, 비공개·연령 제한 영상, 네트워크 끊김, 추출 중 취소, 파일명 충돌, 앱 재시작 후 설정 유지.

## 8. 미정 사항
- WAV/FLAC 샘플레이트·비트 깊이 옵션
- 수익 모델, 결제
- 이용 고지 문구의 법률 검토(MVP는 초안 사용)
- 출력 파일명 규칙: 영상 제목, 충돌 시 번호 붙임(2026-11-14 확정). 다른 규칙(채널명 포함 등) 선택 기능은 MVP 이후
- Apple Developer 계정을 만드는 시점(5b)
- 오픈소스 고지 표시 방법: 라이선스 원문은 번들 `Resources/bin/licenses/`에 포함. 앱 안 표시 방법(정보 화면 등)과 LGPL 소스 제공 방식은 미정
- 글로벌 단축키 플로팅 패널(MVP 이후 5번): 단축키 기본값과 사용자 변경 기능, 클립보드 주소 자동 입력 여부, 패널 크기·위치·항상 위 여부, 추출 중에 패널을 닫으면 어떻게 할지, 구현 방식(전역 단축키 등록 API 또는 외부 라이브러리 — 쓸 경우 GPL이 아닌 라이선스만, CLAUDE.md 규칙)
