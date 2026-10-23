import SwiftUI
import PhotosUI

@main struct ReadingCompanionApp: App {
    @StateObject private var reader = ReaderModel()
    var body: some Scene { WindowGroup { ReaderHome().environmentObject(reader) } }
}
struct BenchmarkArchiveView: View {
    @StateObject private var model = BenchmarkModel()
    var body: some View { BenchmarkHome().environmentObject(model) }
}
struct BenchmarkHome:View {
    @EnvironmentObject var model:BenchmarkModel
    @State private var photo:PhotosPickerItem?
    @State private var layout:PageLayout = .vertical
    @State private var engine:EngineChoice = .mlkit
    @State private var showCamera=false
    var body:some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment:.leading,spacing:10) {
                        Text("A clearer path into the page.").font(.largeTitle.bold()).foregroundStyle(Color(red:0.15,green:0.28,blue:0.23))
                        Text("Recognition lab").font(.headline)
                        Text("Compare offline recognition on your own pages before choosing the reading engine.").foregroundStyle(.secondary)
                    }.padding(.vertical,12)
                    Picker("Page layout",selection:$layout){ForEach(PageLayout.allCases){Text($0.rawValue).tag($0)}}
                    Picker("Engine",selection:$engine){ForEach(EngineChoice.allCases){Text($0.rawValue).tag($0)}}
                    HStack {
                        Button {showCamera=true} label:{Label("Camera",systemImage:"camera")}.buttonStyle(.borderedProminent)
                        PhotosPicker(selection:$photo,matching:.images){Label("Import page",systemImage:"photo")}.buttonStyle(.bordered)
                    }
                }
                Section("Benchmark") {
                    Text("\(model.cases.count) pages · \(model.runs.count) saved runs")
                    Text("Anki labels may differ from the words printed on the page. Hint matches are diagnostic only; a mismatch does not establish an OCR error. Accuracy requires checking the photo, reading order, and source location.").font(.caption).foregroundStyle(.secondary)
                    if model.busy {ProgressView(model.progress);Button("Stop after this page",role:.destructive){model.stop()}}
                    else {
                        Button("Compare all three engines") {Task{await model.run(model.cases,engines:EngineChoice.allCases)}}.disabled(model.cases.isEmpty)
                        Button("Run selected engine on all pages") {Task{await model.run(model.cases,engines:[engine])}}.disabled(model.cases.isEmpty)
                    }
                    if FileManager.default.fileExists(atPath:model.documents.appendingPathComponent("benchmark-report.json").path) {
                        ShareLink("Export benchmark report",item:model.documents.appendingPathComponent("benchmark-report.json"))
                    }
                }
                if let run=model.current {Section("Latest result") {NavigationLink {ResultView(run:run)} label:{ResultSummary(run:run)}}}
                Section("Pages") {
                    ForEach(model.cases) {item in
                        NavigationLink {CaseView(item:item,engine:engine)} label:{
                            HStack {
                                if let image=UIImage(contentsOfFile:model.imageURL(item.image).path) {Image(uiImage:image).resizable().scaledToFill().frame(width:48,height:64).clipped().clipShape(RoundedRectangle(cornerRadius:6))}
                                VStack(alignment:.leading){Text(item.expected.isEmpty ? "Unlabeled page" : item.expected.joined(separator:" · "));Text(item.layout.rawValue).font(.caption).foregroundStyle(.secondary)}
                            }
                        }
                    }
                }
                Section {NavigationLink("Sources & licenses"){ScrollView{Text((try? String(contentsOf:Bundle.main.url(forResource:"Attribution",withExtension:"txt")!,encoding:.utf8)) ?? "").padding()}}}
            }
            .navigationTitle("Reading Companion").navigationBarTitleDisplayMode(.inline)
            .tint(Color(red:0.18,green:0.40,blue:0.31))
            .sheet(isPresented:$showCamera){CameraSheet {data in do{try model.importImage(data,layout:layout)}catch{model.error=error.localizedDescription}}}
            .onChange(of:photo){_,value in Task{do{if let data=try await value?.loadTransferable(type:Data.self){try model.importImage(data,layout:layout)}}catch{model.error=error.localizedDescription}}}
            .alert("Could not complete action",isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})){Button("OK"){model.error=nil}}message:{Text(model.error ?? "")}
            .task {
                if ProcessInfo.processInfo.arguments.contains("--benchmark-all") {await model.run(model.cases,engines:EngineChoice.allCases)}
                else if ProcessInfo.processInfo.arguments.contains("--benchmark-mlkit") {await model.run(model.cases,engines:[.mlkit])}
            }
        }
    }
}
struct CaseView:View {
    @EnvironmentObject var model:BenchmarkModel
    var item:BenchmarkCase;var engine:EngineChoice
    @State private var expected=""
    var body:some View {
        List {
            if let image=UIImage(contentsOfFile:model.imageURL(item.image).path){Image(uiImage:image).resizable().scaledToFit()}
            Section("Reference labels (unverified)") {
                Text("These labels may be edited Anki vocabulary, rather than literal page text.").font(.caption).foregroundStyle(.secondary)
                TextField("Words separated by commas",text:$expected,axis:.vertical)
                Button("Save labels") {
                    guard let index=model.cases.firstIndex(where:{$0.id==item.id}) else{return}
                    model.cases[index].expected=expected.components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
                    // Text labels alone do not verify source boxes or full reading order.
                    model.cases[index].verified=false
                    do {try model.save()}catch{model.error=error.localizedDescription}
                }
                Button("Run \(engine.rawValue)"){Task{await model.run([model.cases.first{$0.id==item.id} ?? item],engines:[engine])}}.disabled(model.busy)
            }
            Section("Results") {ForEach(model.runs.filter{$0.image==item.image}.reversed()){run in NavigationLink{ResultView(run:run)}label:{ResultSummary(run:run)}}}
        }.navigationTitle("Page").onAppear{expected=item.expected.joined(separator:", ")}
    }
}
struct ResultSummary:View {
    var run:BenchmarkRun
    var body:some View {VStack(alignment:.leading,spacing:4){Text(run.engine.rawValue).font(.headline);Text(String(format:"%.2fs · %d dictionary matches",run.totalSeconds,run.vocabulary.filter{$0.dictionaryID != nil}.count));if !run.expected.isEmpty{Text("Reference hint matches: \(run.recovered.count)/\(run.expected.count) (unverified)").font(.caption)};if let error=run.error{Text(error).foregroundStyle(.red)}}}
}
struct ResultView:View {
    @EnvironmentObject var model:BenchmarkModel
    var run:BenchmarkRun
    @State private var overlay=true
    var body:some View {
        List {
            ResultSummary(run:run)
            Toggle("Show recognized regions",isOn:$overlay)
            if let image=UIImage(contentsOfFile:model.imageURL(run.image).path) {
                Image(uiImage:image).resizable().aspectRatio(contentMode:.fit).overlay {
                    if overlay {GeometryReader {geo in ForEach(run.recognition?.lines ?? []) {line in
                        Rectangle().stroke(line.isRuby ? Color.orange : Color.teal,lineWidth:1).frame(width:geo.size.width*line.region.width,height:geo.size.height*line.region.height).position(x:geo.size.width*(line.region.x+line.region.width/2),y:geo.size.height*(line.region.y+line.region.height/2))
                    }}}
                }
            }
            Section("Recognized text"){Text(run.recognition?.text ?? "No text").textSelection(.enabled)}
            Section("Dictionary results"){ForEach(run.vocabulary.filter{$0.dictionaryID != nil}){word in VStack(alignment:.leading){HStack{Text(word.expression).font(.headline);Text(word.reading).foregroundStyle(.secondary)};Text(word.definitions.first ?? "").font(.subheadline)}}}
        }.navigationTitle(run.engine.rawValue)
    }
}
struct CameraSheet:UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    var captured:(Data)->Void
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIViewController(context:Context)->UIImagePickerController {
        let c=UIImagePickerController();c.sourceType=UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary;c.delegate=context.coordinator;return c
    }
    func updateUIViewController(_ uiViewController:UIImagePickerController,context:Context){}
    class Coordinator:NSObject,UIImagePickerControllerDelegate,UINavigationControllerDelegate {
        let parent:CameraSheet;init(_ parent:CameraSheet){self.parent=parent}
        func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) {if let image=info[.originalImage] as? UIImage,let data=image.jpegData(compressionQuality:0.96){parent.captured(data)};parent.dismiss()}
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController){parent.dismiss()}
    }
}
