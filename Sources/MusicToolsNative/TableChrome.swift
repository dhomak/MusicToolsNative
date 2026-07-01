import SwiftUI
import AppKit

/// macOS 13's `Table` keeps drawing the native list background and alternating
/// row stripes even under `.scrollContentBackground(.hidden)`. This drops a tiny
/// probe view behind the table, walks *up* to the nearest enclosing scroll view
/// whose document is an NSTableView (the table's own — reached before the
/// sidebar's), and makes it transparent with stripes off.
///
/// IMPORTANT: the styling runs at most once per row-set change, tracked in the
/// coordinator — never on every SwiftUI render. Re-walking the view hierarchy
/// and mutating NSTableView on each render (as this used to) can stack up on the
/// main queue during scroll-driven re-renders and stall. Scrolling doesn't
/// change the row count, so it never triggers a walk.
///
/// Fails silently: if the hierarchy isn't what we expect it's a no-op, and the
/// table just looks the way it did before.
struct TransparentTableBackground: NSViewRepresentable {
    /// The visible row count. When it changes (new scan or filter) the styling
    /// is re-applied once; otherwise this view does nothing.
    var trigger: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTrigger: Int = .min
        var styled = false
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        scheduleIfNeeded(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.lastTrigger != trigger {
            context.coordinator.lastTrigger = trigger
            context.coordinator.styled = false          // row set changed → allow one re-apply
        }
        scheduleIfNeeded(nsView, context.coordinator)
    }

    /// Schedules a single deferred styling pass, but only if one isn't already
    /// satisfied. No-op once styled — so scrolling (stable trigger) costs nothing.
    private func scheduleIfNeeded(_ probe: NSView, _ coord: Coordinator) {
        guard !coord.styled else { return }
        DispatchQueue.main.async { [weak probe, weak coord] in
            guard let probe, let coord, !coord.styled else { return }
            var node = probe.superview
            while let cur = node {
                if let scroll = firstTableScroll(in: cur) {
                    style(scroll)
                    coord.styled = true                 // found + styled → stop until next change
                    return
                }
                node = cur.superview
            }
            // table view not in the tree yet; leave `styled` false so the next
            // update retries (e.g. right after a scan populates the table).
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
