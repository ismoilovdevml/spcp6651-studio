// ContentView.swift — window chrome and the two layouts.
//
// Same two densities as N75 Studio: the full window puts the mouse preview beside the
// panels, the compact one stacks them. The density is picked from the window size
// rather than from a setting, so resizing is the control.
import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var mouse = MouseController()

    var body: some View {
        GeometryReader { geometry in
            let d: Density = (geometry.size.width < 980 || geometry.size.height < 780)
                ? .compact : .regular

            VStack(spacing: 0) {
                header(d)
                Divider().overlay(Theme.hairline)
                if d.isCompact {
                    compactLayout(d)
                } else {
                    regularLayout(d)
                }
                statusBar(d)
            }
            .background(Theme.bg)
        }
        .background(WindowConfigurator())
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private func header(_ d: Density) -> some View {
        HStack(spacing: 12) {
            // Leave room for the traffic lights, which sit inside this bar.
            Spacer().frame(width: 68)

            VStack(alignment: .leading, spacing: 1) {
                Text("MG330 Studio")
                    .font(.system(size: d.isCompact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(mouse.isConnected ? mouse.productName : "Not connected")
                    .font(.system(size: d.dimSize))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ConnectionBadge(isConnected: mouse.isConnected, d: d)

            PillButton(title: "Re-read", systemImage: "arrow.clockwise", d: d) {
                mouse.refresh()
            }
            PillButton(title: "Export config", systemImage: "square.and.arrow.down",
                       iconOnly: d.isCompact, d: d) {
                exportConfig()
            }
        }
        .padding(.horizontal, d.headerPaddingH)
        .padding(.vertical, d.headerPaddingV)
        .background(Theme.chrome)
    }

    private func statusBar(_ d: Density) -> some View {
        HStack(spacing: 8) {
            switch mouse.status {
            case .idle:
                Text("Reads the mouse's own config — no Input Monitoring permission needed.")
                    .foregroundStyle(Theme.textDim)
            case .busy(let text):
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(Theme.textMid)
            case .ok(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(text).foregroundStyle(Theme.textMid)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                Text(text).foregroundStyle(Theme.textSoft)
            }
            Spacer()
            if !mouse.config.isEmpty {
                Text(mouse.configChecksumMatches ? "checksum ok" : "checksum mismatch")
                    .foregroundStyle(mouse.configChecksumMatches ? Theme.textDim : Theme.amber)
            }
        }
        .font(.system(size: d.dimSize))
        .padding(.horizontal, d.headerPaddingH)
        .padding(.vertical, d.isCompact ? 7 : 9)
        .background(Theme.chrome)
    }

    // MARK: - Layouts

    private func regularLayout(_ d: Density) -> some View {
        HStack(alignment: .top, spacing: d.mainGap) {
            VStack(spacing: d.mainGap) {
                preview(d)
                PerformancePanel(mouse: mouse, d: d)
            }
            .frame(width: 320)

            ScrollView {
                VStack(spacing: d.mainGap) {
                    LightingPanel(mouse: mouse, d: d)
                    DPIPanel(mouse: mouse, d: d)
                    ButtonsPanel(mouse: mouse, d: d)
                }
                .padding(.bottom, d.mainGap)
            }
        }
        .padding(d.mainPadding)
    }

    private func compactLayout(_ d: Density) -> some View {
        ScrollView {
            VStack(spacing: d.mainGap) {
                HStack(alignment: .top, spacing: d.mainGap) {
                    preview(d)
                    PerformancePanel(mouse: mouse, d: d)
                }
                LightingPanel(mouse: mouse, d: d)
                DPIPanel(mouse: mouse, d: d)
                ButtonsPanel(mouse: mouse, d: d)
            }
            .padding(d.mainPadding)
        }
    }

    private func preview(_ d: Density) -> some View {
        Card(d: d, alignment: .center) {
            MousePreview(logoColor: mouse.logoColor.swiftUI,
                         indicatorColor: mouse.indicatorColor.swiftUI,
                         effect: mouse.effect,
                         lightsOn: mouse.lightsOn,
                         gearIndex: mouse.currentGear,
                         gearCount: mouse.gearCount,
                         compact: d.isCompact)
                .frame(maxWidth: .infinity)
            Text("\(MG330.dpi(forStep: mouse.gearSteps[min(mouse.currentGear, mouse.gearSteps.count - 1)])) DPI"
                 + "  ·  \(MG330.pollRates[mouse.pollRateIndex]) Hz")
                .font(.system(size: d.bodySize, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMid)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mg330-config.bin"
        panel.allowedContentTypes = [.data]
        panel.message = "Save the 2 KB config image the mouse is currently holding."
        if panel.runModal() == .OK, let url = panel.url {
            mouse.exportConfig(to: url)
        }
    }
}

private struct ConnectionBadge: View {
    let isConnected: Bool
    let d: Density

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Theme.green : Theme.amber)
                .frame(width: 7, height: 7)
            Text(isConnected ? "1BCF:08B8" : "No device")
                .font(.system(size: d.dimSize, design: .monospaced))
                .foregroundStyle(isConnected ? Theme.greenText : Theme.amber)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isConnected ? Theme.greenTint : Theme.amberTint)
        .clipShape(Capsule())
    }
}

/// The header sits where the title bar would be, so the window needs to stay draggable
/// by its background.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.bg)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
