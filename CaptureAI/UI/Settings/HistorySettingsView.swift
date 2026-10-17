import SwiftUI

/// Aba Histórico: captura, lista, copiar e excluir transcrições.
struct HistorySettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showDeleteAllConfirmation = false
    @State private var detailWindowController = HistoryEntryDetailWindowController()
    /// Motivo pelo qual a reprodução não começou (arquivo apagado por fora).
    @State private var playbackErrorMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Captura") {
                SettingsRow(
                    title: "Salvar histórico",
                    description: "Guarda o texto de cada ditagem neste Mac."
                ) {
                    Toggle("", isOn: $viewModel.isTranscriptionHistoryEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsTheme.accent)
                }
            }

            HStack {
                Text(historyCountLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))

                Spacer(minLength: 8)

                Button("Excluir tudo") {
                    showDeleteAllConfirmation = true
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(viewModel.historyEntries.isEmpty)
            }

            if viewModel.historyEntries.isEmpty {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.historyEntries) { entry in
                        HistoryEntryCard(
                            entry: entry,
                            dateLabel: Self.dateFormatter.string(from: entry.createdAt),
                            durationLabel: durationLabel(for: entry),
                            isPlaying: viewModel.isPlayingHistoryAudio(entry.id),
                            hasAudio: entry.audioFileName != nil,
                            onPlay: { play(entry) },
                            onExpand: { openDetail(entry) },
                            onCopy: { viewModel.copyHistoryEntry(entry) },
                            onDelete: {
                                withAnimation(Self.listAnimation) {
                                    viewModel.deleteHistoryEntry(entry.id)
                                }
                            }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .move(edge: .trailing))
                            )
                        )
                    }
                }
            }
        }
        .animation(Self.listAnimation, value: viewModel.historyEntries.map(\.id))
        .alert("Excluir todo o histórico?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir tudo", role: .destructive) {
                withAnimation(Self.listAnimation) {
                    viewModel.deleteAllHistory()
                }
            }
        } message: {
            Text("Esta ação remove todas as transcrições salvas neste Mac e não pode ser desfeita.")
        }
        .alert(
            "Áudio não encontrado",
            isPresented: Binding(
                get: { playbackErrorMessage != nil },
                set: { if !$0 { playbackErrorMessage = nil } }
            )
        ) {
            Button("Entendi", role: .cancel) {}
        } message: {
            Text(playbackErrorMessage ?? "")
        }
        .onDisappear {
            detailWindowController.dismiss()
            viewModel.stopHistoryAudio()
        }
    }

    /// Animação suave ao inserir/remover cards do histórico.
    private static let listAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    private var historyCountLabel: String {
        let count = viewModel.historyEntries.count
        if count == 0 { return "Nenhuma transcrição salva" }
        if count == 1 { return "1 transcrição" }
        return "\(count) transcrições"
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nada por aqui ainda")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                Text(
                    viewModel.isTranscriptionHistoryEnabled
                        ? "As próximas ditagens (fora do modo teste) aparecem nesta lista."
                        : "Ligue “Salvar histórico” para guardar as próximas ditagens."
                )
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Toca o áudio da entrada, ou explica por que não dá.
    private func play(_ entry: TranscriptionHistoryEntry) {
        do {
            try viewModel.playHistoryAudio(entry)
        } catch {
            playbackErrorMessage = error.localizedDescription
        }
    }

    private func openDetail(_ entry: TranscriptionHistoryEntry) {
        detailWindowController.present(
            entry: entry,
            dateLabel: Self.dateFormatter.string(from: entry.createdAt),
            durationLabel: durationLabel(for: entry),
            appearance: viewModel.appearanceTheme.resolvedNSAppearance(),
            preferredColorScheme: viewModel.preferredColorScheme,
            relativeTo: viewModel.hostWindow,
            onCopy: {
                viewModel.copyHistoryEntry(entry)
            },
            onDelete: {
                withAnimation(Self.listAnimation) {
                    viewModel.deleteHistoryEntry(entry.id)
                }
            }
        )
    }

    /// Duração em `mm:ss`, com o minuto sempre em dois dígitos.
    ///
    /// Largura fixa: numa lista, `0:32` e `12:05` desalinhados chamam mais
    /// atenção que o próprio número.
    private func durationLabel(for entry: TranscriptionHistoryEntry) -> String? {
        guard let duration = entry.durationSeconds, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Card de uma entrada do histórico, com feedback visual ao copiar.
private struct HistoryEntryCard: View {
    let entry: TranscriptionHistoryEntry
    let dateLabel: String
    let durationLabel: String?
    let isPlaying: Bool
    let hasAudio: Bool
    let onPlay: () -> Void
    let onExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var didCopy = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .bottom, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(dateLabel)

                        if let durationLabel {
                            Text("–")
                            Text(durationLabel)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                    Spacer(minLength: 8)

                    // Só aparece quando existe áudio guardado: um play que não
                    // toca nada seria pior que play nenhum.
                    if hasAudio {
                        Button(action: onPlay) {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(HistoryIconButtonStyle())
                        .help(isPlaying ? "Parar reprodução" : "Ouvir o áudio")
                    }

                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(HistoryIconButtonStyle())
                    .help("Ver completa")

                    Button {
                        onCopy()
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(1_400))
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(
                                didCopy
                                    ? SettingsTheme.accent
                                    : SettingsTheme.secondaryLabel(colorScheme)
                            )
                    }
                    .buttonStyle(HistoryIconButtonStyle(overridesLabelColor: true))
                    .help(didCopy ? "Copiado" : "Copiar")
                    .animation(.easeOut(duration: 0.15), value: didCopy)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(HistoryIconButtonStyle())
                    .help("Excluir")
                }
            }
        }
    }
}

/// Botão compacto só com ícone, para ações do histórico.
private struct HistoryIconButtonStyle: ButtonStyle {
    /// Quando `true`, preserva a cor definida no `label` (ex.: checkmark de copiado).
    var overridesLabelColor = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if overridesLabelColor {
                configuration.label
            } else {
                configuration.label
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
            }
        }
        .frame(width: 28, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.ghostFill(colorScheme, pressed: configuration.isPressed))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsTheme.ghostStroke(colorScheme), lineWidth: SettingsTheme.hairline)
        }
        .opacity(configuration.isPressed ? 0.85 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
