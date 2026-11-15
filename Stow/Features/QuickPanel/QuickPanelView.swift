import SwiftUI

/// 빠른 추출 패널 화면(Spotlight형): 주소란 / 불러온 내용 / 저장 설정과 버튼.
struct QuickPanelView: View {
    let model: QuickPanelModel
    @FocusState private var isFieldFocused: Bool

    static let width: CGFloat = 600
    static let height: CGFloat = 176
    /// 패널 모서리 반지름(Liquid Glass 패널은 둥글게)
    static let cornerRadius: CGFloat = 24

    private var extract: ExtractViewModel { model.extract }

    var body: some View {
        @Bindable var extract = extract
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                TextField("주소", text: $extract.urlText, prompt: Text("유튜브 영상이나 재생목록 주소를 붙여 넣으세요"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($isFieldFocused)
                    .onSubmit { model.submit() }
                if extract.isFetching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider().padding(.horizontal, 18)

            ContentRow(extract: extract, addWhenReady: model.addWhenReady) { model.openInMainWindow() }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Divider().padding(.horizontal, 18)

            HStack(spacing: 8) {
                FormatChip(model: model)
                FolderChip(model: model)
                Spacer(minLength: 8)
                Button("닫기") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .modifier(GlassButton(prominent: false))
                Button(extract.addButtonTitle) { model.submit() }
                    .modifier(GlassButton(prominent: true))
                    .disabled(!canSubmit)
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
        .frame(width: Self.width, height: Self.height)
        .modifier(PanelBackground())
        .onChange(of: model.presentationID, initial: true) { isFieldFocused = true }
    }

    private var canSubmit: Bool {
        switch extract.stage {
        case .video, .playlist: extract.canAddToQueue
        case .fetching: !model.addWhenReady
        case .idle, .failed: extract.canFetch
        }
    }
}

/// 포맷 칩: 누르면 포맷 메뉴. 바꾼 값은 메인 창 기본 설정에도 남는다.
private struct FormatChip: View {
    let model: QuickPanelModel

    /// MP3는 높은 음질부터, 그다음 무손실 포맷
    private static let formats: [AudioFormat] =
        MP3Bitrate.allCases.sorted { $0.rawValue > $1.rawValue }.map { .mp3($0) } + [.wav, .flac]

    var body: some View {
        let current = model.extract.settings.format
        Menu {
            ForEach(Self.formats, id: \.self) { format in
                if format == .wav { Divider() }
                Toggle(format.displayName, isOn: Binding(
                    get: { current == format },
                    set: { if $0 { model.select(format) } }
                ))
            }
        } label: {
            Label(current.displayName, systemImage: "music.note")
        }
        .modifier(ChipStyle())
        .help("포맷")
        .accessibilityLabel("포맷: \(current.displayName)")
    }
}

/// 폴더 칩: 누르면 최근 저장 폴더·다른 폴더…·Finder에서 열기 메뉴.
private struct FolderChip: View {
    let model: QuickPanelModel

    var body: some View {
        let settings = model.extract.settings
        Menu {
            ForEach(settings.availableRecentOutputDirectories, id: \.self) { url in
                Toggle(DisplayPath.abbreviated(url), isOn: Binding(
                    get: { AppSettings.isSameDirectory(url, settings.outputDirectory) },
                    set: { if $0 { model.selectOutputDirectory(url) } }
                ))
            }
            Divider()
            Button("다른 폴더…") { model.chooseOtherFolder() }
            Button("Finder에서 열기") { NSWorkspace.shared.open(settings.outputDirectory) }
                .disabled(!AppSettings.directoryExists(settings.outputDirectory))
        } label: {
            Label(settings.outputFolderName, systemImage: "folder")
        }
        .modifier(ChipStyle())
        .frame(maxWidth: 200, alignment: .leading)
        .help(settings.outputDirectory.path)
        .accessibilityLabel("저장 위치: \(settings.outputFolderName)")
    }
}

/// 칩 모양 메뉴 버튼: macOS 26부터는 Liquid Glass 버튼, 그 전에는 테두리 버튼.
private struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        let menu = content
            .menuStyle(.button)
            .menuIndicator(.visible)
            .fixedSize(horizontal: false, vertical: true)
        if #available(macOS 26.0, *) {
            menu.buttonStyle(.glass)
        } else {
            menu.buttonStyle(.bordered)
        }
    }
}

/// 가운데 줄: 안내 / 불러오는 중 / 영상 / 재생목록 / 오류.
private struct ContentRow: View {
    let extract: ExtractViewModel
    let addWhenReady: Bool
    let openInMainWindow: () -> Void

    var body: some View {
        switch extract.state {
        case .idle:
            Text("Return을 누르면 불러온 뒤 지금 설정으로 대기열에 넣고 패널을 닫습니다.")
                .foregroundStyle(.secondary)
        case .fetching:
            Text(addWhenReady ? "영상 정보를 불러오면 바로 대기열에 넣습니다…" : "영상 정보를 불러오는 중…")
                .foregroundStyle(.secondary)
        case .video(let metadata):
            HStack(spacing: 12) {
                VideoThumbnail(url: metadata.thumbnailURL, width: 64, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.title)
                        .font(.headline)
                        .lineLimit(1)
                        .help(metadata.title)
                    Text(detail(uploader: metadata.uploader, duration: metadata.duration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        case .playlist(let playlist):
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.headline)
                        .lineLimit(1)
                        .help(playlist.title)
                    Text(playlistDetail(playlist))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("메인 창에서 고르기…", action: openInMainWindow)
            }
        case .failed(let error):
            Label(error.errorDescription ?? "오류가 발생했습니다.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(error.errorDescription ?? "")
        }
    }

    private func detail(uploader: String?, duration: TimeInterval?) -> String {
        [uploader, duration.map(DurationFormat.string(from:))].compactMap { $0 }.joined(separator: " · ")
    }

    private func playlistDetail(_ playlist: Playlist) -> String {
        let available = extract.pendingAddCount
        let total = playlist.entries.count
        let base = available == total ? "영상 \(total)개" : "영상 \(total)개 중 받을 수 있는 \(available)개"
        return playlist.isTruncated ? base + " (처음 \(Playlist.maxEntries)개까지)" : base
    }
}

/// 패널 배경: macOS 26부터는 Liquid Glass(사용자 요청 2026-11-14), 그 전에는 반투명 재질.
/// 둥근 배경 자체(유리·재질)는 `QuickPanelController`가 AppKit 뷰로 깐다(창 그림자가 둥근 모양을 따르도록).
/// 여기서는 macOS 26 전의 가는 테두리만 그린다.
private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.overlay {
                RoundedRectangle(cornerRadius: QuickPanelView.cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            }
        }
    }
}

/// 버튼: macOS 26부터는 Liquid Glass 버튼, 그 전에는 기본 버튼.
private struct GlassButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content
        }
    }
}
