// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import SwiftUI

public struct PermissionFlowBadge: View {
    let kind: PermissionFlowKind
    var size: CGFloat

    public init(kind: PermissionFlowKind, size: CGFloat = 36) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        let top = Color(nsColor: kind.nsColor.blended(withFraction: 0.22, of: .white) ?? kind.nsColor)
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [top, kind.color], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: kind.color.opacity(0.28), radius: size * 0.1, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

public struct PermissionFlowChecklist: View {
    @ObservedObject var model: PermissionFlowModel
    let sourceFrame: () -> CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    public init(model: PermissionFlowModel, sourceFrame: @escaping () -> CGRect? = { nil }) {
        self.model = model
        self.sourceFrame = sourceFrame
    }

    public var body: some View {
        VStack(spacing: 14) {
            PermissionFlowProgress(model: model)
            if model.relaunchPending {
                PermissionFlowRelaunchBanner(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            VStack(spacing: 10) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    PermissionFlowCard(model: model, item: item, sourceFrame: sourceFrame)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            reduceMotion
                                ? nil
                                : .spring(response: 0.5, dampingFraction: 0.86).delay(0.12 + Double(index) * 0.07),
                            value: appeared)
                }
            }
        }
        .onAppear {
            appeared = true
            model.refresh()
            model.startMonitoring()
        }
        .onDisappear { model.stopMonitoring() }
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
            value: model.relaunchPending)
    }
}

struct PermissionFlowRelaunchBanner: View {
    @ObservedObject var model: PermissionFlowModel

    var body: some View {
        let text = PermissionFlowStrings(model.language)
        let name = model.configuration.appName
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, model.configuration.accent)
            Text(model.relaunchFailed ? text.reopenFailed : text.finishWithReopen(name))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(text.reopen(name)) { model.relaunch() }
                .buttonStyle(PermissionFlowButtonStyle(tint: model.configuration.accent, prominent: true))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.configuration.accent.opacity(0.1))
        )
    }
}

struct PermissionFlowProgress: View {
    @ObservedObject var model: PermissionFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = PermissionFlowStrings(model.language)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(model.items) { item in
                    Capsule()
                        .fill(model.isSatisfied(item.kind) ? Color.green : Color.primary.opacity(0.1))
                        .frame(height: 5)
                }
            }
            Text(text.progress(model.satisfiedCount, of: model.items.count))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8),
            value: model.satisfiedCount
        )
        .accessibilityElement(children: .combine)
    }
}

struct PermissionFlowCard: View {
    @ObservedObject var model: PermissionFlowModel
    let item: PermissionFlowItem
    let sourceFrame: () -> CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: PermissionFlowKind { item.kind }
    private var text: PermissionFlowStrings { PermissionFlowStrings(model.language) }
    private var satisfied: Bool { model.isSatisfied(kind) }
    private var available: Bool { model.isAvailable(kind) }
    private var isNext: Bool { model.next?.kind == kind }
    private var guiding: Bool { model.guiding == kind }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                PermissionFlowBadge(kind: kind, size: 40)
                    .saturation(available || satisfied ? 1 : 0.35)
                    .opacity(available || satisfied ? 1 : 0.7)
                if satisfied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
                        .offset(x: 6, y: 6)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(text.title(kind))
                        .font(.system(size: 14, weight: .semibold))
                    if !item.required {
                        Text(text.optional)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(item.reason.resolve(model.language))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind.mayRequireRelaunch {
                    relaunchLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(minWidth: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(border, lineWidth: isNext && !satisfied ? 1.5 : 1)
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78), value: satisfied
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: guiding)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isNext)
        .accessibilityElement(children: .contain)
    }

    private var background: Color {
        if satisfied { return Color.green.opacity(0.07) }
        if isNext { return kind.color.opacity(0.07) }
        return Color.primary.opacity(0.035)
    }

    private var border: Color {
        if satisfied { return Color.green.opacity(0.3) }
        if isNext { return kind.color.opacity(0.55) }
        return Color.primary.opacity(0.08)
    }

    @ViewBuilder private var trailing: some View {
        if satisfied {
            Label(
                model.status(kind) == .granted ? text.granted : text.requested,
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else if guiding {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button(text.openSettings) { model.request(kind, from: sourceFrame()) }
                    .buttonStyle(PermissionFlowButtonStyle(tint: kind.color, prominent: false))
            }
            .transition(.opacity)
        } else {
            Button(
                model.status(kind) == .denied && !kind.acceptsDraggedApp ? text.openSettings : text.allow
            ) {
                model.request(kind, from: sourceFrame())
            }
            .buttonStyle(PermissionFlowButtonStyle(tint: kind.color, prominent: isNext))
            .disabled(!available)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var relaunchLine: some View {
        if satisfied {
            EmptyView()
        } else if model.relaunchFailed {
            Text(text.reopenFailed)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        } else if model.awaitingRelaunch(kind) {
            Button {
                model.relaunch()
            } label: {
                Label(text.reopenHint(model.configuration.appName), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Label(text.lockedUntilOthers, systemImage: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

struct PermissionFlowButtonStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.13)))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.18 : 0), lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
