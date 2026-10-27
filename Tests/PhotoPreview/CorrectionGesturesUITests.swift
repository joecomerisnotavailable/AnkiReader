import XCTest

final class CorrectionGesturesUITests:XCTestCase {
    private func launch(_ extra:[String]=[])->XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["--corrections-enabled","--gesture-fixture","--phantom-fixture","--ink-ready"]+extra;app.launch()
        XCTAssertTrue(app.buttons["context-0"].waitForExistence(timeout:15));return app
    }
    private func menu(_ app:XCUIApplication,_ offset:Int,_ action:String) {
        app.buttons["context-\(offset)"].press(forDuration:0.5)
        XCTAssertTrue(app.menuItems[action].waitForExistence(timeout:5),app.debugDescription);app.menuItems[action].tap()
    }
    func testContextDiscardJoinAndUndo() {
        let app=launch()
        let ni=app.buttons["context-2"]
        ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.5,thenDragTo:ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:-0.35)))
        let me=app.buttons["context-2"]
        let changed=NSPredicate(format:"label == %@","め")
        expectation(for:changed,evaluatedWith:me);waitForExpectations(timeout:10)
        app.buttons["context-0"].press(forDuration:0.5,thenDragTo:me)
        expectation(for:NSPredicate(format:"label == %@","なだめ"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
        app.buttons["context-0"].press(forDuration:0.5,thenDragTo:app.buttons["context-3"])
        expectation(for:NSPredicate(format:"label == %@","なだめる"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
        app.buttons["Undo"].tap()
        expectation(for:NSPredicate(format:"label == %@","なだめ"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:5)
    }
    func testShatterAndCharacterJoin() {
        let app=launch();menu(app,0,"Shatter")
        XCTAssertTrue(app.buttons["context-1"].waitForExistence(timeout:10));XCTAssertEqual(app.buttons["context-0"].label,"な")
        menu(app,0,"Join")
        let end=app.otherElements["Join end"]
        XCTAssertTrue(end.waitForExistence(timeout:5))
        end.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.1,thenDragTo:app.buttons["context-1"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)))
        app.buttons["Confirm join"].tap()
        expectation(for:NSPredicate(format:"label == %@","なだ"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
    }
    func testCompactEditKeepAndCancel() {
        let app=launch();menu(app,0,"Edit")
        let field=app.textViews["compact-edit-text"]
        XCTAssertTrue(field.waitForExistence(timeout:5));field.typeText("X")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["context-0"].label,"なだ")
        menu(app,0,"Edit");XCTAssertTrue(field.waitForExistence(timeout:5));field.typeText("X")
        app.buttons["Keep"].tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","X"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
        XCTAssertEqual(app.buttons["context-3"].label,"に")
    }
    func testInlineDrawingAndPhotoDismissal() {
        let app=launch();menu(app,0,"Edit")
        XCTAssertTrue(app.buttons["Draw character"].waitForExistence(timeout:5));app.buttons["Draw character"].tap()
        let canvas=app.descendants(matching:.any)["compactInkCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:10));let frame=canvas.frame
        for _ in 0..<2 { canvas.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.2)).press(forDuration:0.01,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.8))) }
        XCTAssertEqual(canvas.value as? String,"2 strokes");XCTAssertEqual(canvas.frame.minY,frame.minY,accuracy:2)
        app.buttons["Keyboard"].tap()
        let field=app.textViews["compact-edit-text"]
        XCTAssertTrue(field.exists)
        app.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.18)).press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.22)))
        XCTAssertTrue(field.exists)
        app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.18)).tap()
        XCTAssertFalse(field.waitForExistence(timeout:1))
    }
    func testFilteredContextAndLargeText() {
        let app=launch(["--large-text"])
        XCTAssertTrue(app.buttons["context-2"].exists)
        app.buttons["context-2"].tap()
        XCTAssertTrue(app.buttons["context-2"].isHittable)
        menu(app,2,"Edit")
        XCTAssertTrue(app.textViews["compact-edit-text"].waitForExistence(timeout:5))
        app.buttons["Cancel"].tap()
    }
}

extension CorrectionGesturesUITests {
    func testAlternativesHideKeyboardAndRemainDraftUntilKeep() {
        let app=launch(["--alternatives-fixture"]);menu(app,0,"Edit")
        let field=app.textViews["compact-edit-text"]
        XCTAssertTrue(field.waitForExistence(timeout:5))
        app.buttons["Character alternatives"].tap()
        let candidate=app.buttons["alternative-なだめる"]
        XCTAssertTrue(candidate.waitForExistence(timeout:5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        candidate.tap();XCTAssertEqual(field.value as? String,"なだめる")
        app.buttons["Cancel"].tap();menu(app,0,"Edit")
        XCTAssertEqual(field.value as? String,"なだ")
        app.buttons["Character alternatives"].tap();XCTAssertTrue(candidate.waitForExistence(timeout:5));candidate.tap()
        field.tap();XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        app.buttons["Keep"].tap()
        expectation(for:NSPredicate(format:"label == %@","なだめる"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
    }
    func testParsingSuggestionHideRecallAndDiscard() {
        let app=launch()
        let ni=app.buttons["context-2"]
        ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.5,thenDragTo:ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:-0.35)))
        let suggestion=app.buttons["parsing-suggestion-なだめる"]
        XCTAssertTrue(suggestion.waitForExistence(timeout:10))
        app.buttons["context-0"].tap()
        XCTAssertFalse(suggestion.isHittable)
        app.buttons["context-2"].tap()
        XCTAssertTrue(suggestion.waitForExistence(timeout:5));XCTAssertTrue(suggestion.isHittable)
        suggestion.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.5,thenDragTo:suggestion.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:-0.5)))
        XCTAssertFalse(suggestion.waitForExistence(timeout:1))
        app.buttons["context-0"].tap();app.buttons["context-2"].tap()
        XCTAssertFalse(suggestion.exists)
        XCTAssertEqual(app.buttons["context-0"].label,"なだ")
        app.buttons["Undo"].tap()
        expectation(for:NSPredicate(format:"label == %@","に"),evaluatedWith:app.buttons["context-2"]);waitForExpectations(timeout:10)
    }
    func testParsingSuggestionAcceptAndUndo() {
        let app=launch()
        let ni=app.buttons["context-2"]
        ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.5,thenDragTo:ni.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:-0.35)))
        let suggestion=app.buttons["parsing-suggestion-なだめる"]
        XCTAssertTrue(suggestion.waitForExistence(timeout:10));XCTAssertTrue(suggestion.isHittable)
        XCTAssertEqual(app.buttons["context-0"].label,"なだ")
        suggestion.tap()
        expectation(for:NSPredicate(format:"label == %@","なだめる"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
        app.buttons["Undo"].tap()
        expectation(for:NSPredicate(format:"label == %@","なだ"),evaluatedWith:app.buttons["context-0"]);waitForExpectations(timeout:10)
    }
}

extension CorrectionGesturesUITests {
    func testPitchGraphAppearsWithBundledAccent() {
        let app=launch(["--pitch-fixture"])
        let graph=app.descendants(matching:.any).matching(identifier:"pitch-accent-graphs").firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout:10))
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@","pitch drops after mora 2")).firstMatch.waitForExistence(timeout:5),app.debugDescription)
    }
}
