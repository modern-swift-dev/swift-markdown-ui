#if os(iOS)
import MarkdownUI
import SnapshotTesting
import SwiftUI
import Testing

extension SnapshotTests {
    @MainActor
    @Suite(.enabled(if: SnapshotTestSupport.supportsPhoneSnapshots, "Skipping on iPad")) struct MarkdownListTests {
        private let layout = SwiftUISnapshotLayout.device(config: .iPhone8)

        @Test func taskList() {
            let view = MarkdownView {
                #"""
                - [x] A finished task
                - [ ] An unfinished task
                - [ ] Another unfinished task
                """#
            }
            .border(Color.accentColor)
            .padding()

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func bulletedList() {
            let view = MarkdownView {
                #"""
                * Systems
                  * FFF units
                  * Great Underground Empire (Zork)
                  * Potrzebie
                    * Equals the thickness of Mad issue 26
                      * Developed by 19-year-old Donald E. Knuth
                """#
            }
            .border(Color.accentColor)
            .padding()

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func bulletedDashedList() {
            let view = MarkdownView {
                #"""
                * Systems
                  * FFF units
                  * Great Underground Empire (Zork)
                  * Potrzebie
                    * Equals the thickness of Mad issue 26
                      * Developed by 19-year-old Donald E. Knuth
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownBulletedListMarker(.dash)

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func numberedList() {
            let view = MarkdownView {
                #"""
                This is an incomplete list of headgear:

                1. Hats
                1. Caps
                1. Bonnets

                Some more:

                10. Helmets
                1. Hoods
                1. Headbands, headscarves, wimples

                A list with a high start:

                999. The sky above the port was the color of television, tuned to a dead channel.
                1. It was a bright cold day in April, and the clocks were striking thirteen.
                """#
            }
            .border(Color.accentColor)
            .padding()

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func romanNumberedList() {
            let view = MarkdownView {
                #"""
                This is an incomplete list of headgear:

                1. Hats
                1. Caps
                1. Bonnets

                A list with a high start:

                999. The sky above the port was the color of television, tuned to a dead channel.
                1. It was a bright cold day in April, and the clocks were striking thirteen.
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownNumberedListMarker(.lowerRoman)

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func looseList() {
            let view = MarkdownView {
                #"""
                A loose list:

                1. Hats

                1. Caps

                1. Bonnets

                Another loose list:

                1. Hats
                1. Caps
                1. Bonnets

                   This paragraph makes the list loose.
                """#
            }
            .border(Color.accentColor)
            .padding()

            assertSnapshot(of: view, as: .image(layout: layout))
        }
    }
}

#endif
