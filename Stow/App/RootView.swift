import SwiftUI

/// 임시 루트 화면. 4단계에서 추출 화면(ExtractView)으로 교체한다.
struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Stow")
                .font(.largeTitle.bold())
            Text("유튜브 링크에서 오디오를 추출합니다.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 300)
    }
}

#Preview {
    RootView()
}
