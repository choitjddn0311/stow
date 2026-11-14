import AppKit
import SwiftUI

/// 추출 화면(디자인 B안 "중앙 카드형", Apple HIG 기준).
/// 위: 주소 입력 → 가운데: 빈 상태 안내 또는 영상 카드 → 아래: 포맷·음질·저장 위치 한 줄 → 추출·진행·완료.
struct ExtractView: View {
    @Bindable var model: ExtractViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            urlField
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 48)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 상태 전환은 짧게, "동작 줄이기"를 켜면 애니메이션 없이 바꾼다.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: phase)
        .alert(
            "유튜브가 요청을 막았습니다",
            isPresented: Binding(get: { model.retryAlert != nil }, set: { if !$0 { model.retryAlert = nil } }),
            presenting: model.retryAlert
        ) { alert in
            Button("다시 시도") { model.retry(alert.action) }
            Button("닫기", role: .cancel) { model.retryAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - 주소 입력

    /// 주소를 붙여 넣으면 자동으로 불러온다(별도 버튼 없음). Return은 바로 불러오거나, 불러온 뒤에는 추출한다.
    /// 조회 중에도 주소를 바꿀 수 있고, 추출 중에만 잠근다. 키보드 포커스 링을 위해 시스템 텍스트 필드를 쓴다.
    private var urlField: some View {
        TextField("유튜브 영상 주소를 붙여 넣으세요", text: $model.urlText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .onSubmit { model.submit() }
            .disabled(isExtracting)
    }

    private var isExtracting: Bool {
        if case .extracting = model.state { true } else { false }
    }

    /// 애니메이션 기준이 되는 화면 단계(진행률 변화에는 애니메이션하지 않는다).
    private var phase: Int {
        switch model.state {
        case .idle: 0
        case .fetching: 1
        case .ready: 2
        case .extracting: 3
        case .completed: 4
        case .failed(_, nil): 5
        case .failed: 6
        }
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView {
                Label("유튜브 링크에서 오디오를 추출합니다", systemImage: "music.note")
            } description: {
                Text("위 칸에 주소를 붙여 넣으면 영상 정보를 자동으로 불러옵니다.")
            }
        case .fetching:
            VStack(spacing: 12) {
                ProgressView()
                Text("영상 정보를 불러오는 중…")
                    .foregroundStyle(.secondary)
                Button("취소") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let error, nil):
            ContentUnavailableView {
                Label("영상을 불러올 수 없습니다", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.errorDescription ?? "")
            }
        default:
            if let metadata = model.metadata {
                VStack(spacing: 16) {
                    VideoCard(metadata: metadata)
                    OptionsBar(settings: model.settings)
                        .disabled(model.isBusy)
                    Spacer(minLength: 0)
                    actionArea
                }
            }
        }
    }

    // MARK: - 추출·진행·완료

    @ViewBuilder
    private var actionArea: some View {
        switch model.state {
        case .extracting(_, let progress):
            ExtractProgressView(progress: progress, format: model.settings.format, onCancel: model.cancel)
        case .completed(_, let file):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("저장했습니다: \(file.lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                HStack {
                    Button("다른 영상 추출") { model.startOver() }
                    Spacer()
                    Button("다시 추출") { model.extract() }
                        .help("다른 포맷이나 음질로 한 번 더 추출합니다")
                    Button("Finder에서 보기") { model.revealInFinder() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        case .failed(let error, .some):
            VStack(alignment: .leading, spacing: 12) {
                ErrorLabel(error: error)
                extractButton
            }
        case .ready:
            extractButton
        case .idle, .fetching, .failed(_, nil):
            EmptyView()
        }
    }

    /// 주 동작. Mac 규칙대로 글자 길이에 맞춘 강조 버튼을 오른쪽 끝에 둔다.
    private var extractButton: some View {
        HStack {
            Spacer()
            Button {
                model.extract()
            } label: {
                Label("\(model.settings.format.displayName)(으)로 추출", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExtract)
        }
    }
}

// MARK: - 하위 화면

/// 큰 썸네일과 제목·채널·길이를 보여 주는 카드.
private struct VideoCard: View {
    let metadata: VideoMetadata

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: metadata.thumbnailURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .clipped()
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(metadata.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(metadata.title)
                Spacer(minLength: 8)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
    }

    /// "채널 · 5:25"
    private var subtitle: String {
        [metadata.uploader, metadata.duration.map(DurationFormat.string(from:))]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// 포맷(세그먼트) · 음질(팝업) · 저장 위치(메뉴)를 한 줄로.
private struct OptionsBar: View {
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Picker("포맷", selection: $settings.formatKind) {
                ForEach(AudioFormatKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if settings.formatKind == .mp3 {
                Picker("음질", selection: $settings.mp3Bitrate) {
                    ForEach(MP3Bitrate.allCases, id: \.self) { bitrate in
                        Text("\(bitrate.rawValue) kbps").tag(bitrate)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text("무손실")
                    .foregroundStyle(.secondary)
                    .help("원본 샘플레이트를 유지합니다")
            }

            Spacer(minLength: 8)

            Menu {
                Button("다른 폴더 선택…") { chooseFolder() }
                Button("Finder에서 열기") { NSWorkspace.shared.open(settings.outputDirectory) }
            } label: {
                Label(folderName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("저장 위치: \(DisplayPath.abbreviated(settings.outputDirectory))")
            .accessibilityLabel("저장 위치: \(folderName)")
        }
    }

    /// Finder에 보이는 이름(예: "다운로드").
    private var folderName: String {
        FileManager.default.displayName(atPath: settings.outputDirectory.path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory
        panel.prompt = "선택"
        panel.message = "추출한 파일을 저장할 폴더를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url
        }
    }
}

private struct ExtractProgressView: View {
    let progress: ExtractProgress?
    let format: AudioFormat
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if case .downloading(let fraction?, _, _) = progress {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("취소", action: onCancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var statusText: String {
        switch progress {
        case nil:
            "준비 중…"
        case .downloading(let fraction, _, let eta):
            if let fraction {
                "다운로드 중 \(Int((fraction * 100).rounded()))%" + (eta.map { " · 약 \($0)초 남음" } ?? "")
            } else {
                "다운로드 중…"
            }
        case .converting:
            "\(format.displayName)(으)로 변환 중…"
        case .embeddingMetadata:
            "제목·아티스트 정보를 넣는 중…"
        }
    }
}

private struct ErrorLabel: View {
    let error: EngineError

    var body: some View {
        Label(error.errorDescription ?? "오류가 발생했습니다.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum DurationFormat {
    /// 325 → "5:25", 3723 → "1:02:03"
    static func string(from seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

extension AudioFormat {
    /// 화면 표시용 이름. 예: "MP3 320kbps", "FLAC"
    var displayName: String {
        switch self {
        case .mp3(let bitrate): "MP3 \(bitrate.rawValue)kbps"
        case .wav: "WAV"
        case .flac: "FLAC"
        }
    }
}

enum DisplayPath {
    /// 홈 폴더로 시작하는 경로만 앞부분을 `~`로 줄인다. 예: /Users/me/Music → ~/Music
    static func abbreviated(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}
