# SPFKLoudness

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-loudness)](https://github.com/ryanfrancesconi/spfk-loudness/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)

Loudness measurement to the [EBU R128](https://tech.ebu.ch/docs/r/r128.pdf) standard for audio
files: integrated loudness, loudness range, true peak, and the maximum momentary and short-term
loudness.

These are the numbers broadcast and streaming delivery specs are written in, and what a library app
needs to show a file's level or match a set of files to one another. Measurement is the vendored
[libebur128](https://github.com/jiixyj/libebur128) (MIT), driven from Swift with Core Audio decoding
and oversampling, so any format Core Audio reads can be measured with no further dependencies.
ShadowTag uses it for loudness analysis, album loudness and Normalize. It depends on neither product
and can be adopted on its own.

## What it does

**Measuring a file.** `LoudnessDescription(parsing:)` decodes a file and returns all five values.
Values outside the representable range come back `nil` rather than as a misleading number, and a
very short file is looped in memory so the integrated measurement has enough material to be stable.

**Measuring decoded audio.** Containers Core Audio cannot open, and audio tracks other than the
first, are measured from a `SequentialPCMSource` instead of a URL, so the decoder can come from
wherever the container is understood.

**Measuring a set of files.** The integrated loudness of an album is not the average of its tracks:
R128 gates the whole program together. `LoudnessAnalyzer.measure` keeps the gating blocks a result
came from, and `LoudnessGatingBlocks` integrates the blocks of many files as one program.

**Normalizing.** `NormalizeAnalyzer` turns a target, either a loudness in LUFS or a peak level, into
the linear gain a file needs, optionally limited by a true-peak ceiling and a maximum gain.

**Channel weighting.** Channels are weighted by the layout the file declares. With no layout
declared, WAV channel order is assumed.

## Usage

```swift
import SPFKAudioBase
import SPFKLoudness

let loudness = try await LoudnessDescription(parsing: url)
// loudness.loudnessIntegrated (LUFS), loudness.maxTruePeakLevel (dBTP), ...
```

Measure an album as one program:

```swift
let tracks = try urls.map { try LoudnessAnalyzer.measure(url: $0, minimumDuration: 5) }
let albumLUFS = LoudnessGatingBlocks.integratedLoudness(of: tracks.map(\.gatingBlocks))
```

Find the gain that brings a file to a target:

```swift
let normalize = try await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions(mode: .lufs))
// normalize.gain is a linear multiplier
```

## Things to know

- Decoding is synchronous. The `async` entry points await nothing, so call them from a task off the
  main actor. Cancelling that task stops the decode.
- `NormalizeAnalyzer` throws when a file cannot be read, so a batch can report that file instead of
  storing unity gain for it. A silent file is not an error: it returns unity gain.
- `LoudnessDescription` itself is declared in spfk-audio-base, so code that only stores or displays
  loudness does not need this package.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
