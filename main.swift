// mic-lock v2 — keep the default audio INPUT pinned to a device you choose,
// with a menu-bar UI, clamshell awareness, and a dead-mic warning.
//
// Event-driven (no polling): CoreAudio property listeners for default-input and
// device-list changes, plus screen-parameter changes to detect the lid opening
// or closing. Work happens only when something actually changes.
//
// Behaviour
//   * A "pin" names the device the default input is held at. Default pin is
//     .auto, which means: lid closed and an iPhone (Continuity) mic present ->
//     use the iPhone, because the built-in mic captures pure digital silence
//     in clamshell mode; otherwise use the built-in mic.
//   * Picking a non-Bluetooth device anywhere (System Settings, another app)
//     is adopted as the new pin, so manual choices stick.
//   * Bluetooth inputs are always bounced back: their HFP mode wrecks headphone
//     audio quality. They can still be pinned deliberately from the menu, but
//     that choice is never persisted and is dropped when the device goes away.
//   * If the pinned device disappears, the pin is remembered and the input
//     temporarily falls back; the device is re-pinned as soon as it returns.
//   * Bringing up an iPhone mic costs ~3.5s and a burst of 2.4GHz traffic that
//     stutters Bluetooth headphones. So once some app has paid that price we
//     hold the session open ourselves and only let it go after a long idle
//     stretch, on the bet that a voice feature used once is used again soon.

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import IOKit

// MARK: - Logging

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func describeDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    return s < 60 ? "\(s)s" : "\(s / 60)m\(s % 60 == 0 ? "" : "\(s % 60)s")"
}

func log(_ msg: String) {
    let line = "\(logFormatter.string(from: Date())) mic-lock: \(msg)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - CoreAudio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func getScalar<T>(_ obj: AudioObjectID, _ addr: inout AudioObjectPropertyAddress, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
}

func getString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let cf = cf else { return "" }
    return cf.takeRetainedValue() as String
}

func allDeviceIDs() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
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

func deviceIsHidden(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIsHidden,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var v: UInt32 = 0
    _ = getScalar(dev, &addr, &v)
    return v != 0
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

struct InputDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    // CoreAudio briefly publishes a private "CADefaultDeviceAggregate-<pid>-<n>"
    // device to back any engine that follows the default device — including our
    // own keep-warm engine. It is an implementation detail, so it must never be
    // listed or adopted as something to pin.
    var isPrivateAggregate: Bool {
        name.hasPrefix("CADefaultDeviceAggregate") || uid.hasPrefix("CADefaultDeviceAggregate")
    }
    // iPhone / iPad mic shared over Continuity Camera.
    var isContinuity: Bool {
        transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}

func inputDevices() -> [InputDevice] {
    allDeviceIDs()
        .filter { hasInput($0) && !deviceIsHidden($0) }
        .map {
            InputDevice(id: $0,
                        name: getString($0, kAudioObjectPropertyName),
                        uid: getString($0, kAudioDevicePropertyDeviceUID),
                        transport: transportType($0))
        }
        .filter { !$0.isPrivateAggregate }
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

// MARK: - Who is capturing

// macOS 14.4+ exposes one audio object per process, which is how we tell that
// somebody *else* started recording without having to hold the device open.
func audioProcessObjects() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &objs) == noErr else { return [] }
    return objs
}

func processPID(_ obj: AudioObjectID) -> pid_t {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var v: pid_t = -1
    _ = getScalar(obj, &addr, &v)
    return v
}

func processIsRunningInput(_ obj: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    _ = getScalar(obj, &addr, &v)
    return v != 0
}

func processName(_ obj: AudioObjectID) -> String {
    let pid = processPID(obj)
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, 4096) > 0 else { return "pid \(pid)" }
    return String(cString: buf).components(separatedBy: "/").last ?? "pid \(pid)"
}

// MARK: - Keep-warm

/// Holds an input stream open so a Continuity session stays established.
/// The captured samples are dropped on the floor; the point is purely to stop
/// the link from tearing down between uses.
final class KeepWarm {
    private var engine: AVAudioEngine?
    private var askedForAccess = false
    var isHolding: Bool { engine != nil }
    /// Called once the user answers the microphone prompt, so we can try again.
    var onAccessGranted: (() -> Void)?

    /// Holding the session means really opening the mic, which needs consent.
    /// Without it we would get a stream of zeros that keeps nothing alive.
    private func haveMicAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard !askedForAccess else { return false }
            askedForAccess = true
            log("keep-warm: asking for microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                log("keep-warm: microphone access \(granted ? "granted" : "denied")")
                if granted { DispatchQueue.main.async { self?.onAccessGranted?() } }
            }
            return false
        default:
            log("keep-warm: microphone access denied; cannot hold the session")
            return false
        }
    }

    @discardableResult
    func start() -> Bool {
        guard engine == nil else { return true }
        guard haveMicAccess() else { return false }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            log("keep-warm: no usable input format; not holding")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { _, _ in }
        do { try e.start() } catch {
            log("keep-warm: could not start engine: \(error.localizedDescription)")
            return false
        }
        engine = e
        return true
    }

    func stop() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }
}

