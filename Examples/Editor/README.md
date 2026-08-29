# MarkdownUIEditor example

This example generates one Xcode project with separate iOS and macOS app targets. Both targets use the local `MarkdownUIEditor` package product and share the SwiftUI editor screen.

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

Generate and open the project:

```sh
make examples
open Examples/Editor/Editor.xcodeproj
```

Run these commands from the repository root. The `examples` target runs XcodeGen
with `Examples/Editor/project.yml`. The generated `Editor.xcodeproj` is ignored
and should not be committed.
