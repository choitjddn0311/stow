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
        // SwiftUI가 처음 그린 뒤 한 번 더(처음 열 때는 위 시점에 아직 그려지지 않았다).
        DispatchQueue.main.async { panel.invalidateShadow() }
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
        // 창 자체는 투명하게 두고, 둥근 배경은 콘텐츠 뷰가 그린다(`roundedBackground`).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // macOS 26의 창 그림자는 둥근 유리 바깥에 사각형 윤곽을 남겨 끈다(유리 효과가 자체 테두리를 그린다).
        // 그 전에는 둥글게 자른 재질을 따라 그림자가 둥글게 생긴다.
        if #available(macOS 26.0, *) {
            panel.hasShadow = false
        } else {
            panel.hasShadow = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.title = "빠른 추출"
        let hostingView = NSHostingView(rootView: QuickPanelView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = Self.roundedBackground(containing: hostingView)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.model.dismiss() }
        return panel
    }

    /// 둥근 배경. 창 그림자·윤곽은 창 콘텐츠의 모양을 따르므로, 배경을 AppKit 뷰로 두고 둥글게 잘라야
    /// 둥근 패널 바깥에 사각형 테두리가 생기지 않는다.
    /// macOS 26+는 Liquid Glass(`NSGlassEffectView`), 그 전에는 반투명 재질을 둥글게 자른다.
    private static func roundedBackground(containing content: NSView) -> NSView {
        let radius = QuickPanelView.cornerRadius
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
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
