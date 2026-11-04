// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase

/// Computes a per-file normalization gain from ``NormalizeOptions``.
///
/// Call ``analyze(url:options:)`` with the user's chosen settings; it returns a
/// ``NormalizeDescription`` carrying the measured values and the linear gain
/// multiplier to apply during playback and export.
public enum NormalizeAnalyzer {
    /// Analyzes the audio file at `url` and returns a ``NormalizeDescription``
    /// whose `gain` is ready to store on `AudioEditDescription.normalize`.
    ///
    /// Throws when the file cannot be read, so a batch can report the file rather than store
    /// unity gain for it as though it had been measured.
    public static func analyze(url: URL, options: NormalizeOptions) async throws -> NormalizeDescription {
        switch options.mode {
        case .lufs:
            try await analyzeLUFS(url: url, options: options)
        case .peak:
            try await analyzePeak(url: url, options: options)
        }
    }
}

// MARK: - Private analysis

extension NormalizeAnalyzer {
    private static func analyzeLUFS(url: URL, options: NormalizeOptions) async throws -> NormalizeDescription {
        let loudness = try await LoudnessDescription(parsing: url)
        guard let measuredLUFS = loudness.loudnessIntegrated else { return NormalizeDescription() }

        var gainDB = Double(options.targetLUFS) - measuredLUFS

        if options.maximumGainEnabled {
            gainDB = min(gainDB, Double(options.maximumGaindB))
        }

        if options.ceilingEnabled, let measuredTP = loudness.maxTruePeakLevel {
            let projectedTP = Double(measuredTP) + gainDB
            let headroom = Double(options.ceilingdBTP) - projectedTP
            if headroom < 0 {
                gainDB += headroom
            }
        }

        return NormalizeDescription(
            measuredLUFS: Float(measuredLUFS),
            truePeakdBTP: loudness.maxTruePeakLevel,
            gain: Float(pow(10.0, gainDB / 20.0))
        )
    }

    private static func analyzePeak(url: URL, options: NormalizeOptions) async throws -> NormalizeDescription {
        let peak = try await BufferPeak(url: url)
        guard peak.amplitude > 0 else { return NormalizeDescription() }

        let measuredPeakDB = 20.0 * log10(Double(peak.amplitude))
        var gainDB = Double(options.targetPeakdBFS) - measuredPeakDB

        if options.maximumGainEnabled {
            gainDB = min(gainDB, Double(options.maximumGaindB))
        }

        return NormalizeDescription(
            measuredPeakdBFS: Float(measuredPeakDB),
            gain: Float(pow(10.0, gainDB / 20.0))
        )
    }
}
