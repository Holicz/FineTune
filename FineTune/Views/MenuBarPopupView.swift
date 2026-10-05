// FineTune/Views/MenuBarPopupView.swift
import AudioToolbox
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    let permission: AudioRecordingPermission

    /// Accessibility trust state — forwarded to the Settings window for the
    /// media-keys section. Bindable so live re-renders occur when trust flips.
    @Bindable var accessibility: AccessibilityPermissionService

    /// Transient status (offline, suppressionDegraded) for the media-keys banner.
    @Bindable var mediaKeyStatus: MediaKeyStatus

    /// Shared popup visibility flag — mirrored to this service so `MediaKeyMonitor`
    /// can skip HUD display while the popup is the "HUD".
    @Bindable var popupVisibility: PopupVisibilityService

    /// Preview HUD button hook in Settings.
    let hudController: HUDWindowController

    /// Needed so the popup can reconcile the tap state when the user toggles
    /// `mediaKeyControlEnabled` inside Settings. Trust-flip reconciliation is
    /// handled globally via `AccessibilityPermissionService.onTrustChanged`
    /// wired in `FineTuneApp.init`.
    let mediaKeyMonitor: MediaKeyMonitor

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Track popup visibility to pause VU meter polling when hidden
    @State private var isPopupVisible = true

    /// Memoized paired Bluetooth devices
    @State private var pairedDevices: [PairedBluetoothDevice] = []

    /// Whether Bluetooth hardware is powered on
    @State private var isBluetoothOn = false

    /// Whether edit mode is active (affects both device priority and app visibility)
    @State private var isEditingDevicePriority = false

    /// Editable copy of device order for drag-and-drop reordering
    @State private var editableDeviceOrder: [AudioDevice] = []

    /// Device whose inline detail panel is expanded in edit mode (nil when
    /// collapsed).
    @State private var expandedDeviceUID: String?

    @State private var navModel = PopupKeyboardNavModel()
    /// Logical keyboard-nav selection. Plain @State (not @FocusState) so reads
    /// and writes are synchronous within a single event handler — using
    /// @FocusState here raced with SwiftUI's auto-focus-on-key-window claim
    /// (WWDC23 "SwiftUI cookbook for focus" calls this anti-pattern). A single
    /// focusable anchor on the popup body root receives key events; rows
    /// render their selection state purely from this @State value.
    @State private var selectedRow: PopupKeyboardNavModel.RowID? = nil
    /// True once the user presses any nav-vocabulary key. Gates the row-highlight
    /// visual so a fresh popup opens clean even though `selectedRow` may be set.
    @State private var hasKeyboardEngaged: Bool = false
    /// `.onKeyPress` only fires when the modifier-owning view (or a focused
    /// descendant) has focus, so the body root holds a focus anchor.
    @FocusState private var anchorFocused: Bool
    /// Owns keyboard percentage entry (buffer + commit/restore signals), broadcast to
    /// rows via the environment. First responder stays on the nav anchor throughout.
    @State private var textEntry = PopupTextEntryCoordinator()

    @Environment(\.openSettings) private var openSettings

    // MARK: - Resolved Dimensions

    private var popupDimensions: PopupDimensions {
        audioEngine.settingsManager.appSettings.popupSize.dimensions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .center) {
                if isEditingDevicePriority {
                    Text("Drag or type a number to set priority")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                } else {
                    defaultDevicesStatus
                }
                Spacer()
                editPriorityButton
                settingsButton
            }
            .padding(.bottom, DesignTokens.Spacing.xs)

            ScrollViewReader { proxy in
                ScrollView {
                    mainContent()
                }
                .scrollIndicators(.never)
                .frame(maxHeight: popupDimensions.maxContentHeight)
                .onChange(of: selectedRow) { _, newFocus in
                    guard let newFocus else { return }
                    withAnimation(DesignTokens.Animation.hover) {
                        proxy.scrollTo(newFocus, anchor: .center)
                    }
                }
            }
        }
        .padding(popupDimensions.contentPadding)
        .frame(width: popupDimensions.width)
        .background(
            WindowAppearanceBridge(appearance: audioEngine.settingsManager.appSettings.appearance.nsAppearance)
                .frame(width: 0, height: 0)
        )
        .darkGlassBackground()
        .preferredColorScheme(audioEngine.settingsManager.appSettings.appearance.swiftUIColorScheme)
        .environment(\.appearancePreference, audioEngine.settingsManager.appSettings.appearance)
        .onAppear {
            updateSortedDevices()
            pairedDevices = audioEngine.bluetoothDeviceMonitor.pairedDevices
            isBluetoothOn = audioEngine.bluetoothDeviceMonitor.isBluetoothOn
            // popupVisibility.isVisible is driven by the filtered NSWindow key
            // notifications below, not by .onAppear — SwiftUI mounts this view
            // before the popup is actually shown, and setting isVisible here
            // would suppress the HUD on the first media key at cold launch.
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            if isEditingDevicePriority {
                mergeDeviceChanges(from: audioEngine.outputDevices)
            }
            updateSortedDevices()
            syncNavOrder()
        }
        .onChange(of: audioEngine.apps) { _, _ in
            syncNavOrder()
        }
        .onChange(of: isEditingDevicePriority) { _, editing in
            if editing {
                selectedRow = nil
                hasKeyboardEngaged = false
            }
            syncNavOrder()
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.pairedDevices) { _, newValue in
            pairedDevices = newValue
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.isBluetoothOn) { _, newValue in
            isBluetoothOn = newValue
        }
        .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
            updateSortedDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // Global notification — fires for every window in the process. Filter to
            // FluidMenuBarExtra's popup window so unrelated windows (the HID-tap
            // primer, NSAlert panels, etc.) don't mark the popup as visible and
            // suppress the HUD.
            guard let window = notification.object as? NSWindow,
                  String(describing: type(of: window)).contains("FluidMenuBarExtra")
            else { return }
            isPopupVisible = true
            popupVisibility.isVisible = true
            audioEngine.bluetoothDeviceMonitor.refresh()
            syncNavOrder()
            hasKeyboardEngaged = false
            selectedRow = nil
            anchorFocused = true
            textEntry.buffer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  String(describing: type(of: window)).contains("FluidMenuBarExtra")
            else { return }
            isPopupVisible = false
            popupVisibility.isVisible = false
            hasKeyboardEngaged = false
            selectedRow = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // SwiftUI Menu tracking (e.g. sample-rate picker in the device
            // inspector) makes the popup window resign key without deactivating
            // the app. Only treat app-level deactivation as a real dismiss so
            // in-popup pickers don't collapse edit mode.
            exitEditModeSaving()
        }
        // Single focus anchor on the body root. `.onKeyPress` only fires when
        // the modifier-owning view (or a focused descendant) has focus, so the
        // anchor must claim it on popup open. `.focusEffectDisabled` suppresses
        // the OS-drawn focus ring around the entire popup.
        .focusable()
        .focusEffectDisabled()
        .focused($anchorFocused)
        // [.down, .repeat] is required so holding a key keeps moving the
        // selection or adjusting volume — `.down` alone fires once per press.
        .onKeyPress(phases: [.down, .repeat]) { keyPress in
            handleKeyPress(keyPress)
        }
        .environment(textEntry)
        .onChange(of: textEntry.navRestoreNonce) { _, _ in
            // A mouse-driven field edit ended; reclaim nav focus so arrows/Return work.
            anchorFocused = true
        }
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    // MARK: - Edit Priority Button

    /// Edit priority button — pencil ↔ checkmark, styled to match settingsButton
    private var editPriorityButton: some View {
        Button(isEditingDevicePriority ? "Done reordering" : "Reorder devices",
               systemImage: isEditingDevicePriority ? "checkmark" : "pencil") {
            toggleDevicePriorityEdit()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: isEditingDevicePriority ? .bold : .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEditingDevicePriority)
        .help(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape.fill") {
            openSettingsWindow()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
    }

    /// Handles Escape key.
    /// Escape order: expanded device detail → edit mode → popup dismiss. Expanded device detail is checked before
    /// `isEditingDevicePriority` so Escape collapses the row first rather than
    /// tearing down edit mode entirely.
    private func handleEscape() {
        // The hidden Escape keyboardShortcut button can win over `.onKeyPress`, so an
        // in-progress keyboard entry is cancelled here too.
        if textEntry.buffer != nil {
            textEntry.buffer = nil
            return
        }
        if expandedDeviceUID != nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedDeviceUID = nil
            }
        } else if isEditingDevicePriority {
            toggleDevicePriorityEdit()
        } else {
            NSApp.keyWindow?.resignKey()
        }
    }

    private func openSettingsWindow() {
        exitEditModeSaving()
        NSApp.keyWindow?.resignKey()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent() -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Devices section (tabbed: Output / Input)
            devicesSection

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Apps section (active + pinned inactive + hidden in edit mode)
            appsSection()
        }
    }

    // MARK: - Default Devices Status

    /// Name of the current default output device
    private var defaultOutputDeviceName: String {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID,
              let device = sortedDevices.first(where: { $0.uid == uid }) else {
            return "No Output"
        }
        return device.name
    }

    /// Subtle display of both default devices in header
    private var defaultDevicesStatus: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9))
            Text(defaultOutputDeviceName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.Colors.textSecondary)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        devicesContent
    }

    private var devicesContent: some View {
        VStack(spacing: 0) {
            if isEditingDevicePriority {
                // Edit mode: drag-and-drop reordering (works for both output and input)
                let defaultDeviceID = deviceVolumeMonitor.defaultDeviceID
                ForEach(Array(editableDeviceOrder.enumerated()), id: \.element.uid) { index, device in
                    editableDeviceRow(device: device, index: index, defaultDeviceID: defaultDeviceID)
                }

                // Paired Bluetooth devices
                if !isBluetoothOn {
                    Text("Turn on Bluetooth to connect devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, DesignTokens.Spacing.xs)
                } else {
                    // Filter out any device already in the output list (handles
                    // IOBluetooth/CoreAudio timing desync where both report the device).
                    let connectedNames = Set(editableDeviceOrder.map(\.name))
                    let filteredPaired = pairedDevices.filter { !connectedNames.contains($0.name) }
                    if !filteredPaired.isEmpty {
                        SectionHeader(title: "Paired")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DesignTokens.Spacing.xs)

                        ForEach(filteredPaired) { device in
                            PairedDeviceRow(
                                device: device,
                                isConnecting: audioEngine.bluetoothDeviceMonitor.connectingIDs.contains(device.id),
                                errorMessage: audioEngine.bluetoothDeviceMonitor.connectionErrors[device.id],
                                onConnect: {
                                    audioEngine.bluetoothDeviceMonitor.connect(device: device)
                                }
                            )
                        }
                    }
                }
            } else {
                ForEach(sortedDevices) { device in
                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        volumeBackend: audioEngine.outputVolumeBackend(for: device.id),
                        onSetDefault: {
                            audioEngine.setDefaultOutputDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                        },
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                        iconOverrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid)
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }

            }
        }
    }

    /// Builds a single row for the priority-edit list. Extracted from
    /// `devicesContent` because the inline expression exceeded Swift's
    /// type-check budget once hide + expand + drop-destination were combined.
    @ViewBuilder
    private func editableDeviceRow(
        device: AudioDevice,
        index: Int,
        defaultDeviceID: AudioDeviceID
    ) -> some View {
        let isDeviceHidden = audioEngine.settingsManager.isOutputDeviceHidden(device.uid)

        DeviceEditRow(
            device: device,
            iconOverrideSymbol: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
            priorityIndex: index,
            isDefault: device.id == defaultDeviceID,
            isInputDevice: false,
            deviceCount: editableDeviceOrder.count,
            isExpanded: expandedDeviceUID == device.uid,
            isHidden: isDeviceHidden,
            onReorder: { newIndex in
                guard let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }) else { return }
                guard newIndex != fromIndex, newIndex >= 0, newIndex < editableDeviceOrder.count else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    editableDeviceOrder.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: newIndex > fromIndex ? newIndex + 1 : newIndex
                    )
                }
            },
            onToggleExpand: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedDeviceUID = (expandedDeviceUID == device.uid) ? nil : device.uid
                }
            },
            onToggleHidden: {
                audioEngine.settingsManager.toggleOutputDeviceHidden(uid: device.uid)
            },
            onIconSelect: { symbol in
                audioEngine.settingsManager.setDeviceIconOverride(for: device.uid, to: symbol)
            },
            expandedContent: {
                // Only render when actually expanded.
                if expandedDeviceUID == device.uid {
                    DeviceDetailSheet(
                        device: device,
                        transportType: device.id.readTransportType(),
                        autoDetectedTier: deviceVolumeMonitor.autoDetectedOutputVolumeBackend(for: device.id),
                        currentOverride: audioEngine.settingsManager.getDeviceVolumeTierOverride(for: device.uid),
                        onOverrideChange: { newTier in
                            audioEngine.settingsManager.setDeviceVolumeTierOverride(for: device.uid, to: newTier)
                            deviceVolumeMonitor.applyTierOverrideChange(for: device.id)
                        },
                        onDismiss: {}
                    )
                }
            }
        )
        .draggable(device.uid) {
            Text(device.name)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { droppedUIDs, _ in
            guard let droppedUID = droppedUIDs.first,
                  let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == droppedUID }),
                  let toIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }),
                  fromIndex != toIndex else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                editableDeviceOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
            return true
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
                if ignoredCount > 0 {
                    Text("\(ignoredCount) ignored · edit to manage")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private func appsSection() -> some View {
        HStack {
            SectionHeader(title: "Apps")
            Spacer()
            let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
            if ignoredCount > 0 && !isEditingDevicePriority {
                Text("\(ignoredCount) ignored")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.bottom, DesignTokens.Spacing.xs)

        if permission.status != .authorized {
            PermissionBannerView(permission: permission)
        } else if isEditingDevicePriority {
            appEditModeContent
        } else if audioEngine.displayableApps.isEmpty {
            emptyStateView
        } else {
            appsContent()
        }
    }

    /// Edit mode content for apps: simplified rows with eye toggle + hidden section at bottom.
    private let appEditColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.xs)
    ]

    @ViewBuilder
    private var appEditModeContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Visible apps in 2-column grid
            LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                ForEach(audioEngine.displayableApps) { displayableApp in
                    switch displayableApp {
                    case .active(let app):
                        AppEditRow(
                            icon: app.icon,
                            name: app.name,
                            isIgnored: false,
                            isPinned: audioEngine.isPinned(app),
                            onToggleVisibility: { audioEngine.ignoreApp(app) },
                            onTogglePin: {
                                if audioEngine.isPinned(app) {
                                    audioEngine.unpinApp(app.persistenceIdentifier)
                                } else {
                                    audioEngine.pinApp(app)
                                }
                            }
                        )
                    case .pinnedInactive(let info):
                        AppEditRow(
                            icon: displayableApp.icon,
                            name: info.displayName,
                            isIgnored: false,
                            isPinned: true,
                            onToggleVisibility: {
                                let hiddenInfo = IgnoredAppInfo(
                                    persistenceIdentifier: info.persistenceIdentifier,
                                    displayName: info.displayName,
                                    bundleID: info.bundleID
                                )
                                audioEngine.settingsManager.ignoreApp(info.persistenceIdentifier, info: hiddenInfo)
                            },
                            onTogglePin: {
                                audioEngine.unpinApp(info.persistenceIdentifier)
                            }
                        )
                    }
                }
            }

            // Ignored apps section
            let ignoredApps = audioEngine.settingsManager.getIgnoredAppInfo()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !ignoredApps.isEmpty {
                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)

                Text("Ignored")
                    .sectionHeaderStyle()
                    .padding(.bottom, DesignTokens.Spacing.xs)

                LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(ignoredApps, id: \.persistenceIdentifier) { info in
                        AppEditRow(
                            icon: DisplayableApp.loadIcon(bundleID: info.bundleID),
                            name: info.displayName,
                            isIgnored: true,
                            isPinned: false,
                            onToggleVisibility: { audioEngine.unignoreApp(info.persistenceIdentifier) },
                            onTogglePin: {}
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appsContent() -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app, displayableApp: displayableApp)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp, displayableApp: DisplayableApp) -> some View {
        if let deviceUID = audioEngine.getDeviceUID(for: app) {
            AppRowWithLevelPolling(
                app: app,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                devices: sortedDevices,
                deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                selectedDeviceUID: deviceUID,
                selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDs(for: app),
                isFollowingDefault: audioEngine.isFollowingDefault(for: app),
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                deviceSelectionMode: audioEngine.getDeviceSelectionMode(for: app),
                getAudioLevel: { audioEngine.getAudioLevel(for: app) },
                isPopupVisible: isPopupVisible,
                onVolumeChange: { volume in
                    audioEngine.setVolume(for: app, to: volume)
                },
                onMuteChange: { muted in
                    audioEngine.setMute(for: app, to: muted)
                },
                onDeviceSelected: { newDeviceUID in
                    audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
                },
                onDevicesSelected: { uids in
                    audioEngine.setSelectedDeviceUIDs(for: app, to: uids)
                },
                onDeviceModeChange: { mode in
                    audioEngine.setDeviceSelectionMode(for: app, to: mode)
                },
                onSelectFollowDefault: {
                    audioEngine.setDevice(for: app, deviceUID: nil)
                },
                onAppActivate: {
                    activateApp(pid: app.id, bundleID: app.bundleID)
                },
                isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id)
            )
            .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
        }
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp) -> some View {
        let identifier = info.persistenceIdentifier
        InactiveAppRow(
            appInfo: info,
            icon: displayableApp.icon,
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            devices: sortedDevices,
            deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
            selectedDeviceUID: audioEngine.getDeviceRoutingForInactive(identifier: identifier),
            selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDsForInactive(identifier: identifier),
            isFollowingDefault: audioEngine.isFollowingDefaultForInactive(identifier: identifier),
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            deviceSelectionMode: audioEngine.getDeviceSelectionModeForInactive(identifier: identifier),
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            onVolumeChange: { volume in
                audioEngine.setVolumeForInactive(identifier: identifier, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: newDeviceUID)
            },
            onDevicesSelected: { uids in
                audioEngine.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
            },
            onDeviceModeChange: { mode in
                audioEngine.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
            },
            onSelectFollowDefault: {
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: nil)
            },
            isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id)
        )
        .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
    }

    // MARK: - Device Priority Edit

    private func toggleDevicePriorityEdit() {
        if isEditingDevicePriority {
            // Exiting edit mode: persist to the correct priority list and
            // collapse any expanded device detail (the inline body only lives
            // inside edit mode, so it must collapse when the mode does).
            persistEditableOrder()
            isEditingDevicePriority = false
            expandedDeviceUID = nil
            updateSortedDevices()
        } else {
            // Entering edit mode: use the full (unfiltered) device list so hidden devices are also shown.
            editableDeviceOrder = audioEngine.prioritySortedOutputDevices
            isEditingDevicePriority = true
        }
    }

    /// Persists the editable order to the correct priority list, preserving disconnected device positions.
    private func persistEditableOrder() {
        let connectedOrder = editableDeviceOrder.map(\.uid)
        audioEngine.settingsManager.mergeDevicePriorityOrder(
            oldPriority: audioEngine.settingsManager.devicePriorityOrder,
            connectedOrder: connectedOrder
        )
    }

    /// Exits edit mode, saving the current order. Called on edge cases like device changes.
    private func exitEditModeSaving() {
        guard isEditingDevicePriority else { return }
        persistEditableOrder()
        isEditingDevicePriority = false
        expandedDeviceUID = nil
    }

    /// Merges device list changes into `editableDeviceOrder` while preserving the user's reordering.
    /// Existing devices are refreshed (CoreAudio may reassign AudioDeviceIDs), removed devices are
    /// dropped, and reconnecting devices are inserted at their saved priority position.
    private func mergeDeviceChanges(from latest: [AudioDevice]) {
        let latestByUID = Dictionary(latest.map { ($0.uid, $0) }, uniquingKeysWith: { _, new in new })
        let priorityOrder = audioEngine.settingsManager.devicePriorityOrder

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // Remove devices that disappeared
            editableDeviceOrder.removeAll { latestByUID[$0.uid] == nil }

            // Refresh existing devices in case AudioDeviceID changed
            for i in editableDeviceOrder.indices {
                if let updated = latestByUID[editableDeviceOrder[i].uid] {
                    editableDeviceOrder[i] = updated
                }
            }

            // Insert reconnecting devices at their saved priority position
            let existingUIDs = Set(editableDeviceOrder.map(\.uid))
            let newDevices = latest.filter { !existingUIDs.contains($0.uid) }
            for device in newDevices {
                let index = Self.priorityInsertionIndex(
                    for: device.uid,
                    in: editableDeviceOrder.map(\.uid),
                    priorityOrder: priorityOrder
                )
                editableDeviceOrder.insert(device, at: index)
            }
        }
    }

    /// Finds the best insertion index for a reconnecting device based on saved priority order.
    ///
    /// Walks `priorityOrder` to find the UIDs that come before and after `uid`, then
    /// places the device between them in `currentOrder`. Falls back to appending at the end
    /// if the device isn't in the priority list or no neighbors are present.
    ///
    /// - Parameters:
    ///   - uid: The device UID to insert.
    ///   - currentOrder: The current list of device UIDs.
    ///   - priorityOrder: The saved full priority list.
    /// - Returns: The index at which to insert the device.
    static func priorityInsertionIndex(for uid: String, in currentOrder: [String], priorityOrder: [String]) -> Int {
        guard let priorityIndex = priorityOrder.firstIndex(of: uid) else {
            // Brand new device not in priority list — append at end
            return currentOrder.count
        }

        // Find the closest priority neighbor that exists in currentOrder and comes AFTER uid in priority.
        // Insert before that neighbor so uid takes its correct position.
        for i in (priorityIndex + 1)..<priorityOrder.count {
            let successor = priorityOrder[i]
            if let currentIndex = currentOrder.firstIndex(of: successor) {
                return currentIndex
            }
        }

        // No successor found — insert at end
        return currentOrder.count
    }

    // MARK: - Helpers

    /// Recomputes sorted output devices, filtering hidden ones.
    /// The current default output device is always kept visible even if hidden.
    /// Falls back to the unfiltered list if the filter produces an empty
    /// result — `defaultDeviceUID` can be briefly nil during device switchover
    /// and we don't want the main view to show zero rows in that window.
    private func updateSortedDevices() {
        let all = audioEngine.prioritySortedOutputDevices
        let defaultUID = deviceVolumeMonitor.defaultDeviceUID
        let filtered = all.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isOutputDeviceHidden(device.uid)
        }
        sortedDevices = filtered.isEmpty ? all : filtered
    }

    // MARK: - Keyboard Navigation

    private func syncNavOrder() {
        navModel.syncOrder(
            activeDevices: sortedDevices,
            appPersistenceIDs: audioEngine.displayableApps.map(\.id),
            isEditingPriority: isEditingDevicePriority
        )
    }

    private func currentDefaultDeviceUID() -> String? {
        deviceVolumeMonitor.defaultDeviceUID
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // `.onKeyPress` also fires for focused descendants; yield while a TextField is editing so its Return commits via onSubmit instead of activating a row.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        // Keyboard entry mode: the popup owns every key so the anchor keeps first responder.
        if textEntry.buffer != nil {
            return handleKeyboardEditKey(keyPress)
        }
        let mods = keyPress.modifiers
        let isM = keyPress.key == KeyEquivalent("m")
        let editSeed = digitSeed(for: keyPress)
        let isRecognized: Bool = {
            switch keyPress.key {
            case .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space:
                return true
            default:
                return isM || editSeed != nil
            }
        }()
        // Wake gate: compute target locally so first-press actions never read a
        // stale selection. ↑/↓ wake without moving; action keys wake and act on
        // the default in the same press.
        let target: PopupKeyboardNavModel.RowID?
        let wokeUp: Bool
        if !hasKeyboardEngaged && isRecognized {
            hasKeyboardEngaged = true
            target = navModel.defaultFocus(defaultOutputUID: currentDefaultDeviceUID())
            selectedRow = target
            wokeUp = true
        } else {
            target = selectedRow
            wokeUp = false
        }
        switch keyPress.key {
        case .upArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.previous(before: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .downArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.next(after: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .leftArrow:
            return adjustVolume(at: target, direction: -1, shift: mods.contains(.shift))
        case .rightArrow:
            return adjustVolume(at: target, direction: +1, shift: mods.contains(.shift))
        case .return, .space:
            return activate(target)
        default:
            if let editSeed, keyPress.phase == .down, target != nil {
                textEntry.buffer = editSeed
                return .handled
            }
            return isM ? toggleMute(for: target) : .ignored
        }
    }

    /// Consumes every key while entry is active so editing keystrokes never leak to navigation.
    private func handleKeyboardEditKey(_ keyPress: KeyPress) -> KeyPress.Result {
        // The Mac ⌫ key arrives as DEL (U+007F), which `KeyEquivalent.delete` doesn't match.
        if keyPress.characters == "\u{7f}" || keyPress.key == .delete {
            let next = String((textEntry.buffer ?? "").dropLast())
            textEntry.buffer = next.isEmpty ? nil : next
            return .handled
        }
        switch keyPress.key {
        case .return:
            textEntry.commitNonce += 1
            return .handled
        case .escape:
            textEntry.buffer = nil
            return .handled
        default:
            if let digit = digitSeed(for: keyPress), keyPress.phase == .down {
                let current = textEntry.buffer ?? ""
                if current.count < 4 {
                    textEntry.buffer = current + digit
                }
            }
            return .handled
        }
    }

    /// The bare digit `0`–`9` for this key press, or nil (modifier combos excluded).
    private func digitSeed(for keyPress: KeyPress) -> String? {
        guard keyPress.modifiers.intersection([.command, .control, .option]).isEmpty,
              keyPress.characters.count == 1,
              let ch = keyPress.characters.first,
              ("0"..."9").contains(ch)
        else { return nil }
        return String(ch)
    }

    private func adjustVolume(at target: PopupKeyboardNavModel.RowID?, direction: Int, shift: Bool) -> KeyPress.Result {
        guard let target else { return .ignored }
        let baseStep = audioEngine.settingsManager.appSettings.volumeHotkeyStep.sliderDelta
        let step = shift ? baseStep * 2.0 : baseStep
        let delta = step * Double(direction)
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                applyAppVolumeStep(
                    currentGain: audioEngine.currentVolume(for: app),
                    currentMute: audioEngine.isMuted(for: app),
                    direction: direction,
                    delta: delta,
                    setGain: { audioEngine.setVolume(for: app, to: $0) },
                    setMute: { audioEngine.setMute(for: app, to: $0) }
                )
                return .handled
            }
            applyAppVolumeStep(
                currentGain: audioEngine.getVolumeForInactive(identifier: persistenceID),
                currentMute: audioEngine.getMuteForInactive(identifier: persistenceID),
                direction: direction,
                delta: delta,
                setGain: { audioEngine.setVolumeForInactive(identifier: persistenceID, to: $0) },
                setMute: { audioEngine.setMuteForInactive(identifier: persistenceID, to: $0) }
            )
            return .handled
        case .device(let uid):
            guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                return .ignored
            }
            let current = Double(deviceVolumeMonitor.volumes[device.id] ?? 1.0)
            let next = Float(max(0.0, min(1.0, current + delta)))
            deviceVolumeMonitor.setVolume(for: device.id, to: next)
            return .handled
        }
    }

    /// Mirrors `ShortcutsRegistry.adjustTargetVolume`'s mute-edge semantics for
    /// both active and pinned-inactive app rows.
    private func applyAppVolumeStep(
        currentGain: Float,
        currentMute: Bool,
        direction: Int,
        delta: Double,
        setGain: (Float) -> Void,
        setMute: (Bool) -> Void
    ) {
        let currentSlider = VolumeMapping.gainToSlider(currentGain)
        let nextSlider = VolumeMapping.steppedSlider(from: currentSlider, delta: delta)
        let nextGain = VolumeMapping.sliderToGain(nextSlider)
        let willBeSilent = nextSlider <= 0.001
        if direction > 0 {
            if currentMute { setMute(false) }
        } else if currentMute && !willBeSilent {
            setMute(false)
        } else if !currentMute && willBeSilent {
            setMute(true)
        }
        setGain(nextGain)
    }

    private func toggleMute(for target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                audioEngine.toggleMute(for: app)
                return .handled
            }
            let current = audioEngine.getMuteForInactive(identifier: persistenceID)
            audioEngine.setMuteForInactive(identifier: persistenceID, to: !current)
            return .handled
        case .device(let uid):
            guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                return .ignored
            }
            let current = deviceVolumeMonitor.muteStates[device.id] ?? false
            deviceVolumeMonitor.setMute(for: device.id, to: !current)
            return .handled
        }
    }

    private func activate(_ target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .device(let uid):
            guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                return .ignored
            }
            audioEngine.setDefaultOutputDevice(device.id)
            NSApp.keyWindow?.resignKey()
            return .handled
        case .app:
            return .ignored
        }
    }

    /// Activates an app, bringing it to foreground and restoring minimized windows
    private func activateApp(pid: pid_t, bundleID: String?) {
        // Step 1: Always activate via NSRunningApplication (reliable for non-minimized)
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        runningApp?.activate()

        // Step 2: Try to restore minimized windows via AppleScript
        if let bundleID = bundleID {
            // reopen + activate restores minimized windows for most apps
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    reopen
                    activate
                end tell
                """)
            script?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Previews

#Preview("Menu Bar Popup") {
    // Note: This preview requires mock AudioEngine and DeviceVolumeMonitor
    // For now, just show the structure
    PreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Output Devices")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleDevices.prefix(2)) { device in
                DeviceRow(
                    device: device,
                    isDefault: device == MockData.sampleDevices[0],
                    volume: 0.75,
                    isMuted: false,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {}
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            SectionHeader(title: "Apps")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleApps.prefix(3)) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.7),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices[0].uid,
                    isMuted: false,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            Button {} label: {
                HStack(spacing: 6) {
                    Text("Quit")
                    Text("⌘Q")
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .font(DesignTokens.Typography.caption)
        }
    }
}
