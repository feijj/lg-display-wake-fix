// lgwakefix — re-initialises an external display after it wakes from sleep.
//
// Works around monitors (here: LG 32UN880 on macOS 27) that light the backlight
// on wake but show no picture until they are power-cycled. On every display wake
// the helper forces a new mode-set, which makes the Mac renegotiate the video link.
//
// Usage:
//   lgwakefix status                 show displays, current mode and DisplayPort link state
//   lgwakefix modes                  list every mode of the target display(s)
//   lgwakefix reinit [--method M]    re-initialise now (M = refresh | resolution | sleepwake)
//   lgwakefix daemon [options]       stay running and re-initialise after each display wake
//
// Options:
//   --method M       re-init method (default: refresh)
//   --delay S        seconds to wait after wake before re-initialising (default: 3)
//   --hold S         seconds to stay on the temporary mode (default: 2)
//   --min-sleep S    skip the re-init when the display slept for less than S seconds (default: 0)
//   --all            act on every external display, not only LG ones

import AppKit
import CoreGraphics
import Foundation
import IOKit

let lgVendorID: UInt32 = 0x1E6D  // "GSM" in EDID

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/lgwakefix.log")

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// MARK: - Options

struct Options {
    var method = "refresh"
    var delay = 3.0
    var hold = 2.0
    var minSleep = 0.0
    var allDisplays = false
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var index = 0
    func value() -> String {
        index += 1
        guard index < args.count else {
            FileHandle.standardError.write("missing value for \(args[index - 1])\n".data(using: .utf8)!)
            exit(2)
        }
        return args[index]
    }
    while index < args.count {
        switch args[index] {
        case "--method": options.method = value()
        case "--delay": options.delay = Double(value()) ?? options.delay
        case "--hold": options.hold = Double(value()) ?? options.hold
        case "--min-sleep": options.minSleep = Double(value()) ?? options.minSleep
        case "--all": options.allDisplays = true
        default:
            FileHandle.standardError.write("unknown option \(args[index])\n".data(using: .utf8)!)
            exit(2)
        }
        index += 1
    }
    return options
}

// MARK: - Displays and modes

func targetDisplays(_ options: Options) -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).filter { id in
        if CGDisplayIsBuiltin(id) != 0 { return false }
        return options.allDisplays || CGDisplayVendorNumber(id) == lgVendorID
    }
}

func allModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
}

func describe(_ mode: CGDisplayMode) -> String {
    let hidpi = mode.pixelWidth > mode.width ? " HiDPI" : ""
    return "\(mode.width)x\(mode.height) (\(mode.pixelWidth)x\(mode.pixelHeight) px)\(hidpi) @ \(String(format: "%.2f", mode.refreshRate)) Hz"
}

func setMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    // .forSession: nothing is written to the saved display preferences.
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

/// Same picture size, different refresh rate — forces new link timing without moving windows.
func refreshAlternate(for current: CGDisplayMode, in modes: [CGDisplayMode]) -> CGDisplayMode? {
    modes
        .filter {
            $0.width == current.width && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
                && abs($0.refreshRate - current.refreshRate) > 0.5
                && $0.isUsableForDesktopGUI()
        }
        .min { abs($0.refreshRate - 30) < abs($1.refreshRate - 30) }
}

/// A plain 1080p-class mode as a second way to force a different timing.
func resolutionAlternate(for current: CGDisplayMode, in modes: [CGDisplayMode]) -> CGDisplayMode? {
    let candidates = modes.filter {
        $0.isUsableForDesktopGUI()
            && ($0.pixelWidth != current.pixelWidth || $0.pixelHeight != current.pixelHeight)
    }
    return candidates.first { $0.pixelWidth == 1920 && $0.pixelHeight == 1080 && $0.width == 1920 }
        ?? candidates.first { $0.pixelWidth == 1920 && $0.pixelHeight == 1080 }
        ?? candidates.first
}

// MARK: - DisplayPort link state (read-only, for the log)

