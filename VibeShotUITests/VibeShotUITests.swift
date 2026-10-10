import XCTest
import ImageIO
import AppKit

@MainActor
final class VibeShotUITests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            // NSSavePanel can defer a polite application termination. Bound failed-test cleanup
            // to the target app beside this signed runner; never terminate a user's other build.
            let target = NSRunningApplication.current.bundleURL?.deletingLastPathComponent().appendingPathComponent("VibeShot.app").resolvingSymlinksInPath()
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.vibeshot.VibeShot") where app.bundleURL?.resolvingSymlinksInPath() == target {
                app.forceTerminate()
            }
        }
    }

    private func launchCapture(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-capture"] + arguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 10))
        return app
    }

    func testRectangleCopyClosesCapture() {
        let app = launchCapture()
        app.descendants(matching: .any)["Rectangle"].click()
        let start = app.dialogs.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: app.dialogs.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        app.buttons["Copy"].click()
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 10))
        app.terminate()
    }

    func testSavePanelVisibleCancelRestoresAndEscapeCloses() {
        let app = launchCapture()
        app.typeKey("s", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
        let cancel = app.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let visibleCancel = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleCancel], timeout: 5), .completed)
        cancel.click()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
        app.buttons["Save As"].click()
        XCTAssertTrue(app.textFields["saveAsNameTextField"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.textFields["saveAsNameTextField"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
        app.terminate()
    }

    func testErrorVisibleAndDismissible() {
        let app = launchCapture(["--export-error"])
        app.buttons["Copy"].click()
        let alert = app.dialogs["alert"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["OK"].isHittable)
        alert.buttons["OK"].click()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.terminate()
    }

    func testSaveWritesTestOwnedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VibeShot-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = launchCapture(["--synthetic-save-directory", folder.path])
        app.buttons["Save As"].click()
        let name = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let save = app.buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let visibleSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleSave], timeout: 5), .completed)
        save.click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix(".png") }
        }, object: nil)
        let result = XCTWaiter.wait(for: [saved], timeout: 10)
        XCTAssertEqual(result, .completed, "Saved files: \((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files.count, 1)
        let output = folder.appendingPathComponent(try XCTUnwrap(files.first))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 2 * Int(NSScreen.main!.frame.width))
        XCTAssertEqual(image.height, 2 * Int(NSScreen.main!.frame.height))
        app.terminate()
    }

    func testCommandQFromSavePanelFilenameFocus() {
        let app = launchCapture()
        app.buttons["Save As"].click()
        let name = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testEscapeDuringExportAndTextAndCommandQ() {
        var app = launchCapture(["--export-delay"])
        app.buttons["Copy"].click()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
        app.terminate()
        app = launchCapture()
        app.descendants(matching: .any)["Text"].click()
        app.dialogs.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()
        app.typeText("test")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["Copy"].waitForNonExistence(timeout: 5))
        app.terminate()
        app = launchCapture()
        app.descendants(matching: .any)["Text"].click()
        app.dialogs.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    func testApplicationLaunchesAsBackgroundAccessory() {
        let application = XCUIApplication()
        application.launch()
        XCTAssertTrue(application.wait(for: .runningBackground, timeout: 5))
        application.terminate()
    }
}
