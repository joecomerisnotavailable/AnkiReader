import Foundation
final class SudachiAnalyzer: MorphologicalAnalyzer {
    private let handle:UnsafeMutableRawPointer
    init(directory:URL) throws {
        guard let p=ar_sudachi_create(directory.path) else { throw StorageError.database("Sudachi dictionary could not be loaded. Rebuild the matching language resources.") }
        handle=p
    }
    deinit { ar_sudachi_destroy(handle) }
    func tokenize(_ text:String) throws -> [MorphToken] {
        guard let pointer=ar_sudachi_tokenize(handle,text) else { throw StorageError.database("Tokenizer returned no result") }
        defer { ar_sudachi_free_string(pointer) }
        let data=Data(String(cString:pointer).utf8)
        if let error=try? JSONDecoder().decode([String:String].self,from:data) { throw StorageError.database(error["error"] ?? "Tokenization failed") }
        return try JSONDecoder().decode([MorphToken].self,from:data)
    }
}
