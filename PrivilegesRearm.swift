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

let targetReason  = "Developer Requirement"
let privilegesApp = "/Applications/Privileges.app"
let profilePath   = "/Library/Managed Preferences/corp.sap.privileges.plist"

// Control positions as fractions of the dialog frame (measured from the real dialog).
let popupXF:  CGFloat = 0.25, popupYF:  CGFloat = 0.488
let buttonXF: CGFloat = 0.50, buttonYF: CGFloat = 0.78

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/privileges-rearm")
let stateFile = stateDir.appendingPathComponent("last_state")

func log(_ s: String) { print(s) }

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

// MARK: - main

try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

switch CommandLine.arguments.dropFirst().first {

case "--setup":
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) {
        log("Accessibility already granted")
    } else {
        log("Approve PrivilegesRearm in the dialog, or in System Settings > Privacy & Security > Accessibility")
    }

case "--status":
    log("admin: \(isAdmin())   accessibility: \(AXIsProcessTrusted())")

case "--now":
    exit(request(dry: false))

case "--dry":
    exit(request(dry: true))

default:
    // Fire only on the admin -> standard edge: the moment access is lost.
    let now  = isAdmin() ? "admin" : "standard"
    let prev = (try? String(contentsOf: stateFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    try? now.write(to: stateFile, atomically: true, encoding: .utf8)
    if prev == "admin" && now == "standard" { exit(request(dry: false)) }
}
