// MouseDevice.swift — IOKit HID transport for the MG330.
//
// Unlike the N75 keyboard, this device never needs kIOHIDOptionsTypeSeizeDevice: the
// vendor page uses feature reports only, and a plain open is enough to Set/GetReport
// them. Measured on a live device: a seized open returns kIOReturnNotPrivileged, while
// a plain open succeeds and both the write and the read-back then work. Not seizing
// also means the mouse keeps working normally while this app is running.
//
// Opening it at all still needs the app to hold Input Monitoring, as any HID access on
// macOS does. That grant is bound to the code signature, so an ad-hoc signature — which
// changes on every build — loses it and the open comes back kIOReturnNotPermitted.
import Foundation
import IOKit
import IOKit.hid

enum DeviceError: Error, LocalizedError {
    case notFound
    case openFailed(IOReturn)
    case transferFailed(IOReturn)
    case unresponsive
    case shortRead(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "2E MG330 (1BCF:08B8) not found — plug the mouse in."
        case .openFailed(let r) where r == kIOReturnNotPermitted || r == kIOReturnNotPrivileged:
            return "macOS refused access to the mouse. Give this app Input Monitoring in "
                 + "System Settings › Privacy & Security, then reopen it."
        case .openFailed(let r):
            return "Could not open the device (IOReturn 0x\(String(format: "%08x", r)))."
        case .transferFailed(let r):
            return "HID transfer failed (IOReturn 0x\(String(format: "%08x", r)))."
        case .unresponsive:
            return "The mouse stopped answering its config channel. "
                 + "Unplug it and plug it back in — the pointer keeps working either way."
        case .shortRead(let expected, let got):
            return "Short read from the device: wanted \(expected) bytes, got \(got)."
        }
    }
}

/// Opens the mouse for the duration of one body call. Every public operation on
/// `MouseDevice` is a complete transaction, so nothing holds the device open in between.
struct MouseDevice {
    private let device: IOHIDDevice

    let productName: String

    private init(device: IOHIDDevice) {
        self.device = device
        self.productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
            ?? "HID Gaming Mouse"
    }

