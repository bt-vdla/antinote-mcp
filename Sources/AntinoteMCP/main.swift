import AppKit
import Foundation

let appVersion = "0.1.0"
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

/// One-time folder picker. Stores a read-only security-scoped bookmark to exactly that folder.
func grant() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Select Antinote's “Application Support” folder (it contains \(Store.dbName)). Access is read-only."
    panel.prompt = "Allow Read Access"
    panel.directoryURL = URL(fileURLWithPath: antinoteFolderGuess, isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { fail("Cancelled.") }
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent(Store.dbName).path) else {
        fail("That folder doesn't contain \(Store.dbName).")
    }
    guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                           includingResourceValuesForKeys: nil, relativeTo: nil) else {
        fail("Couldn't save the folder permission.")
    }
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    print("Granted read-only access to Antinote's database folder.")
}

/// Resolve the stored bookmark and keep the folder accessible for the life of the process.
func openFolder() -> URL {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
        fail("No folder permission yet. Run: antinote-mcp grant")
    }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                             relativeTo: nil, bookmarkDataIsStale: &stale),
          url.startAccessingSecurityScopedResource() else {
        fail("Folder permission is no longer valid (this happens after rebuilding). Run: antinote-mcp grant")
    }
    if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil) {
        UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    return url
}

switch CommandLine.arguments.dropFirst().first ?? "serve" {
case "grant":
    grant()
case "status":
    let tools = Tools(store: Store(folder: openFolder()))
    do {
        let s = try tools.call("antinote_status", [:])
        let d = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: d, as: UTF8.self))
    } catch { fail("\(error)") }
case "serve":
    setvbuf(stdout, nil, _IOLBF, 0)
    MCPServer(tools: Tools(store: Store(folder: openFolder())), version: appVersion).run()
case "--version", "version":
    print(appVersion)
default:
    fail("Usage: antinote-mcp [serve|grant|status|version]")
}
