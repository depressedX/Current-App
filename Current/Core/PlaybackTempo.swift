import Foundation

/// Playback intent is separate from the song's measured tempo and recommendation query.
struct PlaybackTempo: Equatable {
    static let targets = stride(from: 40, through: 200, by: 5).map(Double.init)
    static let targetRange: ClosedRange<Double> = 40...200
    static let rateRange: ClosedRange<Double> = 0.5...2
    var enabled = false
    var targetBPM: Double = 100
    var originalBPM: Double?
    var displayBPM: Double? { enabled ? targetBPM : Self.validOriginal(originalBPM) }

    static func validOriginal(_ bpm: Double?) -> Double? {
        guard let bpm, bpm.isFinite, (20...400).contains(bpm) else { return nil }
        return bpm
    }
    static func snappedTarget(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return 100 }
        return min(targetRange.upperBound, max(targetRange.lowerBound, (bpm / 5).rounded() * 5))
    }
    var playbackRate: Float? {
        guard enabled else { return 1 }
        guard let original = Self.validOriginal(originalBPM) else { return nil }
        let rate = targetBPM / original
        guard rate.isFinite, Self.rateRange.contains(rate) else { return nil }
        return Float(rate)
    }
    var issue: String? {
        guard enabled else { return nil }
        guard Self.validOriginal(originalBPM) != nil else { return "当前歌曲 BPM 未识别" }
        guard playbackRate != nil else { return "超出这首歌的调速范围" }
        return nil
    }
    static func label(_ bpm: Double) -> String {
        guard bpm.isFinite else { return "未知" }
        return String(format: abs(bpm.rounded() - bpm) < 0.05 ? "%.0f" : "%.1f", bpm)
    }
}
