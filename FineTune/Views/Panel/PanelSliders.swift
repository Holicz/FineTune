// FineTune/Views/Panel/PanelSliders.swift
// Native SwiftUI sliders (Liquid Glass thumb on macOS 26) for the panel.

import AppKit
import SwiftUI

// MARK: - Device volume

/// Output-device volume slider with a leading mute toggle.
///
/// Mapping and feedback-loop handling are carried over from the former DeviceRow:
/// hardware/DDC volume is already audio-tapered so it maps 1:1, software volume
/// uses the x² curve, and a device-driven update never writes itself back
/// (USB DACs with coarse dB steps would otherwise spiral).
struct DeviceVolumeSlider: View {
    let volume: Float
    let isMuted: Bool
    var volumeBackend: VolumeControlTier = .hardware
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isUpdatingFromDevice = false
    @State private var suppressAutoUnmute = false

    init(
        volume: Float,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void
    ) {
        self.volume = volume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        _sliderValue = State(initialValue: VolumeMapping.sliderFraction(forSystemGain: volume, tier: volumeBackend))
    }

    private var showsMuted: Bool { isMuted || Int(round(sliderValue * 100)) == 0 }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if showsMuted {
                    if Int(round(sliderValue * 100)) == 0 {
                        suppressAutoUnmute = isMuted
                        sliderValue = 0.5
                    }
                    if isMuted { onMuteToggle() }
                } else {
                    onMuteToggle()
                }
            } label: {
                // Min-volume glyph (doubles as the mute toggle).
                Image(systemName: showsMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showsMuted ? "Unmute" : "Mute")

            Slider(value: $sliderValue, in: 0...1) { editing in
                isEditing = editing
            }
            .controlSize(.regular)
            .opacity(showsMuted ? 0.55 : 1)
            .scrollWheelStep($sliderValue, in: 0.0...1.0)

            // Max-volume glyph, like the native Sound menu.
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onChange(of: sliderValue) { _, newValue in
            if isUpdatingFromDevice {
                isUpdatingFromDevice = false
                return
            }
            onVolumeChange(VolumeMapping.systemGain(forSliderFraction: newValue, tier: volumeBackend))
            if suppressAutoUnmute {
                suppressAutoUnmute = false
                return
            }
            if isMuted && newValue > 0 { onMuteToggle() }
        }
        .onChange(of: volume) { _, newValue in
            guard !isEditing else { return }
            let newSlider = VolumeMapping.sliderFraction(forSystemGain: newValue, tier: volumeBackend)
            guard newSlider != sliderValue else { return }
            isUpdatingFromDevice = true
            sliderValue = newSlider
        }
    }
}

// MARK: - App volume

/// Per-app gain slider (0–100 %, square-law mapped).
struct AppVolumeSlider: View {
    /// Linear gain 0…1.
    let volume: Float
    let isMuted: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void

    @State private var dragOverrideValue: Double?

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    private var binding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                dragOverrideValue = newValue
                onVolumeChange(VolumeMapping.sliderToGain(newValue))
                if isMuted { onMuteChange(false) }
            }
        )
    }

    var body: some View {
        Slider(value: binding, in: 0...1) { editing in
            if !editing { dragOverrideValue = nil }
        }
        .controlSize(.small)
        .opacity(isMuted ? 0.55 : 1)
        .scrollWheelStep(binding, in: 0.0...1.0)
    }
}

// MARK: - Previews

#Preview("Panel sliders") {
    struct Demo: View {
        @State var device: Float = 0.6
        @State var app: Float = 1.0
        var body: some View {
            VStack(spacing: 14) {
                DeviceVolumeSlider(volume: device, isMuted: false, onVolumeChange: { device = $0 }, onMuteToggle: {})
                AppVolumeSlider(volume: app, isMuted: false, onVolumeChange: { app = $0 }, onMuteChange: { _ in })
            }
            .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, PanelMetrics.verticalPadding)
            .frame(width: PanelMetrics.width)
        }
    }
    return Demo()
}
