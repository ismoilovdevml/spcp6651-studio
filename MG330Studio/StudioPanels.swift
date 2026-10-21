// StudioPanels.swift — the four control panels and the button inspector.
import SwiftUI

// MARK: - Lighting

struct LightingPanel: View {
    @ObservedObject var mouse: MouseController
    let d: Density

    /// Fully saturated channel mixes. The mouse's LEDs are far brighter in green and blue
    /// than in red, so a screen colour like #30D158 arrives looking mint — presets that
    /// drive whole channels land much closer to their name.
    private let presets: [RGB] = [
        RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 60, b: 0), RGB(r: 255, g: 160, b: 0),
        RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 255, b: 255), RGB(r: 0, g: 0, b: 255),
        RGB(r: 180, g: 0, b: 255), RGB(r: 255, g: 255, b: 255)
    ]

    @State private var zone: MouseController.Zone = .both

    private var current: RGB { mouse.color(of: zone) }

    var body: some View {
        Card(d: d) {
            HStack {
                SectionLabel(text: "LIGHTING", d: d)
                Spacer()
                SwitchRow(isOn: Binding(get: { mouse.lightsOn },
                                        set: { mouse.setLights(on: $0) }), d: d) {
                    Text(mouse.lightsOn ? "On" : "Off")
                        .font(.system(size: d.dimSize))
                        .foregroundStyle(Theme.textDim)
                }
                .fixedSize()
            }

            SegmentedPair(titles: MouseController.Zone.allCases.map(\.title),
                          selection: Binding(get: { zone.rawValue },
                                             set: { zone = MouseController.Zone(rawValue: $0) ?? .both }),
                          d: d)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: d.cardGap) {
                RoundedRectangle(cornerRadius: d.swatchRadius, style: .continuous)
                    .fill(current.swiftUI)
                    .frame(width: d.swatch, height: d.swatch)
                    .overlay(RoundedRectangle(cornerRadius: d.swatchRadius, style: .continuous)
                        .strokeBorder(Theme.inset, lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(current.hex)
                        .font(.system(size: d.hexSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    Text(zone == .both ? "Logo and DPI strip"
                                       : (zone == .logo ? "The 2E logo" : "The strip under the wheel"))
                        .font(.system(size: d.dimSize))
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                ColorPicker("", selection: Binding(
                    get: { current.swiftUI },
                    set: { if let rgb = RGB($0) { mouse.applyColor(rgb, to: zone) } }
                ))
                .labelsHidden()
                .frame(width: 44)
            }

            Hairline()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: d.fxGap), count: 8),
                      spacing: d.fxGap) {
                ForEach(presets.indices, id: \.self) { index in
                    Button { mouse.applyColor(presets[index], to: zone) } label: {
                        Circle()
                            .fill(presets[index].swiftUI)
                            .frame(height: d.dot)
                            .overlay(Circle().strokeBorder(Theme.inset, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(presets[index].hex)
                }
            }

            Hairline()

            SectionLabel(text: "EFFECT", d: d)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: d.fxGap), count: 4),
                      spacing: d.fxGap) {
                ForEach(MG330.Effect.allCases) { effect in
                    EffectTile(effect: effect, isOn: mouse.effect == effect && mouse.lightsOn, d: d) {
                        mouse.applyEffect(effect)
                    }
                }
            }
            Text("Static and Rainbow were checked on the device; the other six are "
                 + "effect slots the firmware accepts, named from the vendor list.")
                .font(.system(size: d.dimSize - 1))
                .foregroundStyle(Theme.textDim)
        }
    }
}

private struct EffectTile: View {
    let effect: MG330.Effect
    let isOn: Bool
    let d: Density
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: d.fxGap / 2) {
                Image(systemName: effect.symbol)
                    .font(.system(size: d.fxIcon, weight: .medium))
                    .foregroundStyle(isOn ? Theme.accentIcon : Theme.textMid)
                Text(effect.title)
                    .font(.system(size: d.fxFont, weight: .medium))
                    .foregroundStyle(isOn ? Theme.text : Theme.textDim)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: d.fxMinHeight)
            .background(isOn ? Theme.accentTint : Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: d.fxRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: d.fxRadius, style: .continuous)
                .strokeBorder(isOn ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(effect.isConfirmed ? effect.title : "\(effect.title) — slot not verified on the device")
    }
}

// MARK: - DPI

struct DPIPanel: View {
    @ObservedObject var mouse: MouseController
    let d: Density

