import AVFoundation
import Accelerate
import Foundation

struct ChordDetectionResult {
    let chordName: String
    let noteNames: [String]
    let confidence: Float
}

final class ChordDetectionViewModel: ObservableObject {
    @Published var currentChordName: String = "Unknown"
    @Published var detectedNotesText: String = "-"
    @Published var confidence: Double = 0
    @Published var errorMessage: String?
    @Published var isRunning: Bool = false

    private let detector = AudioChordDetector()

    init() {
        detector.onDetection = { [weak self] result in
            DispatchQueue.main.async {
                self?.currentChordName = result.chordName
                self?.detectedNotesText = result.noteNames.isEmpty ? "-" : result.noteNames.joined(separator: ", ")
                self?.confidence = Double(result.confidence)
            }
        }

        detector.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error
                self?.isRunning = false
            }
        }
    }

    func toggleListening() {
        if isRunning {
            detector.stop()
            isRunning = false
            return
        }

        errorMessage = nil
        detector.start()
        isRunning = true
    }
}

final class AudioChordDetector {
    var onDetection: ((ChordDetectionResult) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let identifier = ChordIdentifier()

    private let fftSize = 4096
    private let hopSize = 2048
    private var sampleRate: Double = 44_100

    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var ringBuffer: [Float] = []
    private var lastEmit = DispatchTime.now()
    private var smoothedChroma = Array(repeating: Float(0), count: 12)
    private var noteHold = Array(repeating: Float(0), count: 12)
    private var noiseFloor: Float = 0.002

    private var stableResult = ChordDetectionResult(chordName: "Unknown", noteNames: [], confidence: 0)
    private var lastStableTime = DispatchTime.now()
    private var pendingResult: ChordDetectionResult?
    private var pendingCount = 0

    private let emitIntervalNs: UInt64 = 120_000_000
    private let holdDurationNs: UInt64 = 1_200_000_000
    private let minSwitchIntervalNs: UInt64 = 220_000_000
    private let switchConfirmFrames = 3

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.onError?("Microphone permission denied.")
                return
            }
            self.configureAndStartEngine()
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func configureAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true)

            let input = audioEngine.inputNode
            let format = input.inputFormat(forBus: 0)
            sampleRate = format.sampleRate

            if fftSetup == nil {
                fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
                window = Array(repeating: 0, count: fftSize)
                vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            }

            ringBuffer.removeAll(keepingCapacity: true)
            smoothedChroma = Array(repeating: 0, count: 12)
            noteHold = Array(repeating: 0, count: 12)
            pendingResult = nil
            pendingCount = 0
            stableResult = ChordDetectionResult(chordName: "Unknown", noteNames: [], confidence: 0)
            noiseFloor = 0.002
            lastStableTime = DispatchTime.now()

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hopSize), format: format) { [weak self] buffer, _ in
                self?.consume(buffer: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
        }
    }

    private func consume(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        ringBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))

        while ringBuffer.count >= fftSize {
            let frame = Array(ringBuffer.prefix(fftSize))
            process(frame: frame)
            ringBuffer.removeFirst(hopSize)
        }
    }

    private func process(frame: [Float]) {
        guard let fftSetup else { return }

        var windowed = Array(repeating: Float(0), count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = Array(repeating: Float(0), count: fftSize / 2)
        var imag = Array(repeating: Float(0), count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { rawPtr in
                    let complexPtr = rawPtr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = Array(repeating: Float(0), count: fftSize / 2)
        for i in 0..<(fftSize / 2) {
            magnitudes[i] = hypot(real[i], imag[i])
        }

        let frameRMS = rootMeanSquare(of: frame)
        let hasMusicalSignal = updateNoiseGate(with: frameRMS)
        let pitchClasses = buildPitchClassEnergies(from: magnitudes)
        let active = detectActivePitchClasses(from: pitchClasses, hasSignal: hasMusicalSignal)
        let rawDetection = identifier.identify(activePitchClasses: active)
        let detection = stabilizedResult(from: rawDetection)

        let now = DispatchTime.now()
        let shouldEmit = now.uptimeNanoseconds - lastEmit.uptimeNanoseconds > emitIntervalNs
        if shouldEmit {
            lastEmit = now
            onDetection?(detection)
        }
    }

    private func rootMeanSquare(of frame: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        return rms
    }

    private func updateNoiseGate(with frameRMS: Float) -> Bool {
        let dynamicThreshold = max(0.004, noiseFloor * 2.8)
        let hasSignal = frameRMS > dynamicThreshold

        // During quiet moments update floor quickly; during playing update slowly.
        let alpha: Float = hasSignal ? 0.995 : 0.92
        noiseFloor = alpha * noiseFloor + (1 - alpha) * min(frameRMS, 0.02)
        return hasSignal
    }

    private func buildPitchClassEnergies(from magnitudes: [Float]) -> [Float] {
        var chroma = Array(repeating: Float(0), count: 12)
        let binCount = magnitudes.count

        for bin in 1..<binCount {
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            if frequency < 55 || frequency > 2_000 {
                continue
            }

            let amplitude = magnitudes[bin]
            if amplitude < 1e-4 {
                continue
            }

            for harmonic in 1...5 {
                let fundamental = frequency / Double(harmonic)
                if fundamental < 55 || fundamental > 2_000 {
                    continue
                }
                let midi = 69 + 12 * log2(fundamental / 440)
                let pitchClass = Int(lround(midi)).mod(12)
                chroma[pitchClass] += amplitude / Float(harmonic)
            }
        }

        var maxVal: Float = 0
        vDSP_maxv(chroma, 1, &maxVal, vDSP_Length(chroma.count))
        if maxVal > 0 {
            var scale = 1 / maxVal
            vDSP_vsmul(chroma, 1, &scale, &chroma, 1, vDSP_Length(chroma.count))
        }

        return chroma
    }

    private func detectActivePitchClasses(from chroma: [Float], hasSignal: Bool) -> Set<Int> {
        let smoothing: Float = 0.82
        for i in 0..<12 {
            smoothedChroma[i] = smoothing * smoothedChroma[i] + (1 - smoothing) * chroma[i]
        }

        if !hasSignal {
            for i in 0..<12 {
                noteHold[i] *= 0.95
            }
        } else {
            for i in 0..<12 {
                let value = smoothedChroma[i]
                if value >= 0.34 {
                    noteHold[i] = min(1, noteHold[i] + 0.30)
                } else if value >= 0.23 {
                    noteHold[i] = min(1, noteHold[i] + 0.08)
                } else {
                    noteHold[i] *= 0.965
                }
            }
        }

        var active: Set<Int> = []
        for (idx, energy) in noteHold.enumerated() where energy > 0.55 {
            active.insert(idx)
        }

        // Prevent broad noise activation: keep the top 5 held pitch classes.
        if active.count > 5 {
            let top = noteHold.enumerated()
                .sorted { $0.element > $1.element }
                .prefix(5)
                .map { $0.offset }
            return Set(top)
        }

        return active
    }

    private func stabilizedResult(from raw: ChordDetectionResult) -> ChordDetectionResult {
        let now = DispatchTime.now()

        // Unknown/sparse result: keep previous stable output for a short release window.
        if raw.chordName == "Unknown" {
            let withinHold = now.uptimeNanoseconds - lastStableTime.uptimeNanoseconds < holdDurationNs
            if withinHold && !stableResult.noteNames.isEmpty {
                return stableResult
            }
            stableResult = raw
            return raw
        }

        if raw.chordName == stableResult.chordName {
            stableResult = raw
            lastStableTime = now
            pendingResult = nil
            pendingCount = 0
            return raw
        }

        if let pending = pendingResult, pending.chordName == raw.chordName {
            pendingCount += 1
            pendingResult = raw
        } else {
            pendingResult = raw
            pendingCount = 1
        }

        let canSwitch = now.uptimeNanoseconds - lastStableTime.uptimeNanoseconds > minSwitchIntervalNs
        if pendingCount >= switchConfirmFrames && canSwitch, let confirmed = pendingResult {
            stableResult = confirmed
            lastStableTime = now
            pendingResult = nil
            pendingCount = 0
            return confirmed
        }

        let withinHold = now.uptimeNanoseconds - lastStableTime.uptimeNanoseconds < holdDurationNs
        return withinHold ? stableResult : raw
    }
}

private enum ChordQuality: CaseIterable {
    case major
    case minor
    case diminished
    case augmented
    case sus2
    case sus4
    case dominant7
    case major7
    case minor7
    case halfDiminished7
    case diminished7

    var intervals: Set<Int> {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .halfDiminished7: return [0, 3, 6, 10]
        case .diminished7: return [0, 3, 6, 9]
        }
    }

    var symbol: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .sus2: return "sus2"
        case .sus4: return "sus4"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        case .halfDiminished7: return "m7b5"
        case .diminished7: return "dim7"
        }
    }
}

