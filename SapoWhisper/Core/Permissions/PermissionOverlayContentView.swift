//
//  PermissionOverlayContentView.swift
//  SapoWhisper
//
//  Renders the floating helper shown on top of System Settings.
//

import AppKit

final class PermissionOverlayContentView: NSView {
    static let preferredSize = NSSize(width: 548, height: 184)

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
        let cardView = PermissionOverlayCardContainerView()
        addSubview(cardView)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 24, weight: .bold)
        arrowView.contentTintColor = permission.accentColor
        cardView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithString: permission.overlayTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        cardView.addSubview(titleLabel)

        let closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        cardView.addSubview(closeButton)

        let messageLabel = NSTextField(wrappingLabelWithString: permission.overlayMessage)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        cardView.addSubview(messageLabel)

        let helperView = makeHelperView(hostApp: hostApp, permission: permission)
        cardView.addSubview(helperView)

        let footnoteLabel = NSTextField(wrappingLabelWithString: permission.overlayFootnote)
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
        footnoteLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footnoteLabel.textColor = .tertiaryLabelColor
        cardView.addSubview(footnoteLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            heightAnchor.constraint(equalToConstant: Self.preferredSize.height),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

            arrowView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            arrowView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            arrowView.widthAnchor.constraint(equalToConstant: 24),
            arrowView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: arrowView.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -22),
            messageLabel.topAnchor.constraint(equalTo: arrowView.bottomAnchor, constant: 12),

            helperView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            helperView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            helperView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            helperView.heightAnchor.constraint(equalToConstant: 56),

            footnoteLabel.leadingAnchor.constraint(equalTo: helperView.leadingAnchor),
            footnoteLabel.trailingAnchor.constraint(equalTo: helperView.trailingAnchor),
            footnoteLabel.topAnchor.constraint(equalTo: helperView.bottomAnchor, constant: 10),
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

private final class PermissionOverlayCardContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundAlpha: CGFloat = permissionUsesDarkAppearance ? 0.94 : 0.98
        let borderAlpha: CGFloat = permissionUsesDarkAppearance ? 0.26 : 0.16
        layer?.backgroundColor = permissionCGColor(.windowBackgroundColor, alpha: backgroundAlpha)
        layer?.borderColor = permissionCGColor(.separatorColor, alpha: borderAlpha)
    }
}

private final class PermissionOverlayInfoCardView: NSView {
    private let accentColor: NSColor
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField

    init(title: String, message: String, accentColor: NSColor) {
        self.accentColor = accentColor
        self.titleLabel = NSTextField(labelWithString: title)
        self.messageLabel = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        iconView.contentTintColor = accentColor
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
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
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundAlpha: CGFloat = permissionUsesDarkAppearance ? 0.16 : 0.08
        let borderAlpha: CGFloat = permissionUsesDarkAppearance ? 0.24 : 0.16
        layer?.backgroundColor = permissionCGColor(accentColor, alpha: backgroundAlpha)
        layer?.borderColor = permissionCGColor(accentColor, alpha: borderAlpha)
        titleLabel.textColor = .labelColor
        messageLabel.textColor = .secondaryLabelColor
    }
}
