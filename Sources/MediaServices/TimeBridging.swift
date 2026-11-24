import CoreMedia
import Foundation
import ProjectDomain

extension RationalTime {
    /// Converts to CMTime. Timescales beyond Int32 are re-expressed on the default timescale.
    public var cmTime: CMTime {
        if timescale <= Int64(Int32.max) {
            return CMTime(value: value, timescale: CMTimeScale(timescale))
        }
        let scaled = (seconds * Double(RationalTime.defaultTimescale)).rounded()
        return CMTime(value: CMTimeValue(scaled), timescale: CMTimeScale(RationalTime.defaultTimescale))
    }

    public init(_ time: CMTime) {
        if time.isNumeric, time.timescale != 0 {
            self.init(time.value, Int64(time.timescale))
        } else {
            self = .zero
        }
    }
}

extension TimeRange {
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

extension FrameRate {
    public var cmFrameDuration: CMTime { CMTime(value: denominator, timescale: CMTimeScale(numerator)) }
}
