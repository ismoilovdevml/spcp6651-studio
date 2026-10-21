// MG330Protocol.swift — the 2E Gaming MG330 (Sunplus SPCP6651B, 1BCF:08B8) config layout.
//
// Everything here was reversed from the vendor driver SunplusIT_6651.dll (Ghidra via REA)
// and then checked against a live device: the config read back from the mouse reproduces
// every checksum below. See evidence/mg330-mouse/README.md for the function-by-function trail.
//
// Wire format — all transfers are 8-byte HID feature reports:
//
//   write one byte   SetFeature 0x40  [0x40, 0x05, 0x00, addr, v0, v1, v2, count]
//   block read       SetFeature 0x40  [0x40, 0x09, addrHi, addrLo, lenHi, lenLo, 0, 0]
//                    then GetFeature 0x41, 7 data bytes per report
//   block write      SetFeature 0x40  [0x40, 0x07, addrHi, addrLo, lenHi, lenLo, 0, 0]
//                    then SetFeature 0x41, 7 data bytes per report
//   reset/reload     SetFeature 0x40  [0x40, 0x0e, 0, 0, 0, 0, 0, 0]
import Foundation

enum MG330 {
    static let vendorID = 0x1BCF
    static let productID = 0x08B8

    static let reportWrite: UInt8 = 0x40
    static let reportData: UInt8 = 0x41

    static let cmdWriteByte: UInt8 = 0x05
    static let cmdBlockWrite: UInt8 = 0x07
    static let cmdBlockRead: UInt8 = 0x09
    static let cmdReload: UInt8 = 0x0E

    static let configSize = 0x800

    /// The prefix that holds every setting this app shows — through the end of the third
    /// button profile at 0x152, rounded up to a whole number of 7-byte reports.
    static let settingsSize = 0x160

    /// Everything except the button profiles: colours, DPI, polling, effect, name. Half
    /// the stream length of a full settings read, and the buttons never change on their
    /// own, so this is what the routine verification read asks for.
    static let coreSize = 0xA8

    // MARK: - Config addresses (device address == offset into the 0x800 config image)

    /// Polling rate lives in two bytes as single bits, so both are read-modify-written.
    static let addrPollA = 0x04        // bits 4,5 = rate low/high
    static let addrPollB = 0x08        // bit 3 = "not 125 Hz"
    static let addrGearCount = 0x2B    // stored as count - 1
    static let addrDPI = 0x2C          // 4 bytes, two 4-bit gear steps each
    static let addrPalette = 0x39      // 10 user colors, 3 bytes each
    static let addrGearColor = 0x57    // 8 CPI-gear indicator colors, 3 bytes each
    static let addrProductName = 0x6F  // NUL-terminated ASCII ("HID Gaming Mouse")
    static let addrChecksum = 0xA3     // covers 0x00..0xA2
    static let addrLEDMode = 0xA5      // effect index + 0x81 (0x80 = LEDs on)
    static let addrCurrentGear = 0xA6  // 0-based index of the active gear

    static let maxGears = 8
    static let paletteSlots = 10

    /// Three button profiles, 12 slots of 4 bytes each plus a trailing checksum byte.
    static let buttonProfileBases = [0xC0, 0xF1, 0x122]
    static let buttonProfileStride = 0x31
    static let buttonSlots = 12

    /// LED breath/speed block: 16 bytes at 0x3F0, its own checksum in the last byte.
    static let addrBreathBlock = 0x3F0
    static let breathBlockSize = 0x10
    static let addrBreathSpeed = 0x3F8  // stored as 7 - speed
    static let addrBreathFlags = 0x3F9  // bit 7 = direction, bits 0..3 = 9 - level

    // MARK: - Checksum

