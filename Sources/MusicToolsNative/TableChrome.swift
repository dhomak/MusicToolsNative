import SwiftUI
import AppKit

/// macOS 13's `Table` keeps drawing the native list background and alternating
/// row stripes even under `.scrollContentBackground(.hidden)`, so the themed
/// `consoleBg` only showed at the edges. This drops a tiny probe view behind the
/// table, walks *up* from it to the nearest enclosing scroll view whose document
/// is an NSTableView (the table's own — reached before the sidebar's, which
/// lives in a higher branch), and makes it transparent with stripes off.
///
/// Fails silently: if the hierarchy isn't what we expect, it's a no-op and the
/// table just looks the way it did before.
struct TransparentTableBackground: NSViewRepresentable {
    /// Changing this (e.g. the visible row count) makes SwiftUI call
    /// `updateNSView`, so the styling is re-applied after the table rebuilds.
    var trigger: Int

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        reapply(from: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        reapply(from: nsView)
    }

    private func reapply(from probe: NSView) {
        // Defer to the next runloop tick so the table view exists and is laid out.
        DispatchQueue.main.async {
            var node = probe.superview
            while let cur = node {
                if let scroll = firstTableScroll(in: cur) { style(scroll); return }
                node = cur.superview
            }
        }
    }

    private func firstTableScroll(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView is NSTableView { return s }
        for sub in view.subviews {
            if let found = firstTableScroll(in: sub) { return found }
        }
        return nil
    }

    private func style(_ scroll: NSScrollView) {
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        if let table = scroll.documentView as? NSTableView {
            table.backgroundColor = .clear
            table.usesAlternatingRowBackgroundColors = false
            table.gridColor = .clear
        }
    }
}
