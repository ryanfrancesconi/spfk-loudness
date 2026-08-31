# SPFKLoudness

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-loudness)](https://github.com/ryanfrancesconi/spfk-loudness/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)

A Swift package for measuring audio loudness according to the [EBU R128](https://tech.ebu.ch/docs/r/r128.pdf) standard. Built on [libebur128](https://github.com/jiixyj/libebur128) with a pure Swift analysis layer using Core Audio for decoding and sample-rate conversion.

Provides integrated loudness (LUFS), loudness range (LU), true peak (dBTP), and momentary/short-term loudness values for any audio format supported by Core Audio.

## Measuring

`LoudnessAnalyzer.analyze(url:)` returns the five EBU R128 values for a file.
`LoudnessDescription(parsing:)` wraps it with a default 5-second minimum duration and validates the
result, and a collection of descriptions has an `average`.

Files shorter than 2.5 seconds do not provide enough material for a stable integrated measurement.
Passing a `minimumDuration` loops the audio in memory until the target length is reached.

`NormalizeAnalyzer` measures what gain a file needs to hit a target level.

## EBU R128 Metrics

| Metric | Property | Unit | Description |
|--------|----------|------|-------------|
| Integrated Loudness | `loudnessIntegrated` | LUFS | Program loudness over the entire file, with gating |
| Loudness Range | `loudnessRange` | LU | Dynamic range per EBU Tech 3342 |
| True Peak | `maxTruePeakLevel` | dBTP | Maximum inter-sample peak level |
| Max Momentary | `maxMomentaryLoudness` | LUFS | Highest 400 ms loudness window |
| Max Short-Term | `maxShortTermLoudness` | LUFS | Highest 3 s loudness window |

### Processing Pipeline

1. **File decoding** — `ExtAudioFile` opens the file and delivers 32-bit float interleaved PCM
2. **Oversampling** — `AudioConverter` upsamples for true peak detection (4x for ≤48 kHz, 2x for ≤96 kHz, 1x above)
3. **Loudness measurement** — Decoded frames are fed to libebur128 in 100 ms chunks; momentary and short-term maxima are tracked per chunk
4. **True peak detection** — Oversampled output is scanned with `vDSP_maxmgv` for vectorized max-magnitude detection
5. **Looping** (optional) — If the file is shorter than half the `minimumDuration`, the callback seeks back to the start on EOF and continues feeding frames
6. **Validation** — Results outside the representable range (±99.99) are set to nil

## Supported Formats

Any audio format readable by Core Audio's `ExtAudioFile`, including WAV, AIF, FLAC, M4A, MP4, MP3, AAC, CAF, and OGG.

## Dependencies

| Package | Purpose |
|---------|---------|
| [spfk-audio-base](https://github.com/ryanfrancesconi/spfk-audio-base) | `LoudnessDescription` type |
| [spfk-testing](https://github.com/ryanfrancesconi/spfk-testing) | Test audio resources (test target only) |

## Requirements

- **Platforms:** macOS 13+, iOS 16+
- **Swift:** 6.2+

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