    /// Every checksummed region in this config is "sum of the bytes, XOR 0x5A".
    /// Verified on a live device for the main config and all three button profiles.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 } ^ 0x5A
    }

    // MARK: - DPI

    /// Step index (0...15) to CPI. The six values the factory config actually uses —
    /// steps 3, 6, 8, 9, 10 and 11 — line up exactly with the six DPI stages 2E
    /// publishes for the MG330UB (800/1600/2400/3200/4800/6400). The remaining entries
    /// follow the shape of that table but are not confirmed, so they are marked below.
    static let dpiTable = [100, 200, 400, 800, 1000, 1200, 1600, 2000,
                           2400, 3200, 4800, 6400, 8000, 10000, 12000, 16000]

    /// The steps whose CPI is pinned by the vendor's own published stages.
    static let confirmedSteps: Set<Int> = [3, 6, 8, 9, 10, 11]

    static func dpi(forStep step: Int) -> Int {
        dpiTable[max(0, min(step, dpiTable.count - 1))]
    }

    /// Gear steps are packed two per byte: even gears in the low nibble, odd in the high.
    static func gearStep(_ gear: Int, in config: [UInt8]) -> Int {
        let byte = Int(config[addrDPI + gear / 2])
        return (byte >> ((gear % 2) * 4)) & 0xF
    }

    static func packedDPIByte(gearPair index: Int, steps: [Int]) -> UInt8 {
        let low = steps.indices.contains(index * 2) ? steps[index * 2] & 0xF : 0
        let high = steps.indices.contains(index * 2 + 1) ? steps[index * 2 + 1] & 0xF : 0
        return UInt8((high << 4) | low)
    }

    // MARK: - Polling rate

    static let pollRates = [125, 250, 500, 1000]

    static func pollRateIndex(a: UInt8, b: UInt8) -> Int {
        guard b & 0x08 != 0 else { return 0 }              // bit 3 clear = 125 Hz
        switch (a & 0x10 != 0, a & 0x20 != 0) {
        case (true, false): return 1
        case (false, true): return 2
        case (true, true): return 3
        default: return 0
        }
    }

    /// Returns the two config bytes with only the rate bits changed — every other bit in
    /// those bytes belongs to unrelated settings and is preserved.
    static func pollRateBytes(index: Int, a: UInt8, b: UInt8) -> (UInt8, UInt8) {
        var a = a, b = b
        switch index {
        case 0: a &= ~0x30; b &= ~0x08
        case 1: a = (a | 0x10) & ~0x20; b |= 0x08
        case 2: a = (a & ~0x10) | 0x20; b |= 0x08
        default: a |= 0x30; b |= 0x08
        }
        return (a, b)
    }

    // MARK: - Lighting

    /// Effect index as written to 0xA5 (the stored byte is index + 0x81).
    enum Effect: Int, CaseIterable, Identifiable {
        case staticColor = 0, rainbow, breathing, neon, wave, reactive, ripple, flash

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .staticColor: return "Static"
            case .rainbow: return "Rainbow"
            case .breathing: return "Breathing"
            case .neon: return "Neon"
            case .wave: return "Wave"
            case .reactive: return "Reactive"
            case .ripple: return "Ripple"
            case .flash: return "Flash"
            }
        }

        var symbol: String {
            switch self {
            case .staticColor: return "circle.fill"
            case .rainbow: return "rainbow"
            case .breathing: return "wind"
            case .neon: return "sparkles"
            case .wave: return "waveform"
            case .reactive: return "hand.tap"
            case .ripple: return "drop"
            case .flash: return "bolt.fill"
            }
        }

        /// Only the first two were checked on the device; the rest are index slots the
        /// firmware accepts, with names inferred from the vendor UI's effect list.
        var isConfirmed: Bool { self == .staticColor || self == .rainbow }
    }

    static func ledModeByte(effect: Effect, on: Bool) -> UInt8 {
        on ? UInt8(effect.rawValue + 0x81) : 0x00
    }

    static func effect(fromModeByte byte: UInt8) -> (effect: Effect, on: Bool) {
        guard byte & 0x80 != 0 else { return (.staticColor, false) }
        let index = Int(byte & 0x7F) - 1
        return (Effect(rawValue: index) ?? .staticColor, true)
    }

    // MARK: - Buttons

    /// A button slot is four bytes: an action type, then up to three parameters.
    /// Types 0x01 (mouse button, parameter = HID button mask) and 0x09 (DPI action) are
    /// readable with confidence; the others are shown raw because their parameters were
    /// never traced to a vendor UI label.
    struct ButtonAction {
        var bytes: [UInt8]

        var type: UInt8 { bytes.first ?? 0 }

        var label: String {
            guard bytes.count == 4 else { return "—" }
            switch type {
            case 0x00: return bytes[1...].allSatisfy { $0 == 0 } ? "Disabled" : rawLabel
            case 0x01:
                switch bytes[1] {
                case 0x01: return "Left click"
                case 0x02: return "Right click"
                case 0x04: return "Middle click"
                case 0x08: return "Back"
                case 0x10: return "Forward"
                default: return "Mouse button 0x\(String(bytes[1], radix: 16))"
                }
            case 0x09:
                switch bytes[1] {
                case 0x01: return "DPI cycle"
                case 0x02: return "DPI / profile"
                default: return "DPI action 0x\(String(bytes[1], radix: 16))"
                }
            default: return rawLabel
            }
        }

        var isDecoded: Bool {
            guard bytes.count == 4 else { return false }
            if type == 0x01 { return [0x01, 0x02, 0x04, 0x08, 0x10].contains(bytes[1]) }
            if type == 0x09 { return bytes[1] == 0x01 || bytes[1] == 0x02 }
            if type == 0x00 { return bytes[1...].allSatisfy { $0 == 0 } }
            return false
        }

        var rawLabel: String {
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}
