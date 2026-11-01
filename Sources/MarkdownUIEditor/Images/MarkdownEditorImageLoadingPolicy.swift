import Foundation

/// A policy that decides which URLs Markdown editors may load images from.
///
/// Editors check each image's resolved URL against the current policy before they pass it to the
/// editor's image provider, so the policy also applies to custom ``MarkdownEditorImageProvider`` types.
/// A blocked image is never requested and shows its alternative text instead.
///
/// To configure the policy for a view hierarchy, use the `markdownEditorImageLoadingPolicy(_:)` modifier.
/// The following example only loads secure images from one host, which keeps untrusted Markdown
/// from fetching arbitrary remote URLs:
///
/// ```swift
/// MarkdownEditor(markdown: $untrustedMarkdown)
///   .markdownEditorImageLoadingPolicy(.allowing(schemes: ["https"], hosts: ["images.example.com"]))
/// ```
///
/// Set the policy before the editor appears. Changing it applies to images the editor displays
/// afterwards and doesn't reload images that are already requested or shown.
public struct MarkdownEditorImageLoadingPolicy: Sendable {
    private let decision: @Sendable (URL) -> Bool

    private init(_ decision: @escaping @Sendable (URL) -> Bool) {
        self.decision = decision
    }

    /// Returns whether Markdown editors may load an image from the given URL.
    ///
    /// - Parameter url: The image URL. A relative URL is resolved against its base URL first.
    public func allows(_ url: URL) -> Bool {
        self.decision(url.absoluteURL)
    }

    /// A policy that allows every image URL.
    ///
    /// This is the default policy.
    public static let allowAll = Self { _ in true }

    /// A policy that allows image URLs with one of the given schemes and, optionally, hosts.
    ///
    /// Schemes and hosts are compared case-insensitively. URLs without a scheme, such as a relative
    /// path without a base URL, are blocked.
    ///
    /// - Parameters:
    ///   - schemes: The allowed URL schemes, such as `"https"`, `"file"` or `"data"`.
    ///   - hosts: The allowed hosts, or `nil` to allow any host for the allowed schemes. When you pass
    ///            a set of hosts, URLs without a host, such as `data:` URLs, are blocked.
    public static func allowing(schemes: Set<String>, hosts: Set<String>? = nil) -> Self {
        let schemes = Set(schemes.map { $0.lowercased() })
        let hosts = hosts.map { Set($0.map { $0.lowercased() }) }
        return Self { url in
            guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
                return false
            }
            guard let hosts else {
                return true
            }
            guard let host = url.host(percentEncoded: false)?.lowercased() else {
                return false
            }
            return hosts.contains(host)
        }
    }

    /// A policy that uses a custom decision.
    ///
    /// - Parameter decision: A closure that returns whether an image may load from an absolute URL.
    public static func custom(_ decision: @escaping @Sendable (URL) -> Bool) -> Self {
        Self(decision)
    }
}
