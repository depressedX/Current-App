import Accelerate
import Foundation

/// Discogs-EffNet frontend: 16 kHz, 512-point symmetric Hann, hop 256,
/// 96 Slaney-spaced unit-area triangles on power, log10(1 + 10000 * energy).
/// Returns time-major [128, 96] patches. No dependency on the DCLAP frontend.
final class GenreFrontend {
    private let setup: vDSP_DFT_Setup
    private let hann = (0..<512).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / 511)) }
    private let filters: [[Float]]
    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD) else { throw GenreError.inference }
        self.setup = setup
        func mel(_ hz: Double) -> Double { hz < 1000 ? hz / (200.0 / 3) : 15 + log(hz / 1000) / (log(6.4) / 27) }
        func hz(_ mel: Double) -> Double { mel < 15 ? mel * (200.0 / 3) : 1000 * exp((mel - 15) * (log(6.4) / 27)) }
        let points = (0..<98).map { hz(Double($0) * mel(8000) / 97) }
        filters = (0..<96).map { band in
            (0..<257).map { k in
                let frequency = Double(k) * 16000 / 512
                return Float(max(0, min((frequency - points[band]) / (points[band + 1] - points[band]),
                                        (points[band + 2] - frequency) / (points[band + 2] - points[band + 1]))) * 2 / (points[band + 2] - points[band]))
            }
        }
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func frame(_ samples: [Float]) throws -> [Float] {
        try Task.checkCancellation()
        guard samples.count == 512, samples.allSatisfy(\.isFinite) else { throw GenreError.invalidOutput }
        let real = zip(samples, hann).map(*)
        let imaginary = [Float](repeating: 0, count: 512)
        var outputReal = imaginary, outputImaginary = imaginary
        vDSP_DFT_Execute(setup, real, imaginary, &outputReal, &outputImaginary)
        let power = (0..<257).map { outputReal[$0] * outputReal[$0] + outputImaginary[$0] * outputImaginary[$0] }
        return filters.map { weights in
            var energy: Float = 0
            vDSP_dotpr(power, 1, weights, 1, &energy, 257)
            return log10(1 + 10000 * max(0, energy))
        }
    }
}

/// Bounded framing: first frame centered at zero, padded tail frames,
/// complete 128-frame patches every 62 frames; incomplete patches discarded.
final class GenrePatchStream {
    private let frontend: GenreFrontend
    private let consume: ([Float]) throws -> Void
    private var pcm = [Float](repeating: 0, count: 256)
    private var mel: [Float] = []
    private(set) var sampleCount = 0
    private(set) var windowCount = 0
    init(consume: @escaping ([Float]) throws -> Void) throws {
        frontend = try GenreFrontend(); self.consume = consume
    }
    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        for sample in samples {
            pcm.append(sample); sampleCount += 1
            if pcm.count == 512 { try emitFrame(); pcm.removeFirst(256) }
        }
    }
    func finish() throws {
        // FrameGenerator retains every trailing frame that still contains source samples.
        var tail = sampleCount > 0 ? pcm : []
        while !tail.isEmpty {
            pcm = tail + Array(repeating: 0, count: 512 - tail.count)
            try emitFrame()
            tail.removeFirst(min(256, tail.count))
        }
        pcm.removeAll(); mel.removeAll()
    }
    private func emitFrame() throws {
        mel.append(contentsOf: try frontend.frame(pcm))
        if mel.count == 128 * 96 {
            try consume(mel); windowCount += 1
            mel.removeFirst(62 * 96)
        }
    }
}
