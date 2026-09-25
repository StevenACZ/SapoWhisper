// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import SwiftUI

public struct PermissionFlowWelcomeView: View {
  @ObservedObject var model: PermissionFlowModel
  let autoClose: Bool
  let onDone: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false
  @State private var ring = false
  @State private var badge = false
  @State private var burst = 0
  @State private var countdown = false
  @State private var finished = false

  public init(model: PermissionFlowModel, autoClose: Bool = true, onDone: @escaping () -> Void) {
    self.model = model
    self.autoClose = autoClose
    self.onDone = onDone
  }

  private var text: PermissionFlowStrings { PermissionFlowStrings(model.language) }
  private var name: String { model.configuration.appName }
  private var accent: Color { model.configuration.accent }
  private var duration: TimeInterval { max(1.5, model.configuration.welcomeDuration) }

  public var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 12)
      hero
      VStack(spacing: 8) {
        Text(text.welcome(name))
          .font(.system(size: 26, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
        Text(model.configuration.tagline?.resolve(model.language) ?? text.ready(name))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 22)
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : 8)
      Spacer(minLength: 18)
      VStack(spacing: 10) {
        Button(text.start(name), action: finish)
          .buttonStyle(PermissionFlowButtonStyle(tint: accent, prominent: true))
          .controlSize(.large)
          .keyboardShortcut(.defaultAction)
        if autoClose {
          VStack(spacing: 6) {
            Capsule()
              .fill(Color.primary.opacity(0.08))
              .frame(width: 120, height: 3)
              .overlay(alignment: .leading) {
                Capsule()
                  .fill(accent.opacity(0.7))
                  .frame(width: countdown ? 0 : 120, height: 3)
              }
            Text(text.closesSoon)
              .font(.system(size: 10))
              .foregroundStyle(.tertiary)
          }
        }
      }
      .opacity(shown ? 1 : 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: play)
  }

  private var hero: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [accent.opacity(0.28), .clear], center: .center, startRadius: 8, endRadius: 96)
        )
        .frame(width: 200, height: 200)
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
      if !reduceMotion {
        PermissionFlowBurst(colors: burstColors, trigger: burst)
      }
      Circle()
        .trim(from: 0, to: ring ? 1 : 0)
        .stroke(
          AngularGradient(
            colors: [.green.opacity(0.35), .green, .mint, .green.opacity(0.35)], center: .center),
          style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .frame(width: 128, height: 128)
      Image(nsImage: model.configuration.icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .scaleEffect(shown ? 1 : 0.55)
        .opacity(shown ? 1 : 0)
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 30, weight: .bold))
        .foregroundStyle(.white, .green)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
        .offset(x: 42, y: 42)
        .scaleEffect(badge ? 1 : 0.2)
        .opacity(badge ? 1 : 0)
    }
    .frame(width: 200, height: 170)
  }

  private var burstColors: [Color] {
    let kinds = model.items.map(\.kind.color)
    return [accent, .green] + kinds + [.mint, accent]
  }

  private func play() {
    guard !shown else { return }
    if reduceMotion {
      shown = true
      ring = true
      badge = true
    } else {
      withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) { shown = true }
      withAnimation(.easeInOut(duration: 0.75).delay(0.12)) { ring = true }
      withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.55)) { badge = true }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(420))
        burst += 1
      }
    }
    guard autoClose else { return }
    withAnimation(.linear(duration: duration).delay(0.5)) { countdown = true }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(duration + 0.5))
      finish()
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    onDone()
  }
}

private struct PermissionFlowBurst: View {
  let colors: [Color]
  let trigger: Int

  private struct Frame {
    var distance: CGFloat = 40
    var opacity: Double = 0
    var scale: CGFloat = 1
  }

  var body: some View {
    ZStack {
      ForEach(0..<18, id: \.self) { index in
        let angle = Double(index) / 18 * 2 * .pi + (index.isMultiple(of: 2) ? 0.12 : -0.08)
        let reach: CGFloat = index.isMultiple(of: 3) ? 108 : (index.isMultiple(of: 2) ? 94 : 82)
        let size: CGFloat = index.isMultiple(of: 3) ? 8 : 5.5
        Circle()
          .fill(colors[index % colors.count])
          .frame(width: size, height: size)
          .keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, frame in
            content
              .scaleEffect(frame.scale)
              .opacity(frame.opacity)
              .offset(x: cos(angle) * frame.distance, y: sin(angle) * frame.distance)
          } keyframes: { _ in
            KeyframeTrack(\.distance) {
              CubicKeyframe(52, duration: 0.01)
              SpringKeyframe(reach, duration: 0.9, spring: .init(response: 0.7, dampingRatio: 0.7))
            }
            KeyframeTrack(\.opacity) {
              LinearKeyframe(1, duration: 0.08)
              LinearKeyframe(1, duration: 0.45)
              LinearKeyframe(0, duration: 0.5)
            }
            KeyframeTrack(\.scale) {
              LinearKeyframe(1.2, duration: 0.2)
              LinearKeyframe(0.4, duration: 0.8)
            }
          }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
