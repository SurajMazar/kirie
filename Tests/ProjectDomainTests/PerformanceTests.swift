import Foundation
import Testing
@testable import ProjectDomain

/// Guards against accidental quadratic behaviour on large timelines. Bounds are generous so slow CI
/// machines pass; the measured numbers are printed for the engineering notes.
@Suite("Performance on large timelines", .serialized)
struct PerformanceTests {
    static func clock(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    @Test func threeThousandClipsStayResponsive() throws {
        var engine = CommandEngine(project: Fixture.reel())
        let still = Fixture.image()
        try engine.execute(.importAssets(assets: [still]))
        let ids = (0..<3_000).map { _ in UUID() }
        let build = try Self.clock {
            // One batch, as an import of a folder would do.
            try engine.execute(ids.map { .addClip(sequenceID: nil, clipID: $0, assetID: still.id, trackID: nil, start: nil, sourceStart: nil, duration: RationalTime(1, 1), index: nil) },
                               label: "Add 3,000 clips")
        }
        #expect(engine.main.count == 3_000)
        #expect(engine.project.activeSequence.duration == RationalTime(3_000, 1))

        var single = 0.0
        for index in 0..<20 {
            single += try Self.clock { try engine.execute(.splitClip(clipID: ids[index * 100], at: RationalTime(Int64(index * 100) * 2 + 1, 2), newClipID: UUID())) }
        }
        let undo = try Self.clock { for _ in 0..<20 { try engine.undo() } }
        var data = Data()
        let encode = try Self.clock { data = try ProjectCodec.encode(engine.project) }
        let decode = try Self.clock { _ = try ProjectCodec.decode(data) }
        print(String(format: "PERF 3000 clips: build %.0f ms, edit %.1f ms each, 20 undos %.0f ms, save %.0f ms (%.1f MB), load %.0f ms",
                     build * 1000, single / 20 * 1000, undo * 1000, encode * 1000, Double(data.count) / 1_048_576, decode * 1000))
        #expect(build < 60)
        #expect(single / 20 < 0.5, "one edit on a 3,000-clip timeline took \(single / 20) s")
        #expect(encode < 5 && decode < 10)
    }
}
