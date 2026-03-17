// SuggestionBarView.swift
// TypeBoost
//
// The NSView rendered inside SuggestionBarWindow. Displays up to three
// suggestion "pills" in a tight horizontal row with thin separators,
// styled to blend with the native macOS aesthetic.

import Cocoa

final class SuggestionBarView: NSVisualEffectView {

    // MARK: – Subviews

    private var pillViews: [SuggestionPillView] = []
    private var separators: [NSBox] = []
    private let prefixIconView = NSTextField(labelWithString: "")

    // MARK: – Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.material = .popover
        self.blendingMode = .behindWindow
        self.state = .active
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true

        for i in 0..<3 {
            let pill = SuggestionPillView(index: i)
            pill.isHidden = true
            addSubview(pill)
            pillViews.append(pill)
        }

        // Two separators (between pill 0-1 and pill 1-2).
        for _ in 0..<2 {
            let sep = NSBox()
            sep.boxType = .separator
            sep.isHidden = true
            addSubview(sep)
            separators.append(sep)
        }

        // Prefix icon for next-word mode.
        prefixIconView.font = .systemFont(ofSize: 10)
        prefixIconView.textColor = .secondaryLabelColor
        prefixIconView.isHidden = true
        addSubview(prefixIconView)
    }

    // MARK: – Update

    func update(suggestions: [Suggestion], mode: SuggestionMode = .completion) {
        let isNextWord = mode == .nextWord

        // 1. Configure pill content (text only — no frame changes yet).
        for (i, pill) in pillViews.enumerated() {
            if i < suggestions.count {
                pill.configure(
                    word: suggestions[i].word,
                    shortcut: i + 1
                )
                pill.isHidden = false
                pill.setHighlighted(false)
            } else {
                pill.isHidden = true
            }
        }

        // Hide unused separators.
        let count = min(suggestions.count, 3)
        for (i, sep) in separators.enumerated() {
            sep.isHidden = i >= count - 1
        }

        // 2. Apply mode styling.
        switch mode {
        case .completion:
            self.layer?.borderWidth = 0
            prefixIconView.isHidden = true
        case .spellCorrection:
            self.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
            self.layer?.borderWidth = 1.0
            prefixIconView.isHidden = true
        case .nextWord:
            self.layer?.borderWidth = 0
            prefixIconView.stringValue = "⚡"
            prefixIconView.isHidden = false
        }

        // 3. Schedule a layout pass (does NOT start one now).
        self.needsLayout = true
    }

    func resizeWindowToFitContent() {
        let visiblePills = pillViews.filter { !$0.isHidden }
        guard !visiblePills.isEmpty else { return }

        let padding: CGFloat = 6
        let barHeight: CGFloat = 30
        let iconWidth: CGFloat = prefixIconView.isHidden ? 0 : 16
        let pillWidth = visiblePills.map { $0.intrinsicWidth }.reduce(0, +)
        let separatorWidth = CGFloat(visiblePills.count - 1) * 1
        let totalWidth = pillWidth + separatorWidth + padding * 2 + iconWidth
        let newSize = NSSize(width: max(totalWidth, 80), height: barHeight)

        // Defer setContentSize to the next run-loop pass.
        // Calling it synchronously here can trigger a layout pass on the content
        // view while AppKit is already mid-layout, producing the
        // "layoutSubtreeIfNeeded on a view which is already being laid out" warning.
        // Deferring breaks the re-entrancy without any visible delay.
        guard let window = self.window, window.frame.size != newSize else { return }
        DispatchQueue.main.async { [weak window, newSize] in
            window?.setContentSize(newSize)
        }
    }

    // MARK: – Layout

    override func layout() {
        super.layout()

        // Only position pills within the current bounds.
        // Do NOT resize the window here.
        let visiblePills = pillViews.filter { !$0.isHidden }
        guard !visiblePills.isEmpty else { return }

        let padding: CGFloat = 6
        let separator: CGFloat = 1
        var xOffset = padding

        // Position prefix icon if visible.
        if !prefixIconView.isHidden {
            prefixIconView.frame = NSRect(x: xOffset, y: 7, width: 14, height: 16)
            xOffset += 16
        }

        for (i, pill) in visiblePills.enumerated() {
            let pillWidth = pill.intrinsicWidth
            pill.frame = NSRect(
                x: xOffset,
                y: 4,
                width: pillWidth,
                height: bounds.height - 8
            )
            xOffset += pillWidth

            // Position separator after each pill except the last.
            if i < visiblePills.count - 1, i < separators.count {
                let sep = separators[i]
                sep.frame = NSRect(x: xOffset, y: 5, width: 1, height: bounds.height - 10)
                xOffset += separator
            }
        }
    }

    // MARK: – Highlight

    func highlightIndex(_ index: Int) {
        for (i, pill) in pillViews.enumerated() {
            pill.setHighlighted(i == index)
        }
    }
}

// MARK: – SuggestionPillView

/// A single suggestion pill: word on the left, small number hint top-right.
final class SuggestionPillView: NSView {

    private let wordLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var highlighted = false
    private var cachedIntrinsicWidth: CGFloat = 0

    /// Returns the cached width needed for this pill based on its word text.
    var intrinsicWidth: CGFloat { cachedIntrinsicWidth }

    init(index: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        wordLabel.font = .systemFont(ofSize: 13, weight: .medium)
        wordLabel.textColor = .labelColor
        wordLabel.alignment = .left
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.maximumNumberOfLines = 1
        addSubview(wordLabel)

        shortcutLabel.font = .systemFont(ofSize: 9, weight: .regular)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(word: String, shortcut: Int?) {
        wordLabel.stringValue = word
        if let shortcut {
            shortcutLabel.stringValue = "\(shortcut)"
            shortcutLabel.isHidden = false
        } else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
        }
        // Recompute and cache intrinsic width.
        let wordWidth = ceil(
            (word as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
            ).width
        )
        // 8pt left pad + word + 4pt gap + 10pt for number + 8pt right pad
        cachedIntrinsicWidth = wordWidth + 30
    }

    func setHighlighted(_ flag: Bool) {
        highlighted = flag
        if flag {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func layout() {
        super.layout()
        // Word takes most of the pill, vertically centred.
        wordLabel.frame = NSRect(x: 8, y: 2, width: bounds.width - 24, height: bounds.height - 4)
        // Number sits top-right, small.
        shortcutLabel.frame = NSRect(x: bounds.width - 16, y: bounds.height - 14, width: 12, height: 12)
    }

    override func updateLayer() {
        super.updateLayer()
        setHighlighted(highlighted)
    }
}
