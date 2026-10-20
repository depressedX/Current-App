import AVFoundation
import Foundation
import Darwin

@main struct AudioWindowChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for rate in [44100.0, 48000.0] {
            let url = directory.appendingPathComponent("fixture-\(Int(rate)).wav")
            try autoreleasepool {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                var offset = 0
                while offset < Int(rate * 24) {
                    let count = min(4096, Int(rate * 24) - offset)
                    buffer.frameLength = AVAudioFrameCount(count)
                    for k in 0..<count {
                        let value = Float(0.25 * sin(2 * .pi * 1000 * Double(offset + k) / rate))
                        buffer.floatChannelData![0][k] = value; buffer.floatChannelData![1][k] = value
                    }
                    try file.write(from: buffer); offset += count
                }
            }
            try check(url, expectedTone: true)
        }
        for path in CommandLine.arguments.dropFirst() { try check(URL(fileURLWithPath: path), expectedTone: false) }
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("fixture-44100.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DCLAPAnalyzer.read(file: file, start: 0)
        }
        do { _ = try await cancelled.value; fatalError("Cancelled decode returned samples") }
        catch is CancellationError {}
        print("PASS cancelled decode does not return a result")
        print("ALL AUDIO WINDOW CHECKS PASSED")
    }
    static func check(_ url: URL, expectedTone: Bool) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let starts = DCLAPAnalyzer.windowStarts(duration: duration)
        for start in starts {
            let samples = try DCLAPAnalyzer.read(file: file, start: start)
            precondition(samples.count == 480000 && samples.allSatisfy(\.isFinite))
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            if expectedTone {
                precondition(abs(rms - 0.25 / sqrt(2)) < 0.005, "Stereo downmix or resampling changed the reference level")
                let crossings = zip(samples, samples.dropFirst()).filter { ($0.0 < 0) != ($0.1 < 0) }.count
                precondition(abs(Double(crossings) / 20 - 1000) < 2, "Sample rate or channel conversion changed pitch")
            }
        }
        print("PASS", Int(file.processingFormat.sampleRate), "Hz", file.processingFormat.channelCount,
              "channels → 48k mono;", starts.count, "exact 480000-frame windows")
    }
}
