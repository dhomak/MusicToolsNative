import SwiftUI
import AppKit

/// Kills any still-running job process groups when the app quits, so a
/// cancelled/closed app never leaves an orphaned ffmpeg behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        JobRegistry.killAll()
    }
}

@main
struct MusicToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.titleBar)
    }
}

/// Wraps the app in the currently-selected skin.
struct RootView: View {
    @AppStorage("skin") private var skinRaw = Skin.system.rawValue
    private var skin: Skin { Skin(rawValue: skinRaw) ?? .system }

    var body: some View {
        ContentView()
            .frame(minWidth: 940, minHeight: 640)
            .environment(\.palette, skin.palette)
            .tint(skin.palette.accent)
            .preferredColorScheme(skin.palette.colorScheme)
            .background(WindowSkin(palette: skin.palette))
    }
}

// MARK: - Theming

/// A selectable color scheme. Add a case here + an entry in `Skin.palette`
/// to introduce a new skin; the whole UI recolors live.
struct Palette {
    let accent: Color
    let pink: Color
    let consoleBg: Color
    let consoleText: Color
    let glow: Bool         // neon glow on accent elements
    let chamfer: CGFloat   // clipped-corner amount for the console; 0 = plain rounded
    let windowBg: Color?   // app-wide surface tint; nil = default macOS chrome
    let colorScheme: ColorScheme
}

enum Skin: String, CaseIterable, Identifiable {
    case system, light, cyberpunk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system:    return "Dark"
        case .light:     return "Light"
        case .cyberpunk: return "Cyberpunk"
        }
    }
    var palette: Palette {
        switch self {
        case .system:
            return Palette(
                accent:      Color(red: 0.00, green: 0.91, blue: 0.80),
                pink:        Color(red: 1.00, green: 0.19, blue: 0.55),
                consoleBg:   Color(red: 0.03, green: 0.03, blue: 0.06),
                consoleText: Color(red: 0.78, green: 0.80, blue: 0.92),
                glow: false, chamfer: 0, windowBg: nil, colorScheme: .dark)
        case .light:
            return Palette(
                accent:      Color(red: 0.00, green: 0.55, blue: 0.50),
                pink:        Color(red: 0.86, green: 0.13, blue: 0.45),
                consoleBg:   Color(red: 0.96, green: 0.96, blue: 0.97),
                consoleText: Color(red: 0.12, green: 0.13, blue: 0.18),
                glow: false, chamfer: 0, windowBg: nil, colorScheme: .light)
        case .cyberpunk:
            return Palette(
                accent:      Color(red: 0.00, green: 0.96, blue: 0.86),
                pink:        Color(red: 1.00, green: 0.13, blue: 0.55),
                consoleBg:   Color(red: 0.05, green: 0.02, blue: 0.11),
                consoleText: Color(red: 0.86, green: 0.80, blue: 1.00),
                glow: true, chamfer: 10,
                windowBg:    Color(red: 0.08, green: 0.05, blue: 0.14), colorScheme: .dark)
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = Skin.system.palette
}
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Octagonal clipped-corner rectangle for the cyberpunk skin.
struct ChamferedRectangle: Shape {
    var chamfer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = min(chamfer, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to:    CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX,     y: rect.minY + c))
        p.addLine(to: CGPoint(x: rect.maxX,     y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX,     y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.minX,     y: rect.minY + c))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// Tint a surface with the skin's window color (no-op for the System skin).
    @ViewBuilder func surfaceTint(_ palette: Palette) -> some View {
        if let bg = palette.windowBg { background(bg) } else { self }
    }
    /// Tint a List/scroll surface: hide the default background and paint ours
    /// (no-op for the System skin, which keeps native sidebar material).
    @ViewBuilder func listTint(_ palette: Palette) -> some View {
        if let bg = palette.windowBg {
            scrollContentBackground(.hidden).background(bg)
        } else {
            self
        }
    }
}

/// Recolors the host NSWindow (incl. the titlebar area, which is above SwiftUI's
/// view tree) to match the skin. Restores native chrome for the System skin.
struct WindowSkin: NSViewRepresentable {
    let palette: Palette
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let win = nsView.window else { return }
            win.appearance = NSAppearance(named: palette.colorScheme == .dark ? .darkAqua : .aqua)
            if let bg = palette.windowBg {
                win.titlebarAppearsTransparent = true               // let bg show through
                win.backgroundColor = NSColor(bg)
            } else {
                win.titlebarAppearsTransparent = false
                win.backgroundColor = nil                           // back to system
            }
        }
    }
}
