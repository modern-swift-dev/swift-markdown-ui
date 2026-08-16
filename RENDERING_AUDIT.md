# Rendering Assurance Audit

## Scope

This audit records the current rendering assurance for MarkdownUI. It covers the
package's parser-to-SwiftUI rendering path, deterministic image behavior,
accessibility metadata and interaction, stress fixtures, and platform builds.

## Coverage matrix

| Rendering area | Existing automated evidence | CI coverage | Finding |
| --- | --- | --- | --- |
| Markdown parsing and content builders | Typed `MarkdownConformanceTests`, content/builder tests, and `HTMLTagTests` | macOS and iOS tests | Supported CommonMark/GFM nodes, normalization, Unicode, malformed input, tag filtering, and URLs are explicit fixtures. |
| Recursive AST rewriting | `BlockNodeRewriteTests` | macOS and iOS tests | Covers all containers, tables, deletion, expansion, ordering, metadata, and error propagation. |
| Paragraphs, headings, block quotes, code blocks, and thematic breaks | Legacy iOS snapshots plus `RenderingScenarioTests` | macOS and iOS tests | The pairwise matrix adds macOS, width, appearance, Dynamic Type, and RTL coverage. |
| Bulleted, numbered, and task lists | List snapshots, builder tests, and accessibility UI tests | macOS and iOS tests | Includes nested lists and explicit completed/incomplete accessibility values. |
| Tables | Table snapshots and wide-table scenarios | macOS and iOS tests | Tables retain intrinsic layout; applications control whether their containing layout scrolls. |
| Inline text, links, images, and image layout | `RendererHardeningTests`, image snapshots, and Demo UI tests | macOS and iOS tests | Image providers are deterministic; recursive images, failure isolation, alt fallback, invalid URLs, and link activation are covered. |
| Built-in themes and environments | Theme snapshots and typed pairwise scenarios | macOS and iOS tests | Basic, GitHub, DocC, and custom styling are paired across light/dark, normal/accessibility sizes, LTR/RTL, and narrow/wide layouts. |
| Stress behavior | `MarkdownStressTests` | macOS and iOS tests | Large Unicode content, deep containers, and repeated parse/render round trips are deterministic. |
| tvOS, watchOS, visionOS, and Mac Catalyst compilation | Package build | Generic-destination builds | Compile-only coverage; no platform-specific rendering assertions. |
| Demo integration | Demo build and UI test | Pinned iOS simulator | Verifies the demo target and its deterministic audit flow. |
| Documentation | DocC build | macOS | Detects broken DocC markup and symbol links. |

## Findings

- `MarkdownUITests` now declares `Resources` as Swift Package resources, so test
  image assets are available through the package test bundle.
- `__Snapshots__` remains excluded from Swift Package resources. Reference images
  are test fixtures consumed directly by the snapshot test framework, not runtime
  bundle assets.
- The authoritative deployment-target matrix is `Package.swift`: macOS 15, iOS
  17, tvOS 17, Mac Catalyst 17, watchOS 10, and visionOS 2. README and DocC state
  the same minimums.
- Inline rendering now has one recursive state machine. Nested styles, links,
  line breaks, loaded images, and image alt fallbacks therefore share the same
  whitespace and attribute behavior.
- One failed inline image no longer removes successfully loaded siblings. The
  default block-image provider displays a deterministic failure symbol.
- Color-scheme filtering removes only the recognized GitHub marker for the
  opposite scheme; malformed URLs and unrelated fragments remain renderable.

## Toolchain and execution policy

CI runs on `macos-26` and selects `/Applications/Xcode_26.6.app`. It runs package
tests on macOS and the pinned `iPhone 17 Pro` iOS 26.5 simulator, compiles each
other declared Apple destination with a generic destination, builds and UI-tests
the Demo, and builds DocC documentation with warnings treated as errors.

Snapshot recordings are intentionally not run in CI. Set
`RECORD_SNAPSHOTS=1` when intentionally recording the typed risk-based matrix;
legacy XCTest snapshots use SnapshotTesting's `.all` record option during an
explicit local update. Re-run without recording and visually review every image
diff before committing. A CI mismatch is never accepted automatically.

## Residual limitations

- Generic destinations prove compilation only and do not exercise runtime layout
  or rendering on tvOS, watchOS, visionOS, or Mac Catalyst.
- Pixel snapshots can vary when fonts, rendering engines, simulator runtimes, or
  color-management behavior change. Pinning the CI runner, Xcode, and iOS
  simulator reduces but does not eliminate this risk.
- UI tests validate the accessibility tree, labels, link activation, and an
  accessibility Dynamic Type launch, but they do not automate spoken VoiceOver
  output or every keyboard/focus combination.
- Stress tests assert correctness and determinism rather than hardware-specific
  time or memory thresholds. Runtime layouts on the compile-only platforms and
  live network transport remain residual risks.
- The Demo's existing Splash syntax-highlighter wrapper emits a Swift
  concurrency warning under Xcode 26.6. The Swift 5 Demo target still builds;
  migrating that third-party integration is outside this rendering audit.
