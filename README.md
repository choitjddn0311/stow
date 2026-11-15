# Stow

유튜브 링크를 붙여 넣으면 오디오를 MP3·WAV·FLAC으로 저장하는 macOS 앱입니다.
웹사이트에 의존하지 않고 Mac에서 직접 추출합니다.

- 주소를 붙여 넣으면 제목·채널·길이·썸네일을 자동으로 불러옵니다
- MP3(128/192/320kbps), WAV, FLAC. 제목·아티스트 등 메타데이터를 함께 넣습니다
- 저장 위치와 포맷을 기억하고, 같은 이름의 파일이 있으면 덮어쓰지 않고 번호를 붙입니다

**필요 환경**: macOS 14 Sonoma 이상, Apple Silicon(M1 이후) Mac

## 다운로드와 설치

[Releases](https://github.com/choitjddn0311/stow/releases)에서 `Stow-<버전>.dmg`를 받습니다.

1. DMG를 열고 Stow를 "Applications"(응용 프로그램) 폴더로 끌어다 놓습니다.
2. Stow는 아직 Apple 개발자 서명·공증을 받지 않아서, 처음 열 때 macOS가 실행을 막습니다. 한 번만 허용해 주세요.
   - **macOS 15 Sequoia 이후**: Stow를 열면 "악성 코드가 없음을 확인할 수 없습니다" 경고가 나옵니다. "완료"를 누른 뒤
     **시스템 설정 → 개인정보 보호 및 보안**의 "보안" 항목에서 "그래도 열기"를 누르고 암호나 Touch ID로 확인합니다.
     다시 Stow를 열고 "열기"를 누릅니다.
   - **macOS 14 Sonoma**: Finder의 응용 프로그램 폴더에서 Stow를 Control-클릭(또는 우클릭) → "열기" → 경고창에서 "열기"를 누릅니다.
3. 한 번 열고 나면 이후에는 경고 없이 열립니다.

터미널에 익숙하다면 버전과 관계없이 `xattr -dr com.apple.quarantine /Applications/Stow.app`로도 열 수 있습니다.
받은 파일이 맞는지는 릴리스에 함께 올린 `.sha256`과 `shasum -a 256 Stow-<버전>.dmg` 결과를 비교해 확인할 수 있습니다.

**네트워크 접속**: 영상 정보 조회·다운로드 외에, 앱 새 버전(Sparkle)과 추출 엔진(yt-dlp)을 최신으로 유지하려고 하루에 한 번 GitHub(`api.github.com`, `github.com`, 파일 서버 `*.githubusercontent.com`)에서 새 버전을 확인합니다. 앱 새 버전은 설치 전에 묻고, yt-dlp는 자동으로 받습니다. 이름이나 파일 같은 개인 정보는 보내지 않지만, IP 주소와 접속 시각은 GitHub에 남습니다. 메뉴 "엔진 업데이트 확인…"으로 바로 확인할 수도 있습니다.

**빠른 추출**: 어느 앱에서든 ⌥⌘Y(설정에서 변경)를 누르면 작은 패널이 뜹니다. 이때 클립보드 첫 항목이 유튜브 주소면 채워서 바로 불러오고, Return을 누르면 지금 설정으로 대기열에 넣습니다. 클립보드는 패널을 열 때 주소처럼 보일 때만 읽고, 유튜브 주소가 아니면 쓰지 않으며 유튜브 외의 곳으로 보내지 않습니다(macOS 15.4 이상에서는 처음 읽을 때 확인창이 뜹니다). 창을 닫아도 Stow는 메뉴 막대에 남아 있으며, 끝내려면 ⌘Q나 메뉴 막대 메뉴의 "Stow 종료"를 쓰세요.

## 이용 안내

Stow는 본인이 저작권을 가지고 있거나 사용 허락을 받은 영상의 오디오를 추출하는 도구입니다.
다른 사람의 저작물을 허락 없이 내려받거나 배포하면 저작권법이나 YouTube 이용약관을 위반할 수 있으며,
그에 따른 책임은 사용자에게 있습니다.

## 오픈소스 구성 요소

앱 안에 아래 프로그램을 함께 넣어 실행합니다. 라이선스 원문은 앱의 `Contents/Resources/bin/licenses/`에 있습니다.

| 구성 요소 | 용도 | 라이선스 |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) (zipimport 버전) | 영상 정보 조회, 다운로드 | Unlicense (MIT·ISC 포함 코드 일부) |
| [Python](https://www.python.org) ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) | yt-dlp 실행 | PSF 라이선스 등(원문 참고) |
| [deno](https://deno.com) | 유튜브 JavaScript 처리 | MIT |
| [FFmpeg](https://ffmpeg.org) | 오디오 변환 | LGPL 2.1 이상 |
| [LAME](https://lame.sourceforge.io) | MP3 인코딩 | LGPL |
| [Sparkle](https://sparkle-project.org) | 앱 자동 업데이트 | MIT (포함된 bsdiff·ed25519 등은 BSD·zlib 계열) |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 빠른 추출 전역 단축키 | MIT (원문: 앱의 `Contents/Resources/KeyboardShortcuts-LICENSE.txt`) |

FFmpeg와 LAME은 GPL 구성 없이 LGPL로 직접 빌드했습니다. 사용한 소스와 빌드 방법은
[`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh)에 있고, 소스는
[ffmpeg-9.0.2](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz)와
[lame-3.100](https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz)입니다.

## 직접 빌드하기

Xcode(macOS 14 SDK 이상)와 Apple Silicon Mac이 필요합니다.

```bash
scripts/fetch-binaries.sh   # yt-dlp, Python, deno 받기(버전·체크섬 고정)
scripts/build-ffmpeg.sh     # FFmpeg + LAME(LGPL) 빌드
xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=macOS,arch=arm64' test
scripts/release.sh          # 배포용 DMG(build/release/)
```

개발 문서는 [`docs/development/`](docs/development/)에 있습니다.
