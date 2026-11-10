import XCTest

final class ScrobblerSmokeTests: XCTestCase {
    @MainActor
    func testLaunchAndReturnFromSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let startListening = app.buttons["Start listening"]
        XCTAssertTrue(startListening.waitForExistence(timeout: 10))

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 20) ||
                app.wait(for: .runningBackgroundSuspended, timeout: 2),
            "Scrobbler should enter the background when Settings is in front"
        )

        app.activate()
        XCTAssertTrue(startListening.waitForExistence(timeout: 10))

        startListening.tap()
        let deviceRequired = app.staticTexts["Screen capture requires a physical iPhone"]
        XCTAssertTrue(deviceRequired.waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "After tapping Start listening"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
