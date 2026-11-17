import AppKit
import SwiftUI

/// 추출 화면(디자인 A안 "시스템 설정형", Apple HIG 기준).
/// 묶음 상자(grouped Form): "영상"(주소·불러온 영상) → "재생목록 영상"(재생목록일 때 고르기) → "출력" → "대기열".
/// 아래 고정 바: 대기열 요약과 추출(다른 영상이 추출 중이면 "대기열에 추가") 버튼.
struct ExtractView: View {
    @Bindable var model: ExtractViewModel
    @Bindable var queue: ExtractQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 창을 열면 주소란에 바로 입력할 수 있게 한다.
    @FocusState private var isURLFocused: Bool

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
        .animation(Motion.stateChange(reduceMotion: reduceMotion), value: model.stage)
        .animation(Motion.stateChange(reduceMotion: reduceMotion), value: queue.items.count)
        .onAppear { isURLFocused = true }
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
                RowIcon(symbol: "link")
            }
        }
        .focused($isURLFocused)
        .onSubmit { model.submit() }
        // 묶음 폼의 텍스트 필드는 기본이 오른쪽 정렬이라 긴 주소의 앞부분이 잘려 보인다.
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.state {
        case .idle:
            StatusMessage(.info, "주소를 붙여 넣으면 영상 정보를 자동으로 불러옵니다. 재생목록은 영상을 골라 담을 수 있습니다.")
        case .fetching:
            // 불러온 뒤와 같은 크기의 자리표시를 보여 줘, 영상 정보가 나타날 때 아래 내용이 밀리지 않는다.
            HStack(spacing: Metrics.controlSpacing) {
                MediaSummaryPlaceholder(thumbnailWidth: Metrics.thumbnailWidth)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("불러오는 중…")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("취소") { model.cancelFetch() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 2)
        case .failed(let error):
            HStack(spacing: Metrics.controlSpacing) {
                StatusMessage(error: error)
                Spacer(minLength: 0)
                // 유튜브 차단은 알림창이 "다시 시도"를 띄우므로 여기서는 보여 주지 않는다.
                if error.isWorthRetrying, error != .blockedByYouTube, model.canFetch {
                    Button("다시 시도") { model.retryFetch() }
                }
            }
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
            HStack(spacing: Metrics.controlSpacing) {
                StatusMessage(.warning, "유튜브가 요청을 막아 대기열을 멈췄습니다.", lineLimit: 1)
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
        HStack(spacing: Metrics.controlSpacing) {
            MediaSummary(title: playlist.title, selectableTitle: true) {
                PlaylistThumbnail(width: Metrics.thumbnailWidth)
            } details: {
                Text("영상 \(playlist.entries.count)개 · \(model.pendingAddCount)개 선택")
                    .monospacedDigit()
                if playlist.isTruncated {
                    StatusMessage(
                        .warning,
                        "영상이 많아 처음 \(playlist.entries.count)개만 불러왔습니다(전체 \(playlist.totalCount ?? 0)개).",
                        compact: true
                    )
                }
                Text("저장 위치 아래 \"\(FileNaming.sanitize(playlist.title))\" 폴더에 저장합니다.")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            let allSelected = model.pendingAddCount == playlist.entries.count
            Button(allSelected ? "선택 해제" : "모두 선택") { model.setAllEntriesSelected(!allSelected) }
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// 재생목록 영상 고르기(체크박스).
private struct PlaylistSection: View {
    let playlist: Playlist
    @Bindable var model: ExtractViewModel

    /// 선택 여부는 체크박스가 알리므로 길이나 "볼 수 없음"만 덧붙인다.
    private func entryAccessibilityValue(_ entry: PlaylistEntry) -> String {
        if entry.isUnavailable { return "볼 수 없음" }
        return entry.duration.map(DurationFormat.spoken(from:)) ?? ""
    }

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
                .accessibilityLabel(entry.title)
                .accessibilityValue(entryAccessibilityValue(entry))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: Metrics.rowIconWidth)
                .accessibilityHidden(true)  // 상태는 아래 문구로 읽는다
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(1)
                    .help(item.title)
                    .accessibilityHidden(true)  // 행 이름으로 이미 읽는다
                if item.status == .running {
                    progressBar
                }
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .help(statusText)
            }
            Spacer(minLength: Metrics.controlSpacing)
            actions
        }
        .padding(.vertical, 2)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    /// 진행률을 알면 채워지는 막대, 모르면(준비·변환 중) 움직이는 막대.
    /// 영상을 영상·오디오 스트림으로 나눠 받을 때는 두 칸(영상 → 오디오)으로 나눠 지금 단계를 보여 준다.
    @ViewBuilder
    private var progressBar: some View {
        if case .downloading(let fraction?, _, _, let part) = item.progress.value {
            if item.options.format.isVideo, part != .combined {
                HStack(spacing: 4) {
                    ProgressView(value: part == .video ? fraction : 1)
                    ProgressView(value: part == .audio ? fraction : 0)
                }
                .controlSize(.small)
                .animation(Motion.progress(reduceMotion: reduceMotion), value: fraction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(part == .video ? "영상 다운로드" : "오디오 다운로드")
                .accessibilityValue("\(displayPercent(fraction))%")
            } else {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .animation(Motion.progress(reduceMotion: reduceMotion), value: fraction)
                    .accessibilityLabel("다운로드")
            }
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("처리 중")
        }
    }

    private var statusIcon: some View {
        Image(systemName: statusSymbol)
            .foregroundStyle(statusTint)
            .contentTransition(.symbolEffect(.replace))
            .animation(Motion.stateChange(reduceMotion: reduceMotion), value: statusSymbol)
    }

    private var statusSymbol: String {
        switch item.status {
        case .waiting: "clock"
        case .running: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusTint: AnyShapeStyle {
        switch item.status {
        case .waiting, .cancelled: AnyShapeStyle(.secondary)
        case .running: AnyShapeStyle(.tint)
        case .completed: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch item.status {
            case .waiting, .running:
                IconButton("xmark.circle", label: "취소") { queue.cancel(item.id) }
            case .completed:
                IconButton("magnifyingglass", label: "Finder에서 보기") { queue.revealInFinder(item.id) }
                IconButton("minus.circle", label: "목록에서 지우기") { queue.remove(item.id) }
            case .failed, .cancelled:
                IconButton("arrow.clockwise", label: "다시 시도") { queue.retry(item.id) }
                IconButton("minus.circle", label: "목록에서 지우기") { queue.remove(item.id) }
            }
        }
    }

    /// 오른쪽 클릭 메뉴: 행의 버튼과 같은 동작에 주소·제목 복사를 더한다.
    @ViewBuilder
    private var menuItems: some View {
        switch item.status {
        case .waiting, .running:
            Button("취소") { queue.cancel(item.id) }
        case .completed:
            Button("Finder에서 보기") { queue.revealInFinder(item.id) }
            Button("목록에서 지우기") { queue.remove(item.id) }
        case .failed, .cancelled:
            Button("다시 시도") { queue.retry(item.id) }
            Button("목록에서 지우기") { queue.remove(item.id) }
        }
        Divider()
        Button("제목 복사") { Self.copy(item.title) }
        Button("주소 복사") { Self.copy(item.url.absoluteString) }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            return "실패: " + (error.errorDescription ?? "오류가 발생했습니다.")
        case .cancelled:
            return "취소했습니다."
        }
    }
}

enum ProgressText {
    static func text(for progress: ExtractProgress?, format: OutputFormat) -> String {
        switch progress {
        case nil:
            return "준비 중…"
        case .downloading(let fraction, _, let eta, let part):
            // 영상은 영상·오디오를 따로 받으므로 지금 받는 쪽을 밝힌다(합쳐진 스트림이면 그냥 다운로드).
            let verb = switch (format.isVideo, part) {
            case (true, .video): "영상 받는 중"
            case (true, .audio): "오디오 받는 중"
            default: "다운로드 중"
            }
            guard let fraction else { return "\(verb)…" }
            return "\(verb) \(displayPercent(fraction))%" + (eta.map { " · 약 \($0)초 남음" } ?? "")
        case .converting:
            return "\(format.displayName)(으)로 변환 중…"
        case .merging:
            return "영상과 오디오를 합치는 중…"
        case .embeddingMetadata:
            return format.isVideo ? "제목·채널 정보를 넣는 중…" : "제목·아티스트 정보를 넣는 중…"
        }
    }
}

// MARK: - 공통 하위 화면

/// 불러온 영상: 썸네일 + 제목·채널·길이.
private struct VideoRow: View {
    let metadata: VideoMetadata

    var body: some View {
        MediaSummary(title: metadata.title, selectableTitle: true) {
            VideoThumbnail(url: metadata.thumbnailURL, width: Metrics.thumbnailWidth)
        } details: {
            if let uploader = metadata.uploader {
                Text(uploader).lineLimit(1)
            }
            if let duration = metadata.duration {
                Text(DurationFormat.string(from: duration))
                    .monospacedDigit()
                    .accessibilityLabel(DurationFormat.spoken(from: duration))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "출력" 섹션: 종류 · 포맷 · 음질(해상도) · 저장 위치. 대기열에 넣을 때의 값이 그 항목에 고정된다.
private struct OutputSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: $settings.mediaKind) {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            } label: {
                Label {
                    Text("종류")
                } icon: {
                    RowIcon(symbol: settings.mediaKind.symbol)
                }
            }
            .pickerStyle(.segmented)

            switch settings.mediaKind {
            case .audio: audioRows
            case .video: videoRows
            }

            LabeledContent {
                HStack(spacing: Metrics.controlSpacing) {
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
                    RowIcon(symbol: "folder")
                }
            }
        } header: {
            Text("출력")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if settings.mediaKind == .video {
                    Text(settings.videoFormat.note)
                }
                Text("대기열에 넣는 순간의 포맷·저장 위치로 \(settings.mediaKind == .video ? "받습니다" : "추출합니다").")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var audioRows: some View {
        Picker(selection: $settings.formatKind) {
            ForEach(AudioFormatKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
            }
        } label: {
            formatLabel
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
    }

    @ViewBuilder
    private var videoRows: some View {
        Picker(selection: $settings.videoFormat) {
            ForEach(VideoFormat.allCases, id: \.self) { format in
                Text(format.displayName).tag(format)
            }
        } label: {
            formatLabel
        }
        .pickerStyle(.segmented)

        Picker(selection: $settings.videoResolution) {
            ForEach(settings.videoFormat.resolutions, id: \.self) { resolution in
                Text(resolution.displayName).tag(resolution)
            }
        } label: {
            Label {
                Text("해상도")
            } icon: {
                RowIcon(symbol: "rectangle.on.rectangle")
            }
        }
        .help("고른 해상도가 없으면 그보다 낮은 것 중 가장 높은 해상도로 받습니다.")
    }

    private var formatLabel: some View {
        Label {
            Text("포맷")
        } icon: {
            RowIcon(symbol: "waveform")
        }
    }

    private var qualityLabel: some View {
        Label {
            Text("음질")
        } icon: {
            RowIcon(symbol: "dial.medium")
        }
    }

    private func chooseFolder() {
        if let url = OutputFolderPicker.choose(current: settings.outputDirectory) {
            settings.outputDirectory = url
        }
    }
}

extension EngineError {
    /// 같은 주소로 다시 해 볼 만한 오류(일시적인 문제). 주소가 틀렸거나 볼 수 없는 영상, 엔진을 실행하지 못한 경우
    /// (`launchFailed`·`missingComponent`: 앱을 다시 설치해야 함)는 다시 해도 같다.
    var isWorthRetrying: Bool {
        switch self {
        case .network, .blockedByYouTube, .metadataUnreadable, .unknown:
            true
        default:
            false
        }
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

    /// 화면 읽기 프로그램용: 325 → "5분 25초", 3723 → "1시간 2분 3초"
    static func spoken(from seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)시간") }
        if minutes > 0 { parts.append("\(minutes)분") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs)초") }
        return parts.joined(separator: " ")
    }
}

extension OutputFormat {
    /// 화면 표시용 이름. 예: "MP3 320kbps", "FLAC", "MP4 1080p", "최고 화질", "최고 화질 1440p"
    var displayName: String {
        switch self {
        case .mp3(let bitrate): "MP3 \(bitrate.rawValue)kbps"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .video(let format, let resolution):
            resolution == .best ? format.displayName : "\(format.displayName) \(resolution.displayName)"
        }
    }

    /// 추가 버튼 등에 쓰는 짧은 이름(음질·해상도 없이). 예: "MP3", "MP4", "최고 화질"
    var shortName: String {
        switch self {
        case .mp3: "MP3"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .video(let format, _): format.displayName
        }
    }

    /// "MP3로 추출", "FLAC으로 추출", "MP4로 받기", "최고 화질로 받기". 영상은 변환 없이 그대로 받으므로 "받기".
    var actionTitle: String {
        switch self {
        case .mp3, .wav: "\(shortName)로 추출"
        case .flac: "FLAC으로 추출"
        case .video: "\(shortName)로 받기"
        }
    }
}

extension VideoFormat {
    var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .best: "최고 화질"
        }
    }

    /// 출력 섹션 아래 설명
    var note: String {
        switch self {
        case .mp4: "편집 프로그램(Premiere·Final Cut 등)에서 바로 열리는 H.264 MP4입니다. 유튜브가 1080p까지만 제공합니다."
        case .best: "가장 높은 화질로 받습니다. 4K 이상은 VP9·AV1 코덱이라 일부 편집 프로그램에서 열리지 않을 수 있고, 파일 형식(MP4·WebM·MKV)은 영상에 따라 정해집니다."
        }
    }
}

extension VideoResolution {
    /// 예: "1080p", "최고"
    var displayName: String {
        self == .best ? "최고" : "\(rawValue)p"
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
