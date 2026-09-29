//
//  OverlayMotion.swift
//  SapoWhisper
//

import SwiftUI

/// How far an overlay element is from resting on screen: every overlay
/// entrance, exit and hand-off is a mix of scale, slide, blur and fade.
struct OverlayPresence: ViewModifier {
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    var x: CGFloat = 0
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .offset(x: x, y: y)
            .blur(radius: max(0, blur))
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func presence(_ away: OverlayPresence) -> AnyTransition {
        .modifier(active: away, identity: OverlayPresence())
    }

    static func presence(in insertion: OverlayPresence, out removal: OverlayPresence) -> AnyTransition {
        .asymmetric(insertion: .presence(insertion), removal: .presence(removal))
    }

    /// Status text hand-off: the new line rises in as the old one leaves
    /// upward, both through a short blur.
    static var statusSwap: AnyTransition {
        .presence(
            in: OverlayPresence(y: 7, blur: 3, opacity: 0),
            out: OverlayPresence(y: -7, blur: 3, opacity: 0)
        )
    }

    /// Controls and indicators trading places inside the pill.
    static var controlSwap: AnyTransition {
        .presence(OverlayPresence(scale: 0.5, blur: 2, opacity: 0))
    }
}
