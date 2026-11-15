import KeyboardShortcuts
import SwiftUI

/// 설정 창(⌘,). 포맷·저장 위치는 메인 창에서 바꾸고, 여기서는 빠른 추출 단축키를 정한다.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("단축키") {
                    KeyboardShortcuts.Recorder(for: .quickExtract)
                }
            } header: {
                Text("빠른 추출")
            } footer: {
                Text("어느 앱에서든 이 단축키를 누르면 빠른 추출 패널이 열립니다. 클립보드에 유튜브 주소가 있으면 바로 불러오고, Return을 누르면 지금 설정으로 대기열에 넣습니다. 창을 닫아도 Stow가 메뉴 막대에 남아 있는 동안 동작합니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