private final class ChordIdentifier {
    private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    func identify(activePitchClasses: Set<Int>) -> ChordDetectionResult {
        if activePitchClasses.count < 2 {
            let notes = activePitchClasses.sorted().map { noteNames[$0] }
            let confidence: Float = notes.isEmpty ? 0 : 0.35
            return ChordDetectionResult(chordName: "Unknown", noteNames: notes, confidence: confidence)
        }

        var bestName = "Unknown"
        var bestNotes: [Int] = []
        var bestScore: Float = 0

        for root in 0..<12 {
            for quality in ChordQuality.allCases {
                let template = Set(quality.intervals.map { ($0 + root).mod(12) })
                let intersection = activePitchClasses.intersection(template)
                if intersection.count < 2 {
                    continue
                }

                let overlap = Float(intersection.count) / Float(template.count)
                let extra = Float(activePitchClasses.subtracting(template).count)
                let miss = Float(template.subtracting(activePitchClasses).count)
                let score = overlap - 0.12 * extra - 0.08 * miss

                if score > bestScore {
                    bestScore = score
                    bestName = noteNames[root] + quality.symbol
                    bestNotes = template.sorted()
                }
            }
        }

        if bestScore < 0.4 {
            let notes = activePitchClasses.sorted().map { noteNames[$0] }
            return ChordDetectionResult(chordName: "Unknown", noteNames: notes, confidence: max(0.05, min(0.35, bestScore + 0.2)))
        }

        let renderedNotes = bestNotes.map { noteNames[$0] }
        let confidence = min(1, max(0, bestScore))
        return ChordDetectionResult(chordName: bestName, noteNames: renderedNotes, confidence: confidence)
    }
}

private extension Int {
    func mod(_ n: Int) -> Int {
        let r = self % n
        return r >= 0 ? r : r + n
    }
}
