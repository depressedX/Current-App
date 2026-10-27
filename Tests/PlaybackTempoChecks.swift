import Foundation

@main struct PlaybackTempoChecks {
    static func main() {
        precondition(PlaybackTempo.targets.first == 40 && PlaybackTempo.targets.last == 200)
        precondition(PlaybackTempo.snappedTarget(113) == 115)
        precondition(PlaybackTempo.snappedTarget(96) == 95)
        precondition(PlaybackTempo.snappedTarget(-100) == 40)
        precondition(PlaybackTempo.snappedTarget(.infinity) == 100)
        precondition(PlaybackTempo.snappedTarget(.nan) == 100)
        for target in PlaybackTempo.targets {
            for original in [60.0, 96, 100, 120, 180, 240] {
                let tempo = PlaybackTempo(enabled: true, targetBPM: target, originalBPM: original)
                if let rate = tempo.playbackRate {
                    precondition(abs(Double(rate) * original - target) < 0.0001)
                } else { precondition(tempo.issue != nil) }
            }
        }
        var tempo = PlaybackTempo(enabled: true, targetBPM: 100, originalBPM: 96)
        precondition(abs(tempo.playbackRate! - 100 / 96) < 0.0001)
        tempo.originalBPM = 120
        precondition(tempo.targetBPM == 100 && abs(tempo.playbackRate! - 100 / 120) < 0.0001)
        for invalid: Double? in [nil, 0, -1, .nan, .infinity, 401] {
            tempo.originalBPM = invalid
            precondition(tempo.playbackRate == nil && tempo.issue != nil)
        }
        tempo.originalBPM = 240
        precondition(tempo.playbackRate == nil, "Never silently clamp and claim the target BPM")
        tempo.enabled = false
        precondition(tempo.playbackRate == 1 && tempo.issue == nil)
        tempo.originalBPM = 123
        precondition(tempo.displayBPM == 123, "Original mode must not display the saved 100 BPM target")
        tempo.enabled = true
        precondition(tempo.displayBPM == 100)
        tempo.enabled = false
        precondition(tempo.displayBPM == 123 && tempo.playbackRate == 1)
        tempo.originalBPM = nil
        precondition(tempo.displayBPM == nil)
        precondition(PlaybackTempo.label(96.3) == "96.3")
        print("PASS: 5-BPM scale, cross-track target invariance, output BPM across all ticks, unknown/invalid BPM, rate limits, original mode")
    }
}
