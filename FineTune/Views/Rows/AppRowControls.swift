// FineTune/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker, EQ button.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    var deviceIconOverrides: [String: String] = [:]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let isEQExpanded: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onEQToggle: () -> Void
    var isRowFocused: Bool = false

    @State private var dragOverrideValue: Double?
    @State private var isEQButtonHovered = false

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    /// Drag binding: positions near 100% snap to it, so the thumb catches at unity.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { applySlider(VolumeMapping.applyingUnityDetent($0)) }
        )
    }

    /// Scroll-wheel binding: steps stop once at 100% instead of snapping back
    /// into the detent on every tick.
    private var scrollBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: {
                applySlider(VolumeMapping.steppedSlider(from: sliderValue, delta: $0 - sliderValue))
                // No drag is in progress, so let the value track the engine again.
                dragOverrideValue = nil
            }
        )
    }

    private func applySlider(_ newValue: Double) {
        // Tick the trackpad when the slider lands on the 100% detent.
        if newValue == 1.0 && sliderValue != 1.0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        dragOverrideValue = newValue
        onVolumeChange(VolumeMapping.sliderToGain(newValue))
        if isMuted {
            onMuteChange(false)
        }
    }

    /// The displayed percentage value, matching EditablePercentage's formula.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because the x² volume
    /// mapping round-trip can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    private var eqButtonColor: Color {
        if isEQExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isEQButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Mute button
            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    if displayedPercentage == 0 {
                        onVolumeChange(1.0)
                    }
                    onMuteChange(false)
                } else {
                    onMuteChange(true)
                }
            }

            // Volume slider
            LiquidGlassSlider(
                value: sliderBinding,
                in: 0...VolumeMapping.maxSlider,
                showUnityMarker: true,
                onEditingChanged: { editing in
                    if !editing {
                        dragOverrideValue = nil
                    }
                }
            )
            .frame(width: DesignTokens.Dimensions.sliderWidth)
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .scrollWheelStep(scrollBinding, in: 0.0...VolumeMapping.maxSlider)

            // Editable volume percentage (shows slider position, not raw gain)
            EditablePercentage(
                percentage: Binding(
                    get: {
                        Int(round(sliderValue * 100))
                    },
                    set: { newPercentage in
                        let sliderPos = Double(newPercentage) / 100.0
                        let gain = VolumeMapping.sliderToGain(sliderPos)
                        onVolumeChange(gain)
                    }
                ),
                range: 0...Int(VolumeMapping.maxSlider * 100),
                isRowFocused: isRowFocused
            )

            DevicePicker(
                devices: devices,
                deviceIconOverrides: deviceIconOverrides,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                mode: deviceSelectionMode,
                onModeChange: onDeviceModeChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onSelectFollowDefault: onSelectFollowDefault,
                showModeToggle: true,
                triggerWidth: 0,
                triggerStyle: .iconOnly
            )
        }
        .fixedSize()
    }
}
