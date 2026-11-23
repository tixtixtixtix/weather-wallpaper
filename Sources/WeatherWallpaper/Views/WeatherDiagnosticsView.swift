import SwiftUI

struct WeatherDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.weatherIssue?.title ?? "Weather Diagnostics").font(.title2).bold()
            Text(model.weatherIssue?.errorDescription ?? "Open-Meteo supplies weather without an account, API key, or Apple Developer team.")
            Form {
                LabeledContent("Provider", value: "Open-Meteo")
                LabeledContent("Authentication", value: "None Required")
                LabeledContent("Refresh Interval", value: "15 Minutes")
            }
            .formStyle(.grouped).frame(height: 145)
            Text("The public endpoint is for eligible non-commercial use. Commercial distribution requires an appropriate Open-Meteo plan. Current conditions are model estimates, not on-site observations.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Link("Provider Details", destination: URL(string: "https://open-meteo.com/en/docs")!)
                Spacer()
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticText, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 530)
    }
}
