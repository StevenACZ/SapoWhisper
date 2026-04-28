//
//  PermissionAppDragSourceView.swift
//  SapoWhisper
//
//  Draws the draggable app card used by the permission assistant overlay.
//

import AppKit

final class PermissionAppDragSourceView: NSView, NSPasteboardItemDataProvider, NSDraggingSource {
    private let hostApp: PermissionHostApp
    private let accentColor: NSColor
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let titleLabel: NSTextField
    private let subtitleLabel = NSTextField(labelWithString: "permissions.overlay.drag_subtitle".localized)

    init(hostApp: PermissionHostApp, accentColor: NSColor) {
        self.hostApp = hostApp
        self.accentColor = accentColor
        self.titleLabel = NSTextField(labelWithString: hostApp.displayName)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.fileURL])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage())

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        item.setData(hostApp.bundleURL.dataRepresentation, forType: .fileURL)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private func setup() {
        wantsLayer = true

        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 12
        rowView.layer?.borderWidth = 1
        addSubview(rowView)

        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        iconChrome.wantsLayer = true
        iconChrome.layer?.cornerRadius = 10
        rowView.addSubview(iconChrome)

        let iconView = NSImageView(image: hostApp.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        rowView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        rowView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 56),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 12),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 36),
            iconChrome.heightAnchor.constraint(equalToConstant: 36),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 11),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])

        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let fillAlpha: CGFloat = permissionUsesDarkAppearance ? 0.16 : 0.08
        let borderAlpha: CGFloat = permissionUsesDarkAppearance ? 0.24 : 0.16
        rowView.layer?.backgroundColor = permissionCGColor(accentColor, alpha: fillAlpha)
        rowView.layer?.borderColor = permissionCGColor(accentColor, alpha: borderAlpha)
        iconChrome.layer?.backgroundColor = permissionCGColor(.windowBackgroundColor, alpha: 0.92)
        titleLabel.textColor = .labelColor
        subtitleLabel.textColor = .secondaryLabelColor
    }

    private func dragPreviewImage() -> NSImage {
        let image = NSImage(size: rowView.bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current {
            rowView.displayIgnoringOpacity(rowView.bounds, in: context)
        }
        image.unlockFocus()
        return image
    }
}
