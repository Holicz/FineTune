// FineTune/Audio/Bluetooth/AppleHeadphones.swift
// Identifies AirPods / Beats by Bluetooth product ID, so detection survives the
// user renaming the device ("klapky na uši" is still AirPods Max).

import Foundation
import IOBluetooth
import Synchronization

enum AppleHeadphones {
    /// Apple's Bluetooth SIG vendor ID (0x004C).
    static let appleVendorID = 76

    /// SF Symbol for a known Apple/Beats product ID, nil for anything else.
    static func symbol(forProductID productID: Int) -> String? {
        switch productID {
        case 0x2002, 0x200F: return "airpods"
        case 0x2013: return "airpods.gen3"
        case 0x2019, 0x201B: return "airpods.gen4"
        case 0x200E, 0x2014, 0x2024, 0x2027: return "airpodspro"
        case 0x200A, 0x201F: return "airpodsmax"
        case 0x2003, 0x200B, 0x201D: return "beats.powerbeatspro"
        case 0x2011, 0x2016: return "beats.studiobuds"
        case 0x2012: return "beats.fitpro"
        case 0x2005, 0x2010: return "beats.earphones"
        case 0x2006, 0x2009, 0x200C, 0x2017: return "beats.headphones"
        default: return nil
        }
    }

    /// SF Symbol for the headphones behind a CoreAudio device UID, if they are
    /// a recognised Apple/Beats model.
    static func symbol(forAudioUID uid: String) -> String? {
        guard let productID = productID(forAudioUID: uid) else { return nil }
        return symbol(forProductID: productID)
    }

    /// Paired IOBluetooth device behind a CoreAudio Bluetooth UID
    /// ("70-F9-4A-9C-51-F9:output" → address 70-f9-4a-9c-51-f9).
    static func bluetoothDevice(forAudioUID uid: String) -> IOBluetoothDevice? {
        guard let address = bluetoothAddress(fromAudioUID: uid) else { return nil }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { normalized($0.addressString) == address }
    }

    /// Apple product ID of a paired device, via IOBluetooth's (undocumented) `productID`.
    static func productID(of device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: NSSelectorFromString("productID")),
              device.responds(to: NSSelectorFromString("vendorID")),
              (device.value(forKey: "vendorID") as? Int) == appleVendorID,
              let productID = device.value(forKey: "productID") as? Int,
              productID != 0
        else { return nil }
        return productID
    }

    // MARK: - Private

    /// Product IDs never change for an address, so cache lookups (including misses).
    private static let cache = Mutex<[String: Int?]>([:])

    private static func productID(forAudioUID uid: String) -> Int? {
        guard let address = bluetoothAddress(fromAudioUID: uid) else { return nil }
        if let cached = cache.withLock({ $0[address] }) { return cached }
        let productID = bluetoothDevice(forAudioUID: uid).flatMap { productID(of: $0) }
        cache.withLock { $0[address] = productID }
        return productID
    }

    static func bluetoothAddress(fromAudioUID uid: String) -> String? {
        let candidate = normalized(String(uid.split(separator: ":").first ?? ""))
        // xx-xx-xx-xx-xx-xx
        guard candidate.count == 17, candidate.split(separator: "-").count == 6 else { return nil }
        return candidate
    }

    private static func normalized(_ address: String?) -> String {
        (address ?? "").lowercased().replacingOccurrences(of: ":", with: "-")
    }
}
