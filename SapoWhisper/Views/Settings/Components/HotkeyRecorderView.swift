//
//  HotkeyRecorderView.swift
//  SapoWhisper
//
//

import Carbon
import SwiftUI

/// Vista para grabar atajos de teclado personalizados
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var isRecording: Bool
    var onHotkeyChanged: (Int, Int) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.delegate = context.coordinator
        view.recordingPrompt = "config.hotkey_recorder_listening".localized
        view.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.recordingPrompt = "config.hotkey_recorder_listening".localized
        nsView.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        nsView.isRecording = isRecording
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, HotkeyRecorderDelegate {
        var parent: HotkeyRecorderView

        init(_ parent: HotkeyRecorderView) {
            self.parent = parent
        }

        func hotkeyRecorded(keyCode: Int, modifiers: Int) {
            parent.keyCode = keyCode
            parent.modifiers = modifiers
            parent.isRecording = false
            parent.onHotkeyChanged(keyCode, modifiers)
        }

        func recordingStateChanged(_ isRecording: Bool) {
            parent.isRecording = isRecording
        }
    }
}

// MARK: - Delegate Protocol

protocol HotkeyRecorderDelegate: AnyObject {
    func hotkeyRecorded(keyCode: Int, modifiers: Int)
    func recordingStateChanged(_ isRecording: Bool)
}

// MARK: - NSView Implementation

class HotkeyRecorderNSView: NSView {
    weak var delegate: HotkeyRecorderDelegate?
    var recordingPrompt = "Press your shortcut…" {
        didSet {
            if isRecording { needsDisplay = true }
        }
    }
    var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    private var displayKeyCode: Int = 49
    private var displayModifiers: Int = 2048  // optionKey

    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    func updateDisplay(keyCode: Int, modifiers: Int) {
        displayKeyCode = keyCode
        displayModifiers = modifiers
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor: NSColor = isRecording ? NSColor.systemGreen.withAlphaComponent(0.2) : NSColor.controlBackgroundColor
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.fill()

        // Border
        let borderColor: NSColor = isRecording ? NSColor.systemGreen : NSColor.separatorColor
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        // Text
        let text = isRecording ? recordingPrompt : hotkeyDescription(keyCode: displayKeyCode, modifiers: displayModifiers)
        let textColor: NSColor = isRecording ? .secondaryLabelColor : .labelColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]

        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        delegate?.recordingStateChanged(true)
        currentModifiers = []
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Necesita al menos un modificador
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let keyCode = Int(event.keyCode)
        let modifierValue = carbonModifiers(from: modifiers)

        displayKeyCode = keyCode
        displayModifiers = modifierValue
        isRecording = false

        delegate?.hotkeyRecorded(keyCode: keyCode, modifiers: modifierValue)
        delegate?.recordingStateChanged(false)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        currentModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    private func hotkeyDescription(keyCode: Int, modifiers: Int) -> String {
        HotkeyKeyName.keycapLabels(keyCode: keyCode, modifiers: modifiers).joined(separator: " ")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 200, height: 36)
    }
}