    var body: some View {
        Card(d: d) {
            HStack {
                SectionLabel(text: "DPI GEARS", d: d)
                Spacer()
                Menu {
                    ForEach(1...MG330.maxGears, id: \.self) { count in
                        Button("\(count) gears") { mouse.applyGearCount(count) }
                    }
                } label: {
                    Text("\(mouse.gearCount) gears")
                        .font(.system(size: d.dimSize))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ForEach(0..<mouse.gearCount, id: \.self) { gear in
                GearRow(mouse: mouse, gear: gear, d: d)
                if gear < mouse.gearCount - 1 { Hairline() }
            }

            Text("Steps 3, 6, 8, 9, 10 and 11 carry the DPI values 2E publishes for this "
                 + "model. The other steps are labelled from the same table but were not "
                 + "verified — they are marked with a dot.")
                .font(.system(size: d.dimSize - 1))
                .foregroundStyle(Theme.textDim)
        }
    }
}

private struct GearRow: View {
    @ObservedObject var mouse: MouseController
    let gear: Int
    let d: Density

    /// Held only while the slider is being dragged, so the device sees one write on
    /// release instead of one per step.
    @State private var draft: Double?

    private var isActive: Bool { mouse.currentGear == gear }

    private var step: Int { Int(draft ?? Double(mouse.gearSteps[gear])) }

    var body: some View {
        HStack(spacing: d.cardGap) {
            Button { mouse.applyCurrentGear(gear) } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isActive ? Theme.green : Theme.trackOff)
                        .frame(width: 8, height: 8)
                    Text("Gear \(gear + 1)")
                        .font(.system(size: d.bodySize, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Theme.text : Theme.textMid)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? "Active gear" : "Make this the active gear")
            .frame(width: d.isCompact ? 76 : 92, alignment: .leading)

            ColorPicker("", selection: Binding(
                get: { mouse.gearColors[gear].swiftUI },
                set: { if let rgb = RGB($0) { mouse.applyGearColor(rgb, gear: gear) } }
            ))
            .labelsHidden()
            .frame(width: 36)
            .help("Indicator colour for this gear")

            Slider(
                value: Binding(get: { Double(step) }, set: { draft = $0.rounded() }),
                in: 0...15, step: 1,
                onEditingChanged: { editing in
                    guard !editing, let value = draft else { return }
                    draft = nil
                    mouse.applyGearStep(Int(value), gear: gear)
                }
            )
            .tint(Theme.accent)

            HStack(spacing: 4) {
                if !MG330.confirmedSteps.contains(step) {
                    Circle().fill(Theme.amber).frame(width: 5, height: 5)
                }
                // String(), not interpolation: SwiftUI would otherwise group the digits
                // and render 1600 as "1 600".
                Text(String(MG330.dpi(forStep: step)))
                    .font(.system(size: d.bodySize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
            .frame(width: d.isCompact ? 62 : 74, alignment: .trailing)
        }
    }
}

// MARK: - Performance

struct PerformancePanel: View {
    @ObservedObject var mouse: MouseController
    let d: Density

    var body: some View {
        Card(d: d) {
            SectionLabel(text: "POLLING RATE", d: d)
            HStack(spacing: d.fxGap) {
                ForEach(MG330.pollRates.indices, id: \.self) { index in
                    let isOn = mouse.pollRateIndex == index
                    Button { mouse.applyPollRate(index) } label: {
                        VStack(spacing: 1) {
                            Text(String(MG330.pollRates[index]))
                                .font(.system(size: d.bodySize, weight: .semibold))
                                .foregroundStyle(isOn ? Theme.text : Theme.textMid)
                            Text("Hz")
                                .font(.system(size: d.dimSize - 1))
                                .foregroundStyle(Theme.textDim)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: d.btnHeight + 6)
                        .background(isOn ? Theme.accentTint : Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: d.btnRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: d.btnRadius, style: .continuous)
                            .strokeBorder(isOn ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Changing the rate reloads the firmware, so the pointer pauses for about "
                 + "half a second.")
                .font(.system(size: d.dimSize - 1))
                .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Buttons (read-only)

struct ButtonsPanel: View {
    @ObservedObject var mouse: MouseController
    let d: Density

    var body: some View {
        Card(d: d) {
            HStack {
                SectionLabel(text: "BUTTONS", d: d)
                Spacer()
                Text("read-only")
                    .font(.system(size: d.dimSize - 1, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.amberTint)
                    .clipShape(Capsule())
            }

            ForEach(mouse.buttons.indices, id: \.self) { slot in
                let action = mouse.buttons[slot]
                if action.type != 0 || !action.isDecoded {
                    HStack {
                        Text("Slot \(slot + 1)")
                            .font(.system(size: d.dimSize))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: d.isCompact ? 50 : 60, alignment: .leading)
                        Text(action.label)
                            .font(.system(size: d.bodySize,
                                          design: action.isDecoded ? .default : .monospaced))
                            .foregroundStyle(action.isDecoded ? Theme.text : Theme.textMid)
                        Spacer()
                        Text(action.rawLabel)
                            .font(.system(size: d.dimSize - 1, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }

            Text("The slot table and its checksum are decoded, but which physical button "
                 + "each slot drives — and what the unlabelled action codes mean — was never "
                 + "traced, so writing here could disable a button. Reading only, for now.")
                .font(.system(size: d.dimSize - 1))
                .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Colour bridging

extension RGB {
    var swiftUI: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    init?(_ color: Color) {
        guard let components = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: UInt8((components.redComponent * 255).rounded()),
                  g: UInt8((components.greenComponent * 255).rounded()),
                  b: UInt8((components.blueComponent * 255).rounded()))
    }
}
