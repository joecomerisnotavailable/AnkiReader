import SwiftUI
import UIKit

struct CorrectionBadge:View {
    var changes:[TextCorrection]
    var legacy=false
    var body:some View {
        if let change=changes.last {
            HStack(spacing:3) {
                Spacer(minLength:0)
                Text(change.before.isEmpty ? "∅" : change.before).strikethrough()
                Text("→")
                Text(change.after.isEmpty ? "∅" : change.after)
                if changes.count>1 { Text("+\(changes.count-1)") }
            }.font(.caption).foregroundStyle(.orange).lineLimit(1)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("Corrected \(change.before) to \(change.after)\(changes.count>1 ? ", plus \(changes.count-1) earlier changes" : "")")
        } else if legacy { Text("Previously edited").font(.caption).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.trailing) }
    }
}
struct OccurrenceCorrectionBadge:View {
    @EnvironmentObject var model:ReaderModel
    let occurrence:Occurrence
    var body:some View {
        if let page=model.state.captures.first(where:{$0.id==occurrence.captureID}) {
            CorrectionBadge(changes:CorrectionMapping.history(occurrence,page:page),legacy:occurrence.corrected)
        }
    }
}