// MARK: - Lid state

// True when the laptop lid is shut (clamshell mode on an external display).
// The built-in mic delivers pure silence in this state, so it must not be used.
func clamshellClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    guard let prop = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else { return false }
    return (prop as? Bool) ?? false
}

// MARK: - Pin state

enum Pin: Equatable {
    case auto            // follow the lid: clamshell -> iPhone, otherwise built-in
    case continuityMic   // whichever iPhone/iPad mic is currently shared
    case device(String)  // pinned to a specific device UID
}

// A Continuity session gets a fresh UID every time the phone reconnects, so
// that class of device is remembered by kind rather than by identity.
let continuityToken = "@continuity"

let defaultsKey = "pinnedDeviceUID"
let keepWarmKey = "keepWarmEnabled"
let keepWarmIdleKey = "keepWarmIdleSeconds"
// The launchd label, the preferences domain and the dispatch queue all follow
// the bundle identifier, so one source builds for any install prefix.
let agentLabel = Bundle.main.bundleIdentifier ?? "com.miclock"

// Preferences live in the app's own domain, so the standard suite is correct.
let store = UserDefaults.standard

func loadPin() -> Pin {
    guard let uid = store.string(forKey: defaultsKey), !uid.isEmpty else { return .auto }
    return uid == continuityToken ? .continuityMic : .device(uid)
}

