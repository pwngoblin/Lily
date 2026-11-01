import Foundation

/// A web page's origin written the way `location.origin` writes it, for comparing a URL Lily holds
/// with the document a script runs in.
enum WebOrigin {
    /// `scheme://host[:port]` for http(s) URLs: lowercased, default port left out, IPv6 bracketed.
    /// Nil for other schemes (a `file:` page's origin is "null").
    nonisolated static func of(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed)" + (url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")
    }
}
