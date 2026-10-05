// FineTune/Views/Panel/PanelRows.swift
// Rows for the menu bar panel: output devices and per-app volume.

import AppKit
import SwiftUI

// MARK: - Output device

/// "Circle badge + name" row; clicking makes the device the default output.
struct PanelDeviceRow<Accessory: View>: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    var isFocused: Bool = false
    let onSelect: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    init(
        name: String,
        symbol: String,
        isSelected: Bool,
        isFocused: Bool = false,
        onSelect: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.name = name
        self.symbol = symbol
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.onSelect = onSelect
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            PanelCircleIcon(systemName: symbol, isSelected: isSelected)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            accessory()
        }
        .panelRow(isFocused: isFocused)
        .onTapGesture {
            if !isSelected { onSelect() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - App volume

/// App icon + name over a 0–200 % slider and percentage.
/// Clicking the icon toggles mute.
struct PanelAppRow: View {
    let name: String
    let icon: NSImage
    let volume: Float
    let isMuted: Bool
    var isInactive: Bool = false
    var isFocused: Bool = false
    var routingSubtitle: String? = nil
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void

    private var percentage: Int { Int(round(VolumeMapping.gainToSlider(volume) * 100)) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onMuteChange(!isMuted)
            } label: {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: PanelMetrics.circleSize, height: PanelMetrics.circleSize)
                    .saturation(isMuted ? 0 : 1)
                    .opacity(isMuted || isInactive ? 0.5 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if isMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Circle().fill(.red))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(name)" : "Mute \(name)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let routingSubtitle {
                        Text(routingSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    EditablePercentage(
                        percentage: Binding(
                            get: { percentage },
                            set: { onVolumeChange(VolumeMapping.sliderToGain(Double($0) / 100)) }
                        ),
                        range: 0...Int(VolumeMapping.maxSlider * 100),
                        isRowFocused: isFocused
                    )
                }
                AppVolumeSlider(
                    volume: volume,
                    isMuted: isMuted,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange
                )
            }
        }
        .panelRow(isFocused: isFocused)
    }
}

// MARK: - System sounds

/// Alert/UI-sound volume (screenshot shutter, Trash, alerts). Bell toggles mute,
/// restoring the previous level.
struct PanelSystemSoundsRow: View {
    let volume: Float
    var isFocused: Bool = false
    let onVolumeChange: (Float) -> Void

    @State private var volumeBeforeMute: Float = 0.5

    private var isSilent: Bool { volume <= 0.001 }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isSilent {
                    onVolumeChange(max(volumeBeforeMute, 0.1))
                } else {
                    volumeBeforeMute = volume
                    onVolumeChange(0)
                }
            } label: {
                PanelCircleIcon(systemName: isSilent ? "bell.slash.fill" : "bell.fill")
            }
            .buttonStyle(.plain)
            .help(isSilent ? "Unmute system sounds" : "Mute system sounds")

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("System Sounds")
                        .font(.system(size: 13))
                    Spacer(minLength: 4)
                    Text("\(Int(round(volume * 100)))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { Double(volume) }, set: { onVolumeChange(Float($0)) }),
                    in: 0...1
                )
                .controlSize(.small)
                .opacity(isSilent ? 0.55 : 1)
            }
        }
        .panelRow(isFocused: isFocused)
        .help("Alerts and sound effects such as the screenshot shutter")
    }
}

// MARK: - Plain action row

/// Menu-item style text row ("Allow Volume Keys…").
struct PanelActionRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelRow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Panel rows") {
    VStack(alignment: .leading, spacing: 2) {
        PanelSectionHeader("Output")
        PanelDeviceRow(name: "AirPods Max", symbol: "airpodsmax", isSelected: true, onSelect: {})
        PanelDeviceRow(name: "MacBook Pro Speakers", symbol: "macbook", isSelected: false, onSelect: {})
        PanelDivider()
        PanelSectionHeader("Apps")
        PanelSystemSoundsRow(volume: 0.3, onVolumeChange: { _ in })
        PanelAppRow(name: "Spotify", icon: MockData.sampleApps[0].icon, volume: 1.0, isMuted: false,
                    onVolumeChange: { _ in }, onMuteChange: { _ in })
        PanelAppRow(name: "Zoom", icon: MockData.sampleApps[2].icon, volume: 2.25, isMuted: false,
                    routingSubtitle: "→ MacBook Pro Speakers", onVolumeChange: { _ in }, onMuteChange: { _ in })
        PanelAppRow(name: "Chrome", icon: MockData.sampleApps[1].icon, volume: 0.4, isMuted: true,
                    onVolumeChange: { _ in }, onMuteChange: { _ in })
        PanelDivider()
        PanelActionRow(title: "Allow Volume Keys…") {}
    }
    .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, PanelMetrics.verticalPadding)
    .frame(width: PanelMetrics.width)
}
