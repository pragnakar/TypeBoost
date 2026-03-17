// SuggestionBarWindow.swift
// TypeBoost
//
// A borderless, floating NSPanel that displays the three word suggestions
// near the text cursor. The panel:
//   • Floats above all windows (kCGPopUpMenuWindowLevel)
//   • Never becomes key or main (so focus stays in the target app)
//   • Adapts to light / dark mode automatically
//   • Animates in/out with a brief fade
//   • Supports keyboard-driven selection (arrow keys + Enter)

import Cocoa
import os

/// Whether the bar is showing completions, spell corrections, or next-word predictions.
enum SuggestionMode {
    case completion
    case spellCorrection
    case nextWord
}

final class SuggestionBarWindow: NSPanel {

    // MARK: – Subviews

    private let suggestionView = SuggestionBarView()

    // MARK: – State

    private(set) var isSelectionActive: Bool = false
    private var selectedIndex: Int = 0
    private var currentSuggestions: [Suggestion] = []
    /// Generation counter to prevent hide() completion from clearing a concurrent show().
    private var generation: UInt = 0

    // MARK: – Thread-Safe Visibility Flags
    // These atomic flags allow the CGEventTap background thread to check
    // suggestion visibility without dispatching to the main thread.

    private let _atomicVisible = OSAllocatedUnfairLock(initialState: false)
    private let _atomicSelectionActive = OSAllocatedUnfairLock(initialState: false)

    /// Thread-safe check: is the suggestion bar currently visible?
    var isVisibleAtomic: Bool { _atomicVisible.withLock { $0 } }

    /// Thread-safe check: is keyboard selection mode active?
    var isSelectionActiveAtomic: Bool { _atomicSelectionActive.withLock { $0 } }

    /// Updates isSelectionActive and its atomic mirror in one call.
    private func setSelectionActive(_ active: Bool) {
        isSelectionActive = active
        _atomicSelectionActive.withLock { $0 = active }
    }

    // MARK: – Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        self.level = .init(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false

