// FineTune/Audio/Bluetooth/ListeningModeController.swift
// AirPods / Beats noise control (Off · Transparency · Adaptive · Noise Cancellation).
//
// There is no public API for this. IOBluetoothDevice exposes undocumented
// `listeningMode` / `setListeningMode:` and `is…Supported` accessors (the same ones
// NoiseBuddy uses). Every call is guarded with `responds(to:)` so a future macOS
// that drops them simply hides the controls instead of crashing.

import Foundation
import IOBluetooth
import Observation

enum ListeningMode: Int, CaseIterable, Identifiable {
    case off = 1
    case noiseCancellation = 2
    case transparency = 3
    case adaptive = 4

    var id: Int { rawValue }

    /// Order used by the native Sound menu.
    static let displayOrder: [ListeningMode] = [.off, .transparency, .adaptive, .noiseCancellation]

    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancellation: "Noise Cancellation"
        case .transparency: "Transparency"
        case .adaptive: "Adaptive"
        }
    }

    var symbol: String {
        switch self {
        case .off: "person.fill"
        case .noiseCancellation: "person.and.background.striped.horizontal"
        case .transparency: "person.and.background.dotted"
        case .adaptive: "person.wave.2.fill"
        }
    }

    /// Private `is…Supported` accessor gating this mode (nil = always available).
    fileprivate var supportSelector: String? {
        switch self {
        case .off: nil
        case .noiseCancellation: "isANCSupported"
        case .transparency: "isTransparencySupported"
        case .adaptive: "isAdaptiveSupported"
        }
    }
}

@Observable
@MainActor
final class ListeningModeController {
    /// CoreAudio UID of the output the modes belong to (nil = no controllable headphones).
    private(set) var deviceUID: String?
    private(set) var supportedModes: [ListeningMode] = []
    private(set) var currentMode: ListeningMode?

    @ObservationIgnored private var device: IOBluetoothDevice?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var isAvailable: Bool { deviceUID != nil && supportedModes.count > 1 }

    /// Re-resolves controllable headphones for the given output device.
    func update(outputUID: String?) {
        guard let uid = outputUID,
              let bt = AppleHeadphones.bluetoothDevice(forAudioUID: uid),
              bt.isConnected(),
              AppleHeadphones.productID(of: bt) != nil,
              Self.responds(bt, "listeningMode"),
              Self.responds(bt, "setListeningMode:")
        else {
            clear()
            return
        }

        let modes = ListeningMode.displayOrder.filter { mode in
            guard let selector = mode.supportSelector else { return true }
            return Self.bool(bt, selector)
        }
        guard modes.count > 1 else {
            clear()
            return
        }

        device = bt
        deviceUID = uid
        supportedModes = modes
        currentMode = Self.readMode(bt)
    }

    func select(_ mode: ListeningMode) {
        guard let device, supportedModes.contains(mode), Self.responds(device, "setListeningMode:") else { return }
        currentMode = mode  // optimistic; corrected by the next poll if the headphones refuse
        device.setValue(NSNumber(value: UInt8(mode.rawValue)), forKey: "listeningMode")
    }

    /// Polls while the panel is open so presses on the headphones show up live.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let device = self.device else { continue }
                let mode = Self.readMode(device)
                if mode != nil, mode != self.currentMode { self.currentMode = mode }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func clear() {
        device = nil
        deviceUID = nil
        supportedModes = []
        currentMode = nil
    }

    private static func readMode(_ device: IOBluetoothDevice) -> ListeningMode? {
        guard responds(device, "listeningMode"),
              let raw = (device.value(forKey: "listeningMode") as? NSNumber)?.intValue
        else { return nil }
        return ListeningMode(rawValue: raw)
    }

    private static func responds(_ device: IOBluetoothDevice, _ selector: String) -> Bool {
        device.responds(to: NSSelectorFromString(selector))
    }

    private static func bool(_ device: IOBluetoothDevice, _ selector: String) -> Bool {
        guard responds(device, selector) else { return false }
        return (device.value(forKey: selector) as? NSNumber)?.boolValue ?? false
    }
}
