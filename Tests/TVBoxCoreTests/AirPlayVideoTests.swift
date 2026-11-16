import Foundation
import Testing
@testable import TVBoxCore

@Suite struct AirPlayVideoTests {
    @Test func capabilitiesAndLocalDeviceValidation() throws {
        #expect(AirPlayVideoProtocol.features("0x527FFFF7,0x1E") == 0x1E527FFFF7)
        #expect(AirPlayVideoProtocol.features("0x1") == 1)
        for value in ["", "1", "0x", "0x100000000", "0x1,", "0x1,0x2,0x3"] {
            #expect(AirPlayVideoProtocol.features(value) == nil)
        }
        let device = try AirPlayVideoProtocol.device(name: "测试电视", id: "test", address: "192.168.1.10", port: 7000, features: "0x1", passwordRequired: false)
        #expect(device.isAirPlayVideo && device.rendering == nil)
        #expect(device.transport.actions.contains("Seek"))
        #expect(throws: (any Error).self) { try AirPlayVideoProtocol.device(name: "锁定", id: "locked", address: "192.168.1.10", port: 7000, features: "0x1", passwordRequired: true) }
        #expect(throws: (any Error).self) { try AirPlayVideoProtocol.device(name: "仅镜像", id: "screen", address: "192.168.1.10", port: 7000, features: "0x80", passwordRequired: false) }
        for invalid in ["example.com", "8.8.8.8", "192.168.1.1.bad", "10..1.2.3", "10.1.2.3.999"] {
            #expect(!LANIPv4.isLocal(invalid))
            #expect(throws: (any Error).self) { try AirPlayVideoProtocol.device(name: "无效", id: "invalid", address: invalid, port: 7000, features: "0x1", passwordRequired: false) }
        }
    }
    @Test func parsesActualStyleXMLAndBinaryPlaybackStates() throws {
        for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
            let body = try PropertyListSerialization.data(fromPropertyList: ["readyToPlay": true, "duration": 8.0, "position": 3.0, "rate": 1.0], format: format, options: 0)
            let state = try AirPlayVideoState(data: body)
            #expect(state.ready && state.position == 3 && state.duration == 8 && state.rate == 1)
        }
        let stopped = try AirPlayVideoState(data: PropertyListSerialization.data(fromPropertyList: ["readyToPlay": false], format: .binary, options: 0))
        #expect(!stopped.ready && stopped.position == nil && stopped.duration == nil && stopped.rate == 0)
    }
    @Test func invalidStateCannotMasqueradeAsPlayback() throws {
        #expect(throws: (any Error).self) { try AirPlayVideoState(data: Data("not a plist".utf8)) }
        let failure = try PropertyListSerialization.data(fromPropertyList: ["error": ["code": 401]], format: .binary, options: 0)
        #expect(throws: (any Error).self) { try AirPlayVideoState(data: failure) }
        let unsafe = try PropertyListSerialization.data(fromPropertyList: ["position": Double.nan, "duration": -1.0, "rate": Double.infinity], format: .binary, options: 0)
        let state = try AirPlayVideoState(data: unsafe)
        #expect(!state.ready && state.position == nil && state.duration == nil && state.rate == 0)
    }
}
