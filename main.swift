// mic-lock — keep the default audio INPUT pinned to the Mac's built-in mic.
//
// Event-driven (no polling): registers CoreAudio property listeners and only
// does work when the system's default input device or device list changes.
// On any such change, if the default input drifted off the built-in mic
// (e.g. AirPods connected and grabbed it), it switches it right back.
//
// By default the "built-in mic" is found by hardware transport type, so this
// keeps working across different Macs. Pass a device name as argv[1] to pin a
// specific device by name instead.

import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

// Optional: pin a device by exact name instead of "the built-in one".
let nameOverride: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

func getScalar<T>(_ obj: AudioObjectID, _ addr: inout AudioObjectPropertyAddress, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var devices = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

// Does this device expose any input channels?
func hasInput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var channels: UInt32 = 0
    for buf in abl { channels += buf.mNumberChannels }
    return channels > 0
}

func transportType(_ dev: AudioObjectID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    _ = getScalar(dev, &addr, &t)
    return t
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf) == noErr, let cf = cf else { return "" }
    return cf.takeRetainedValue() as String
}

func targetDevice() -> AudioObjectID? {
    let inputs = allDevices().filter { hasInput($0) }
    if let name = nameOverride {
        return inputs.first { deviceName($0) == name }
    }
    return inputs.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

func currentDefaultInput() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    _ = getScalar(systemObject, &addr, &dev)
    return dev
}

@discardableResult
func setDefaultInput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
}

func log(_ msg: String) {
    FileHandle.standardError.write("mic-lock: \(msg)\n".data(using: .utf8)!)
}

func enforce() {
    guard let target = targetDevice() else {
        log("no built-in input device found; skipping")
        return
    }
    let current = currentDefaultInput()
    if current != target {
        if setDefaultInput(target) {
            log("input was '\(deviceName(current))' -> reset to '\(deviceName(target))'")
        } else {
            log("failed to reset input to '\(deviceName(target))'")
        }
    }
}

// Pin immediately on launch.
enforce()

let queue = DispatchQueue(label: "com.miclock")

// Fires the instant the system default input device changes.
var defAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
_ = AudioObjectAddPropertyListenerBlock(systemObject, &defAddr, queue) { _, _ in enforce() }

// Backup: fires when devices appear/disappear (e.g. AirPods connecting).
var devAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
_ = AudioObjectAddPropertyListenerBlock(systemObject, &devAddr, queue) { _, _ in
    queue.asyncAfter(deadline: .now() + 0.4) { enforce() }
}

log("started; pinning built-in input")
RunLoop.main.run()
