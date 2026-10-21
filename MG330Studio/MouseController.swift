// MouseController.swift — the app's single source of truth about the mouse.
//
// Nothing here assumes a factory default. The controller reads the device's own 2 KB
// config image on launch and after every write, so what the UI shows is what the mouse
// holds. A failed transfer leaves the last good snapshot in place and surfaces the error.
import Foundation
import SwiftUI

@MainActor
final class MouseController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var productName = "2E MG330"
    @Published private(set) var status: Status = .idle
    @Published private(set) var config: [UInt8] = []

    // Settings, mirrored from `config` after each read.
    /// The two zones the firmware lights independently: the palm-rest logo (user palette)
    /// and the strip under the wheel (per-gear table).
    @Published var logoColor = RGB(r: 0, g: 0, b: 255)
    @Published var indicatorColor = RGB(r: 0, g: 0, b: 255)
    @Published var effect: MG330.Effect = .staticColor
    @Published var lightsOn = true
    @Published var gearCount = 6
    @Published var currentGear = 0
    @Published var gearSteps = [3, 6, 8, 9, 10, 11, 0, 0]
    @Published var pollRateIndex = 3

    /// Per-gear indicator colours, kept so the DPI panel can show each gear's own colour.
    @Published private(set) var gearColors = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: MG330.maxGears)

    /// Button slots for the active profile, decoded for display only.
    @Published private(set) var buttons: [MG330.ButtonAction] = []

    enum Status: Equatable {
        case idle
        case busy(String)
        case ok(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: return nil
            case .busy(let text), .ok(let text), .failed(let text): return text
            }
        }
    }

    private var pollTimer: Timer?

    init() {
        refresh()
        // The mouse can be unplugged at any time; a slow poll keeps the header honest
        // without hammering the HID manager.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPresence() }
        }
    }

    deinit { pollTimer?.invalidate() }

    private func checkPresence() {
        // A transaction in flight already proves the device is there, and queueing a
        // read behind it only makes the UI lag.
        if case .busy = status { return }
        let present = MouseDevice.isConnected()
        guard present != isConnected else { return }
        isConnected = present
        if present { refresh() }
    }

    // MARK: - Reading

    /// Re-reads the settings block now and republishes every value from it.
    func refresh() {
        status = .busy("Reading the mouse…")
        verification?.cancel()
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try MouseDevice.withDevice { try $0.repairChecksum(in: $0.readSettings()) }
                }.value
                self.apply(image)
                self.isConnected = true
                self.status = .ok("Read from the mouse")
            } catch {
                if case DeviceError.notFound = error { self.isConnected = false }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ image: [UInt8]) {
        guard image.count >= MG330.coreSize else { return }
        config = image
        productName = storedProductName.isEmpty ? "2E MG330" : storedProductName

        gearCount = min(Int(image[MG330.addrGearCount]) + 1, MG330.maxGears)
        currentGear = min(Int(image[MG330.addrCurrentGear]), gearCount - 1)
        gearSteps = (0..<MG330.maxGears).map { MG330.gearStep($0, in: image) }

        let (storedEffect, on) = MG330.effect(fromModeByte: image[MG330.addrLEDMode])
        effect = storedEffect
        lightsOn = on

        gearColors = (0..<MG330.maxGears).map { gear in
            let base = MG330.addrGearColor + gear * 3
            return RGB(image[base..<(base + 3)])
        }
        indicatorColor = gearColors[min(currentGear, gearColors.count - 1)]
        logoColor = RGB(image[MG330.addrPalette..<(MG330.addrPalette + 3)])

        pollRateIndex = MG330.pollRateIndex(a: image[MG330.addrPollA], b: image[MG330.addrPollB])

        // Only a full settings read carries the button profiles; a core read stops
        // before them and leaves whatever was last seen in place.
        let base = MG330.buttonProfileBases[0]
        if image.count >= base + MG330.buttonSlots * 4 {
            buttons = (0..<MG330.buttonSlots).map { slot in
                let start = base + slot * 4
                return MG330.ButtonAction(bytes: Array(image[start..<(start + 4)]))
            }
        }
    }

    /// The name the mouse stores for itself, as opposed to the USB product string.
    var storedProductName: String {
        guard config.count > MG330.addrProductName else { return productName }
        let tail = config[MG330.addrProductName...]
        let bytes = Array(tail.prefix { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }

    var configChecksumMatches: Bool {
        guard config.count > MG330.addrChecksum else { return false }
        return MG330.checksum(config[0..<MG330.addrChecksum]) == config[MG330.addrChecksum]
    }

    // MARK: - Writing

    /// Which zone the colour controls act on.
    enum Zone: Int, CaseIterable {
        case both = 0, logo, indicator

        var title: String {
            switch self {
            case .both: return "Both"
            case .logo: return "Logo"
            case .indicator: return "DPI strip"
            }
        }
    }

    func color(of zone: Zone) -> RGB {
        zone == .indicator ? indicatorColor : logoColor
    }

    func applyColor(_ newColor: RGB, to zone: Zone) {
        // A colour is only visible in the solid mode, so picking one switches to it.
        let needsStatic = effect != .staticColor || !lightsOn
        let count = gearCount
        effect = .staticColor
        lightsOn = true

        if zone != .indicator { logoColor = newColor }
        if zone != .logo {
            indicatorColor = newColor
            gearColors = gearColors.enumerated().map { $0.offset < count ? newColor : $0.element }
        }

        run("Setting the \(zone.title.lowercased()) colour") { device in
            if zone != .indicator { try device.setLogoColor(newColor) }
            if zone != .logo { try device.setIndicatorColor(newColor, gearCount: count) }
            if needsStatic { try device.setEffect(.staticColor, on: true) }
        }
    }

    func applyEffect(_ newEffect: MG330.Effect) {
        effect = newEffect
        lightsOn = true
        run("Setting the effect") { device in
            try device.setEffect(newEffect, on: true)
        }
    }

    func setLights(on: Bool) {
        lightsOn = on
        let current = effect
        run(on ? "Lights on" : "Lights off") { device in
            try device.setEffect(current, on: on)
        }
    }

    func applyGearStep(_ step: Int, gear: Int) {
        guard gear < gearSteps.count else { return }
        gearSteps[gear] = step
        let steps = gearSteps
        let count = gearCount
        let active = currentGear
        run("Setting DPI for gear \(gear + 1)") { device in
            try device.setDPISteps(steps, gearCount: count, currentGear: active)
        }
    }

    func applyCurrentGear(_ gear: Int) {
        currentGear = gear
        run("Switching to gear \(gear + 1)") { device in
            try device.setCurrentGear(gear)
        }
    }

    func applyGearCount(_ count: Int) {
        gearCount = count
        let active = min(currentGear, count - 1)
        currentGear = active
        run("Setting \(count) DPI gears") { device in
            try device.setGearCount(count)
            try device.setCurrentGear(active)
        }
    }

    func applyGearColor(_ newColor: RGB, gear: Int) {
        guard gear < gearColors.count else { return }
        gearColors[gear] = newColor
        run("Setting the colour for gear \(gear + 1)") { device in
            try device.setGearColor(newColor, gear: gear)
        }
    }

    func applyPollRate(_ index: Int) {
        pollRateIndex = index
        run("Setting \(MG330.pollRates[index]) Hz") { device in
            try device.setPollRate(index: index)
        }
    }

    // MARK: - Config image

    /// Reads the full 2 KB image straight from the mouse and writes it to disk — a backup
    /// to compare against later, and the only safe way to record what the mouse held
    /// before an experiment.
    func exportConfig(to url: URL) {
        status = .busy("Reading the full config…")
        Task.detached(priority: .userInitiated) {
            do {
                let image = try MouseDevice.withDevice { try $0.readConfig() }
                try Data(image).write(to: url)
                await MainActor.run {
                    self.status = .ok("Saved \(image.count) bytes to \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Plumbing

    private var work: Task<Void, Never>?
    private var verification: Task<Void, Never>?

    /// Runs one device transaction off the main actor.
    ///
    /// Writes do not read the config back. A read is 50 round-trips, and issuing one
    /// after every click floods the firmware's config channel until it stops answering
    /// — which is what made rapid colour changes fail. Instead the UI updates
    /// optimistically and a single verification read runs once the user stops changing
    /// things; `Re-read` forces one at any time.
    ///
    /// Transactions are also chained rather than fired in parallel, so a burst of clicks
    /// turns into a queue the device can keep up with.
    private func run(_ label: String,
                     verify: Bool = true,
                     _ body: @escaping @Sendable (MouseDevice) throws -> Void) {
        status = .busy(label + "…")
        verification?.cancel()
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MouseDevice.withDevice { try body($0) }
                }.value
                self.isConnected = true
                self.status = .ok(label + " — done")
                if verify { self.scheduleVerification() }
            } catch {
                if case DeviceError.notFound = error { self.isConnected = false }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-reads the device once the dust settles, repairing the config checksum on the
    /// way — the firmware does not maintain it when single bytes are written.
    private func scheduleVerification() {
        verification?.cancel()
        verification = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                let image = try await Task.detached(priority: .utility) {
                    try MouseDevice.withDevice { try $0.repairChecksum(in: $0.readCore()) }
                }.value
                guard !Task.isCancelled else { return }
                self.apply(image)
                self.status = .ok("Verified against the mouse")
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }
}
