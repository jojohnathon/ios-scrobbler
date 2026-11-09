import XCTest

final class ScrobblerSmokeTests: XCTestCase {
    @MainActor
    func testLaunchAndReturnFromHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let startListening = app.buttons["Start listening"]
        XCTAssertTrue(startListening.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 20) ||
                app.wait(for: .runningBackgroundSuspended, timeout: 2),
            "Scrobbler should enter the background after pressing Home"
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
