//
//  HotkeyRecorderView.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI
import Carbon

/// Vista para grabar atajos de teclado personalizados
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var isRecording: Bool
    var onHotkeyChanged: (Int, Int) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.delegate = context.coordinator
        view.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
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
    var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    private var displayKeyCode: Int = 49
    private var displayModifiers: Int = 2048 // optionKey

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
        let text = isRecording ? "Presiona tu atajo..." : hotkeyDescription(keyCode: displayKeyCode, modifiers: displayModifiers)
        let textColor: NSColor = isRecording ? .secondaryLabelColor : .labelColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
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
        var parts: [String] = []

        if modifiers & controlKey != 0 { parts.append("⌃") }
        if modifiers & optionKey != 0 { parts.append("⌥") }
        if modifiers & shiftKey != 0 { parts.append("⇧") }
        if modifiers & cmdKey != 0 { parts.append("⌘") }

        parts.append(keyName(for: keyCode))

        return parts.joined(separator: " ")
    }

    private func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        default: return "Key\(keyCode)"
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 200, height: 36)
    }
}
