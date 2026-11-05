import AppKit
import Foundation

let appVersion = "0.2.0"
let bookmarkKey = "antinoteDatabaseFolder"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("antinote-mcp: " + message + "\n").utf8))
    exit(1)
}

/// The real (non-sandboxed) path of Antinote's data folder; inside our sandbox NSHomeDirectory() is our own container.
let antinoteFolderGuess: String = {
    let home = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first ?? NSHomeDirectory()
    return home + "/Library/Containers/com.chabomakers.Antinote/Data/Library/Application Support"
}()

/// Folder picker. Must run on the main thread. Stores a read-only security-scoped bookmark to exactly that folder.
/// Returns false if the user cancelled or picked the wrong folder.
func showGrantPanel() -> Bool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Antinote MCP needs read-only access to Antinote's notes. Select Antinote's “Application Support” folder (it contains \(Store.dbName))."
    panel.prompt = "Allow Read Access"
    panel.directoryURL = URL(fileURLWithPath: antinoteFolderGuess, isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url,
          FileManager.default.fileExists(atPath: url.appendingPathComponent(Store.dbName).path),
          let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                           includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    return true
}

/// Resolves the stored bookmark and keeps the folder accessible for the life of the process.
/// If permission is missing or invalid, it shows the folder picker itself (at most once per process)
/// and retries — so there is nothing to remember or re-run by hand.
final class FolderAccess {
    private var url: URL?
    private var askedThisRun = false
    private let lock = NSLock()

    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale),
              u.startAccessingSecurityScopedResource(),
              FileManager.default.isReadableFile(atPath: u.appendingPathComponent(Store.dbName).path) else { return nil }
        if stale, let fresh = try? u.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return u
    }

    func folder() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let u = url { return u }
        if let u = resolve() { url = u; return u }
        if !askedThisRun {
            askedThisRun = true
            let granted = Thread.isMainThread ? showGrantPanel() : DispatchQueue.main.sync { showGrantPanel() }
            if granted, let u = resolve() { url = u; return u }
        }
        throw StoreError(description: "Antinote MCP can't read Antinote's notes: folder access wasn't granted (the picker was cancelled). "
            + "Run ./install.sh in the antinote-mcp folder, or `antinote-mcp grant`, and pick Antinote's “Application Support” folder.")
    }
}

func printJSON(_ v: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        print(String(decoding: d, as: UTF8.self))
    }
}

switch CommandLine.arguments.dropFirst().first ?? "serve" {
case "grant":
    // Skips the picker if access already works; pass --force to pick again.
    let force = CommandLine.arguments.contains("--force")
    if !force, (try? Store(folder: FolderAccess().folderIfGranted).schemaCheck()) != nil {
        print("Access already granted.")
    } else if showGrantPanel() {
        print("Granted read-only access to Antinote's database folder.")
    } else {
        fail("Not granted (cancelled, or that folder doesn't contain \(Store.dbName)).")
    }
case "status":
    let access = FolderAccess()
    do { printJSON(try Tools(store: Store(folder: access.folder)).call("antinote_status", [:])) } catch { fail("\(error)") }
case "serve":
    setvbuf(stdout, nil, _IOLBF, 0)
    // Folder access is resolved lazily on the first tool call, so the server always starts and Claude sees
    // its tools. The MCP loop runs on a background thread; the main thread stays free for the folder picker.
    let access = FolderAccess()
    let server = MCPServer(tools: Tools(store: Store(folder: access.folder)), version: appVersion)
    Thread.detachNewThread {
        server.run()
        exit(0)  // stdin closed: client went away
    }
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    RunLoop.main.run()
case "--version", "version":
    print(appVersion)
default:
    fail("Usage: antinote-mcp [serve|grant [--force]|status|version]")
}

extension FolderAccess {
    /// Like folder(), but never shows UI.
    func folderIfGranted() throws -> URL {
        if let u = (try? withoutPrompt()) { return u }
        throw StoreError(description: "not granted")
    }
    private func withoutPrompt() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { throw StoreError(description: "none") }
        var stale = false
        let u = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard u.startAccessingSecurityScopedResource() else { throw StoreError(description: "denied") }
        return u
    }
}
