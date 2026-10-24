import XCTest

final class CorrectionGesturesUITests:XCTestCase {
    func testCorrectedTermDragsOnPhoto() { merge(grid:false,reverse:false) }
    func testNeighborDragsOntoCorrectedTermInGrid() { merge(grid:true,reverse:true) }
    private func merge(grid:Bool,reverse:Bool) {
        let app=XCUIApplication();app.launchArguments=["--corrections-enabled","--gesture-fixture"];app.launch()
        let first=app.buttons["なだ"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:15))
        if grid { app.buttons["Show text grid"].tap() }
        let neighbor=app.buttons["め"].firstMatch
        XCTAssertTrue(neighbor.waitForExistence(timeout:5))
        (reverse ? neighbor : first).press(forDuration:0.7,thenDragTo:reverse ? first : neighbor)
        let combined=app.buttons["なだめ"].firstMatch
        XCTAssertTrue(combined.waitForExistence(timeout:10),app.debugDescription)
        combined.press(forDuration:0.7,thenDragTo:app.buttons["る"].firstMatch)
        XCTAssertTrue(app.buttons["なだめる"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
    }
    func testInterveningOCRTermExplainsRejectedMerge() {
        let app=XCUIApplication();app.launchArguments=["--corrections-enabled","--gesture-fixture","--phantom-fixture"];app.launch()
        let first=app.buttons["なだ"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:15))
        app.buttons["Show text grid"].tap()
        first.press(forDuration:0.7,thenDragTo:app.buttons["め"].firstMatch)
        let alert=app.alerts["Terms could not be joined"]
        XCTAssertTrue(alert.waitForExistence(timeout:5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","‘に’")).firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["に"].firstMatch.exists)
        XCTAssertFalse(app.buttons["なだめ"].firstMatch.exists)
    }
    func testContextDeletionProposesJoinedWord() {
        let app=XCUIApplication();app.launchArguments=["--corrections-enabled","--gesture-fixture","--phantom-fixture","--context-fixture"];app.launch()
        let token=app.buttons["context-token-2"]
        XCTAssertTrue(token.waitForExistence(timeout:15));token.tap()
        app.buttons["Delete 「に」 from the draft"].tap()
        app.buttons["Preview context edit"].tap()
        XCTAssertTrue(app.staticTexts["→ Delete the text shown above"].waitForExistence(timeout:15))
        XCTAssertTrue(app.switches["なだめる"].exists,app.debugDescription)
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["なだめる"].firstMatch.waitForExistence(timeout:10))
    }
    func testHandwritingTargetIsExplicitForMultiCharacterWord() {
        let app=XCUIApplication();app.launchArguments=["--drawing-fixture"];app.launch()
        XCTAssertTrue(app.staticTexts["Replacing: 「泣き」"].waitForExistence(timeout:15))
        app.buttons["泣"].tap()
        XCTAssertTrue(app.staticTexts["Replacing: 「泣」"].exists)
        app.buttons["Whole term"].tap()
        XCTAssertTrue(app.staticTexts["Replacing: 「泣き」"].exists)
    }
    func testDrawingFromWordDetailsFullScreen() {
        let app=XCUIApplication();app.launchArguments=["--corrections-enabled","--gesture-fixture","--word-fixture","--ink-ready"];app.launch()
        XCTAssertTrue(app.buttons["Draw kanji"].waitForExistence(timeout:15));app.buttons["Draw kanji"].tap()
        let canvas=app.descendants(matching:.any)["handwritingCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:10))
        let frame=canvas.frame
        for _ in 0..<3 {
            canvas.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.2)).press(forDuration:0.01,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.8)))
        }
        XCTAssertEqual(canvas.value as? String,"3 strokes")
        XCTAssertEqual(canvas.frame.minY,frame.minY,accuracy:2)
        app.navigationBars["Draw kanji"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["See in context"].waitForExistence(timeout:5))
    }
    func testDrawingCapturesStrokeInsteadOfScrolling() {
        let app=XCUIApplication();app.launchArguments=["--drawing-fixture"];app.launch()
        let canvas=app.descendants(matching:.any)["handwritingCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:15))
        let frame=canvas.frame
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.2)).press(forDuration:0.05,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8)))
        let done=NSPredicate(format:"value == %@","1 strokes")
        expectation(for:done,evaluatedWith:canvas);waitForExpectations(timeout:5)
        XCTAssertEqual(canvas.frame.minY,frame.minY,accuracy:2)
        app.buttons["Undo stroke"].tap()
        XCTAssertEqual(canvas.value as? String,"0 strokes")
    }
}
