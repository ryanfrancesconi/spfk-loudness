// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation
import SPFKLoudnessC

/// libebur128 channel types for a declared channel layout, which libebur128 otherwise guesses from
/// the channel count alone.
enum ChannelMap {
    /// One libebur128 channel type per channel, or `nil` when any label has no BS.1770 weighting
    /// here — ambisonics among them — and the channel-count default stands.
    ///
    /// Rear surrounds are weighted as surrounds: WAV's 5.1 mask declares its surrounds as rear.
    static func ebur128Channels(for labels: [AudioChannelLabel]) -> [Int32]? {
        var channels: [Int32] = []

        for label in labels {
            switch label {
            case kAudioChannelLabel_Left, kAudioChannelLabel_LeftCenter:
                channels.append(Int32(EBUR128_LEFT.rawValue))
            case kAudioChannelLabel_Right, kAudioChannelLabel_RightCenter:
                channels.append(Int32(EBUR128_RIGHT.rawValue))
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono:
                channels.append(Int32(EBUR128_CENTER.rawValue))
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2:
                channels.append(Int32(EBUR128_UNUSED.rawValue))
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftSurroundDirect:
                channels.append(Int32(EBUR128_LEFT_SURROUND.rawValue))
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightSurroundDirect:
                channels.append(Int32(EBUR128_RIGHT_SURROUND.rawValue))
            default:
                return nil
            }
        }

        return channels
    }

    /// The label of each channel `layout` declares, expanding a layout tag or bitmap. `nil` when
    /// the layout names no channels individually.
    static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag

        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return descriptions(of: layout).map { $0.map(\.mChannelLabel) }
        }

        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return expand(property: kAudioFormatProperty_ChannelLayoutForBitmap, specifier: layout.pointee.mChannelBitmap.rawValue)
        }

        return expand(property: kAudioFormatProperty_ChannelLayoutForTag, specifier: tag)
    }

    /// Both specifiers — a layout tag and a channel bitmap — are 32-bit values.
    private static func expand(property: AudioFormatPropertyID, specifier: UInt32) -> [AudioChannelLabel]? {
        var specifier = specifier
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var size: UInt32 = 0

        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr, size > 0 else {
            return nil
        }

        let byteCount = max(Int(size), MemoryLayout<AudioChannelLayout>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { raw.deallocate() }

        guard AudioFormatGetProperty(property, specifierSize, &specifier, &size, raw) == noErr else {
            return nil
        }

        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        return descriptions(of: layout).map { $0.map(\.mChannelLabel) }
    }

    private static func descriptions(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelDescription]? {
        let count = Int(layout.pointee.mNumberChannelDescriptions)

        guard count > 0,
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)
        else { return nil }

        let first = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return Array(UnsafeBufferPointer(start: first, count: count))
    }
}
