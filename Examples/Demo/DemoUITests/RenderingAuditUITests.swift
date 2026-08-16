import XCTest

final class RenderingAuditUITests: XCTestCase {
    @MainActor func testAccessibilityAndLinkActivation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rendering-audit"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Rendering Audit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Accessible heading"].exists)
        XCTAssertTrue(app.images["Audit image"].exists)
        XCTAssertEqual(app.staticTexts["Completed audit item"].value as? String, "Completed")
        XCTAssertEqual(app.staticTexts["Incomplete audit item"].value as? String, "Incomplete")

        let validLink = app.links["Open audit link"]
        XCTAssertTrue(validLink.exists)
        XCTAssertTrue(validLink.isHittable)
        XCTAssertFalse(app.links["Invalid link"].exists)
        XCTAssertTrue(app.staticTexts["Invalid link"].exists)

        let linkedImage = app.buttons["Linked audit image"]
        XCTAssertTrue(linkedImage.exists)
        XCTAssertTrue(linkedImage.isHittable)
        linkedImage.tap()
        XCTAssertEqual(app.staticTexts["opened-url"].label, "Opened: https://example.com/audit/image-opened")

        validLink.tap()
        XCTAssertEqual(app.staticTexts["opened-url"].label, "Opened: https://example.com/audit/opened")
    }

    @MainActor func testAccessibilityDynamicTypeDoesNotHideContent() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--rendering-audit",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Rendering Audit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Accessible heading"].exists)
        XCTAssertTrue(app.links["Open audit link"].exists)
    }
}
