import AppKit
import SwiftUI

/// 빠른 추출 패널 창. 다른 앱을 쓰는 중에도 그 앱을 뒤로 보내지 않고(비활성 패널) 위에 뜬다.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    let model: QuickPanelModel
    private var panel: QuickPanel?
    /// 클립보드를 읽는 동안(확인창이 뜰 수 있음)은 초점을 잃어도 닫지 않는다.
    private var isPreparing = false

    init(model: QuickPanelModel) {
        self.model = model
        super.init()
        model.onClose = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 패널을 연다. 이미 열려 있으면 입력을 지우지 않고 초점만 준다.
    func show() {
        if let panel, panel.isVisible {
            panel.makeKey()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // 투명 창의 그림자는 그려진 모양을 따라가므로, 화면을 그린 뒤 다시 계산한다.
        panel.invalidateShadow()
        isPreparing = true
        Task {
            await model.prepareForPresentation()
            isPreparing = false
            // 확인창이 떠서 초점을 잃었으면 되찾는다.
            if panel.isVisible, !panel.isKeyWindow { panel.makeKey() }
        }
    }

    private func close() {
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // 바깥을 클릭하면 닫는다(Spotlight처럼).
        guard !isPreparing, isVisible else { return }
        model.dismiss()
    }

    // MARK: - 내부

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickPanelView.width, height: QuickPanelView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // 창 자체는 투명하게 두고, 둥근 모양·유리 효과는 SwiftUI 화면이 그린다(Liquid Glass).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.title = "빠른 추출"
        let hostingView = NSHostingView(rootView: QuickPanelView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.model.dismiss() }
        return panel
    }

    /// 마우스가 있는 화면의 위쪽 가운데(Spotlight와 비슷한 높이).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - visible.height * 0.2 - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

/// 제목 막대 없이도 키 입력을 받는 패널. Esc는 닫기로 보낸다.
final class QuickPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
