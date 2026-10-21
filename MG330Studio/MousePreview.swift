// MousePreview.swift — a lit outline of the MG330 showing both RGB zones.
//
// The shape is drawn rather than traced from a photo: a symmetric body, the scroll
// wheel, and the two zones the firmware lights separately — the DPI indicator strip
// under the wheel and the logo on the palm rest.
import SwiftUI

struct MousePreview: View {
    let logoColor: Color
    let indicatorColor: Color
    let effect: MG330.Effect
    let lightsOn: Bool
    let gearIndex: Int
    let gearCount: Int
    var compact: Bool = false

    @State private var phase: Double = 0

    private func zoneColor(_ base: Color) -> Color {
        guard lightsOn else { return Theme.keyOff }
        return effect == .staticColor ? base : animatedColor
    }

    private var logo: Color { zoneColor(logoColor) }
    private var indicator: Color { zoneColor(indicatorColor) }

    /// Non-solid effects cycle on the device; the preview cycles too so the two agree
    /// about *that* they move, without claiming to match the firmware's exact timing.
    private var animatedColor: Color {
        Color(hue: phase.truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1)
    }

    private var width: CGFloat { compact ? 108 : 168 }
    private var height: CGFloat { compact ? 170 : 264 }

    var body: some View {
        ZStack {
            body(shape: RoundedRectangle(cornerRadius: width * 0.46, style: .continuous))
            wheel
            dpiZone
            logoZone
        }
        .frame(width: width, height: height)
        .onAppear { animateIfNeeded() }
        .onChange(of: effect) { _, _ in animateIfNeeded() }
    }

    private func animateIfNeeded() {
        guard effect != .staticColor, lightsOn else { return }
        phase = 0
        withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }

    private func body(shape: some InsettableShape) -> some View {
        shape
            .fill(
                LinearGradient(colors: [Theme.keyFill, Theme.well],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .overlay(alignment: .top) {
                // The split between the two main buttons.
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1, height: height * 0.38)
            }
            .shadow(color: lightsOn ? logo.opacity(0.28) : .clear, radius: 24)
    }

    private var wheel: some View {
        Capsule()
            .fill(Theme.segTrack)
            .frame(width: width * 0.11, height: height * 0.1)
            .overlay(Capsule().strokeBorder(Theme.inset, lineWidth: 1))
            .offset(y: -height * 0.3)
    }

    /// The strip whose colour tracks the active DPI gear.
    private var dpiZone: some View {
        VStack(spacing: compact ? 3 : 4) {
            ForEach(0..<max(gearCount, 1), id: \.self) { index in
                Capsule()
                    .fill(index == gearIndex ? indicator : indicator.opacity(0.22))
                    .frame(width: width * (index == gearIndex ? 0.2 : 0.13),
                           height: compact ? 3 : 4)
            }
        }
        .offset(y: -height * 0.12)
        .animation(.easeOut(duration: 0.2), value: gearIndex)
    }

    /// The "2E" logo on the palm rest.
    private var logoZone: some View {
        Circle()
            .fill(
                RadialGradient(colors: [logo, logo.opacity(0.1)],
                               center: .center, startRadius: 0, endRadius: width * 0.2)
            )
            .frame(width: width * 0.34)
            .overlay(
                Text("2E")
                    .font(.system(size: compact ? 11 : 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(lightsOn ? Color.black.opacity(0.55) : Theme.textDim)
            )
            .offset(y: height * 0.2)
    }
}
