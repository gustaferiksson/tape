import AppKit
import Observation

@MainActor
@Observable
final class AppUpdater {
    enum Status: Equatable {
        case idle, checking, downloading
        case upToDate(String)
        case ready(String)
        case blocked(String)
        case failed(String)
    }

    enum Trigger {
        case scheduled, manual
    }

    private enum AfterSwap: String {
        case open, quiet
    }

    nonisolated static let releasesURL = URL(string: "https://github.com/gustaferiksson/tape/releases/latest")!
    nonisolated static let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"82K3YC8HVF\" and identifier \"dev.gustaf.tape\""
    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let stagingPrefix = ".tape-update-"

    private(set) var status = Status.idle
    private(set) var staged: (version: String, app: URL)?
    @ObservationIgnored private var newerVersion: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var swapping = false
    @ObservationIgnored var isInstallBlocked: () -> Bool = { false }

    var isBusy: Bool { status == .checking || status == .downloading }

    nonisolated static var isSelfUpdatable: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.bundleURL.pathExtension == "app"
        #endif
    }

    nonisolated static var installDir: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    func start() {
        guard Self.isSelfUpdatable else {
            status = .blocked("This build doesn’t update itself.")
            return
        }
        Self.clearStaging()
        // build.sh stamps local builds "<describe>-local", which would otherwise compare older than every release.
        guard !Self.currentVersion.hasSuffix("-local") else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check(_ trigger: Trigger = .scheduled) {
        guard Self.isSelfUpdatable else {
            status = .blocked("This build doesn’t update itself.")
            return
        }
        if let staged {
            status = .ready(staged.version)
            if trigger == .manual { offer(staged.version) }
            return
        }
        guard !isBusy else { return }
        let previous = status
        status = .checking
        Task { await runCheck(trigger, previous: previous) }
    }

    private func runCheck(_ trigger: Trigger, previous: Status) async {
        guard let latest = await Self.latestVersion() else {
            status = trigger == .manual ? .failed("Couldn’t reach github.com.") : newerVersion == nil ? .idle : previous
            return
        }
        guard Self.isNewerVersion(latest, than: Self.currentVersion) else {
            newerVersion = nil
            status = .upToDate(Self.currentVersion)
            return
        }
        newerVersion = latest
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            status = .blocked("Tape can’t update itself in \(Self.installDir.path). Download it instead.")
            if trigger == .manual { NSWorkspace.shared.open(Self.releasesURL) }
            return
        }
        status = .downloading
        do {
            staged = (latest, try await Self.downloadVerified(version: latest))
            status = .ready(latest)
            offer(latest)
        } catch {
            Self.clearStaging()
            status = .failed(error.localizedDescription)
            if trigger == .manual { NSWorkspace.shared.open(Self.releasesURL) }
        }
    }

    private func offer(_ version: String) {
        guard !isInstallBlocked() else { return }
        let panel = NSAlert()
        panel.messageText = "Tape \(version) is available"
        panel.informativeText = "Tape will download it, replace itself and relaunch."
        panel.addButton(withTitle: "Install")
        panel.addButton(withTitle: "Later")
        NSApp.activate()
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        installAndRelaunch()
    }

    func installAndRelaunch() {
        guard !isInstallBlocked() else { return }
        if let reason = spawnSwap(then: .open) {
            if !isBusy { status = .blocked(reason) }
            return
        }
        NSApp.terminate(nil)
    }

    func installOnQuit() {
        guard staged != nil else { return }
        _ = spawnSwap(then: .quiet)
    }

    private func spawnSwap(then after: AfterSwap) -> String? {
        guard !swapping else { return nil }
        guard let staged else { return "No update is downloaded." }
        let installed = Self.bundleVersion(of: Bundle.main.bundleURL)
        if let installed, !Self.isNewerVersion(staged.version, than: installed) {
            self.staged = nil
            Self.clearStaging()
            return "\(installed) is already installed."
        }
        guard FileManager.default.isWritableFile(atPath: Self.installDir.path) else {
            return "\(Self.installDir.path) isn’t writable."
        }
        let script = URL.temporaryDirectory.appending(path: "tape-update-\(UUID().uuidString).sh")
        guard (try? Self.swapScript.write(to: script, atomically: true, encoding: .utf8)) != nil else {
            return "Couldn’t prepare the update."
        }
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = [script.path, "\(getpid())", staged.app.path, Bundle.main.bundleURL.path, after.rawValue, installed ?? ""]
        guard (try? helper.run()) != nil else { return "Couldn’t start the update." }
        swapping = true
        return nil
    }

    nonisolated private static func latestVersion() async -> String? {
        var request = URLRequest(url: releasesURL)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: RedirectBlocker()),
              let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
        else { return nil }
        return releaseVersion(fromLocation: location)
    }

    nonisolated private static func clearStaging() {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: installDir.path)) ?? []
        for entry in leftovers where entry.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: installDir.appending(path: entry))
        }
    }

    @concurrent nonisolated private static func downloadVerified(version: String) async throws -> URL {
        let fileManager = FileManager.default
        let root = installDir.appending(path: "\(stagingPrefix)\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fileManager.removeItem(at: root) } }

        let zipURL = URL(string: "https://github.com/gustaferiksson/tape/releases/download/v\(version)/Tape-\(version).zip")!
        let (download, response) = try await URLSession.shared.download(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("The update download failed.") }
        let zip = root.appending(path: "Tape.zip")
        try fileManager.moveItem(at: download, to: zip)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path]) else {
            throw UpdateFailure("Couldn’t unpack the update.")
        }
        try fileManager.removeItem(at: zip)

        let app = root.appending(path: "Tape.app")
        guard bundleVersion(of: app) == version else { throw UpdateFailure("The downloaded app isn’t version \(version).") }
        // spctl is avoided on purpose: it false-negatives on stapled builds.
        guard run("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, app.path]) else { throw UpdateFailure("The downloaded app failed signature checks.") }
        keep = true
        return app
    }

    nonisolated private static func bundleVersion(of app: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: app.appending(path: "Contents/Info.plist").path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    nonisolated private static func releaseVersion(fromLocation location: String) -> String? {
        guard let tag = location.split(separator: "/").last else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : String(tag)
        guard !version.isEmpty, version.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) else { return nil }
        return version
    }

    nonisolated private static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let components = { (version: String) in
            (version.hasPrefix("v") ? String(version.dropFirst()) : version).split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = components(remote), l = components(local)
        for index in 0..<max(r.count, l.count) {
            let a = index < r.count ? r[index] : 0, b = index < l.count ? l[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // Paths only ever arrive as arguments; interpolating one into this script would make it shell-injectable.
    nonisolated private static let swapScript = """
    #!/bin/sh
    set -u
    [ "$(id -u)" = "0" ] && exit 1
    pid=$1; staged=$2; target=$3; relaunch=$4; expected=$5
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    kill -0 "$pid" 2>/dev/null && exit 1
    [ -d "$staged" ] && [ -d "$target" ] || exit 1
    now=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$target/Contents/Info.plist" 2>/dev/null)
    [ "$now" = "$expected" ] || exit 1
    backup="$target.tape-old"
    rm -rf "$backup"
    mv "$target" "$backup" || exit 1
    if ! mv "$staged" "$target"; then
      mv "$backup" "$target"
      exit 1
    fi
    rm -rf "$backup"
    rm -rf "$(dirname "$staged")"
    if [ "$relaunch" = "open" ]; then open "$target"; fi
    rm -f "$0"
    exit 0
    """
}

private struct UpdateFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// URLSession follows redirects by default, and the release tag lives only in the 302's Location header.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
