// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKLoudnessC
import SPFKUtils

extension LoudnessDescription {
    public init(parsing url: URL) async throws {
        // will only create a longer file if needed
        var tmpfile: URL?

        do {
            tmpfile = try await AudioTools.createLoopedAudio(input: url, minimumDuration: 5)
        } catch {
            Log.debug("Failed to create looped audio for", url.lastPathComponent, ":", error.localizedDescription)
        }

        defer {
            if let tmpfile, tmpfile.exists {
                try? tmpfile.delete()
                Log.debug("Removed tmpfile at", tmpfile.path)
            }
        }

        let url = tmpfile ?? url

        guard let scanner = LoudnessScanner(path: url.path) else {
            throw NSError(description: "Failed to analyze '\(url.lastPathComponent)'")
        }

        self = LoudnessDescription(
            loudnessIntegrated: scanner.loudnessIntegrated,
            loudnessRange: scanner.loudnessRange,
            maxTruePeakLevel: scanner.maxTruePeakLevel,
            maxMomentaryLoudness: scanner.maxMomentaryLoudness,
            maxShortTermLoudness: scanner.maxShortTermLoudness
        ).validated()
    }
}
