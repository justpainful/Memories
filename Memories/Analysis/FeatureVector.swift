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

    init?(data: Data) {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    var data: Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
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
    /// Unpack the observation's raw buffer according to the element type it reports.
    var featureVector: FeatureVector {
        let raw = data
        switch elementType {
        case .float:
            guard raw.count % MemoryLayout<Float>.size == 0 else { return FeatureVector(values: []) }
            return FeatureVector(values: raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })

        case .float16:
            guard raw.count % MemoryLayout<Float16>.size == 0 else { return FeatureVector(values: []) }
            let halves: [Float16] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return FeatureVector(values: halves.map(Float.init))

        default:
            return FeatureVector(values: [])
        }
    }
}
