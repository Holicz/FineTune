// FineTuneTests/AppleHeadphonesTests.swift
import Testing
@testable import FineTune

@Suite("AppleHeadphones — product ID and address mapping")
struct AppleHeadphonesTests {

    @Test("Known product IDs map to their glyph", arguments: [
        (0x201F, "airpodsmax"),
        (0x200A, "airpodsmax"),
        (0x200E, "airpodspro"),
        (0x2024, "airpodspro"),
        (0x2013, "airpods.gen3"),
        (0x2019, "airpods.gen4"),
        (0x2017, "beats.headphones"),
    ])
    func knownProducts(productID: Int, symbol: String) {
        #expect(AppleHeadphones.symbol(forProductID: productID) == symbol)
    }

    @Test("Unknown product IDs return nil")
    func unknownProduct() {
        #expect(AppleHeadphones.symbol(forProductID: 0) == nil)
        #expect(AppleHeadphones.symbol(forProductID: 0x09CC) == nil)
    }

    @Test("CoreAudio Bluetooth UIDs yield a normalized address")
    func addressFromUID() {
        #expect(AppleHeadphones.bluetoothAddress(fromAudioUID: "70-F9-4A-9C-51-F9:output") == "70-f9-4a-9c-51-f9")
        #expect(AppleHeadphones.bluetoothAddress(fromAudioUID: "14-85-09-C4-2D-02") == "14-85-09-c4-2d-02")
    }

    @Test("Non-Bluetooth UIDs are rejected")
    func nonBluetoothUID() {
        #expect(AppleHeadphones.bluetoothAddress(fromAudioUID: "BuiltInSpeakerDevice") == nil)
        #expect(AppleHeadphones.bluetoothAddress(fromAudioUID: "AppleUSBAudioEngine:Apple:USB-C:1234:1,2") == nil)
    }
}
