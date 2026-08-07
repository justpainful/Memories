import Foundation
import Vision

/// A Vision feature print reduced to a plain float vector.
///
/// Vision can compare two live observations directly, but incremental indexing needs to
/// compare a photo imported today against one analyzed months ago, long after those
/// observations are gone. So the vector is extracted once, stored on the row, and compared
/// arithmetically from then on.
struct FeatureVector: Sendable, Equatable {
    var values: [Float]

    init(values: [Float]) {
        self.values = values
    }

    var isEmpty: Bool { values.isEmpty }

    // MARK: Persistence

    /// Stored at half precision.
    ///
    /// A print is around 768 dimensions. At full precision that is 3 KB per asset, which on a
    /// library of tens of thousands of photos is the single largest thing this app writes to
    /// disk — and it is spent on a number that only ever feeds a cosine comparison. Half
    /// precision halves it and changes similarity in about the fourth decimal place, far below
    /// the 0.92 threshold anything is judged against.
    init?(data: Data) {
        guard !data.isEmpty, data.count % MemoryLayout<Float16>.size == 0 else { return nil }
        let halves: [Float16] = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        values = halves.map(Float.init)
    }

    var data: Data {
        let halves = values.map(Float16.init)
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Comparison

    /// Cosine similarity in 0...1. Feature prints are non-negative, so this stays in range.
    func similarity(to other: FeatureVector) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot: Double = 0, lhs: Double = 0, rhs: Double = 0
        for index in values.indices {
            let a = Double(values[index]), b = Double(other.values[index])
            dot += a * b
            lhs += a * a
            rhs += b * b
        }
        guard lhs > 0, rhs > 0 else { return 0 }
        return max(0, min(1, dot / (lhs.squareRoot() * rhs.squareRoot())))
    }
}

extension FeaturePrintObservation {
    /// Unpack the observation's raw buffer.
    ///
    /// The element width is derived from the buffer rather than matched against enum cases,
    /// so this keeps working if Vision changes what it hands back.
    var featureVector: FeatureVector {
        let raw = data
        guard elementCount > 0, raw.count % elementCount == 0 else {
            return FeatureVector(values: [])
        }

        switch raw.count / elementCount {
        case MemoryLayout<Float16>.size:
            let halves: [Float16] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return FeatureVector(values: halves.map(Float.init))

        case MemoryLayout<Float>.size:
            return FeatureVector(values: raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })

        case MemoryLayout<Double>.size:
            let doubles: [Double] = raw.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            return FeatureVector(values: doubles.map(Float.init))

        default:
            return FeatureVector(values: [])
        }
    }
}
