#if os(iOS)
    import MarkdownUI
    import SnapshotTesting
    import SwiftUI
    import Testing

    extension SnapshotTests {
        @MainActor
        @Suite(.enabled(if: SnapshotTestSupport.supportsPhoneSnapshots, "Skipping on iPad")) struct ThemeDocCTests {
            private let layout = SwiftUISnapshotLayout.device(config: .iPhone8)

            @Test func inlines() {
                let view = ThemePreview(theme: .docC) {
                    #"""
                    **This is bold text**

                    *This text is italicized*

                    ~~This was mistaken text~~

                    **This text is _extremely_ important**

                    MarkdownUI is fully compliant with the [CommonMark Spec](https://spec.commonmark.org/current/).

                    Use `git status` to list all new or modified files that haven't yet been committed.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func headings() {
                let view = ThemePreview(theme: .docC, colorScheme: .light) {
                    #"""
                    Paragraph.
                    # Heading 1
                    Paragraph.
                    ## Heading 2
                    Paragraph.
                    ### Heading 3
                    Paragraph.
                    #### Heading 4
                    Paragraph.
                    ##### Heading 5
                    Paragraph.
                    ###### Heading 6
                    Paragraph.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func paragraph() {
                let view = ThemePreview(theme: .docC, colorScheme: .light) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    It was a bright cold day in April, and the clocks were striking thirteen.

                    The sky above the port was the color of television, tuned to a dead channel.

                    It was a bright cold day in April, and the clocks were striking thirteen.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func blockquote() {
                let view = ThemePreview(theme: .docC) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    > Outside of a dog, a book is man's best friend. Inside of a dog it's too dark to read.

                    It was a bright cold day in April, and the clocks were striking thirteen.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func codeBlock() {
                let view = ThemePreview(theme: .docC) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    ```swift
                    struct Sightseeing: Activity {
                        func perform(with sloth: inout Sloth) -> Speed {
                            sloth.energyLevel -= 10
                            return .slow
                        }
                    }
                    ```

                    It was a bright cold day in April, and the clocks were striking thirteen.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func image() {
                let view = ThemePreview(theme: .docC, colorScheme: .light) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    ![](https://example.com/picsum/237-100x150)

                    It was a bright cold day in April, and the clocks were striking thirteen.

                    ![](https://example.com/picsum/237-100x150)
                    ![](https://example.com/picsum/237-125x75)

                    ― Photo by André Spieker
                    """#
                }
                .markdownImageProvider(AssetImageProvider(bundle: .module))
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func list() {
                let view = ThemePreview(theme: .docC, colorScheme: .light) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    * Systems
                      * FFF units
                      * Great Underground Empire (Zork)
                      * Potrzebie
                        * Equals the thickness of Mad issue 26
                          * Developed by 19-year-old Donald E. Knuth

                    It was a bright cold day in April, and the clocks were striking thirteen.

                    10. Helmets
                    1. Hoods
                    1. Headbands, headscarves, wimples

                    The sky above the port was the color of television, tuned to a dead channel.

                    - [x] A finished task
                    - [ ] An unfinished task
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func table() {
                let view = ThemePreview(theme: .docC) {
                    #"""
                    Add tables of data:

                    | Sloth speed  | Description                           |
                    | ------------ | ------------------------------------- |
                    | `slow`       | Moves slightly faster than a snail.   |
                    | `medium`     | Moves at an average speed.            |
                    | `fast`       | Moves faster than a hare.             |
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }

            @Test func thematicBreak() {
                let view = ThemePreview(theme: .docC) {
                    #"""
                    The sky above the port was the color of television, tuned to a dead channel.

                    ---

                    It was a bright cold day in April, and the clocks were striking thirteen.
                    """#
                }
                assertSnapshot(of: view, as: .image(layout: layout))
            }
        }
    }

#endif
