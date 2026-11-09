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
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)

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
