// FineTune/Views/MenuBarPopupView.swift
import AudioToolbox
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    let permission: AudioRecordingPermission

    /// Accessibility trust gates media-key interception; the panel offers a
    /// grant row while it's missing. Bindable so the row disappears live.
    @Bindable var accessibility: AccessibilityPermissionService

    /// Transient status (offline, suppressionDegraded) for the media-keys banner.
    @Bindable var mediaKeyStatus: MediaKeyStatus

    /// Shared popup visibility flag — mirrored to this service so `MediaKeyMonitor`
    /// can skip HUD display while the popup is the "HUD".
    @Bindable var popupVisibility: PopupVisibilityService

    let hudController: HUDWindowController
    let mediaKeyMonitor: MediaKeyMonitor

    /// Outputs that never appear in the panel (virtual devices installed by other apps).
    static let hiddenOutputNames = ["Microsoft Teams Audio", "Splashtop Remote Sound"]

    /// How long an app stays listed after it last produced sound.
    static let audibleLinger: TimeInterval = 8
    /// How long a silent output stream must stay open before the app is listed.
    static let steadyRunThreshold: TimeInterval = 15
    /// Peak level above which an app counts as audible (≈ −60 dBFS).
    static let audibleThreshold: Float = 0.001

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State private var sortedDevices: [AudioDevice] = []

    /// Last time each app (by persistence ID) produced sound. Apps briefly
    /// re-open their output stream on every device switch, so "is running"
    /// alone makes idle apps (paused Spotify) flicker in and out.
    @State private var lastAudible: [String: Date] = [:]

    /// When each app's output stream started running, tracked even while the
    /// panel is closed. A stream that stays open (a call where nobody is
    /// talking) is listed once it has run for `steadyRunThreshold`.
    @State private var runningSince: [String: Date] = [:]

    /// True while the panel window is key; drives level polling.
    @State private var isPanelOpen = false

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

    /// Ceiling on the scrollable body, sized for a 13" MacBook Air.
    private let maxContentHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
                .padding(.bottom, 6)

            if let device = defaultOutputDevice {
                DeviceVolumeSlider(
                    volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                    isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                    volumeBackend: audioEngine.outputVolumeBackend(for: device.id),
                    onVolumeChange: { deviceVolumeMonitor.setVolume(for: device.id, to: $0) },
                    onMuteToggle: {
                        let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                        deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                    }
                )
                // Rebuild per device so the slider re-reads its initial position.
                .id(device.uid)
                .padding(.horizontal, PanelMetrics.rowHorizontalPadding)

                PanelDivider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    mainContent()
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxContentHeight)
                .onChange(of: selectedRow) { _, newFocus in
                    guard let newFocus else { return }
                    withAnimation(DesignTokens.Animation.hover) {
                        proxy.scrollTo(newFocus, anchor: .center)
                    }
                }
            }

        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, PanelMetrics.verticalPadding)
        .frame(width: PanelMetrics.width)
        .animation(.snappy(duration: 0.25), value: visibleApps.map(\.id))
        .onAppear {
            updateRunningSince()
            updateSortedDevices()
            // popupVisibility.isVisible is driven by the filtered NSWindow key
            // notifications below, not by .onAppear — SwiftUI mounts this view
            // before the popup is actually shown, and setting isVisible here
            // would suppress the HUD on the first media key at cold launch.
        }
        .task(id: isPanelOpen) {
            guard isPanelOpen else { return }
            while !Task.isCancelled {
                updateAudibility()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            updateSortedDevices()
            syncNavOrder()
        }
        .onChange(of: audioEngine.apps) { _, _ in
            updateRunningSince()
        }
        .onChange(of: visibleApps.map(\.id)) { _, _ in
            syncNavOrder()
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
            popupVisibility.isVisible = true
            deviceVolumeMonitor.refreshAlertVolume()
            updateAudibility()
            isPanelOpen = true
            syncNavOrder()
            hasKeyboardEngaged = false
            selectedRow = nil
            anchorFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  String(describing: type(of: window)).contains("FluidMenuBarExtra")
            else { return }
            popupVisibility.isVisible = false
            isPanelOpen = false
            hasKeyboardEngaged = false
            selectedRow = nil
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
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    /// Escape dismisses the popup.
    private func handleEscape() {
        NSApp.keyWindow?.resignKey()
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelSectionHeader("Output")
            devicesContent

            PanelDivider()

            appsSection()
        }
    }

    /// The current default output device (even if it's one of the hidden ones).
    private var defaultOutputDevice: AudioDevice? {
        audioEngine.outputDevices.first(where: { $0.id == deviceVolumeMonitor.defaultDeviceID })
    }

    // MARK: - Devices

    private var devicesContent: some View {
        VStack(spacing: 0) {
            ForEach(sortedDevices) { device in
                PanelDeviceRow(
                    name: device.name,
                    symbol: device.panelSymbol(override: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid)),
                    isSelected: device.id == deviceVolumeMonitor.defaultDeviceID,
                    isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                    onSelect: { audioEngine.setDefaultOutputDevice(device.id) }
                )
                .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
            }

        }
    }

    // MARK: - Apps

    /// Apps shown in the panel: pinned ones always, others only while they
    /// actually make sound (plus a short linger), so idle-but-open streams don't flicker.
    private var visibleApps: [DisplayableApp] {
        let now = Date()
        return audioEngine.displayableApps.filter { displayable in
            switch displayable {
            case .pinnedInactive:
                return true
            case .active(let app):
                if audioEngine.isPinned(app) { return true }
                if let since = runningSince[app.persistenceIdentifier],
                   now.timeIntervalSince(since) >= Self.steadyRunThreshold { return true }
                guard let last = lastAudible[app.persistenceIdentifier] else { return false }
                return now.timeIntervalSince(last) < Self.audibleLinger
            }
        }
    }

    private func updateAudibility() {
        let now = Date()
        // Expired entries drop out here, which is also what re-renders the list.
        var updated = lastAudible.filter { now.timeIntervalSince($0.value) < Self.audibleLinger }
        for app in audioEngine.apps where audioEngine.getAudioLevel(for: app) > Self.audibleThreshold {
            // Refresh at most once a second to avoid re-rendering on every tick.
            if let last = updated[app.persistenceIdentifier], now.timeIntervalSince(last) < 1 { continue }
            updated[app.persistenceIdentifier] = now
        }
        if updated != lastAudible { lastAudible = updated }
    }

    private func updateRunningSince() {
        let now = Date()
        let running = Set(audioEngine.apps.map(\.persistenceIdentifier))
        var updated = runningSince.filter { running.contains($0.key) }
        for id in running where updated[id] == nil { updated[id] = now }
        if updated != runningSince { runningSince = updated }
    }

    @ViewBuilder
    private func appsSection() -> some View {
        PanelSectionHeader("Apps")

        PanelSystemSoundsRow(
            volume: deviceVolumeMonitor.alertVolume,
            onVolumeChange: { deviceVolumeMonitor.setAlertVolume($0) }
        )

        if permission.status != .authorized {
            PermissionBannerView(permission: permission)
        } else {
            appsContent()
        }
    }

    private func appsContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleApps) { displayableApp in
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
            let isFollowingDefault = audioEngine.isFollowingDefault(for: app)
            PanelAppRow(
                name: app.name,
                icon: app.icon,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id),
                routingSubtitle: routingSubtitle(deviceUID: deviceUID, isFollowingDefault: isFollowingDefault),
                onVolumeChange: { audioEngine.setVolume(for: app, to: $0) },
                onMuteChange: { audioEngine.setMute(for: app, to: $0) }
            )
            .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
            .transition(.opacity)
        }
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp) -> some View {
        let identifier = info.persistenceIdentifier
        let deviceUID = audioEngine.getDeviceRoutingForInactive(identifier: identifier)
            ?? deviceVolumeMonitor.defaultDeviceUID ?? ""
        let isFollowingDefault = audioEngine.isFollowingDefaultForInactive(identifier: identifier)
        PanelAppRow(
            name: info.displayName,
            icon: displayableApp.icon,
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            isInactive: true,
            isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id),
            routingSubtitle: routingSubtitle(deviceUID: deviceUID, isFollowingDefault: isFollowingDefault),
            onVolumeChange: { audioEngine.setVolumeForInactive(identifier: identifier, to: $0) },
            onMuteChange: { audioEngine.setMuteForInactive(identifier: identifier, to: $0) }
        )
        .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
    }

    /// "→ Device" next to the app name when it doesn't follow the system output.
    private func routingSubtitle(deviceUID: String, isFollowingDefault: Bool) -> String? {
        guard !isFollowingDefault else { return nil }
        return sortedDevices.first(where: { $0.uid == deviceUID }).map { "→ \($0.name)" }
    }

    // MARK: - Helpers

    static func isHiddenOutput(name: String) -> Bool {
        hiddenOutputNames.contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// Recomputes the visible output list: priority order, minus the
    /// hardcoded virtual devices.
    private func updateSortedDevices() {
        sortedDevices = audioEngine.prioritySortedOutputDevices.filter { !Self.isHiddenOutput(name: $0.name) }
    }

    // MARK: - Keyboard Navigation

    private func syncNavOrder() {
        navModel.syncOrder(
            activeDevices: sortedDevices,
            appPersistenceIDs: visibleApps.map(\.id),
            isEditingPriority: false
        )
    }

    private func currentDefaultDeviceUID() -> String? {
        deviceVolumeMonitor.defaultDeviceUID
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // `.onKeyPress` also fires for focused descendants; yield while a TextField is editing so its Return commits via onSubmit instead of activating a row.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let mods = keyPress.modifiers
        let isM = keyPress.key == KeyEquivalent("m")
        let isRecognized: Bool = {
            switch keyPress.key {
            case .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space:
                return true
            default:
                return isM
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
            return isM ? toggleMute(for: target) : .ignored
        }
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

}

// MARK: - Previews

/// Static stand-in for the panel (the real view needs a live AudioEngine).
private struct PanelPreview: View {
    @State private var deviceVolume: Float = 0.55
    @State private var volumes: [Float] = [1.0, 0.6, 0.4]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
                .padding(.bottom, 6)
            DeviceVolumeSlider(volume: deviceVolume, isMuted: false, onVolumeChange: { deviceVolume = $0 }, onMuteToggle: {})
                .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
            PanelDivider()
            PanelSectionHeader("Output")
            PanelDeviceRow(name: "AirPods Max", symbol: "airpodsmax", isSelected: true, onSelect: {})
            PanelDeviceRow(name: "MacBook Pro Speakers", symbol: "macbook", isSelected: false, onSelect: {})
            PanelDivider()
            PanelSectionHeader("Apps")
            PanelSystemSoundsRow(volume: 0.3, onVolumeChange: { _ in })
            ForEach(0..<3) { i in
                PanelAppRow(
                    name: MockData.sampleApps[i].name,
                    icon: MockData.sampleApps[i].icon,
                    volume: volumes[i],
                    isMuted: i == 2,
                    onVolumeChange: { volumes[i] = $0 },
                    onMuteChange: { _ in }
                )
            }
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, PanelMetrics.verticalPadding)
        .frame(width: PanelMetrics.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius))
        .padding(40)
        .background(
            LinearGradient(colors: [.indigo, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

#Preview("Menu Bar Panel") {
    PanelPreview()
}

#Preview("Menu Bar Panel – Dark") {
    PanelPreview()
        .preferredColorScheme(.dark)
}
