#!/usr/bin/env python3
"""Import fixtures with the official Anki backend into a disposable collection.
Never opens a user's Anki profile. Run WorkflowTests to generate the fixtures first.
"""
import pathlib
import sqlite3
import tempfile
import zipfile
from anki.collection import Collection
from anki.import_export_pb2 import ImportAnkiPackageRequest

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="reading-anki-validation-") as temporary:
    directory = pathlib.Path(temporary)
    package = root / ".build/fixtures/reading.apkg"
    with zipfile.ZipFile(package) as archive:
        assert archive.testzip() is None
        archive.extract("collection.anki2", directory)
    db = sqlite3.connect(directory / "collection.anki2")
    assert db.execute("pragma integrity_check").fetchone()[0] == "ok"
    original_guid = db.execute("select guid from notes").fetchone()[0]
    db.close()
    collection = Collection(str(directory / "validation.anki2"))
    try:
        for filename in ["reading.apkg", "reading-again.apkg"]:
            result = collection.import_anki_package(ImportAnkiPackageRequest(package_path=str(root / ".build/fixtures" / filename)))
            assert collection.note_count() == 1, result
            assert collection.card_count() == 1, result
        note = collection.get_note(collection.find_notes("")[0])
        assert note.guid == original_guid
        assert note["Word"] == "薄明"
        assert note["Reading"] == "はくめい"
        assert note["Definition"] == "twilight &lt;dawn&gt; &amp; dusk"
        assert "<b>薄明</b>" in note["Example"]
        assert "Context" in note.cards()[0].question()
        assert "はくめい" in note.cards()[0].answer()
        print("PASS: official Anki backend imported both packages; one note, one card, stable GUID, valid rendered front/back")
    finally:
        collection.close()
