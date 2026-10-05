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

    // Liquid Glass background, like the macOS 26 menu bar extras. It sits inset
    // in a transparent container so its soft shadow isn't clipped by the window edge.
    private lazy var glassView: NSGlassEffectView = {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = GlassMetrics.cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let containerView = NSView()

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
        // The glass draws its own rim; a window shadow would trace the square frame.
        hasShadow = false

        animationBehavior = animation
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let margin = GlassMetrics.shadowMargin
        contentView = containerView
        containerView.addSubview(glassView)
        glassView.contentView = hostingView
        setContentSize(GlassMetrics.windowSize(forGlass: hostingView.intrinsicContentSize))

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: margin),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -margin),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -margin),
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: margin),
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

/// Geometry of the glass panel inside its (larger, transparent) window.
enum GlassMetrics {
    static let cornerRadius: CGFloat = 22
    /// Transparent room around the glass for its shadow.
    static let shadowMargin: CGFloat = 24
    /// Gap between the menu bar and the top of the glass.
    static let menuBarGap: CGFloat = 5

    static func windowSize(forGlass size: CGSize) -> CGSize {
        CGSize(width: size.width + 2 * shadowMargin, height: size.height + 2 * shadowMargin)
    }

    static func glassSize(forWindow size: CGSize) -> CGSize {
        CGSize(width: size.width - 2 * shadowMargin, height: size.height - 2 * shadowMargin)
    }
}
