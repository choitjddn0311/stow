# Stow

유튜브 URL에서 오디오(MP3/WAV/FLAC)를 추출하는 macOS 네이티브 앱. SwiftUI, macOS 14+, Apple Silicon 전용.

## Project Documentation
- 프로젝트 개요·설계·로드맵: docs/development/PROJECT.md
- 현재 진행 상황·다음 작업: docs/development/SESSION_HANDOFF.md
- 컨텍스트 관리 절차: docs/development/CONTEXT_GUIDE.md

## 개발 규칙
- 확정된 설계(PROJECT.md)를 임의로 변경하지 않는다. 변경이 필요하면 이유를 설명하고 먼저 확인받는다.
- 현재 로드맵 단계에 필요한 작업만 진행한다.
- 외부 프로세스(yt-dlp/ffmpeg) 인자는 항상 배열로 전달하고 셸 문자열을 조합하지 않는다.
- GPL 구성 요소를 앱에 포함하지 않는다(ffmpeg는 LGPL 빌드만).
- UI 문구는 한국어로 작성한다.
- 실제로 빌드·테스트로 확인하지 않은 기능을 완료로 보고하지 않는다.

## Git 규칙 (상세: CONTEXT_GUIDE.md 5장)
- `main`에 직접 커밋·푸시하지 않는다. 작업 브랜치(`feat/`, `fix/`, `docs/`, `chore/`)에서 작업하고 PR로 병합한다.
- PR 전 로컬 Debug 테스트 → PR 생성 → CI `build-test` 통과 → (코드 변경 PR만) `/code-review` 1회 → 결과 보고 → **사용자 승인 후** squash 병합.
- 검증 중 하나라도 실패하면 병합하지 않고 수정한다.

## Context Management
- 작업 시작 시 SESSION_HANDOFF.md로 현재 상태를 확인한다.
- 기능 단위 작업 완료 또는 세션 종료 전에 SESSION_HANDOFF.md를 갱신한다.
- 문서에 기록되지 않은 사실을 추측하지 않는다.
- 필요한 파일과 코드 구간만 읽는다.
