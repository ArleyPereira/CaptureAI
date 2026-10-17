import SwiftUI

/// Indicador visual do estado atual da aplicação.
struct StatusIndicator: View {
    let state: RecordingState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.55), radius: state == .recording ? 3 : 0)

            Text(state.statusLabel)
                .font(.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(state.statusLabel)")
    }

    private var color: Color {
        switch state {
        case .idle, .success:
            return .green
        case .recording:
            return .red
        case .paused, .transcribing, .inserting, .awaitingManualInsert:
            return .orange
        case .error:
            return .red
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        StatusIndicator(state: .idle)
        StatusIndicator(state: .recording)
        StatusIndicator(state: .transcribing)
        StatusIndicator(state: .error)
    }
    .padding()
}
