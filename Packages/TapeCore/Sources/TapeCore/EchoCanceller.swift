import Accelerate

public final class EchoCanceller {
    public static let blockSize = 512
    private static let filterSeconds = 0.2
    private static let stepSize: Float = 0.5
    private static let regularization: Float = 1e-6
    private static let switchRatio: Float = 0.25
    private static let decisionSmoothing: Float = 0.25

    public let sampleRate: Double
    private let blockSize = EchoCanceller.blockSize
    private let size = 2 * EchoCanceller.blockSize
    private let bins = EchoCanceller.blockSize
    private let log2Size = vDSP_Length(log2(Double(2 * EchoCanceller.blockSize)))
    private let partitions: Int
    private let setup: FFTSetup
    private let storage: UnsafeMutablePointer<Float>
    private let reference: UnsafeMutablePointer<Float>
    private let microphone: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let background: UnsafeMutablePointer<Float>
    private let foreground: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let spectrum: UnsafeMutablePointer<Float>
    private let gradient: UnsafeMutablePointer<Float>
    private let time: UnsafeMutablePointer<Float>
    private var filled = 0
    private var foregroundResidual: Float = 0
    private var backgroundResidual: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        partitions = Int((Self.filterSeconds * sampleRate / Double(blockSize)).rounded(.up))
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        let filterFloats = partitions * size
        let total = 4 * size + 2 * blockSize + 3 * filterFloats + bins + 1
        storage = .allocate(capacity: total)
        storage.initialize(repeating: 0, count: total)
        reference = storage
        microphone = reference + size
        output = microphone + blockSize
        history = output + blockSize
        background = history + filterFloats
        foreground = background + filterFloats
        spectrum = foreground + filterFloats
        gradient = spectrum + size
        time = gradient + size
        power = time + size
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        storage.deallocate()
    }

    public func process(microphone near: some Sequence<Float>, reference far: some Sequence<Float>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(near.underestimatedCount)
        for (nearSample, farSample) in zip(near, far) {
            result.append(output[filled])
            microphone[filled] = nearSample
            reference[blockSize + filled] = farSample
            filled += 1
            guard filled == blockSize else { continue }
            processBlock()
            filled = 0
        }
        return result
    }

    public func flush() -> [Float] {
        let pending = Array(UnsafeBufferPointer(start: output + filled, count: blockSize - filled))
        let partial = filled
        (microphone + partial).update(repeating: 0, count: blockSize - partial)
        (reference + blockSize + partial).update(repeating: 0, count: blockSize - partial)
        processBlock()
        filled = 0
        return pending + UnsafeBufferPointer(start: output, count: partial)
    }

    private func processBlock() {
        (history + size).update(from: history, count: (partitions - 1) * size)
        forward(reference, into: history)
        reference.update(from: reference + blockSize, count: blockSize)
        accumulatePower()

        filter(foreground)
        vDSP_vsub(time + blockSize, 1, microphone, 1, output, 1, vDSP_Length(blockSize))
        filter(background)
        vDSP_vsub(time + blockSize, 1, microphone, 1, time + blockSize, 1, vDSP_Length(blockSize))
        time.update(repeating: 0, count: blockSize)

        var foregroundEnergy: Float = 0
        var backgroundEnergy: Float = 0
        vDSP_svesq(output, 1, &foregroundEnergy, vDSP_Length(blockSize))
        vDSP_svesq(time + blockSize, 1, &backgroundEnergy, vDSP_Length(blockSize))
        foregroundResidual += Self.decisionSmoothing * (foregroundEnergy - foregroundResidual)
        backgroundResidual += Self.decisionSmoothing * (backgroundEnergy - backgroundResidual)
        if backgroundResidual < Self.switchRatio * foregroundResidual {
            foreground.update(from: background, count: partitions * size)
            output.update(from: time + blockSize, count: blockSize)
            foregroundResidual = backgroundResidual
        } else if foregroundResidual < Self.switchRatio * backgroundResidual {
            background.update(from: foreground, count: partitions * size)
            backgroundResidual = foregroundResidual
            return
        }

        adapt()
    }

    private func adapt() {
        forward(time, into: spectrum)
        var error = DSPSplitComplex(realp: spectrum, imagp: spectrum + bins)
        var step = DSPSplitComplex(realp: gradient, imagp: gradient + bins)
        var mu = Self.stepSize
        for partition in 0..<partitions {
            var far = DSPSplitComplex(realp: history + partition * size, imagp: history + partition * size + bins)
            vDSP_zvcmul(&far, 1, &error, 1, &step, 1, vDSP_Length(bins))
            step.realp[0] = far.realp[0] * error.realp[0]
            step.imagp[0] = far.imagp[0] * error.imagp[0]
            vDSP_vdiv(power, 1, step.realp, 1, step.realp, 1, vDSP_Length(bins))
            vDSP_vdiv(power + 1, 1, step.imagp + 1, 1, step.imagp + 1, 1, vDSP_Length(bins - 1))
            step.imagp[0] /= power[bins]
            inverse(gradient, into: time)
            (time + blockSize).update(repeating: 0, count: blockSize)
            forward(time, into: gradient)
            let weights = background + partition * size
            vDSP_vsma(gradient, 1, &mu, weights, 1, weights, 1, vDSP_Length(size))
        }
    }

    private func accumulatePower() {
        var floor = Self.regularization * Float(size * partitions)
        vDSP_vfill(&floor, power, 1, vDSP_Length(bins + 1))
        for partition in 0..<partitions {
            var far = DSPSplitComplex(realp: history + partition * size, imagp: history + partition * size + bins)
            vDSP_zvmgsa(&far, 1, power, 1, power, 1, vDSP_Length(bins))
            power[0] -= far.imagp[0] * far.imagp[0]
            power[bins] += far.imagp[0] * far.imagp[0]
        }
    }

    private func filter(_ weights: UnsafeMutablePointer<Float>) {
        var sum = DSPSplitComplex(realp: spectrum, imagp: spectrum + bins)
        spectrum.update(repeating: 0, count: size)
        for partition in 0..<partitions {
            var far = DSPSplitComplex(realp: history + partition * size, imagp: history + partition * size + bins)
            var filter = DSPSplitComplex(realp: weights + partition * size, imagp: weights + partition * size + bins)
            let dc = sum.realp[0] + far.realp[0] * filter.realp[0]
            let nyquist = sum.imagp[0] + far.imagp[0] * filter.imagp[0]
            vDSP_zvma(&far, 1, &filter, 1, &sum, 1, &sum, 1, vDSP_Length(bins))
            sum.realp[0] = dc
            sum.imagp[0] = nyquist
        }
        inverse(spectrum, into: time)
    }

    private func forward(_ samples: UnsafeMutablePointer<Float>, into destination: UnsafeMutablePointer<Float>) {
        var packed = DSPSplitComplex(realp: destination, imagp: destination + bins)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ctoz($0, 2, &packed, 1, vDSP_Length(bins)) }
        vDSP_fft_zrip(setup, &packed, 1, log2Size, FFTDirection(FFT_FORWARD))
    }

    private func inverse(_ source: UnsafeMutablePointer<Float>, into samples: UnsafeMutablePointer<Float>) {
        var packed = DSPSplitComplex(realp: source, imagp: source + bins)
        vDSP_fft_zrip(setup, &packed, 1, log2Size, FFTDirection(FFT_INVERSE))
        samples.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ztoc(&packed, 1, $0, 2, vDSP_Length(bins)) }
        var scale = 1 / Float(2 * size)
        vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(size))
    }
}
