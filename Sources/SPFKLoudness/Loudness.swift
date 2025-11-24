// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/SPFKLoudness

import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKLoudnessC

public enum Loudness {
    public static func analyze(url: URL) async throws -> LoudnessDescription {
        let tmpfile: URL? = try? await AudioTools.createLoopedAudio(input: url, minimumDuration: 5)

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

        return LoudnessDescription(
            lufs: scanner.lufs.isFinite ? scanner.lufs : nil,
            loudnessRange: scanner.loudnessRange.isFinite ? scanner.loudnessRange : nil,
            truePeak: scanner.truePeak.isFinite ? scanner.truePeak : nil
        )
    }
}
