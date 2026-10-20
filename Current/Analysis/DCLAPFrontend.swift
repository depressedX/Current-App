import Accelerate
import Foundation

/// Matches librosa: 48k, periodic Hann 2048, hop 480, reflect-center, Slaney 128 mel, unbounded power dB.
/// One 10-second window at a time; no whole-song PCM or mel allocation.
final class DCLAPFrontend {
    static let sampleCount = 480_000
    static let frames = 1001
    private let setup: vDSP_DFT_Setup
    private let hann: [Float]
    private let filters: [(Int, [Float])]
    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 2048, .FORWARD) else { throw SemanticError.inference }
        self.setup = setup
        hann = (0..<2048).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / 2048)) }
        func mel(_ hz: Double) -> Double { hz < 1000 ? hz / (200.0 / 3) : 15 + log(hz / 1000) / (log(6.4) / 27) }
        func hz(_ mel: Double) -> Double { mel < 15 ? mel * (200.0 / 3) : 1000 * exp((mel - 15) * (log(6.4) / 27)) }
        let points = (0..<130).map { hz(Double($0) * mel(14000) / 129) }
        filters = (0..<128).map { band in
            let left = points[band], center = points[band + 1], right = points[band + 2]
            let first = max(0, Int(ceil(left / 48000 * 2048)))
            let last = min(1024, Int(floor(right / 48000 * 2048)))
            let weights = (first...last).map { k -> Float in
                let f = Double(k) * 48000 / 2048
                return Float(max(0, min((f - left) / (center - left), (right - f) / (right - center))) * 2 / (right - left))
            }
            return (first, weights)
        }
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func mel(samples: [Float]) throws -> [Float] {
        guard samples.count == Self.sampleCount, samples.allSatisfy(\.isFinite) else { throw SemanticError.invalidVector }
        let quantized = samples.map { Float(Int(max(-1, min(1, $0)) * 32767)) / 32767 }
        var real = [Float](repeating: 0, count: 2048), imaginary = real, outReal = real, outImaginary = real
        var power = [Float](repeating: 0, count: 1025)
        var result = [Float](repeating: 0, count: 128 * Self.frames)
        for frame in 0..<Self.frames {
            if frame % 16 == 0 { try Task.checkCancellation() }
            let offset = frame * 480 - 1024
            for k in 0..<2048 {
                let index = offset + k
                let reflected = index < 0 ? -index : (index >= quantized.count ? 2 * quantized.count - 2 - index : index)
                real[k] = quantized[reflected] * hann[k]
            }
            vDSP_DFT_Execute(setup, &real, &imaginary, &outReal, &outImaginary)
            for k in 0..<1025 { power[k] = outReal[k] * outReal[k] + outImaginary[k] * outImaginary[k] }
            for (band, filter) in filters.enumerated() {
                var energy: Float = 0
                power.withUnsafeBufferPointer { p in
                    filter.1.withUnsafeBufferPointer { w in
                        vDSP_dotpr(p.baseAddress! + filter.0, 1, w.baseAddress!, 1, &energy, vDSP_Length(w.count))
                    }
                }
                result[band * Self.frames + frame] = 10 * log10(max(1e-10, energy))
            }
        }
        return result
    }
}
