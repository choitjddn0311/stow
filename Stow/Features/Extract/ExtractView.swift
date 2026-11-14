import AppKit
import SwiftUI

/// 추출 화면: 주소 입력 → 영상 정보 → 포맷·저장 위치 → 추출·진행률·완료.
struct ExtractView: View {
    @Bindable var model: ExtractViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            urlField
            content
            Divider()
            OptionsSection(settings: model.settings)
                .disabled(model.isBusy)
            Spacer(minLength: 0)
            actionArea
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 500)
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

    private var urlField: some View {
        HStack {
            TextField("유튜브 영상 주소를 붙여 넣으세요", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.fetch() }
                .disabled(model.isBusy)
            Button("불러오기") { model.fetch() }
                .disabled(!model.canFetch)
        }
    }

    // MARK: - 영상 정보

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Text("주소를 붙여 넣고 불러오기를 누르면 영상 정보가 표시됩니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        case .fetching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("영상 정보를 불러오는 중…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        case .failed(let error, nil):
            ErrorLabel(error: error)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        default:
            if let metadata = model.metadata {
                MetadataCard(metadata: metadata)
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
                Label("저장했습니다: \(file.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                HStack {
                    Button("Finder에서 보기") { model.revealInFinder() }
                    Button("다른 영상 추출") { model.startOver() }
                    Spacer()
                    Button("다시 추출") { model.extract() }
                        .help("다른 포맷이나 음질로 한 번 더 추출합니다")
                }
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

    private var extractButton: some View {
        HStack {
            Spacer()
            Button {
                model.extract()
            } label: {
                Label("\(model.settings.format.displayName)(으)로 추출", systemImage: "arrow.down.circle")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExtract)
        }
    }
}

// MARK: - 하위 화면

private struct MetadataCard: View {
    let metadata: VideoMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: metadata.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(metadata.title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let uploader = metadata.uploader {
                    Text(uploader).foregroundStyle(.secondary)
                }
                if let duration = metadata.duration {
                    Text(DurationFormat.string(from: duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OptionsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("포맷").gridColumnAlignment(.trailing)
                Picker("포맷", selection: $settings.formatKind) {
                    ForEach(AudioFormatKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            GridRow {
                Text("음질")
                if settings.formatKind == .mp3 {
                    Picker("음질", selection: $settings.mp3Bitrate) {
                        ForEach(MP3Bitrate.allCases, id: \.self) { bitrate in
                            Text("\(bitrate.rawValue) kbps").tag(bitrate)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                } else {
                    Text("무손실(원본 샘플레이트 유지)").foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("저장 위치")
                HStack {
                    Image(systemName: "folder")
                    Text(settings.outputDirectory.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                    ))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(settings.outputDirectory.path)
                    Button("변경…") { chooseFolder() }
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
            if case .downloading(let fraction?, _, _) = progress {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(statusText).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("취소", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
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
