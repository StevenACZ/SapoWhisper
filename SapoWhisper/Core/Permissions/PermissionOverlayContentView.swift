//
//  PermissionOverlayContentView.swift
//  SapoWhisper
//
//  Renders the floating helper shown on top of System Settings.
//

import AppKit

final class PermissionOverlayContentView: NSView {
    static let preferredSize = NSSize(width: 548, height: 170)

    private let onClose: () -> Void

    init(hostApp: PermissionHostApp, permission: AppPermission, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        translatesAutoresizingMaskIntoConstraints = false
        setup(hostApp: hostApp, permission: permission)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(hostApp: PermissionHostApp, permission: AppPermission) {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 20
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 1
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        materialView.addSubview(tintView)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 24, weight: .bold)
        arrowView.contentTintColor = permission.accentColor
        materialView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithString: permission.overlayTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        materialView.addSubview(titleLabel)

        let closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        materialView.addSubview(closeButton)

        let messageLabel = NSTextField(wrappingLabelWithString: permission.overlayMessage)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        materialView.addSubview(messageLabel)

        let helperView = makeHelperView(hostApp: hostApp, permission: permission)
        materialView.addSubview(helperView)

        let footnoteLabel = NSTextField(wrappingLabelWithString: permission.overlayFootnote)
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
        footnoteLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footnoteLabel.textColor = .tertiaryLabelColor
        materialView.addSubview(footnoteLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            heightAnchor.constraint(equalToConstant: Self.preferredSize.height),

            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            arrowView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 24),
            arrowView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 18),
            arrowView.widthAnchor.constraint(equalToConstant: 24),
            arrowView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: arrowView.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),
            messageLabel.topAnchor.constraint(equalTo: arrowView.bottomAnchor, constant: 12),

            helperView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 24),
            helperView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -24),
            helperView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            helperView.heightAnchor.constraint(equalToConstant: 56),

            footnoteLabel.leadingAnchor.constraint(equalTo: helperView.leadingAnchor),
            footnoteLabel.trailingAnchor.constraint(equalTo: helperView.trailingAnchor),
            footnoteLabel.topAnchor.constraint(equalTo: helperView.bottomAnchor, constant: 10)
        ])
    }

    private func makeHelperView(hostApp: PermissionHostApp, permission: AppPermission) -> NSView {
        if permission.supportsAppDragInSettings {
            return PermissionAppDragSourceView(
                hostApp: hostApp,
                accentColor: permission.accentColor
            )
        }

        return PermissionOverlayInfoCardView(
            title: permission.helperTitle,
            message: permission.helperMessage,
            accentColor: permission.accentColor
        )
    }

    @objc
    private func closePressed() {
        onClose()
    }
}

private final class PermissionOverlayInfoCardView: NSView {
    init(title: String, message: String, accentColor: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = accentColor.withAlphaComponent(0.15).cgColor
        layer?.backgroundColor = accentColor.withAlphaComponent(0.08).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        iconView.contentTintColor = accentColor
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),

            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
