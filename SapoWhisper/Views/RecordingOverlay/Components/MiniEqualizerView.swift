import AppKit
import Combine
import SwiftUI

struct MiniEqualizerView: View {
    let audioLevelPublisher: AnyPublisher<Float, Never>
    var barCount: Int = 5
    var isConnecting: Bool = false
    var barColor: Color = .recording

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RecordingMeterRepresentable(
            publisher: audioLevelPublisher,
            barCount: max(0, barCount),
            isConnecting: isConnecting,
            color: NSColor(barColor),
            reduceMotion: reduceMotion
        )
        .frame(width: CGFloat(max(0, barCount)) * 6.5 - (barCount > 0 ? 2.5 : 0), height: 20)
    }
}

private struct RecordingMeterRepresentable: NSViewRepresentable {
    let publisher: AnyPublisher<Float, Never>
    let barCount: Int
    let isConnecting: Bool
    let color: NSColor
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RecordingMeterNSView {
        let view = RecordingMeterNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecordingMeterNSView, context: Context) {
        view.configure(self)
    }

    static func dismantleNSView(_ view: RecordingMeterNSView, coordinator: ()) {
        view.stop()
    }
}

private final class RecordingMeterNSView: NSView {
    private var configuration: RecordingMeterRepresentable?
    private var bars: [CALayer] = []
    private var levels: [CGFloat] = []
    private var audioSubscription: AnyCancellable?
    private var connectingSubscription: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ next: RecordingMeterRepresentable) {
        let previous = configuration
        configuration = next
        let countChanged = bars.count != next.barCount
        if countChanged {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<next.barCount).map { _ in
                let bar = CALayer()
                bar.bounds = CGRect(x: 0, y: 0, width: 4, height: 20)
                bar.cornerRadius = 2
                layer?.addSublayer(bar)
                return bar
            }
            levels = Array(repeating: 0, count: next.barCount)
            needsLayout = true
        }
        if countChanged || previous?.color != next.color {
            updateColors()
        }
        let phaseChanged = previous?.isConnecting != next.isConnecting
        let motionChanged = previous?.reduceMotion != next.reduceMotion
        if countChanged || phaseChanged || motionChanged {
            if next.isConnecting || previous?.isConnecting == true {
                levels = connectingLevels()
            }
            render(animated: false)
            updateConnectingSubscription()
        }
        startAudioSubscription()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = CGFloat(bars.count) * 6.5 - (bars.isEmpty ? 0 : 2.5)
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: (bounds.width - width) / 2 + CGFloat(index) * 6.5 + 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        updateColors()
        render(animated: false)
        startAudioSubscription()
        updateConnectingSubscription()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func stop() {
        audioSubscription?.cancel()
        audioSubscription = nil
        connectingSubscription?.cancel()
        connectingSubscription = nil
        bars.forEach { $0.removeAllAnimations() }
    }

    private func startAudioSubscription() {
        guard window != nil, audioSubscription == nil, let configuration else { return }
        // Keep the attached meter's source across unrelated SwiftUI updates.
        audioSubscription = configuration.publisher.receive(on: RunLoop.main).sink { [weak self] level in
            // receive(on:) establishes the main-run-loop callback boundary.
            MainActor.assumeIsolated {
                guard let self, self.window != nil, self.configuration?.isConnecting == false else { return }
                let next = RecordingMeterLevels.advance(CGFloat(level), previous: self.levels)
                guard next != self.levels else { return }
                self.levels = next
                self.render(animated: true)
            }
        }
    }

    private func updateConnectingSubscription() {
        connectingSubscription?.cancel()
        connectingSubscription = nil
        guard window != nil, let configuration, configuration.isConnecting, !configuration.reduceMotion else { return }
        connectingSubscription = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                // Timer publishes only on the main run loop.
                MainActor.assumeIsolated {
                    guard let self, self.window != nil, self.configuration?.isConnecting == true else { return }
                    self.levels = self.connectingLevels()
                    self.render(animated: true)
                }
            }
    }

    private func connectingLevels() -> [CGFloat] {
        guard configuration?.reduceMotion == false else {
            return Array(repeating: 0.18, count: bars.count)
        }
        let phase = (Date.timeIntervalSinceReferenceDate * (0.55 / 0.12))
            .truncatingRemainder(dividingBy: 2 * .pi)
        return bars.indices.map { index in
            let distance = Double(abs(index - bars.count / 2))
            return CGFloat(0.10 + 0.16 * (1 + sin(phase - distance * 0.9)) / 2)
        }
    }

    private func updateColors() {
        guard let configuration else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.backgroundColor = configuration.color.cgColor }
            CATransaction.commit()
        }
    }

    private func render(animated: Bool) {
        guard let configuration else { return }
        let shouldAnimate = animated && !configuration.reduceMotion && window != nil
        let center = bars.count / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let distance = CGFloat(abs(index - center))
            let falloff = center == 0 ? 0 : distance / CGFloat(center)
            let weight = max(0.55, 1 - falloff * 0.42)
            let scale = min(20, 4 + 16 * levels[index] * weight) / 20
            let opacity = Float(0.5 + levels[index] * 0.5)
            let presentation = bar.presentation()
            let oldScale = presentation?.transform.m22 ?? bar.transform.m22
            let oldOpacity = presentation?.opacity ?? bar.opacity
            bar.transform = CATransform3DMakeScale(1, scale, 1)
            bar.opacity = opacity
            if shouldAnimate {
                animate(bar, key: "transform.scale.y", from: oldScale, to: scale)
                animate(bar, key: "opacity", from: CGFloat(oldOpacity), to: CGFloat(opacity))
            } else {
                bar.removeAllAnimations()
            }
        }
        CATransaction.commit()
    }

    private func animate(_ bar: CALayer, key: String, from: CGFloat, to: CGFloat) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = configuration?.isConnecting == true ? 0.12 : 0.075
        animation.timingFunction = CAMediaTimingFunction(
            name: configuration?.isConnecting == true ? .easeInEaseOut : .easeOut
        )
        bar.add(animation, forKey: key)
    }
}

nonisolated enum RecordingMeterLevels {
    static func advance(_ rawLevel: CGFloat, previous: [CGFloat]) -> [CGFloat] {
        guard !previous.isEmpty else { return [] }
        let level = rawLevel.isFinite ? min(1, max(0, (rawLevel - 0.27) / 0.73)) : 0
        let center = previous.count / 2
        var levels = previous
        for index in previous.indices where index != center {
            let source = index < center ? min(center, index + 2) : max(center, index - 2)
            levels[index] = previous[source]
        }
        levels[center] = level
        return levels
    }
}
