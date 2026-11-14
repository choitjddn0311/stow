import Foundation

/// 영상 정보 조회와 오디오 추출. 앱은 `YtDlpClient`를, 테스트는 가짜 구현을 쓴다.
protocol AudioExtracting: Sendable {
    func fetchMetadata(for url: URL) async throws -> VideoMetadata

    func extract(
        _ url: URL,
        options: ExtractOptions,
        fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL
}

extension YtDlpClient: AudioExtracting {}
