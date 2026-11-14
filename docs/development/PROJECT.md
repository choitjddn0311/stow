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
- 파일명 충돌 처리, 사용자용 오류 메시지
- 첫 실행 이용 고지("권리가 있는 콘텐츠에만 사용"). 문구는 미정이고 법률 검토는 사용자가 진행한다.
- UI 언어: 한국어만 지원

### MVP 이후 (우선순위 순)
1. 앱 안에서 엔진(yt-dlp) 업데이트
2. 앱 자동 업데이트(Sparkle): **미정**
3. 여러 URL 대기열, 재생목록 추출
4. 결제와 라이선스: **미정**
5. 기타 후보: 다른 사이트 지원, 구간 자르기, 메뉴바 실행, 다국어 지원, Intel/Windows 지원

## 3. 기술 스택

| 영역 | 결정 |
|---|---|
| 언어/UI | Swift, SwiftUI(필요한 부분만 AppKit) |
| 최소 OS | macOS 14 Sonoma (`@Observable` 사용) |
| 아키텍처 | Apple Silicon(arm64) 전용 |
| 프로젝트 관리 | Xcode 프로젝트(`.xcodeproj`) 직접 사용, 폴더 동기화 그룹 사용(파일 추가 시 pbxproj 수정 불필요), 공유 스킴 `Stow` |
| Swift 언어 모드 | Swift 6 (엄격한 동시성) |
| 테스트 | Swift Testing (`@Test`, `#expect`), 앱 호스트 테스트 대상 `StowTests` |
| 번들 ID | `com.example.stow` **(임시, 5단계 전 확정 필요)** |
| 서명(개발) | 로컬 실행용 ad-hoc 서명(`-`), 팀 미지정 |
| 추출 엔진 | yt-dlp 단독 실행 파일(macOS용), 앱 번들에 포함, `Process`로 실행 |
| 변환 | ffmpeg/ffprobe **LGPL 구성으로 직접 빌드**(arm64, MP3·WAV·FLAC에 필요한 기능만, libmp3lame 포함) |
| 설정 저장 | `UserDefaults` |
| 서버/DB/인증 | 없음(모든 처리 로컬) |
| 배포 | Developer ID 서명 → notarytool 공증 → DMG → GitHub Releases. Mac App Store에는 배포하지 않음 |
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
├── Core/Settings/       # AppSettings (UserDefaults)
└── Resources/bin/       # yt-dlp, ffmpeg, ffprobe (서명 대상, git 미포함·스크립트로 생성)
StowTests/
scripts/                 # fetch-binaries.sh, build-ffmpeg.sh, release.sh
```

### 데이터 흐름
1. URL을 검증한다(호스트가 youtube.com 또는 youtu.be인지).
2. `yt-dlp -J`로 메타데이터를 조회한다 → `VideoMetadata`
3. `yt-dlp -x --audio-format <fmt> --audio-quality <q> --ffmpeg-location <bundle> --newline -o <template>`로 추출한다.
4. 출력을 한 줄씩 읽어 `ProgressParser`로 진행률을 파싱하고 UI에 반영한다.
5. 완료되면 알림을 띄우고 Finder에서 보기를 제공한다. 취소하면 자식 프로세스를 종료한다.

### ViewModel 상태
대기 → 조회 중 → 준비 → 추출 중 → 완료 / 실패

### 데이터 모델
- **설정**: 기본 저장 위치, 기본 포맷·품질
- **작업**: URL, 메타데이터, 옵션, 진행률, 결과 경로, 오류

## 5. 주요 설계 결정
- **yt-dlp 사용**: 유튜브가 바뀌어도 커뮤니티가 가장 빨리 고친다. Swift 자체 파서는 자주 고장 나서 배제했다.
- **엔진 업데이트**: MVP에서는 앱 릴리스 때 함께 갱신한다. MVP 직후 앱 안에서 업데이트하는 기능을 추가한다.
- **직접 배포**: 유튜브 다운로드 앱은 App Store 심사(가이드라인 5.2.3)에서 거절될 위험이 높다.
- **샌드박스 끔**: 포함한 실행 파일을 띄우고 임의 폴더에 저장하기 쉽게 하기 위해서다.
- **Hardened Runtime**: 프로젝트 설정은 YES. 단, Xcode가 Debug 빌드(`ENABLE_DEBUG_DYLIB=YES`)에서는 자동으로 끄므로, 런타임 플래그 확인은 Release 빌드로 한다.
- **LGPL ffmpeg**: 상용 배포 시 GPL 의무를 피하기 위해서다.
- **실행 파일은 git에 넣지 않음**: yt-dlp·ffmpeg 바이너리는 `scripts/`로 받거나 빌드해 `Stow/Resources/bin/`에 둔다(버전 고정, 체크섬 검증). 저장소 용량과 라이선스 관리를 위해서다. CI도 같은 스크립트를 실행한다.
- **보안**: 프로세스 인자는 배열로 전달한다. 포함한 실행 파일도 Hardened Runtime으로 서명한다.

## 6. 리스크
- **법적 리스크**: 유튜브 약관은 공식 기능이 아닌 다운로드를 금지한다. 상용화 전에 법률 검토가 필요하다(사용자 담당).
- **엔진 고장**: 유튜브 측 변경으로 yt-dlp가 고장 날 수 있다. 엔진 업데이트 기능으로 대응한다.
- **실행 지연**: yt-dlp 단일 파일 버전은 시작이 1~2초 늦다. 문제가 되면 압축을 풀어 둔 폴더 버전으로 바꾼다.

## 7. 개발 로드맵

| 단계 | 목표 | 주요 구현 | 선행 작업 | 완료 조건 | 테스트 |
|---|---|---|---|---|---|
| 1. 기반 구축 | 빌드되는 빈 앱 | Xcode 프로젝트(macOS 14, arm64, Hardened Runtime, 샌드박스 끔), 테스트 대상, git 초기화 | 없음 | `xcodebuild build/test` 성공, 앱 실행 시 빈 창 | CLI 빌드·테스트, 실행 확인 |
| 2. 엔진 번들링 | 포함한 엔진을 안전하게 실행 | yt-dlp 확보 스크립트(체크섬), ffmpeg LGPL 빌드 스크립트, `EngineLocator`, `ProcessRunner`(비동기, 줄 단위 출력, 취소) | 1 | 앱에서 `yt-dlp --version`과 `ffmpeg -version` 실행, 취소 후 남은 프로세스 없음, ffmpeg 구성에 GPL 없음 | ProcessRunner 단위 테스트, `ffmpeg -buildconf` 확인 |
| 3. 추출 코어 | UI 없이 추출 | `YtDlpClient`(메타데이터, 추출), 인자 생성, `ProgressParser`, `EngineError` 매핑 | 2 | 실제 영상으로 MP3 320, WAV, FLAC 생성·재생 확인 | 단위 테스트(픽스처), 네트워크 통합 테스트는 분리 |
| 4. UI·설정 | MVP 기능 완성 | ExtractView/ViewModel, 포맷·품질 선택, 저장 위치, 설정 기억, 진행률, 취소, 알림, Finder에서 보기, 충돌 처리, 오류 문구, 이용 고지 | 3 | 수동 시나리오 체크리스트 전체 통과 | 가짜 엔진으로 ViewModel 테스트, 수동 테스트 |
| 5. 배포 | 다른 Mac에서 설치·실행 | 포함한 실행 파일까지 서명, 공증, stapler, DMG, `release.sh` | 4, Apple Developer 계정 | `spctl --assess` 통과, 깨끗한 계정에서 설치해 추출 성공 | 다른 계정이나 기기에서 설치 테스트 |

**4단계 수동 시나리오**: 정상 추출(3개 포맷), 잘못된 URL, 비공개·연령 제한 영상, 네트워크 끊김, 추출 중 취소, 파일명 충돌, 앱 재시작 후 설정 유지.

## 8. 미정 사항
- WAV/FLAC 샘플레이트·비트 깊이 옵션
- 앱 자동 업데이트(Sparkle) 도입 여부
- 수익 모델, 결제
- 이용 고지 문구, 법률 검토
- 출력 파일명 규칙(기본값: 영상 제목)
- 번들 ID(현재 임시값 `com.example.stow`)
