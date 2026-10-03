// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase

/// The 400 ms gating blocks of one measurement that pass the absolute gate, as mean-square energies.
///
/// Integrated loudness gates the blocks of every file together, so a set of files is measured by
/// combining these rather than averaging each file's result.
public struct LoudnessGatingBlocks: Sendable, Equatable {
    public internal(set) var energies: [Double] = []

    /// BS.1770's −70 LUFS absolute gate, as an energy.
    static let absoluteGate = energy(loudness: -70)

    /// BS.1770's relative gate, 10 LU below the absolutely gated mean.
    static let relativeGateFactor = pow(10.0, -10.0 / 10.0)

    public init() {}

    static func energy(loudness: Double) -> Double {
        pow(10, (loudness + 0.691) / 10)
    }

    /// Integrated loudness of `blocks` gated together, to two decimal places as the analyzer
    /// reports it. `nil` when no block passes the gates.
    public static func integratedLoudness(of blocks: some Collection<LoudnessGatingBlocks>) -> Double? {
        var sum = 0.0
        var count = 0

        for set in blocks {
            sum += set.energies.reduce(0, +)
            count += set.energies.count
        }

        guard count > 0 else { return nil }

        let relativeThreshold = sum / Double(count) * relativeGateFactor

        var gatedSum = 0.0
        var gatedCount = 0

        for set in blocks {
            for energy in set.energies where energy >= relativeThreshold {
                gatedSum += energy
                gatedCount += 1
            }
        }

        guard gatedCount > 0 else { return nil }

        let loudness = 10 * log10(gatedSum / Double(gatedCount)) - 0.691
        return rint(100 * loudness) / 100
    }
}

/// A measurement's metrics together with the gating blocks it was integrated from.
public struct LoudnessMeasurement: Sendable {
    public let description: LoudnessDescription
    public let gatingBlocks: LoudnessGatingBlocks

    /// Whether channels were weighted by the layout the source declares. When `false`, libebur128
    /// assumed one from the channel count, which is right only for WAV order.
    public let usesDeclaredChannelLayout: Bool
}
