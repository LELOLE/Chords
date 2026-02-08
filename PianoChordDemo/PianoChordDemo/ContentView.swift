import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChordDetectionViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Piano Chord Demo")
                .font(.largeTitle.bold())

            Text(viewModel.currentChordName)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundStyle(viewModel.currentChordName == "Unknown" ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 10) {
                Label("Detected Notes", systemImage: "music.note.list")
                    .font(.headline)
                Text(viewModel.detectedNotesText)
                    .font(.title3.monospaced())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Label("Confidence", systemImage: "waveform.path.ecg")
                    .font(.headline)
                ProgressView(value: viewModel.confidence)
                Text("\(Int(viewModel.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            Text("Tip: play 3-4 notes together (triad/seventh) near middle C for best detection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(viewModel.isRunning ? "Stop Listening" : "Start Listening") {
                viewModel.toggleListening()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
