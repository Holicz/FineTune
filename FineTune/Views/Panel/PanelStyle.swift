// FineTune/Views/Panel/PanelStyle.swift
// Building blocks for the menu bar panel, modeled on the macOS 26 Sound menu extra:
// plain section headers, circular glyph badges, full-width rows with a soft hover fill.

import AppKit
import AudioToolbox
import SwiftUI

/// Measured against the native Sound menu extra (macOS 26): ~308pt wide,
/// content inset 14pt from the edge, 26pt badges in 32pt rows.
enum PanelMetrics {
    static let width: CGFloat = 310
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    static let circleSize: CGFloat = 26
    static let rowRadius: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 3
    static let rowHorizontalPadding: CGFloat = 6
}

// MARK: - Section header

/// "Output", "Apps" … — semibold secondary text, optional trailing accessory.
struct PanelSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }
}

// MARK: - Divider

/// Hairline between sections, inset to the content edge like the native menu.
struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
            .padding(.vertical, 6)
    }
}

// MARK: - Circle badge

/// Circular glyph badge. Selected = accent fill with white glyph (like the active
/// output in the native Sound menu); otherwise a translucent neutral fill.
struct PanelCircleIcon: View {
    let systemName: String
    var isSelected: Bool = false
    var size: CGFloat = PanelMetrics.circleSize

    /// Native badges use filled glyphs where one exists (hifispeaker.fill, tv.fill …)
    /// and the generic laptop instead of the MacBook outline.
    private var glyph: String {
        let base = systemName == "macbook" ? "laptopcomputer" : systemName
        let filled = base + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : base
    }

    var body: some View {
        Image(systemName: glyph)
            .font(.system(size: size * 0.5, weight: .medium))
            // Unselected: grey two-tone glyph like the native Sound menu; selected: white on accent.
            .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

// MARK: - Row

/// Full-width row with a rounded hover/keyboard-focus fill.
struct PanelRowModifier: ViewModifier {
    var isFocused: Bool = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
            .padding(.vertical, PanelMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius))
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius)
                    .fill(.primary.opacity(isHovered || isFocused ? 0.08 : 0))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func panelRow(isFocused: Bool = false) -> some View {
        modifier(PanelRowModifier(isFocused: isFocused))
    }
}

// MARK: - Device glyphs

extension AudioDevice {
    /// SF Symbol for the panel's circle badge: user override first, else the
    /// name/transport heuristic (AirPods Pro/Max, HomePod, MacBook …).
    func panelSymbol(override: String?) -> String {
        if let override, NSImage(systemSymbolName: override, accessibilityDescription: nil) != nil {
            return override
        }
        return AppleHeadphones.symbol(forAudioUID: uid)
            ?? AudioDeviceID.iconSymbol(forName: name, transport: id.readTransportType())
    }
}

// MARK: - Previews

#Preview("Panel building blocks") {
    VStack(alignment: .leading, spacing: 4) {
        PanelSectionHeader("Output")
        HStack(spacing: 10) {
            PanelCircleIcon(systemName: "airpodsmax", isSelected: true)
            Text("AirPods Max").font(.system(size: 13))
        }
        .panelRow()
        HStack(spacing: 10) {
            PanelCircleIcon(systemName: "macbook")
            Text("MacBook Pro Speakers").font(.system(size: 13))
        }
        .panelRow(isFocused: true)
    }
    .padding(.horizontal, PanelMetrics.horizontalPadding)
    .padding(.vertical, PanelMetrics.verticalPadding)
    .frame(width: PanelMetrics.width)
}
