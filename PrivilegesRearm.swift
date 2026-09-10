// PrivilegesRearm — re-arm SAP Privileges admin the moment it expires.
//
// Opens the request dialog, selects "Developer Requirement" from the reason
// dropdown, and clicks Request Privileges. It stops there: macOS asks for your
// fingerprint, and only you can supply that. This tool cannot complete an
// elevation on its own.
//
// Everything (window lookup + clicking) happens in THIS process, so macOS has
// exactly one binary to authorize for Accessibility.
//
// Build:
//   swiftc -O -o PrivilegesRearm PrivilegesRearm.swift \
//       -framework CoreGraphics -framework ApplicationServices
//
// Modes: --setup (ask for Accessibility), --status, --now, --dry, (no args) = edge detect

import Foundation
import CoreGraphics
import ApplicationServices
import Security

let appName       = "PrivilegesRearm"
let bundleID      = "com.camurphy.privileges-rearm"
let targetReason  = "Developer Requirement"
let privilegesApp = "/Applications/Privileges.app"
let profilePath   = "/Library/Managed Preferences/corp.sap.privileges.plist"

// Control positions as fractions of the dialog frame (measured from the real dialog).
let popupXF:  CGFloat = 0.25, popupYF:  CGFloat = 0.488
let buttonXF: CGFloat = 0.50, buttonYF: CGFloat = 0.78

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/privileges-rearm")
let stateFile = stateDir.appendingPathComponent("last_state")
let logFile   = stateDir.appendingPathComponent("rearm.log")

/// Log to stdout and to a file, because launchd discards stdout by default and
/// a silent background failure is impossible to diagnose otherwise.
func log(_ s: String) {
    print(s)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let d = "\(stamp)  \(s)\n".data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(d); try? h.close()
    } else {
        try? d.write(to: logFile)
    }
}

// MARK: - admin membership

func isAdmin() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/dseditgroup")
    p.arguments = ["-o", "checkmember", "-m", NSUserName(), "admin"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError  = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - window lookup (no accessibility needed for bounds)

func privilegesWindows() -> [[String: Any]] {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.filter { (($0[kCGWindowOwnerName as String] as? String) ?? "").contains("Privileges") }
}

func frame(_ w: [String: Any]) -> CGRect? {
    guard let d = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: d)
}

/// The alert panel: layer 0, taller than wide, largest such window.
func dialogBounds() -> CGRect? {
    var best: CGRect?
    for w in privilegesWindows() {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
        guard layer == 0, let r = frame(w), r.height > r.width else { continue }
        if best == nil || r.width * r.height > best!.width * best!.height { best = r }
    }
    return best
}

/// The open popup menu: highest layer above 0.
func menuBounds() -> CGRect? {
    var best: CGRect?
    var bestLayer = 0
    for w in privilegesWindows() {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
        guard layer > 0, let r = frame(w) else { continue }
        if best == nil || layer > bestLayer { best = r; bestLayer = layer }
    }
    return best
}

func waitFor(_ probe: () -> CGRect?, timeout: Double) -> CGRect? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let r = probe() { return r }
        usleep(150_000)
    }
    return nil
}

// MARK: - clicking

func click(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// MARK: - reason row, derived from the managed profile

/// Menu rows are the profile's presets in order, then "Other...".
func reasonLayout() -> (index: Int, count: Int) {
    if let d = NSDictionary(contentsOfFile: profilePath),
       let presets = d["ReasonPresetList"] as? [[String: Any]] {
        for (i, entry) in presets.enumerated() where (entry["default"] as? String) == targetReason {
            return (i, presets.count + 1)
        }
    }
    return (2, 4)
}

// MARK: - the request

@discardableResult
func request(dry: Bool) -> Int32 {
    if isAdmin() { log("already admin — nothing to do"); return 0 }
    guard AXIsProcessTrusted() else {
        log("Accessibility not granted for this binary — run: PrivilegesRearm --setup")
        return 2
    }

    let op = Process()
    op.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    op.arguments = ["-a", privilegesApp]
    try? op.run()
    op.waitUntilExit()

    guard let d = waitFor(dialogBounds, timeout: 8) else {
        log("request dialog did not appear"); return 1
    }

    let (idx, count) = reasonLayout()

    // open the reason dropdown
    click(CGPoint(x: d.minX + d.width * popupXF, y: d.minY + d.height * popupYF))
    guard let m = waitFor(menuBounds, timeout: 3) else {
        log("reason menu did not open"); return 1
    }

    // click the target row, positioned from the menu's real frame
    let rowY = m.minY + m.height * ((CGFloat(idx) + 0.5) / CGFloat(count))
    click(CGPoint(x: m.midX, y: rowY))
    usleep(350_000)

    if dry { log("dry run — '\(targetReason)' selected, NOT submitted"); return 0 }

    click(CGPoint(x: d.minX + d.width * buttonXF, y: d.minY + d.height * buttonYF))
    log("submitted — authenticate with Touch ID to finish")
    return 0
}

// MARK: - self install

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError  = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Resolve App Translocation back to the real file on disk.
///
/// Launching a quarantined app from somewhere like ~/Downloads does not run it
/// in place: macOS mounts a read-only randomized copy under AppTranslocation
/// and runs that. Bundle.main.bundleURL then points at an ephemeral mount with
/// no Trash, so cleaning up needs the original path instead.
/// The SecTranslocate functions are C-only in the SDK and aren't visible to
/// Swift through `import Security`, so bind them at runtime.
private typealias IsTranslocatedFn =
    @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutableRawPointer?) -> Bool
