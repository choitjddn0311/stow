import Combine
import Sparkle
import SwiftUI

/// 메뉴 "업데이트 확인…". Sparkle 권장 방식대로, 업데이터가 확인할 수 있을 때만 켠다
/// (예약된 확인·다운로드가 진행 중이거나 업데이터가 시작되지 않았으면 비활성).
struct CheckForUpdatesButton: View {
    @ObservedObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        model = CheckForUpdatesModel(updater: updater)
    }

    var body: some View {
        Button("업데이트 확인…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

@MainActor
private final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }
}
