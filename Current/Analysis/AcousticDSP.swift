import Foundation

/// Bounded, streaming measurements. No semantic inference and no whole-track PCM buffer.
struct AcousticDSP {
    static let sampleRate = 11_025.0
    static let hop = 110
    private var squares = 0.0
    private var peak = 0.0
    private var crossings = 0
    private var previous: Float = 0
    private var frameSquares = 0.0
    private var frameCount = 0
    private(set) var count = 0
    private var envelope: [Double] = []
    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        for value in samples {
            let sample = value.isFinite ? Double(value) : 0
            squares += sample * sample; frameSquares += sample * sample
            peak = max(peak, abs(sample))
            if count > 0 && (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = Float(sample); count += 1; frameCount += 1
            if frameCount == Self.hop {
                envelope.append(sqrt(frameSquares / Double(frameCount)))
                frameSquares = 0; frameCount = 0
            }
        }
    }
    func result(start: Double, elapsed: Double) throws -> AcousticFeatures {
        let duration = Double(count) / Self.sampleRate
        guard duration >= 8 else { throw AnalysisError.tooShort }
        guard squares / Double(max(1, count)) > 1e-10 else { throw AnalysisError.silent }
        let levels = envelope.map { Self.db($0) }.sorted()
        let spread = levels.isEmpty ? 0 : levels[Int(Double(levels.count - 1) * 0.9)] - levels[Int(Double(levels.count - 1) * 0.1)]
        let rhythm = Self.tempo(envelope: envelope, rate: Self.sampleRate / Double(Self.hop))
        return AcousticFeatures(bpm: rhythm.0, rhythmStrength: rhythm.1,
                                rmsDBFS: Self.db(sqrt(squares / Double(count))), peakDBFS: Self.db(peak),
                                dynamicSpreadDB: spread, zeroCrossingsPerSecond: Double(crossings) / duration,
                                sampleStart: start, sampleDuration: duration, elapsedSeconds: elapsed)
    }
    static func db(_ amplitude: Double) -> Double { 20 * log10(max(1e-6, amplitude)) }
    static func tempo(envelope: [Double], rate: Double) -> (Double?, Double) {
        guard envelope.count > Int(rate * 8) else { return (nil, 0) }
        var onset = [Double](repeating: 0, count: envelope.count)
        for i in 1..<envelope.count { onset[i] = max(0, envelope[i] - envelope[i - 1]) }
        // Smooth the onset grid to avoid integer-lag quantization favoring half tempo.
        let raw = onset
        for i in 2..<(onset.count - 2) {
            onset[i] = (raw[i - 2] + 2 * raw[i - 1] + 3 * raw[i] + 2 * raw[i + 1] + raw[i + 2]) / 9
        }
        let norm = onset.reduce(0) { $0 + $1 * $1 }
        guard norm > 1e-9 else { return (nil, 0) }
        let lower = Int(rate * 60 / 200), upper = min(onset.count / 2, Int(rate * 60 / 45))
        guard lower < upper else { return (nil, 0) }
        var strengths: [Double] = []
        var best = 0.0, lag = lower
        for offset in lower...upper {
            var sum = 0.0
            for i in offset..<onset.count { sum += onset[i] * onset[i - offset] }
            let strength = sum / norm
            strengths.append(strength)
            if strength > best { best = strength; lag = offset }
        }
        // Weak periodicity stays unknown. Half/double-time ambiguity remains visible in UI.
        let baseline = strengths.sorted()[strengths.count / 2]
        return (best >= 0.15 && best > baseline * 1.35 ? 60 * rate / Double(lag) : nil, min(1, max(0, best)))
    }
}

enum AnalysisError: LocalizedError {
    case tooShort, silent, noAudio, tooLarge, download, decode, invalidAudioResponse
    case downloadHTTP(Int)
    var errorDescription: String? {
        switch self {
        case .tooShort: return "有效音频不足 8 秒"
        case .silent: return "音频接近静音，无法测量"
        case .noAudio: return "没有可分析的音轨"
        case .tooLarge: return "音频超过 40 MB 限制"
        case .download: return "音频获取失败，请重试"
        case .decode: return "音频无法解码"
        case .invalidAudioResponse: return "服务器未返回可识别的音频文件"
        case .downloadHTTP(let code): return "音频下载失败（HTTP \(code)）"
        }
    }
}


extension AnalysisError: SafeLogError {
    var logFailure: LogFailure {
        switch self {
        case .tooShort: return .tooShort
        case .silent: return .silent
        case .noAudio: return .missingAudio
        case .tooLarge: return .tooLarge
        case .download: return .download
        case .decode: return .decode
        case .invalidAudioResponse: return .invalidAudioResponse
        case .downloadHTTP: return .httpStatus
        }
    }
}