        self.contentView = suggestionView
        suggestionView.frame = self.contentRect(forFrameRect: self.frame)
    }

    // MARK: – Display

    /// Show the suggestion bar near the given cursor rect.
    func show(suggestions: [Suggestion], near cursorRect: NSRect,
              activateSelection: Bool = false, mode: SuggestionMode = .completion) {
        generation &+= 1
        currentSuggestions = suggestions
        suggestionView.update(suggestions: suggestions, mode: mode)

        let doActivate = activateSelection

        if self.isVisible {
            // Already showing — reposition synchronously (no layout recursion risk).
            // Cancel any in-flight hide fade and ensure the bar is fully opaque.
            // Without this, a hide→show race leaves the bar at alpha 0 (invisible)
            // because hide() starts an 80ms fade before ordering out, and show()
            // can fire during that fade via the synchronous path which never
            // restored alpha.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                self.animator().alphaValue = 1.0
            }
            _atomicVisible.withLock { $0 = true }
            suggestionView.resizeWindowToFitContent()
            positionPanel(near: cursorRect)
            applySelectionState(activate: doActivate)
        } else {
            // First display — defer to prevent layoutSubtreeIfNeeded recursion.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suggestionView.resizeWindowToFitContent()
                self.positionPanel(near: cursorRect)
                self.applySelectionState(activate: doActivate)

                self.alphaValue = 0
                self.orderFrontRegardless()
                self._atomicVisible.withLock { $0 = true }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.1
                    self.animator().alphaValue = 1.0
                }
            }
        }
    }

    /// Shared helper for selection state to avoid duplication.
    private func applySelectionState(activate: Bool) {
        if activate {
            setSelectionActive(true)
            selectedIndex = 0
            suggestionView.highlightIndex(0)
        } else {
            setSelectionActive(false)
            selectedIndex = -1
            suggestionView.highlightIndex(-1)
        }
    }

    // MARK: – Positioning

    private func positionPanel(near cursorRect: NSRect) {
        let panelSize = self.frame.size
        let gap: CGFloat = 3  // Tight but clear of the text line.

        let targetScreen = NSScreen.screens.first(where: {
            $0.frame.intersects(cursorRect)
        }) ?? NSScreen.main
        guard let screen = targetScreen else { return }
        let visibleFrame = screen.visibleFrame

        // Validate the cursor rect — if it's not on any screen, use mouse position.
        var anchor = cursorRect
        if !NSScreen.screens.contains(where: { $0.frame.intersects(anchor) }) {
            let mouse = NSEvent.mouseLocation
            anchor = NSRect(x: mouse.x, y: mouse.y, width: 2, height: 16)
        }

        // Place bar ABOVE cursor — close enough to feel attached, far enough
        // to never overlap the text being typed.
        var origin = NSPoint(
            x: anchor.minX,
            y: anchor.maxY + gap
        )

        // Flip below cursor if no room above.
        if origin.y + panelSize.height > visibleFrame.maxY {
            origin.y = anchor.minY - panelSize.height - gap
        }

        // Hard clamp to visible screen area.
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - panelSize.width))
        origin.y = max(visibleFrame.minY + 4, min(origin.y, visibleFrame.maxY - panelSize.height - 4))

        // Animate small moves (same-line typing); snap for large jumps or first appearance.
        let currentOrigin = self.frame.origin
        let distance = hypot(origin.x - currentOrigin.x, origin.y - currentOrigin.y)

        if self.isVisible && distance < 80 && distance > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.04
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrameOrigin(origin)
            }
        } else {
            self.setFrameOrigin(origin)
        }
    }

    /// Update the suggestion bar in-place with new suggestions (e.g. async FM results).
    /// Re-positions the panel near the given cursor rect after the content resizes.
    func update(suggestions: [Suggestion], near cursorRect: NSRect,
                mode: SuggestionMode = .nextWord) {
        currentSuggestions = suggestions
        suggestionView.update(suggestions: suggestions, mode: mode)

        if self.isVisible {
            // Already showing — reposition synchronously for zero-lag tracking.
            // Cancel any in-flight hide fade (same race as in show()).
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                self.animator().alphaValue = 1.0
            }
            _atomicVisible.withLock { $0 = true }
            suggestionView.resizeWindowToFitContent()
            positionPanel(near: cursorRect)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suggestionView.resizeWindowToFitContent()
                self.positionPanel(near: cursorRect)
            }
        }
    }

    /// Reposition the bar near a new cursor rect without changing suggestions.
    /// Used by the async AX query that fires after every keystroke to keep
    /// the bar accurately anchored even when AX is slow.
    func reposition(near cursorRect: NSRect) {
        guard self.isVisible else { return }
        positionPanel(near: cursorRect)
    }

    /// Hide the suggestion bar with a fade.
    func hide() {
        guard self.isVisible else { return }
        _atomicVisible.withLock { $0 = false }
        let hideGeneration = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hideGeneration else { return }
            self.orderOut(nil)
            self.setSelectionActive(false)
            self.selectedIndex = -1
            self.currentSuggestions = []
        })
    }

    // MARK: – Navigation

    /// Enter selection mode (highlights the first suggestion).
    func activateSelection() {
        guard !currentSuggestions.isEmpty else { return }
        setSelectionActive(true)
        selectedIndex = 0
        suggestionView.highlightIndex(0)
    }

    /// Move highlight to the next suggestion.
    func moveNext() {
        guard isSelectionActive, !currentSuggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % currentSuggestions.count
        suggestionView.highlightIndex(selectedIndex)
    }

    /// Move highlight to the previous suggestion.
    func movePrevious() {
        guard isSelectionActive, !currentSuggestions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + currentSuggestions.count) % currentSuggestions.count
        suggestionView.highlightIndex(selectedIndex)
    }

    /// Accept the currently highlighted suggestion.
    func acceptSelection() -> Suggestion? {
        guard isSelectionActive,
              selectedIndex >= 0,
              selectedIndex < currentSuggestions.count else { return nil }
        let suggestion = currentSuggestions[selectedIndex]
        setSelectionActive(false)
        return suggestion
    }

    /// Returns the suggestion at the given 0-based index, or nil.
    func suggestion(at index: Int) -> Suggestion? {
        guard index >= 0, index < currentSuggestions.count else { return nil }
        return currentSuggestions[index]
    }

    // MARK: – Panel Overrides

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
