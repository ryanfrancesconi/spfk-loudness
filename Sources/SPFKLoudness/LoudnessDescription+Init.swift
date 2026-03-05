// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase
import SPFKBase
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
        let result = try LoudnessAnalyzer.analyze(url: url)

        self = LoudnessDescription(
            loudnessIntegrated: result.loudnessIntegrated,
            loudnessRange: result.loudnessRange,
            maxTruePeakLevel: result.maxTruePeakLevel,
            maxMomentaryLoudness: result.maxMomentaryLoudness,
            maxShortTermLoudness: result.maxShortTermLoudness
        ).validated()
    }
}
