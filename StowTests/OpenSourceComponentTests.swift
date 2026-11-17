import Foundation
import Testing
@testable import Stow

struct OpenSourceComponentTests {
    /// 테스트 호스트는 앱이므로 Bundle.main이 실제 앱 번들이다. 목록의 모든 원문이 번들에 있어야 한다.
    @Test func everyLicenseFileIsInAppBundle() throws {
        for component in OpenSourceComponent.all {
            #expect(!component.licenseFiles.isEmpty, "\(component.name): 원문 없음")
            for file in component.licenseFiles {
                let url = try #require(file.url(in: .main))
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.isEmpty, "\(component.name): \(file.resourcePath) 비어 있음")
            }
        }
    }

    /// 번들의 licenses 폴더에 있는 원문은 모두 창에 보여야 한다(엔진을 추가하고 목록을 빠뜨리지 않도록).
    @Test func everyBundledEngineLicenseIsListed() throws {
        let folder = try #require(Bundle.main.resourceURL?.appending(path: "bin/licenses"))
        let bundled = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        let listed = Set(OpenSourceComponent.all.flatMap(\.licenseFiles).map(\.resourcePath))
        for name in bundled where !name.hasPrefix(".") {
            #expect(listed.contains("bin/licenses/\(name)"), "목록에 없는 원문: \(name)")
        }
    }

    @Test func idsAreUnique() {
        let ids = OpenSourceComponent.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lgplComponentsProvideSource() {
        let lgpl = OpenSourceComponent.all.filter { $0.license.contains("LGPL") }
        #expect(lgpl.map(\.id).sorted() == ["ffmpeg", "lame"])
        #expect(lgpl.allSatisfy { $0.providesSource })
        #expect(OpenSourceComponent.all.filter(\.providesSource).count == lgpl.count)
    }

    @Test func sourceReleaseURLPointsToVersionTag() {
        #expect(
            OpenSourceComponent.sourceReleaseURL(version: "0.5.0").absoluteString
                == "https://github.com/choitjddn0311/stow/releases/tag/v0.5.0"
        )
    }
}
