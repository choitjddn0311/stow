import AppKit
import SwiftUI

/// "오픈소스 라이선스" 창: 왼쪽은 구성 요소 목록, 오른쪽은 용도·라이선스·원문. LGPL 구성 요소에는 소스 받는 곳을 알린다.
struct OpenSourceLicensesView: View {
    static let windowID = "open-source-licenses"

    @State private var selection: OpenSourceComponent.ID? = OpenSourceComponent.all.first?.id

    var body: some View {
        NavigationSplitView {
            List(OpenSourceComponent.all, selection: $selection) { component in
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.name)
                    Text(component.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            if let component = OpenSourceComponent.all.first(where: { $0.id == selection }) {
                ComponentDetail(component: component)
                    .id(component.id)
            } else {
                Text("구성 요소를 고르세요.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

private struct ComponentDetail: View {
    let component: OpenSourceComponent
    @State private var fileIndex = 0

    private var file: OpenSourceComponent.LicenseFile { component.licenseFiles[fileIndex] }
    private var fileURL: URL? { file.url(in: .main) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(component.name)
                    .font(.title2.weight(.semibold))
                Text(component.purpose)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("라이선스").foregroundStyle(.secondary)
                    Text(component.license).textSelection(.enabled)
                }
                GridRow {
                    Text("홈페이지").foregroundStyle(.secondary)
                    Link(component.homepage.host() ?? component.homepage.absoluteString, destination: component.homepage)
                }
            }

            if component.providesSource {
                SourceNotice(name: component.name)
            }

            HStack {
                if component.licenseFiles.count > 1 {
                    Picker("원문", selection: $fileIndex) {
                        ForEach(component.licenseFiles.indices, id: \.self) { index in
                            Text(component.licenseFiles[index].title).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("라이선스 원문").font(.headline)
                }
                Spacer()
                if let fileURL {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    .controlSize(.small)
                }
            }

            LicenseTextView(url: fileURL)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(20)
        .navigationTitle(component.name)
    }
}

/// LGPL 구성 요소 안내: 이 버전의 릴리스 페이지에 원본 소스를 함께 올려 둔다.
private struct SourceNotice: View {
    let name: String

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stow에 들어 있는 \(name)은 GPL 구성 없이 LGPL로 직접 빌드했습니다. 원본 소스는 이 버전(\(version))의 릴리스 페이지에서, 빌드 방법은 같은 버전 소스 코드의 scripts/build-ffmpeg.sh에서 볼 수 있습니다.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("소스 코드 받기", destination: OpenSourceComponent.sourceReleaseURL(version: version))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("소스 코드", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }
}

/// 라이선스 원문. yt-dlp의 포함 코드 목록처럼 큰 파일(수백 KB)도 바로 그리도록 NSTextView를 쓴다.
private struct LicenseTextView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.setAccessibilityLabel("라이선스 원문")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, context.coordinator.shownURL != url else { return }
        context.coordinator.shownURL = url
        textView.string = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "라이선스 원문을 찾지 못했습니다."
        textView.scrollToBeginningOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownURL: URL?
    }
}

/// 앱 메뉴의 "오픈소스 라이선스…"(메뉴 명령에서 `openWindow`를 쓰려고 뷰로 둔다)
struct OpenSourceLicensesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("오픈소스 라이선스…") {
            openWindow(id: OpenSourceLicensesView.windowID)
        }
    }
}
