import AppKit
import SwiftUI

/// 추출 화면(디자인 A안 "시스템 설정형", Apple HIG 기준).
/// 묶음 상자(grouped Form): "영상"(주소·불러온 영상) → "재생목록 영상"(재생목록일 때 고르기) → "출력" → "대기열".
/// 아래 고정 바: 대기열 요약과 추출(다른 영상이 추출 중이면 "대기열에 추가") 버튼.
struct ExtractView: View {
    @Bindable var model: ExtractViewModel
    @Bindable var queue: ExtractQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ExtractViewModel) {
        self.model = model
        queue = model.queue
    }

    var body: some View {
        Form {
            Section("영상") {
                urlRow
                statusRow
            }
            if case .playlist(let playlist) = model.state {
                PlaylistSection(playlist: playlist, model: model)
            }
            OutputSection(settings: model.settings)
            if !queue.items.isEmpty {
                QueueSection(queue: queue)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(minHeight: 60)
                    .alert(
                        "유튜브가 요청을 막았습니다",
                        isPresented: Binding(get: { queue.blockedAlert != nil }, set: { if !$0 { queue.blockedAlert = nil } }),
                        presenting: queue.blockedAlert
                    ) { _ in
                        Button("다시 시도") { queue.resume() }
                        Button("나중에", role: .cancel) { queue.blockedAlert = nil }
                    } message: { alert in
                        Text(alert.message + "\n대기열을 멈췄습니다. 잠시 후 다시 시도해 주세요.")
                    }
            }
            .background(.bar)
        }
        // 상태 전환은 짧게, "동작 줄이기"를 켜면 애니메이션 없이 바꾼다.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.stage)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: queue.items.count)
        .alert(
            "유튜브가 요청을 막았습니다",
            isPresented: Binding(get: { model.retryAlert != nil }, set: { if !$0 { model.retryAlert = nil } }),
            presenting: model.retryAlert
        ) { _ in
            Button("다시 시도") { model.retryFetch() }
            Button("닫기", role: .cancel) { model.retryAlert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - 영상 섹션

    /// 주소를 붙여 넣으면 자동으로 불러온다(별도 버튼 없음). Return은 바로 불러오거나, 불러온 뒤에는 대기열에 추가한다.
    private var urlRow: some View {
        TextField(text: $model.urlText, prompt: Text("유튜브 영상·재생목록 주소를 붙여 넣으세요")) {
            Label {
                Text("주소")
            } icon: {
                SettingsIcon(symbol: "link", color: .blue)
            }
        }
        .onSubmit { model.submit() }
        // 묶음 폼의 텍스트 필드는 기본이 오른쪽 정렬이라 긴 주소의 앞부분이 잘려 보인다.
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.state {
        case .idle:
            Label("주소를 붙여 넣으면 영상 정보를 자동으로 불러옵니다. 재생목록은 영상을 골라 담을 수 있습니다.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .fetching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("불러오는 중…").foregroundStyle(.secondary)
                Spacer()
                Button("취소") { model.cancelFetch() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let error):
            ErrorLabel(error: error)
        case .video(let metadata):
            VideoRow(metadata: metadata)
        case .playlist(let playlist):
            PlaylistHeaderRow(playlist: playlist, model: model)
        }
    }

    // MARK: - 하단 바

    private var bottomBar: some View {
        HStack(spacing: 12) {
            summary
            Spacer(minLength: 8)
            if model.stage == .video || model.stage == .playlist {
                Button {
                    model.addToQueue()
                } label: {
                    Label(model.addButtonTitle, systemImage: model.addButtonSymbol)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAddToQueue)
            }
        }
    }


    @ViewBuilder
    private var summary: some View {
        if queue.isPaused, queue.waitingCount > 0 || queue.failedCount > 0 {
            HStack(spacing: 8) {
                Label("유튜브가 요청을 막아 대기열을 멈췄습니다.", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("재개") { queue.resume() }
            }
        } else if !queue.items.isEmpty {
            Text(queueSummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text("\(model.settings.format.displayName) · \(model.settings.outputFolderName)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.settings.outputDirectory.path)
        }
    }

    private var queueSummary: String {
        var parts: [String] = []
        if queue.isRunning { parts.append("추출 중 1") }
        if queue.waitingCount > 0 { parts.append("대기 \(queue.waitingCount)") }
        if queue.completedCount > 0 { parts.append("완료 \(queue.completedCount)") }
        if queue.failedCount > 0 { parts.append("실패 \(queue.failedCount)") }
        return parts.isEmpty ? "대기열이 끝났습니다." : parts.joined(separator: " · ")
    }
}

// MARK: - 재생목록

/// 재생목록 제목·영상 수와 전체 선택.
private struct PlaylistHeaderRow: View {
    let playlist: Playlist
    @Bindable var model: ExtractViewModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 112, height: 63)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("영상 \(playlist.entries.count)개 · \(model.pendingAddCount)개 선택")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if playlist.isTruncated {
                    Text("영상이 많아 처음 \(playlist.entries.count)개만 불러왔습니다(전체 \(playlist.totalCount ?? 0)개).")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("저장 위치 아래 \"\(FileNaming.sanitize(playlist.title))\" 폴더에 저장합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let allSelected = model.pendingAddCount == playlist.entries.count
            Button(allSelected ? "선택 해제" : "모두 선택") { model.setAllEntriesSelected(!allSelected) }
        }
        .padding(.vertical, 2)
    }
}

/// 재생목록 영상 고르기(체크박스).
private struct PlaylistSection: View {
    let playlist: Playlist
    @Bindable var model: ExtractViewModel

    var body: some View {
        Section("재생목록 영상") {
            ForEach(playlist.entries) { entry in
                Toggle(isOn: Binding(
                    get: { model.selectedEntryIDs.contains(entry.id) },
                    set: { _ in model.toggleEntry(entry.id) }
                )) {
                    HStack {
                        Text(entry.title)
                            .lineLimit(1)
                            .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                            .help(entry.title)
                        Spacer(minLength: 8)
                        if entry.isUnavailable {
                            Text("볼 수 없음").foregroundStyle(.secondary)
                        } else if let duration = entry.duration {
                            Text(DurationFormat.string(from: duration))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - 대기열

private struct QueueSection: View {
    @Bindable var queue: ExtractQueue

    var body: some View {
        Section {
            ForEach(queue.items) { item in
                QueueRow(item: item, queue: queue)
            }
        } header: {
            HStack {
                Text("대기열")
                Spacer()
                Button("완료 항목 지우기") { queue.clearFinished() }
                    .disabled(!queue.hasFinishedItems)
                Button("모두 취소") { queue.cancelAll() }
                    .disabled(!queue.hasPendingItems)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

private struct QueueRow: View {
    let item: ExtractQueue.Item
    let queue: ExtractQueue

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(1)
                    .help(item.title)
                if item.status == .running, case .downloading(let fraction?, _, _) = item.progress.value {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else if item.status == .running {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                    .lineLimit(2)
                    .help(statusText)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .waiting, .running:
                iconButton("xmark.circle", label: "취소") { queue.cancel(item.id) }
            case .completed:
                iconButton("magnifyingglass", label: "Finder에서 보기") { queue.revealInFinder(item.id) }
                iconButton("minus.circle", label: "목록에서 지우기") { queue.remove(item.id) }
            case .failed, .cancelled:
                iconButton("arrow.clockwise", label: "다시 시도") { queue.retry(item.id) }
                iconButton("minus.circle", label: "목록에서 지우기") { queue.remove(item.id) }
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var statusText: String {
        let format = item.options.format.displayName
        switch item.status {
        case .waiting:
            return "대기 중 · \(format)"
        case .running:
            return ProgressText.text(for: item.progress.value, format: item.options.format)
        case .completed(let file):
            return "저장했습니다: \(file.lastPathComponent)"
        case .failed(let error):
            return error.errorDescription ?? "오류가 발생했습니다."
        case .cancelled:
            return "취소했습니다."
        }
    }

    private var statusColor: Color {
        if case .failed = item.status { .red } else { .secondary }
    }
}

enum ProgressText {
    static func text(for progress: ExtractProgress?, format: AudioFormat) -> String {
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

// MARK: - 공통 하위 화면

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
            VideoThumbnail(url: metadata.thumbnailURL, width: 112, cornerRadius: 6)

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

/// 영상 썸네일(16:9). 불러오지 못하면 자리표시를 보여 준다. 메인 창과 빠른 추출 패널이 같이 쓴다.
struct VideoThumbnail: View {
    let url: URL?
    let width: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: width * 0.18, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: width, height: (width * 9 / 16).rounded())
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
        .accessibilityHidden(true)
    }
}

/// "출력" 섹션: 포맷 · 음질 · 저장 위치. 대기열에 넣을 때의 값이 그 항목에 고정된다.
private struct OutputSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
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
        } header: {
            Text("출력")
        } footer: {
            Text("대기열에 넣는 순간의 포맷·저장 위치로 추출합니다.")
                .foregroundStyle(.secondary)
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