    private static func matchingDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return devices.first { device in
            let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            let featureSize = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int
            // Both HID interfaces answer to the VID/PID; only the vendor one carries
            // 8-byte feature reports.
            return vendor == MG330.vendorID && product == MG330.productID && (featureSize ?? 0) >= 8
        }
    }

    static func isConnected() -> Bool { matchingDevice() != nil }

    /// The firmware answers one request at a time. Two overlapping transactions — a
    /// colour write and the presence poll's read, say — make it time out and then stay
    /// unresponsive for a while, so every transaction is serialised here.
    private static let queue = DispatchQueue(label: "mg330.device")

    /// Runs `body` against an open device. Throws rather than returning a half-applied
    /// state. A timeout is never retried: once the channel stops answering it stays that
    /// way until the mouse is replugged, so a retry only costs another five seconds.
    static func withDevice<T>(_ body: (MouseDevice) throws -> T) throws -> T {
        try queue.sync {
            guard let hid = matchingDevice() else { throw DeviceError.notFound }
            let options = IOOptionBits(kIOHIDOptionsTypeNone)
            let result = IOHIDDeviceOpen(hid, options)
            guard result == kIOReturnSuccess else { throw DeviceError.openFailed(result) }
            defer { IOHIDDeviceClose(hid, options) }
            return try body(MouseDevice(device: hid))
        }
    }

    // MARK: - Primitives

    /// A timed-out feature transfer means the firmware's config channel has stopped
    /// answering. Retrying individual transfers makes that worse — a block read is 50
    /// round-trips, and retrying each one buries the device in a burst it never recovers
    /// from. So a timeout aborts the whole transaction here and is retried once, as a
    /// whole, by `withDevice`.
    private func check(_ result: IOReturn) throws {
        guard result != kIOReturnSuccess else { return }
        throw result == kIOReturnTimeout ? DeviceError.unresponsive
                                         : DeviceError.transferFailed(result)
    }

    private func send(_ bytes: [UInt8]) throws {
        var buffer = bytes
        try check(IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                       CFIndex(buffer[0]), &buffer, buffer.count))
        usleep(12_000)
    }

    /// Reads one 8-byte data report; the 7 payload bytes follow the report ID.
    private func receive() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8)
        buffer[0] = MG330.reportData
        var size = buffer.count
        try check(IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                       CFIndex(MG330.reportData), &buffer, &size))
        usleep(2_500)
        return Array(buffer[1...7])
    }

    /// Writes `values` (1...3 bytes) starting at `address` in the config image.
    func writeBytes(at address: Int, _ values: [UInt8]) throws {
        precondition((1...3).contains(values.count), "the write primitive carries 1-3 bytes")
        var report: [UInt8] = [MG330.reportWrite, MG330.cmdWriteByte, 0x00, UInt8(address & 0xFF),
                               0, 0, 0, UInt8(values.count)]
        for (index, value) in values.enumerated() { report[4 + index] = value }
        try send(report)
    }

    func writeByte(at address: Int, _ value: UInt8) throws {
        try writeBytes(at: address, [value])
    }

    /// A block read is a stream: the header tells the firmware how many 7-byte chunks to
    /// hand over, and it stays mid-stream until every one has been collected.
    ///
    /// **Abandoning a stream part-way is what wedges this mouse.** Measured: collecting 3
    /// of 51 chunks and then starting anything else leaves the config channel answering
    /// kIOReturnTimeout to every request — reads *and* writes — and nothing brings it
    /// back. A reload command cannot be delivered, draining the stream does not help, and
    /// closing and reopening the device does not help; only unplugging the mouse does.
    ///
    /// So this loop is never interrupted: no cancellation check, no per-chunk retry. Once
    /// a chunk does time out the channel is already gone, and since each failed transfer
    /// costs five seconds, the read gives up at once rather than stalling the app for
    /// minutes on a stream that cannot be rescued.
    func readBlock(at address: Int, length: Int) throws -> [UInt8] {
        try send([MG330.reportWrite, MG330.cmdBlockRead,
                  UInt8(address >> 8), UInt8(address & 0xFF),
                  UInt8(length >> 8), UInt8(length & 0xFF), 0, 0])

        var out = [UInt8]()
        out.reserveCapacity(length + 7)
        for _ in 0..<((length + 6) / 7) {
            out.append(contentsOf: try receive())
        }
        guard out.count >= length else { throw DeviceError.shortRead(expected: length, got: out.count) }
        return Array(out.prefix(length))
    }

    /// Everything the UI shows lives below `MG330.settingsSize` — 51 chunks rather than
    /// the 293 a full image costs. Used when the button table matters.
    func readSettings() throws -> [UInt8] {
        try readBlock(at: 0, length: MG330.settingsSize)
    }

    /// Colours, DPI, polling and the effect — 24 chunks. Every chunk is a chance to be
    /// interrupted, so the routine read after a change asks only for this.
    func readCore() throws -> [UInt8] {
        try readBlock(at: 0, length: MG330.coreSize)
    }

    /// The whole 2 KB image — used for the config export, not on the write path.
    func readConfig() throws -> [UInt8] {
        try readBlock(at: 0, length: MG330.configSize)
    }

    /// The firmware does not recompute the config checksum when single bytes are written;
    /// the vendor driver keeps it current by hand (it recomputes the byte before every
    /// block write). Leaving it stale risks the mouse deciding its config is corrupt on
    /// the next power-up, so each transaction ends by putting it right.
    func repairChecksum(in image: [UInt8]) throws -> [UInt8] {
        guard image.count > MG330.addrChecksum else { return image }
        let expected = MG330.checksum(image[0..<MG330.addrChecksum])
        guard expected != image[MG330.addrChecksum] else { return image }
        try writeByte(at: MG330.addrChecksum, expected)
        var repaired = image
        repaired[MG330.addrChecksum] = expected
        return repaired
    }

    /// Tells the firmware to reload its settings — the vendor driver sends this after
    /// changing the report rate, with the same half-second settle it waits out there.
    func reload() throws {
        try send([MG330.reportWrite, MG330.cmdReload, 0, 0, 0, 0, 0, 0])
        usleep(500_000)
    }

    // MARK: - Settings

    /// The logo on the palm rest draws its colour from the user palette.
    func setLogoColor(_ color: RGB) throws {
        for slot in 0..<MG330.paletteSlots {
            try writeBytes(at: MG330.addrPalette + slot * 3, color.bytes)
        }
    }

    /// The strip under the wheel draws its colour from the per-gear table. Only the gears
    /// the mouse actually has are written — the unused entries cost a round-trip each and
    /// change nothing visible.
    func setIndicatorColor(_ color: RGB, gearCount: Int) throws {
        for gear in 0..<min(gearCount, MG330.maxGears) {
            try writeBytes(at: MG330.addrGearColor + gear * 3, color.bytes)
        }
    }

    func setGearColor(_ color: RGB, gear: Int) throws {
        try writeBytes(at: MG330.addrGearColor + gear * 3, color.bytes)
    }

    func setEffect(_ effect: MG330.Effect, on: Bool) throws {
        try writeByte(at: MG330.addrLEDMode, MG330.ledModeByte(effect: effect, on: on))
    }

    /// Writes the DPI steps for every gear and then makes the active gear re-read its
    /// value. The vendor driver does the same bump — without it the new step only takes
    /// effect the next time the DPI button is pressed.
    func setDPISteps(_ steps: [Int], gearCount: Int, currentGear: Int) throws {
        let byteCount = (gearCount + 1) / 2
        for index in 0..<byteCount {
            try writeByte(at: MG330.addrDPI + index, MG330.packedDPIByte(gearPair: index, steps: steps))
        }
        let neighbour = currentGear == 0 ? currentGear + 1 : currentGear - 1
        try writeByte(at: MG330.addrCurrentGear, UInt8(neighbour))
        try writeByte(at: MG330.addrCurrentGear, UInt8(currentGear))
    }

    func setCurrentGear(_ gear: Int) throws {
        try writeByte(at: MG330.addrCurrentGear, UInt8(gear))
    }

    func setGearCount(_ count: Int) throws {
        try writeByte(at: MG330.addrGearCount, UInt8(max(1, min(count, MG330.maxGears)) - 1))
    }

    /// Read-modify-write: the two polling bytes carry unrelated settings in their other bits.
    func setPollRate(index: Int) throws {
        let current = try readBlock(at: MG330.addrPollA, length: MG330.addrPollB - MG330.addrPollA + 1)
        let (a, b) = MG330.pollRateBytes(index: index,
                                         a: current[0],
                                         b: current[MG330.addrPollB - MG330.addrPollA])
        try writeByte(at: MG330.addrPollA, a)
        try writeByte(at: MG330.addrPollB, b)
        try reload()
    }
}

/// An 8-bit-per-channel colour, the form the device stores.
struct RGB: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var bytes: [UInt8] { [r, g, b] }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ bytes: ArraySlice<UInt8>) {
        let values = Array(bytes)
        self.init(r: values.count > 0 ? values[0] : 0,
                  g: values.count > 1 ? values[1] : 0,
                  b: values.count > 2 ? values[2] : 0)
    }
}