// Bluetooth pins are deliberately not remembered across restarts.
func savePin(_ pin: Pin, devices: [InputDevice]) {
    switch pin {
    case .continuityMic:
        store.set(continuityToken, forKey: defaultsKey)
    case .device(let uid) where !(devices.first { $0.uid == uid }?.isBluetooth ?? false):
        store.set(uid, forKey: defaultsKey)
    default:
        store.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let queue = DispatchQueue(label: "\(agentLabel).events")
    private var pin: Pin = loadPin()
    private var paused = false
    // Set while we are the ones changing the device, so our own writes are not
    // mistaken for a manual selection and adopted as a new pin.
    private var applying = false

    private let keepWarm = KeepWarm()
    private var warmSince: Date?
    private var lastSawOthers = Date()
    private var idleWatch: DispatchSourceTimer?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var watchedDevice = AudioObjectID(0)
    private var keepWarmEnabled: Bool = (store.object(forKey: keepWarmKey) as? Bool) ?? true
    private var idleTimeout: TimeInterval = {
        let v = store.double(forKey: keepWarmIdleKey)
        return v > 0 ? v : 600   // ten minutes
    }()

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        enforce(reason: "startup")

        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &defAddr, queue) { [weak self] _, _ in
            DispatchQueue.main.async { self?.defaultInputChanged() }
        }

        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &devAddr, queue) { [weak self] _, _ in
            // Devices settle a moment after they appear.
            self?.queue.asyncAfter(deadline: .now() + 0.4) {
                DispatchQueue.main.async { self?.enforce(reason: "device list changed") }
            }
        }

        // Opening or closing the lid reconfigures the displays.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.enforce(reason: "screen layout changed")
                }
        }

        var procAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &procAddr, queue) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluateKeepWarm() }
        }
        evaluateKeepWarm()

        log("started; pin=\(describe(pin)), clamshell=\(clamshellClosed()), keep-warm=\(keepWarmEnabled)")
    }

    // MARK: Target resolution

    private func describe(_ pin: Pin) -> String {
        switch pin {
        case .auto: return "auto"
        case .continuityMic: return "continuity"
        case .device(let uid): return uid
        }
    }

    /// The device the input should currently sit on, and whether the explicit
    /// pin was unavailable and we fell back.
    private func resolveTarget(_ devices: [InputDevice]) -> (device: InputDevice?, fellBack: Bool) {
        if case .continuityMic = pin, let hit = devices.first(where: { $0.isContinuity }) {
            return (hit, false)
        }
        if case .device(let uid) = pin, let hit = devices.first(where: { $0.uid == uid }) {
            return (hit, false)
        }
        let explicitButMissing = pin != .auto
        // Auto rule: the built-in mic is deaf with the lid shut, so prefer iPhone.
        if clamshellClosed(), let iphone = devices.first(where: { $0.isContinuity }) {
            return (iphone, explicitButMissing)
        }
        return (devices.first { $0.isBuiltIn }, explicitButMissing)
    }

    /// The pinned device is present but cannot actually hear anything.
    private func targetIsDeaf(_ device: InputDevice?) -> Bool {
        guard let device = device else { return true }
        return device.isBuiltIn && clamshellClosed()
    }

    // MARK: Enforcement

    private func enforce(reason: String) {
        let devices = inputDevices()

        // A Bluetooth pin evaporates once the device leaves.
        if case .device(let uid) = pin,
           !devices.contains(where: { $0.uid == uid }),
           store.string(forKey: defaultsKey) == nil, pin != .auto {
            log("bluetooth pin '\(uid)' went away; back to auto")
            pin = .auto
        }

        let (target, fellBack) = resolveTarget(devices)
        guard let target = target else {
            log("no usable input device found (\(reason)); leaving input alone")
            refreshUI(devices: devices, target: nil)
            return
        }

        if paused {
            refreshUI(devices: devices, target: target)
            return
        }

        let current = currentDefaultInput()
        if current != target.id {
            let was = devices.first { $0.id == current }?.name ?? getString(current, kAudioObjectPropertyName)
            // The held engine is bound to the outgoing device; let it go first.
            releaseHold(reason: "input device changing")
            applying = true
            let ok = setDefaultInput(target.id)
            applying = false
            if ok {
                let note = fellBack ? " (pinned device absent, temporary)" : ""
                log("[\(reason)] input was '\(was)' -> '\(target.name)'\(note)")
            } else {
                log("[\(reason)] failed to set input to '\(target.name)'")
            }
        }
        refreshUI(devices: devices, target: target)
        evaluateKeepWarm()
    }

    /// Someone else moved the default input. Bounce Bluetooth, adopt anything else.
    private func defaultInputChanged() {
        guard !applying, !paused else { return }
        let devices = inputDevices()
        let current = currentDefaultInput()
        let (target, _) = resolveTarget(devices)

        if current == target?.id {
            refreshUI(devices: devices, target: target)
            return
        }
        guard let now = devices.first(where: { $0.id == current }) else {
            enforce(reason: "unknown device selected")
            return
        }
        if now.isPrivateAggregate {
            enforce(reason: "private aggregate device selected")
        } else if now.isBluetooth {
            enforce(reason: "bluetooth grabbed input")
        } else {
            // A manual pick worth honouring: make it the new pin.
            pin = now.isContinuity ? .continuityMic : .device(now.uid)
            savePin(pin, devices: devices)
            log("adopted manual selection '\(now.name)' as the pinned device")
            refreshUI(devices: devices, target: now)
        }
    }

    private func select(_ device: InputDevice) {
        pin = device.isContinuity ? .continuityMic : .device(device.uid)
        savePin(pin, devices: inputDevices())
        if device.isBluetooth { log("pinned bluetooth '\(device.name)' (not remembered)") }
        enforce(reason: "menu selection")
    }

    // MARK: Keep-warm

    /// Every process that is capturing input right now, ignoring our own hold.
    private func otherCapturers() -> [AudioObjectID] {
        let me = getpid()
        return audioProcessObjects().filter { processIsRunningInput($0) && processPID($0) != me }
    }

    /// Follow kAudioDevicePropertyDeviceIsRunningSomewhere on whichever device
    /// we are pinning. Per-process IsRunningInput listeners register cleanly but
    /// never actually fire, so this is the signal that an app opened the mic.
    private func watchRunningState(of device: AudioObjectID) {
        guard device != watchedDevice else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if let old = runningListener, watchedDevice != 0 {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, queue, old)
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluateKeepWarm() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, queue, block) == noErr {
            runningListener = block
            watchedDevice = device
        }
    }

    /// Hold the session while anything is capturing, and for a good while after.
    private func evaluateKeepWarm() {
        let target = resolveTarget(inputDevices()).device

        // Only Continuity sessions are expensive enough to be worth holding.
        guard keepWarmEnabled, !paused, let target = target, target.isContinuity else {
            releaseHold(reason: "not applicable")
            return
        }
        watchRunningState(of: target.id)

        let others = otherCapturers()
        guard !others.isEmpty else { return }

        lastSawOthers = Date()
        if !keepWarm.isHolding {
            keepWarm.onAccessGranted = { [weak self] in self?.evaluateKeepWarm() }
            if keepWarm.start() {
                warmSince = Date()
                let who = others.map(processName).joined(separator: ", ")
                log("keep-warm: holding '\(target.name)' (\(who) started capturing)")
                startIdleWatch()
                refreshUI(devices: inputDevices(), target: target)
            }
        }
    }

    /// Only runs while we are holding: once we occupy the device its
    /// IsRunningSomewhere flag is pinned at 1 and stops telling us anything.
    private func startIdleWatch() {
        guard idleWatch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.keepWarm.isHolding else { self.stopIdleWatch(); return }
            if !self.otherCapturers().isEmpty {
                self.lastSawOthers = Date()
                return
            }
            let idle = Date().timeIntervalSince(self.lastSawOthers)
            if idle >= self.idleTimeout {
                self.releaseHold(reason: "unused for \(describeDuration(idle))")
            }
        }
        timer.resume()
        idleWatch = timer
    }

    private func stopIdleWatch() {
        idleWatch?.cancel()
        idleWatch = nil
    }

    private func releaseHold(reason: String) {
        stopIdleWatch()
        guard keepWarm.isHolding else { return }
        keepWarm.stop()
        warmSince = nil
        log("keep-warm: released (\(reason))")
        refreshUI(devices: inputDevices(), target: resolveTarget(inputDevices()).device)
    }

    // MARK: UI

    private func refreshUI(devices: [InputDevice], target: InputDevice?) {
        guard let button = statusItem.button else { return }
        let deaf = targetIsDeaf(target)
        let symbol = paused ? "mic.slash" : (deaf ? "exclamationmark.triangle.fill" : "mic.fill")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mic-lock")
        button.image?.isTemplate = !deaf || paused
        button.contentTintColor = (deaf && !paused) ? .systemRed : nil
        var tip = paused ? "mic-lock：已暂停"
                         : "mic-lock：\(target?.name ?? "无可用设备")" + (deaf ? "（合盖，收不到声音）" : "")
        if keepWarm.isHolding { tip += "\n会话保活中（下次唤起约 0.4 秒）" }
        button.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = inputDevices()
        let (target, fellBack) = resolveTarget(devices)
        let deaf = targetIsDeaf(target)

        let header = NSMenuItem(title: "当前输入：\(target?.name ?? "无")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if deaf {
            let warn = NSMenuItem(title: "⚠️ 合盖状态，内置麦收不到声音", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        if fellBack {
            let fb = NSMenuItem(title: "↩︎ 锁定的设备不在，已临时回落", action: nil, keyEquivalent: "")
            fb.isEnabled = false
            menu.addItem(fb)
        }
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "自动（跟随盖子状态）",
                              action: #selector(pickAuto), keyEquivalent: "")
        auto.target = self
        auto.state = (pin == .auto) ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        for device in devices {
            let tag: String
            if device.isBuiltIn { tag = "内置" }
            else if device.isContinuity { tag = "Continuity" }
            else if device.isBluetooth { tag = "蓝牙・不记忆" }
            else { tag = "外接" }
            let item = NSMenuItem(title: "\(device.name)  —  \(tag)",
                                  action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            let pinned = device.isContinuity ? (pin == .continuityMic) : (pin == .device(device.uid))
            item.state = pinned ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let warmTitle: String
        if !keepWarmEnabled {
            warmTitle = "会话保活：已关闭"
        } else if keepWarm.isHolding {
            let held = Date().timeIntervalSince(warmSince ?? Date())
            warmTitle = "会话保活：保持中（已 \(describeDuration(held))）"
        } else if target?.isContinuity == true {
            warmTitle = "会话保活：待命（首次唤起后启动）"
        } else {
            warmTitle = "会话保活：当前设备无需保活"
        }
        let warmStatus = NSMenuItem(title: warmTitle, action: nil, keyEquivalent: "")
        warmStatus.isEnabled = false
        menu.addItem(warmStatus)

        let warmToggle = NSMenuItem(title: keepWarmEnabled ? "关闭会话保活" : "开启会话保活",
                                    action: #selector(toggleKeepWarm), keyEquivalent: "")
        warmToggle.target = self
        menu.addItem(warmToggle)

        menu.addItem(.separator())
        let pauseItem = NSMenuItem(title: paused ? "恢复锁定" : "暂停锁定",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let settings = NSMenuItem(title: "打开声音设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出（下次登录恢复）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func pickAuto() {
        pin = .auto
        savePin(pin, devices: inputDevices())
        enforce(reason: "menu: auto")
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let device = inputDevices().first(where: { $0.uid == uid }) else { return }
        select(device)
    }

    @objc private func toggleKeepWarm() {
        keepWarmEnabled.toggle()
        store.set(keepWarmEnabled, forKey: keepWarmKey)
        log("keep-warm: \(keepWarmEnabled ? "enabled" : "disabled")")
        if keepWarmEnabled { evaluateKeepWarm() } else { releaseHold(reason: "disabled") }
    }

    @objc private func togglePause() {
        paused.toggle()
        log(paused ? "paused" : "resumed")
        if paused {
            releaseHold(reason: "paused")
            refreshUI(devices: inputDevices(), target: resolveTarget(inputDevices()).device)
        } else {
            enforce(reason: "resumed")
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    // Unload the launchd job too, otherwise KeepAlive restarts us immediately.
    @objc private func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no Cmd-Tab
let controller = Controller()
controller.start()
app.run()
