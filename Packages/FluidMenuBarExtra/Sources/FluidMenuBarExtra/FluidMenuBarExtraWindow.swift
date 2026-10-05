//
//  FluidMenuBarExtraWindow.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-16.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// A custom window configured to behave as closely to an `NSMenu` as possible.
///
/// `FluidMenuBarExtraWindow` listens for changes to the size of its content and
/// automatically adjusts its frame to match.
final class FluidMenuBarExtraWindow<Content: View>: NSPanel {
    private let content: () -> Content
    weak var statusItem: FluidMenuBarExtraStatusItem? = nil

    // Liquid Glass background, like the macOS 26 menu bar extras.
    private lazy var glassView: NSGlassEffectView = {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = GlassMetrics.cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// Clips everything to the panel's rounded shape so the window server derives
    /// a rounded system shadow (the glass's own shadow would otherwise be cut off
    /// at the window edge or fill the corners).
    private let containerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = GlassMetrics.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }()

    private var rootView: some View {
        content()
            .modifier(RootViewModifier(windowTitle: title))
            .onSizeUpdate { [weak self] size in
                self?.contentSizeDidUpdate(to: size)
            }
    }

    private lazy var hostingView: NSHostingView<some View> = {
        let view = NSHostingView(rootView: rootView)
        // Disable NSHostingView's default automatic sizing behavior.
        view.sizingOptions = []
        view.isVerticalContentSizeConstraintActive = false
        view.isHorizontalContentSizeConstraintActive = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(title: String,
         animation: NSWindow.AnimationBehavior = .none,
         content: @escaping () -> Content) {
        self.content = content

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            // Borderless so the glass view defines the panel's shape and shadow.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = title

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        animationBehavior = animation
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        contentView = containerView
        containerView.addSubview(glassView)
        glassView.contentView = hostingView
        setContentSize(GlassMetrics.windowSize(forGlass: hostingView.intrinsicContentSize))

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.topAnchor.constraint(equalTo: glassView.topAnchor),
            hostingView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor)
        ])
    }

    // Borderless panels refuse key status by default; the popup needs it for
    // keyboard navigation and text entry.
    override var canBecomeKey: Bool { true }

    private func contentSizeDidUpdate(to size: CGSize) {
        guard frame.size != GlassMetrics.windowSize(forGlass: size) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.setWindowFrame(size: size, animate: true)
        }
    }
}

/// Geometry of the glass panel window.
enum GlassMetrics {
    /// Matches the native Sound / Control Center menu extras.
    static let cornerRadius: CGFloat = 18
    /// No extra room needed: the shadow is the window's own.
    static let shadowMargin: CGFloat = 0
    /// Vertical offset from the status item window. Negative because that window
    /// extends below the visible bar; this lines the panel up with native extras.
    static let menuBarGap: CGFloat = -4

    static func windowSize(forGlass size: CGSize) -> CGSize {
        CGSize(width: size.width + 2 * shadowMargin, height: size.height + 2 * shadowMargin)
    }

    static func glassSize(forWindow size: CGSize) -> CGSize {
        CGSize(width: size.width - 2 * shadowMargin, height: size.height - 2 * shadowMargin)
    }
}
