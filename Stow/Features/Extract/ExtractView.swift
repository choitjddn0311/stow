import AppKit
import SwiftUI

/// 추출 화면(디자인 A안 "시스템 설정형", Apple HIG 기준).
/// macOS 시스템 설정처럼 묶음 상자(grouped Form)에 "영상"·"출력"을 두고, 아래 고정 바에서 추출·진행·완료를 다룬다.
struct ExtractView: View {
    @Bindable var model: ExtractViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("영상") {
                urlRow
                statusRow
            }
            OutputSection(settings: model.settings)
                .disabled(model.isBusy)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(minHeight: 60)
            }
            .background(.bar)
        }
        // 상태 전환은 짧게, "동작 줄이기"를 켜면 애니메이션 없이 바꾼다.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.stage)
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

    private var isExtracting: Bool {
        if case .extracting = model.state { true } else { false }
    }

    // MARK: - 영상 섹션

    /// 주소를 붙여 넣으면 자동으로 불러온다(별도 버튼 없음). Return은 바로 불러오거나, 불러온 뒤에는 추출한다.
    /// 조회 중에도 주소를 바꿀 수 있고, 추출 중에만 잠근다.
    private var urlRow: some View {
        TextField(text: $model.urlText, prompt: Text("유튜브 영상 주소를 붙여 넣으세요")) {
            Label {
                Text("주소")
            } icon: {
                SettingsIcon(symbol: "link", color: .blue)
            }
        }
        .onSubmit {
            // 완료 화면에서는 Return이 "Finder에서 보기"(기본 버튼)만 하도록 다시 추출하지 않는다.
            if case .completed = model.state { return }
            model.submit()
        }
        // 묶음 폼의 텍스트 필드는 기본이 오른쪽 정렬이라 긴 주소의 앞부분이 잘려 보인다.
        .multilineTextAlignment(.leading)
        .disabled(isExtracting)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.state {
        case .idle:
            Label("주소를 붙여 넣으면 영상 정보를 자동으로 불러옵니다.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .fetching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("영상 정보를 불러오는 중…").foregroundStyle(.secondary)
                Spacer()
                Button("취소") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let error, nil):
            ErrorLabel(error: error)
        default:
            if let metadata = model.metadata {
                VideoRow(metadata: metadata)
            }
        }
    }

    // MARK: - 하단 바: 추출·진행·완료

    @ViewBuilder
    private var bottomBar: some View {
        switch model.state {
        case .idle, .fetching, .failed(_, nil):
            HStack {
                Text("영상을 불러오면 추출할 수 있습니다.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .ready:
            HStack {
                // 폴더가 사라졌는지는 추출을 누를 때 확인하므로(ExtractViewModel.extract), 여기서는 위치만 알린다.
                Label("저장 위치: \(model.settings.outputFolderName)", systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.settings.outputDirectory.path)
                Spacer()
                extractButton
            }
        case .extracting(_, let progress):
            ExtractProgressView(progress: progress, format: model.settings.format, onCancel: model.cancel)
        case .completed(_, let file):
            HStack(spacing: 8) {
                Label {
                    Text("저장했습니다: \(file.lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                Button("다른 영상 추출") { model.startOver() }
                Button("다시 추출") { model.extract() }
                    .help("다른 포맷이나 음질로 한 번 더 추출합니다")
                Button("Finder에서 보기") { model.revealInFinder() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        case .failed(let error, .some):
            HStack {
                // 아래 고정 바가 커져 "출력" 섹션을 가리지 않도록 최대 3줄, 전체 문구는 도움말로.
                ErrorLabel(error: error, lineLimit: 3)
                Spacer(minLength: 8)
                extractButton
            }
        }
    }

    /// 주 동작. 글자 길이에 맞춘 강조 버튼을 오른쪽 끝에 둔다.
    private var extractButton: some View {
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

// MARK: - 하위 화면

/// 시스템 설정의 행 아이콘: 색 사각형 위 흰 SF Symbol.
private struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 불러온 영상: 썸네일 + 제목·채널·길이.
private struct VideoRow: View {
    let metadata: VideoMetadata

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: metadata.thumbnailURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(metadata.title)
                    .textSelection(.enabled)  // 제목을 복사할 수 있게
                if let uploader = metadata.uploader {
                    Text(uploader).foregroundStyle(.secondary)
                }
                if let duration = metadata.duration {
                    Text(DurationFormat.string(from: duration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "출력" 섹션: 포맷 · 음질 · 저장 위치.
private struct OutputSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("출력") {
            Picker(selection: $settings.formatKind) {
                ForEach(AudioFormatKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Label {
                    Text("포맷")
                } icon: {
                    SettingsIcon(symbol: "waveform", color: .purple)
                }
            }
            .pickerStyle(.segmented)

            if settings.formatKind == .mp3 {
                Picker(selection: $settings.mp3Bitrate) {
                    ForEach(MP3Bitrate.allCases, id: \.self) { bitrate in
                        Text("\(bitrate.rawValue) kbps").tag(bitrate)
                    }
                } label: {
                    qualityLabel
                }
            } else {
                LabeledContent {
                    Text("무손실(원본 샘플레이트 유지)")
                } label: {
                    qualityLabel
                }
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Text(DisplayPath.abbreviated(settings.outputDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.outputDirectory.path)
                    Button("변경…") { chooseFolder() }
                }
            } label: {
                Label {
                    Text("저장 위치")
                } icon: {
                    SettingsIcon(symbol: "folder.fill", color: .cyan)
                }
            }
        }
    }

    private var qualityLabel: some View {
        Label {
            Text("음질")
        } icon: {
            SettingsIcon(symbol: "dial.medium", color: .orange)
        }
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
    /// 최대 줄 수. nil이면 제한 없음. 잘리면 전체 문구는 도움말로 볼 수 있다.
    var lineLimit: Int? = nil

    var body: some View {
        let message = error.errorDescription ?? "오류가 발생했습니다."
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
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
