import MarkdownUI
import SwiftUI

struct RenderingAuditView: View {
    @State private var openedURL = "None"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MarkdownView(Self.fixture, baseURL: URL(string: "https://example.com/audit/"))
                        .markdownImageProvider(AuditImageProvider())
                        .markdownInlineImageProvider(AuditInlineImageProvider())
                        .environment(\.openURL, OpenURLAction { url in
                            self.openedURL = url.absoluteString
                            return .handled
                        })
                        .accessibilityIdentifier("rendering-audit-markdown")

                    Text("Opened: \(self.openedURL)")
                        .accessibilityIdentifier("opened-url")
                }
                .padding()
            }
            .navigationTitle("Rendering Audit")
        }
    }

    private static let fixture = """
        # Accessible heading

        [Open audit link](opened)

        [Invalid link](http://[)

        ![Audit image](audit-image)

        [![Linked audit image](linked-audit-image)](image-opened)

        Text before *![Inline audit image](inline-image)* text after.

        - [x] Completed audit item
        - [ ] Incomplete audit item

        | Column | Value |
        | --- | --- |
        | A very wide table value that must remain reachable | Another wide value |
        """
}

private struct AuditImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Image(systemName: "photo")
            .resizable()
            .scaledToFit()
            .frame(width: 80, height: 60)
    }
}

private struct AuditInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "star.fill")
    }
}
