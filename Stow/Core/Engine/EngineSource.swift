import Foundation
import os

/// 지금 쓸 엔진. 앱 안 엔진 업데이트가 끝나면 바뀐다.
/// 추출은 시작할 때 한 번 읽으므로, 진행 중인 작업은 바뀌기 전 엔진으로 끝까지 돈다.
final class EngineSource: Sendable {
    private let state: OSAllocatedUnfairLock<EngineLocator>

    init(_ engine: EngineLocator) {
        state = OSAllocatedUnfairLock(initialState: engine)
    }

    var current: EngineLocator {
        state.withLock { $0 }
    }

    func update(_ engine: EngineLocator) {
        state.withLock { $0 = engine }
    }
}