func linkSummary() -> String {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("IOPortTransportStateDisplayPort")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return "link: unavailable"
    }
    defer { IOObjectRelease(iterator) }
    var parts: [String] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { continue }
        let sinks = props["SinkCount"] as? Int ?? 0
        let active = props["Active"] as? Bool ?? false
        if sinks == 0 && !active { continue }  // unused port
        let name = props["ProductName"] as? String ?? "?"
        let rate = props["LinkRateDescription"] as? String ?? "?"
        let lanes = props["LaneCount"] as? Int ?? 0
        let hpd = props["HPD_StateDescription"] as? String ?? "?"
        parts.append("\(name): active=\(active) rate=\(rate) lanes=\(lanes) hpd=\(hpd) sinks=\(sinks)")
    }
    return parts.isEmpty ? "link: no active DisplayPort sink" : "link: " + parts.joined(separator: " | ")
}

// MARK: - Re-initialisation

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

func reinit(_ options: Options) {
    log("reinit start (method=\(options.method)) — \(linkSummary())")

    if options.method == "sleepwake" {
        run("/usr/bin/pmset", ["displaysleepnow"])
        Thread.sleep(forTimeInterval: options.hold)
        run("/usr/bin/caffeinate", ["-u", "-t", "1"])
        log("reinit done — \(linkSummary())")
        return
    }

    let displays = targetDisplays(options)
    if displays.isEmpty { log("no matching external display online") }
    for display in displays {
        guard let current = CGDisplayCopyDisplayMode(display) else {
            log("display \(display): cannot read current mode")
            continue
        }
        let modes = allModes(display)
        let alternate = options.method == "resolution"
            ? resolutionAlternate(for: current, in: modes)
            : (refreshAlternate(for: current, in: modes) ?? resolutionAlternate(for: current, in: modes))
        guard let alternate else {
            log("display \(display): no alternate mode available")
            continue
        }
        log("display \(display): \(describe(current)) -> \(describe(alternate))")
        if !setMode(display, alternate) { log("display \(display): switching to alternate mode failed") }
        Thread.sleep(forTimeInterval: options.hold)
        let restored = setMode(display, current)
        log("display \(display): restored \(describe(current)) ok=\(restored)")
    }
    log("reinit done — \(linkSummary())")
}

// MARK: - Daemon

final class WakeWatcher {
    let options: Options
    var sleptAt: Date?
    var busyUntil = Date.distantPast

    init(_ options: Options) { self.options = options }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            if Date() < self.busyUntil { return }
            self.sleptAt = Date()
            log("display sleep")
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            self.woke("display wake")
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            self.woke("system wake")
        }
        log("daemon started (method=\(options.method) delay=\(options.delay)s hold=\(options.hold)s min-sleep=\(options.minSleep)s)")
    }

    func woke(_ reason: String) {
        if Date() < busyUntil { return }  // our own re-init, or a duplicate notification
        let slept = sleptAt.map { Date().timeIntervalSince($0) }
        sleptAt = nil
        let sleptText = slept.map { String(format: "%.0fs", $0) } ?? "unknown"
        if let slept, slept < options.minSleep {
            log("\(reason) after \(sleptText) — shorter than min-sleep, skipping")
            return
        }
        log("\(reason) after \(sleptText) — re-initialising in \(options.delay)s")
        busyUntil = Date().addingTimeInterval(options.delay + options.hold + 20)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.delay) {
            reinit(self.options)
            // Just long enough to drop notifications queued up by the re-init itself.
            self.busyUntil = Date().addingTimeInterval(2)
        }
    }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"
let options = parseOptions(Array(arguments.dropFirst()))

switch command {
case "status":
    print(linkSummary())
    for display in targetDisplays(options) {
        let mode = CGDisplayCopyDisplayMode(display).map(describe) ?? "?"
        print("display \(display): vendor=0x\(String(CGDisplayVendorNumber(display), radix: 16)) model=\(CGDisplayModelNumber(display)) asleep=\(CGDisplayIsAsleep(display) != 0) mode=\(mode)")
    }
case "modes":
    for display in targetDisplays(options) {
        print("display \(display):")
        let current = CGDisplayCopyDisplayMode(display)
        for mode in allModes(display) where mode.isUsableForDesktopGUI() {
            print("  \(mode.ioDisplayModeID == current?.ioDisplayModeID ? "*" : " ") \(describe(mode))")
        }
    }
case "reinit":
    reinit(options)
case "daemon":
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let watcher = WakeWatcher(options)
    watcher.start()
    app.run()
default:
    print("usage: lgwakefix status | modes | reinit | daemon  [--method refresh|resolution|sleepwake] [--delay S] [--hold S] [--min-sleep S] [--all]")
    exit(2)
}
