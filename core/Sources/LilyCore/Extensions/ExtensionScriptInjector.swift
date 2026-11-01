import Foundation
import WebKit

/// Compatibility mode for macOS 14–15.3, where WebKit has no extension controller: runs the
/// content scripts of the library's verified, pinned extensions as `WKUserScript`s, each extension
/// in its own content world (`LilyExtension.<id>`), so it can't see the page's scripts, Lily's
/// injections, or another extension. A first-party shim (`injections/extension-compat.js`) gives
/// those scripts `chrome.storage` and clean errors for APIs that need a background context or
/// native messaging, through `ExtensionMessageBridge`.
///
/// Scripts are chosen by the main frame's address when a page starts loading (WKUserScript has no
/// per-frame match patterns). `all_frames` scripts then run only in frames of the main frame's
/// origin: a cross-origin frame (a payment field, a login widget) was never matched, so the
/// extension gets no access to it.
@MainActor
final class ExtensionScriptInjector {
    struct Planned: Equatable {
        let extensionID: String
        let path: String
        let time: WKUserScriptInjectionTime
        let mainFrameOnly: Bool
    }

    let library: ExtensionLibrary
    private let shimSource: String
    private var applied: [ObjectIdentifier: [Planned]] = [:]
    private var bridges: [ObjectIdentifier: [String: ExtensionMessageBridge]] = [:]

    init(library: ExtensionLibrary, shimURL: URL) throws {
        self.library = library
        shimSource = try String(contentsOf: shimURL, encoding: .utf8)
    }

    static func world(for extensionID: String) -> WKContentWorld { .world(name: "LilyExtension.\(extensionID)") }

    /// The content scripts of `entries` that apply to `url`, in manifest order.
    static func plan(for url: URL?, entries: [ExtensionLibrary.Entry]) -> [Planned] {
        guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        var planned: [Planned] = []
        for entry in entries {
            for script in entry.manifest.contentScripts where Self.matches(script, url) {
                let time: WKUserScriptInjectionTime = script.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
                for path in script.js ?? [] where entry.package.files[path] != nil {
                    planned.append(Planned(extensionID: entry.id, path: path, time: time, mainFrameOnly: !(script.allFrames ?? false)))
                }
            }
        }
        return planned
    }

    static func matches(_ script: ExtensionManifest.ContentScript, _ url: URL) -> Bool {
        script.matches.compactMap(ExtensionMatchPattern.init).contains { $0.matches(url) }
            && !(script.excludeMatches ?? []).compactMap(ExtensionMatchPattern.init).contains { $0.matches(url) }
    }

    /// The CSS of content scripts that apply to `url` for one extension (served to the shim).
    func css(for extensionID: String, url: URL?) -> [String] {
        guard let url, let entry = library.entry(extensionID) else { return [] }
        return entry.manifest.contentScripts.filter { Self.matches($0, url) }.flatMap { $0.css ?? [] }
            .compactMap { entry.package.files[$0].map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Called before a main-frame navigation: re-installs Lily's scripts plus the extension
    /// scripts for `url`, only when that set changes.
    func configure(_ controller: WKUserContentController, for url: URL?, registry: ScriptRegistry) {
        let key = ObjectIdentifier(controller)
        let planned = Self.plan(for: url, entries: library.ready)
        guard applied[key, default: []] != planned else { return }
        registry.install(into: controller) // starts from Lily's own scripts only
        let needed = Set(planned.map(\.extensionID))
        var attached = bridges[key, default: [:]]
        for (id, bridge) in attached where !needed.contains(id) {
            bridge.detach(from: controller)
            attached[id] = nil
        }
        for id in needed where attached[id] == nil {
            let bridge = ExtensionMessageBridge(extensionID: id, contentWorld: Self.world(for: id), injector: self)
            bridge.attach(to: controller)
            attached[id] = bridge
        }
        bridges[key] = attached
        var shimmed = Set<String>()
        for script in planned {
            guard let entry = library.entry(script.extensionID), let data = entry.package.files[script.path] else { continue }
            let world = Self.world(for: script.extensionID)
            if shimmed.insert(script.extensionID).inserted {
                controller.addUserScript(WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            }
            let source = String(decoding: data, as: UTF8.self)
            controller.addUserScript(WKUserScript(source: script.mainFrameOnly ? source : Self.sameOriginFramesOnly(source, mainFrame: url),
                                                  injectionTime: script.time,
                                                  forMainFrameOnly: script.mainFrameOnly, in: world))
        }
        applied[key] = planned
    }

    /// `source` guarded to stop in any frame whose origin isn't the main frame's (`url`). A thrown
    /// error ends a classic script without wrapping it, so its top-level declarations keep their
    /// meaning; a leading "use strict" is repeated before the guard so the script stays strict.
    nonisolated static func sameOriginFramesOnly(_ source: String, mainFrame url: URL?) -> String {
        let origin = url.flatMap(WebOrigin.of) ?? "null"
        let literal = (try? String(decoding: JSONEncoder().encode([origin]), as: UTF8.self)).map { String($0.dropFirst().dropLast()) } ?? "\"null\""
        let strict = Self.startsStrict(source) ? "\"use strict\";" : ""
        return strict + "if (window !== window.top && location.origin !== \(literal)) "
            + "throw new Error(\"Lily: this content script doesn't run in frames of other sites\");\n" + source
    }

    /// Whether the script's directive prologue opens with "use strict", after any BOM, whitespace
    /// and comments (a license header usually comes first).
    nonisolated static func startsStrict(_ source: String) -> Bool {
        var rest = Substring(source)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if rest.hasPrefix("//") {
                rest = rest.drop { !$0.isNewline } // CRLF is one Character; also U+2028/U+2029
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return false }
                rest = rest[end.upperBound...]
            } else {
                return rest.hasPrefix("\"use strict\"") || rest.hasPrefix("'use strict'")
            }
        }
    }

    /// A tab is closing: drop what was installed for it.
    func forget(_ controller: WKUserContentController) {
        let key = ObjectIdentifier(controller)
        bridges.removeValue(forKey: key)?.values.forEach { $0.detach(from: controller) }
        applied[key] = nil
    }
}
