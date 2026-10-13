import Cocoa
import CoreMIDI
import CoreGraphics

// Matches MidiKeyboardProtocol.luau and the Windows companion exactly.
func packetKeys(_ kind: Int, _ channel: Int, _ note: Int, _ value: Int) -> [Int] {
    let digits = [kind, channel / 12, channel % 12, note / 12, note % 12, value / 12, value % 12]
    let checksum = digits.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element } % 12
    return [13] + digits.map { $0 + 1 } + [checksum + 1, 15]
}
let functionKeys: [CGKeyCode] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113]

final class Companion: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let devices = NSPopUpButton(frame: .zero)
    let curves = NSPopUpButton(frame: .zero)
    let armed = NSButton(checkboxWithTitle: "Send to Piano Party", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "Stopped")
    let queue = DispatchQueue(label: "piano-party-midi-send", qos: .userInteractive)
    var client: MIDIClientRef = 0
    var port: MIDIPortRef = 0
    var source: MIDIEndpointRef = 0
    var sources: [MIDIEndpointRef] = []
    // The following state is owned by the serial sending queue.
    var enabled = false
    var curve = 0
    var running: UInt8 = 0
    var pending: [UInt8] = []
    var sysex = false
    var received = 0
    var sent = 0
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Piano Party MIDI — prototype"
        window.backgroundColor = NSColor(calibratedRed: 10/255, green: 13/255, blue: 18/255, alpha: 1)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        let title = NSTextField(labelWithString: "Piano Party MIDI"); title.font = .boldSystemFont(ofSize: 26); title.textColor = NSColor(calibratedRed: 231/255, green: 186/255, blue: 116/255, alpha: 1)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(labelWithString: "MIDI input device")); stack.addArrangedSubview(devices)
        devices.target = self; devices.action = #selector(openDevice)
        let refresh = NSButton(title: "Refresh devices", target: self, action: #selector(refreshDevices)); stack.addArrangedSubview(refresh)
        stack.addArrangedSubview(NSTextField(labelWithString: "Velocity curve")); curves.addItems(withTitles: ["Linear", "Softer touch", "Harder touch"]); curves.target = self; curves.action = #selector(changeCurve); stack.addArrangedSubview(curves)
        armed.target = self; armed.action = #selector(changeArmed); stack.addArrangedSubview(armed)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSButton(title: "Stop / release notes", target: self, action: #selector(stop)))
        stack.addArrangedSubview(NSButton(title: "Test C4 in 3 seconds", target: self, action: #selector(testNote)))
        stack.addArrangedSubview(NSButton(title: "Allow keyboard events", target: self, action: #selector(accessibility)))
        let help = NSTextField(wrappingLabelWithString: "Select MIDI in the game's Layout menu, enable sending, then focus Roblox. macOS requires Accessibility permission for this app."); help.textColor = .secondaryLabelColor; stack.addArrangedSubview(help)
        MIDIClientCreate("Piano Party MIDI" as CFString, nil, nil, &client)
        let result = MIDIInputPortCreate(client, "Keyboard Input" as CFString, { list, context, _ in
            guard let context = context else { return }
            let owner = Unmanaged<Companion>.fromOpaque(context).takeUnretainedValue()
            let offset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
            var packet = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<list.pointee.numPackets {
                let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
                let bytes = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                let data = Array(UnsafeBufferPointer(start: bytes, count: Int(packet.pointee.length)))
                let receivedAt = ProcessInfo.processInfo.systemUptime
                owner.queue.async {
                    if ProcessInfo.processInfo.systemUptime - receivedAt > 0.1 { owner.send(4,0,0,0); return }
                    owner.read(data)
                }
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &port)
        if result != noErr { status.stringValue = "CoreMIDI could not open (error \(result))." }
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                if self.enabled { self.send(5,0,0,0) }
                let text = "\(self.enabled ? (self.robloxFocused() ? "Sending to Roblox" : "Armed — focus Roblox") : "Stopped")\nMIDI messages: \(self.received) · Packets sent: \(self.sent)"
                DispatchQueue.main.async { self.status.stringValue = text }
            }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func robloxFocused() -> Bool {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ["com.roblox.Roblox", "com.roblox.RobloxPlayer", "com.roblox.RobloxStudio"].contains(bundle)
    }
    func send(_ kind: Int, _ channel: Int, _ note: Int, _ value: Int) {
        guard robloxFocused(), AXIsProcessTrusted() else { return }
        if kind != 4 && !enabled { return }
        for key in packetKeys(kind,channel,note,value) {
            let code = functionKeys[key-1]
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
            down.flags = []; up.flags = []; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
        sent += 1
    }
    func read(_ bytes: [UInt8]) {
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte == 0xF0 { sysex = true; running = 0; pending = []; continue }
            if byte == 0xF7 { sysex = false; continue }
            if sysex { continue }
            if byte >= 0x80 { running = byte < 0xF0 ? byte : 0; pending = []; continue }
            if running == 0 { continue }
            pending.append(byte)
            let type = running & 0xF0
            let length = type == 0xC0 || type == 0xD0 ? 1 : 2
            if pending.count < length { continue }
            let a = Int(pending[0]); let b = length == 2 ? Int(pending[1]) : 0; let channel = Int(running & 15)
            received += 1; pending = []
            if !enabled { continue }
            if type == 0x90 && a >= 21 && a <= 108 {
                let exponent = curve == 1 ? 0.7 : curve == 2 ? 1.4 : 1.0
                let velocity = b == 0 ? 0 : max(1,min(127,Int((pow(Double(b)/127,exponent)*127).rounded())))
                send(b == 0 ? 1 : 0,channel,a,velocity)
            } else if type == 0x80 && a >= 21 && a <= 108 { send(1,channel,a,0)
            } else if type == 0xB0 {
                if a == 64 { send(2,channel,0,b) } else if a == 67 { send(3,channel,0,b) } else if a == 120 || a == 123 { send(4,0,0,0) }
            }
        }
    }
    @objc func refreshDevices() {
        stop()
        if source != 0 { MIDIPortDisconnectSource(port,source); source = 0 }
        devices.removeAllItems(); sources = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index); var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&name)
            sources.append(endpoint); devices.addItem(withTitle: name?.takeRetainedValue() as String? ?? "MIDI input \(index+1)")
        }
        if !sources.isEmpty { devices.selectItem(at: 0); openDevice() }
    }
    @objc func openDevice() {
        stop()
        if source != 0 { MIDIPortDisconnectSource(port,source) }
        let index = devices.indexOfSelectedItem
        guard index >= 0 && index < sources.count else { return }
        source = sources[index]; let result = MIDIPortConnectSource(port,source,nil)
        if result != noErr { status.stringValue = "Could not connect MIDI source (\(result))." }
        queue.async { self.running = 0; self.pending = [] }
    }
    @objc func changeArmed() { let value = armed.state == .on; queue.async { self.enabled = value; if !value { self.send(4,0,0,0) } } }
    @objc func changeCurve() { let value = curves.indexOfSelectedItem; queue.async { self.curve = value } }
    @objc func stop() { armed.state = .off; queue.async { self.enabled = false; self.send(4,0,0,0) } }
    @objc func accessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    @objc func testNote() {
        queue.asyncAfter(deadline: .now()+3) { self.send(0,0,60,40) }
        queue.asyncAfter(deadline: .now()+3.35) { self.send(1,0,60,0) }
        queue.asyncAfter(deadline: .now()+3.7) { self.send(0,0,60,115) }
        queue.asyncAfter(deadline: .now()+4.05) { self.send(1,0,60,0) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); queue.sync { self.enabled = false; self.send(4,0,0,0) }
        if port != 0 { MIDIPortDispose(port) }; if client != 0 { MIDIClientDispose(client) }
    }
}
let app = NSApplication.shared
let delegate = Companion()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
