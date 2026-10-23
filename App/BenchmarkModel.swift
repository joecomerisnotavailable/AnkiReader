import Foundation
import UIKit
import Combine

struct BenchmarkCase:Codable,Identifiable {
    var id:String {image}; var image:String; var layout:PageLayout; var expected:[String]; var verified:Bool
}
struct BenchmarkRun:Codable,Identifiable {
    var id=UUID().uuidString; var image:String; var layout:PageLayout; var engine:EngineChoice
    var recognition:Recognition?; var totalSeconds:Double; var vocabulary:[Lexeme]; var expected:[String]; var recovered:[String]; var error:String?
}
struct BenchmarkReport:Codable {
    var schemaVersion=1; var generated=Date(); var device:String; var os:String; var simulator:Bool; var cases:[BenchmarkCase]; var runs:[BenchmarkRun]
}
final class RecognitionWorker:@unchecked Sendable {
    let queue=DispatchQueue(label:"reading.recognition",qos:.userInitiated)
    private var analyzers:[EngineChoice:PageRecognizer]=[:]
    private var tokenizer:SudachiAnalyzer?
    private var dictionary:DictionaryIndex?
    func process(data:Data,engine:EngineChoice,layout:PageLayout,completion:@escaping (Result<(Recognition,[Lexeme]),Error>)->Void) {
        queue.async { [self] in
            do {
                if tokenizer==nil {tokenizer=try SudachiAnalyzer(directory:Bundle.main.resourceURL!.appendingPathComponent("sudachi"))}
                if dictionary==nil {dictionary=try DictionaryIndex(url:Bundle.main.url(forResource:"dictionary",withExtension:"sqlite")!)}
                if analyzers[engine]==nil {
                    switch engine {case .vision:analyzers[engine]=AppleRecognizer(); case .mlkit:analyzers[engine]=GoogleRecognizer();case .tesseract:analyzers[engine]=TesseractRecognizer()}
                }
                guard let image=UIImage(data:data)?.normalized() else {throw StorageError.database("Image could not be decoded")}
                let recognition=try analyzers[engine]!.recognize(image,layout:layout)
                let tokens=try tokenizer!.tokenize(recognition.text)
                var items:[Lexeme]=[],seen=Set<String>()
                for token in tokens where !token.surface.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    var lexeme=try dictionary!.resolve(token)
                    // Morphological POS is used for grammatical filtering; dictionary senses retain their own metadata.
                    lexeme.partOfSpeech=token.partOfSpeech
                    if seen.insert(lexeme.id).inserted {items.append(lexeme)}
                }
                completion(.success((recognition,items)))
            } catch {completion(.failure(error))}
        }
    }
}
@MainActor final class BenchmarkModel:ObservableObject {
    @Published var cases:[BenchmarkCase]=[]
    @Published var runs:[BenchmarkRun]=[]
    @Published var busy=false
    @Published var progress="Ready"
    @Published var error:String?
    @Published var current:BenchmarkRun?
    let worker=RecognitionWorker()
    let documents:URL
    private var corpus:URL
    private var cancelRequested=false
    init() {
        documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        corpus=documents.appendingPathComponent("captures",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:corpus,withIntermediateDirectories:true)
            if let bundled=Bundle.main.url(forResource:"device-corpus",withExtension:nil) {
                let manifest=bundled.appendingPathComponent("cases.json")
                let bundledCases=try JSONDecoder().decode([BenchmarkCase].self,from:Data(contentsOf:manifest))
                for item in bundledCases where !FileManager.default.fileExists(atPath:corpus.appendingPathComponent(item.image).path) {try FileManager.default.copyItem(at:bundled.appendingPathComponent(item.image),to:corpus.appendingPathComponent(item.image))}
                cases=bundledCases
            }
            let saved=documents.appendingPathComponent("cases.json")
            if FileManager.default.fileExists(atPath:saved.path) {cases=try JSONDecoder().decode([BenchmarkCase].self,from:Data(contentsOf:saved))}
            let report=documents.appendingPathComponent("benchmark-report.json")
            if FileManager.default.fileExists(atPath:report.path) {runs=try JSONDecoder().decode(BenchmarkReport.self,from:Data(contentsOf:report)).runs}
        } catch {self.error=error.localizedDescription}
    }
    func imageURL(_ name:String)->URL {corpus.appendingPathComponent(name)}
    func importImage(_ data:Data,layout:PageLayout) throws {
        guard let image=UIImage(data:data)?.normalized(),let jpeg=image.jpegData(compressionQuality:0.96) else {throw StorageError.database("Unsupported image")}
        let name=UUID().uuidString+".jpg"
        try jpeg.write(to:corpus.appendingPathComponent(name),options:.atomic)
        cases.append(BenchmarkCase(image:name,layout:layout,expected:[],verified:false));try save()
    }
    func save() throws {
        try JSONEncoder().encode(cases).write(to:documents.appendingPathComponent("cases.json"),options:.atomic)
        let report=BenchmarkReport(device:deviceModel(),os:UIDevice.current.systemVersion,simulator:isSimulator,cases:cases,runs:runs)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:documents.appendingPathComponent("benchmark-report.json"),options:.atomic)
    }
    func stop() {cancelRequested=true;progress="Stopping after this page…"}
    func run(_ selected:[BenchmarkCase],engines:[EngineChoice]) async {
        guard !busy else{return};busy=true;cancelRequested=false
        defer {busy=false;progress=cancelRequested ? "Stopped; results saved" : "Finished; results saved"}
        let total=selected.count*engines.count
        var done=0
        for item in selected {
            for engine in engines {
                if cancelRequested || Task.isCancelled {return}
                progress="\(done+1) of \(total) · \(engine.rawValue)"
                let start=Date()
                do {
                    let data=try Data(contentsOf:imageURL(item.image))
                    let result:(Recognition,[Lexeme])=try await withCheckedThrowingContinuation { continuation in worker.process(data:data,engine:engine,layout:item.layout){continuation.resume(with:$0)} }
                    let expressions=Set(result.1.map(\.expression))
                    let recovered=item.expected.filter{expressions.contains($0) || result.0.text.contains($0)}
                    let run=BenchmarkRun(image:item.image,layout:item.layout,engine:engine,recognition:result.0,totalSeconds:Date().timeIntervalSince(start),vocabulary:result.1,expected:item.expected,recovered:recovered)
                    runs.append(run);current=run
                } catch {
                    runs.append(BenchmarkRun(image:item.image,layout:item.layout,engine:engine,totalSeconds:Date().timeIntervalSince(start),vocabulary:[],expected:item.expected,recovered:[],error:error.localizedDescription))
                }
                do {try save()} catch {self.error=error.localizedDescription;return}
                done+=1
            }
        }
    }
    private var isSimulator:Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    private func deviceModel()->String {
        var info=utsname();uname(&info)
        return withUnsafePointer(to:&info.machine) {$0.withMemoryRebound(to:CChar.self,capacity:1){String(cString:$0)}}
    }
}
