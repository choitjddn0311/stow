import SwiftUI

/// 영상 썸네일(16:9). 불러오는 동안과 불러오지 못했을 때는 자리표시를 보여 주고, 불러오면 부드럽게 나타난다.
struct VideoThumbnail: View {
    let url: URL?
    let width: CGFloat
    var cornerRadius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: Motion.imageAppear(reduceMotion: reduceMotion))) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ThumbnailPlaceholder(symbol: "play.rectangle", width: width)
            }
        }
        .modifier(ThumbnailFrame(width: width, cornerRadius: cornerRadius))
    }
}

/// 재생목록 자리 그림(썸네일과 같은 크기).
struct PlaylistThumbnail: View {
    let width: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        ThumbnailPlaceholder(symbol: "list.bullet.rectangle", width: width)
            .modifier(ThumbnailFrame(width: width, cornerRadius: cornerRadius))
    }
}

private struct ThumbnailPlaceholder: View {
    let symbol: String
    let width: CGFloat

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: max(14, width * 0.2), weight: .light))
                    .foregroundStyle(.secondary)
            }
    }
}

private struct ThumbnailFrame: ViewModifier {
    let width: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
            .accessibilityHidden(true)
    }
}

/// 불러온 영상·재생목록 요약: 썸네일 + 제목 + 보조 문구. 메인 창과 빠른 추출 패널이 같이 쓴다.
struct MediaSummary<Thumbnail: View, Details: View>: View {
    let title: String
    /// 제목 최대 줄 수(메인 창 2줄, 패널 1줄)
    var titleLineLimit = 2
    /// 제목을 골라 복사할 수 있게 한다(메인 창)
    var selectableTitle = false
    @ViewBuilder let thumbnail: Thumbnail
    @ViewBuilder let details: Details

    var body: some View {
        HStack(spacing: Metrics.rowSpacing) {
            thumbnail
            VStack(alignment: .leading, spacing: Metrics.textSpacing) {
                titleText
                details
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var titleText: some View {
        let text = Text(title)
            .font(.headline)
            .lineLimit(titleLineLimit)
            .help(title)
        if selectableTitle {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}

/// 영상 정보를 불러오는 동안의 자리표시. 메인 창 영상 행과 같은 줄 수(제목 2줄·채널·길이)라
/// 긴 제목의 영상을 불러와도 아래 내용이 거의 밀리지 않는다. 영상인지 재생목록인지 아직 모르므로 중립 모양을 쓴다.
struct MediaSummaryPlaceholder: View {
    let thumbnailWidth: CGFloat

    var body: some View {
        MediaSummary(title: "영상 제목을 불러오는 중입니다 영상 제목을 불러오는 중입니다 영상 제목", titleLineLimit: 2) {
            ThumbnailPlaceholder(symbol: "rectangle", width: thumbnailWidth)
                .modifier(ThumbnailFrame(width: thumbnailWidth, cornerRadius: 6))
                .opacity(0.6)
        } details: {
            Text("채널 이름")
            Text("0:00")
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