private typealias OriginalPathFn =
    @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?

func originalPath(of url: URL) -> URL {
    let looksTranslocated = url.path.contains("/AppTranslocation/")
    guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let isSym   = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
          let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
    else {
        if looksTranslocated { log("running translocated but SecTranslocate is unavailable") }
        return url
    }
    let isTranslocated = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
    let createOriginal = unsafeBitCast(origSym, to: OriginalPathFn.self)

    var flag: DarwinBoolean = false
    guard isTranslocated(url as CFURL, &flag, nil), flag.boolValue,
          let original = createOriginal(url as CFURL, nil)
    else {
        if looksTranslocated { log("could not resolve the translocated path back to the original") }
        return url
    }
    return original.takeRetainedValue() as URL
}

/// True if the item carries com.apple.quarantine, i.e. it was downloaded rather
/// than built here. Used to tell a throwaway copy from a real working one.
func isQuarantined(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

/// Trash the copy the user launched, once it has been installed elsewhere.
/// Only for downloaded copies: a locally built bundle has no quarantine flag,
/// so `make install` never deletes your build output. Trash rather than delete,
/// so it is recoverable. Moving the bundle is safe while running from it; the
/// process keeps its already-open executable.
func cleanUpSource(_ source: URL) {
    guard isQuarantined(source) else {
        log("left \(source.path) alone (not a downloaded copy)")
        return
    }
    var resulting: NSURL?
    do {
        try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
        let landed = (resulting as URL?)?.path ?? "the Trash"
        log("moved the downloaded copy to the Trash: \(source.path) -> \(landed)")
    } catch {
        log("could not trash \(source.path): \(error)")
    }
}

/// Copy ourselves to ~/Applications, write and load the LaunchAgent, then ask
/// for Accessibility. This is what happens when the app is simply opened, so
/// installing needs no Makefile, no Xcode, and no terminal.
func installSelf() -> Int32 {
    let fm   = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let dest = home.appendingPathComponent("Applications/\(appName).app")
    // Where we are actually executing, which may be a translocated mount, and
    // where that really lives on disk. Copy from the former (always readable);
    // clean up the latter (the file the user can actually see).
    let running = Bundle.main.bundleURL
    let me = originalPath(of: running)
    if me != running { log("running translocated; real path is \(me.path)") }
    let copied = me.standardizedFileURL != dest.standardizedFileURL

    if copied {
        try? fm.createDirectory(at: home.appendingPathComponent("Applications"),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: running, to: dest) }
        catch { log("could not install to \(dest.path): \(error)"); return 1 }
        log("installed to \(dest.path)")
    }

    let exe = dest.appendingPathComponent("Contents/MacOS/\(appName)").path
    let agentPlist: [String: Any] = [
        "Label": bundleID,
        "ProgramArguments": [exe, "--watch"],
        "StartInterval": 15,
        "RunAtLoad": true,
        "StandardOutPath": "/tmp/privileges-rearm.out",
        "StandardErrorPath": "/tmp/privileges-rearm.err",
    ]
    let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
    try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    let plistURL = agentsDir.appendingPathComponent("\(bundleID).plist")
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: agentPlist, format: .xml, options: 0) else {
        log("could not build the LaunchAgent plist"); return 1
    }
    do { try data.write(to: plistURL) }
    catch { log("could not write \(plistURL.path): \(error)"); return 1 }

    let uid = getuid()
    run("/bin/launchctl", ["bootout", "gui/\(uid)", plistURL.path])
    let rc = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
    log(rc == 0 ? "LaunchAgent loaded, checking every 15s"
                : "launchctl bootstrap failed (\(rc))")

    // Raise the prompt from the installed copy, so what you approve is the
    // thing launchd will actually run.
    if copied {
        // Do everything before launching the installed copy. When we are running
        // translocated, launching it can tear down the read-only mount we are
        // executing from, killing this process the moment it faults in more code.
        cleanUpSource(me)
        log("finishing setup from \(dest.path)")
        run("/usr/bin/open", ["-a", dest.path, "--args", "--setup"])
        return 0
    }
    return requestAccessibility()
}

func requestAccessibility() -> Int32 {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) {
        log("Accessibility already granted — setup complete")
    } else {
        log("approve \(appName) in System Settings > Privacy & Security > Accessibility")
    }
    return 0
}

// MARK: - edge detection

func edgeDetect() {
    let now  = isAdmin() ? "admin" : "standard"
    let prev = (try? String(contentsOf: stateFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    try? now.write(to: stateFile, atomically: true, encoding: .utf8)
    if prev == "admin" && now == "standard" {
        log("edge detected (admin -> standard), accessibility=\(AXIsProcessTrusted())")
        exit(request(dry: false))
    }
}

// MARK: - main

try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

switch CommandLine.arguments.dropFirst().first {

case "--setup":
    exit(requestAccessibility())

case "--status":
    log("admin: \(isAdmin())   accessibility: \(AXIsProcessTrusted())")

case "--now":
    exit(request(dry: false))

case "--dry":
    exit(request(dry: true))

case "--watch":
    // What the LaunchAgent runs: fire only on the admin -> standard edge.
    edgeDetect()

case nil, "--install":
    // Opening the app (double-click, or `open -a`) installs it.
    exit(installSelf())

case .some(let other):
    log("unknown option: \(other)")
    exit(64)
}
