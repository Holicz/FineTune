// FineTune/Views/Panel/PanelStyle.swift
// Building blocks for the menu bar panel, modeled on the macOS 26 Sound menu extra:
// plain section headers, circular glyph badges, full-width rows with a soft hover fill.

import AudioToolbox
import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 330
    static let padding: CGFloat = 14
    static let cornerRadius: CGFloat = 22
    static let circleSize: CGFloat = 28
    static let rowRadius: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 5
    static let rowHorizontalPadding: CGFloat = 6
    static let sectionSpacing: CGFloat = 10
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

// MARK: - Circle badge

/// Circular glyph badge. Selected = accent fill with white glyph (like the active
/// output in the native Sound menu); otherwise a translucent neutral fill.
struct PanelCircleIcon: View {
    let systemName: String
    var isSelected: Bool = false
    var size: CGFloat = PanelMetrics.circleSize

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
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
        return AudioDeviceID.iconSymbol(forName: name, transport: id.readTransportType())
    }
}

// MARK: - Previews

#Preview("Panel building blocks") {
    VStack(alignment: .leading, spacing: 4) {
        PanelSectionHeader("Output") {
            Button("Edit") {}.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
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
    .padding(PanelMetrics.padding)
    .frame(width: PanelMetrics.width)
}
