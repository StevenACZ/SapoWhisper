//
//  TranscribingIndicator.swift
//  SapoWhisper
//

import AppKit
import SwiftUI

/// Indicador de carga durante la transcripcion: a pulse travels across three
/// dots. The loop runs as Core Animation on the render server; the previous
/// SwiftUI phase loop re-rendered the overlay on the main thread hundreds of
/// times per second for the whole transcription.
struct TranscribingIndicator: View {
    var color: Color = .processing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulsingDotsRepresentable(color: NSColor(color), reduceMotion: reduceMotion)
            .frame(width: PulsingDotsNSView.width, height: PulsingDotsNSView.height)
            .accessibilityHidden(true)
    }
}

private struct PulsingDotsRepresentable: NSViewRepresentable {
    let color: NSColor
    let reduceMotion: Bool

    func makeNSView(context: Context) -> PulsingDotsNSView {
        PulsingDotsNSView()
    }

    func updateNSView(_ view: PulsingDotsNSView, context: Context) {
        view.configure(color: color, reduceMotion: reduceMotion)
    }
}

private final class PulsingDotsNSView: NSView {
    static let dotSize: CGFloat = 6
    static let spacing: CGFloat = 5
    static let width = dotSize * 3 + spacing * 2
    static let height = dotSize * 1.3
    private static let beat: CFTimeInterval = 0.5

    private var dots: [CALayer] = []
    private var color: NSColor?
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dots = (0..<3).map { _ in
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            dot.cornerRadius = Self.dotSize / 2
            layer?.addSublayer(dot)
            return dot
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, reduceMotion: Bool) {
        let colorChanged = color != self.color
        let motionChanged = reduceMotion != self.reduceMotion
        self.color = color
        self.reduceMotion = reduceMotion
        if colorChanged { updateColors() }
        if motionChanged { updateAnimations() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(
                x: Self.dotSize / 2 + CGFloat(index) * (Self.dotSize + Self.spacing),
                y: bounds.midY
            )
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
        updateAnimations()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        guard let color else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dots.forEach { $0.backgroundColor = color.cgColor }
            CATransaction.commit()
        }
    }

    /// Each dot lights up on its own third of a shared 1.5 s cycle, the same
    /// travelling pulse the SwiftUI version drew.
    private func updateAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            guard window != nil, !reduceMotion else {
                dot.opacity = 0.7
                dot.transform = CATransform3DIdentity
                continue
            }
            dot.opacity = 0.4
            dot.transform = CATransform3DMakeScale(0.8, 0.8, 1)

            let lit = (0..<4).map { step in step % 3 == index }
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = lit.map { $0 ? 1.3 : 0.8 }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = lit.map { $0 ? 1.0 : 0.4 }

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            for animation in [scale, opacity] {
                animation.keyTimes = [0, NSNumber(value: 1.0 / 3.0), NSNumber(value: 2.0 / 3.0), 1]
                animation.timingFunctions = [ease, ease, ease]
            }
            group.duration = Self.beat * 3
            group.repeatCount = .infinity
            dot.add(group, forKey: "pulse")
        }
        CATransaction.commit()
    }
}

#Preview("Transcribing Indicator") {
    HStack(spacing: 12) {
        TranscribingIndicator()
        Text("Transcribiendo...")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
    }
    .padding(20)
}
