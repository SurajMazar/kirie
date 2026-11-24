import Foundation
import Testing
@testable import ProjectDomain

@Suite("Rational time")
struct TimeTests {
    @Test func reducesAndCompares() {
        #expect(RationalTime(2, 4) == RationalTime(1, 2))
        #expect(RationalTime(-3, -6) == RationalTime(1, 2))
        #expect(RationalTime(1, 3) < RationalTime(1, 2))
        #expect(RationalTime(1001, 30000) > RationalTime(1, 30).scaled(by: 0.99))
        #expect(RationalTime(5, 0).timescale == 1, "a zero timescale must not trap")
    }

    @Test func addsAcrossTimescalesExactly() {
        let sum = RationalTime(1, 3) + RationalTime(1, 6)
        #expect(sum == RationalTime(1, 2))
        #expect(RationalTime(1001, 30000) * 30 == RationalTime(1001, 1000))
        #expect(RationalTime(7, 10) - RationalTime(7, 10) == .zero)
    }

    @Test func thousandFramesOfNTSCStayExact() {
        let frame = FrameRate.fps29_97.frameDuration
        var total = RationalTime.zero
        for _ in 0..<1000 { total += frame }
        #expect(total == RationalTime(1001 * 1000, 30000))
        #expect(total.frameIndex(rate: .fps29_97) == 1000)
    }

    @Test func roundsToFrames() {
        let rate = FrameRate.fps30
        #expect(seconds(1.016).rounded(toFrame: rate) == RationalTime(frames: 30, rate: rate))
        #expect(seconds(1.018).rounded(toFrame: rate) == RationalTime(frames: 31, rate: rate))
        #expect(seconds(1.99).floored(toFrame: rate) == RationalTime(frames: 59, rate: rate))
        #expect(seconds(-0.01).frameIndex(rate: rate) == -1)
    }

    @Test func codableUsesReadableStrings() throws {
        let encoded = try JSONEncoder().encode([RationalTime(1001, 30000)])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"1001\\/30000\"]")
        let decoded = try JSONDecoder().decode([RationalTime].self, from: Data("[\"3/2\", 0.5, \"2\"]".utf8))
        #expect(decoded == [RationalTime(3, 2), RationalTime(1, 2), RationalTime(2, 1)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([RationalTime].self, from: Data("[\"1/0\"]".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([RationalTime].self, from: Data("[\"abc\"]".utf8)) }
    }

    @Test func timecodeRoundTrips() {
        let rate = FrameRate.fps30
        let time = RationalTime(frames: 30 * 75 + 12, rate: rate)
        #expect(Timecode.string(time, rate: rate) == "00:01:15:12")
        #expect(Timecode.parse("00:01:15:12", rate: rate) == time)
        #expect(Timecode.parse("15:12", rate: rate) == RationalTime(frames: 30 * 15 + 12, rate: rate))
        #expect(Timecode.parse("not a time", rate: rate) == nil)
    }

    @Test func easingEndpoints() {
        for easing in Easing.allCases {
            #expect(abs(easing.apply(1) - 1) < 1e-9)
            if easing != .hold { #expect(abs(easing.apply(0)) < 1e-9) }
        }
    }
}
