import SwiftUI

/// Conteúdo da sub-aba Local: backend, modelo Parakeet, download e exclusão.
struct LocalModelsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showMissingModelAlert = false
    @Environment(\.colorScheme) private var colorScheme

    /// Único modelo local do app — o catálogo de modelos deixou de existir
    /// quando o Whisper saiu, então os rótulos vivem aqui mesmo.
    private enum Model {
        static let name = "NVIDIA Parakeet TDT 0.6B V3"
        static let description = "Ultra-rápido via Core ML (Neural Engine). Multilíngue europeu, ideal para ditado."
        static let sizeLabel = "~496 MB · multilíngue"
        static let systemImage = "bolt.fill"
    }

    var body: some View {
        VStack(spacing: 16) {
            backendCard
            modelCard
            wordReplacementModelCard
            footerBar
        }
        .onAppear {
            viewModel.refreshLocalModelDiskState()
        }
        .alert("Modelo local necessário", isPresented: $showMissingModelAlert) {
            Button("Entendi", role: .cancel) {}
        } message: {
            Text("Baixe o modelo local antes de ativar “Usar no ditado”. Enquanto isso, o atalho continua com a API OpenAI ou o modo teste.")
        }
    }

    // MARK: - Backend

    private var backendCard: some View {
        SettingsCard {
            SettingsRow(
                title: "Usar no ditado",
                description: viewModel.usesLocalTranscription
                    ? "Com o atalho, a transcrição roda no modelo local deste Mac (sem enviar áudio à OpenAI)."
                    : "Com o atalho, a transcrição usa a API OpenAI na nuvem. Ligue este interruptor para usar o modelo local baixado."
            ) {
                Toggle("", isOn: Binding(
                    get: { viewModel.usesLocalTranscription },
                    set: { newValue in
                        if newValue, !viewModel.localStatusIsReady {
                            showMissingModelAlert = true
                            return
                        }
                        viewModel.usesLocalTranscription = newValue
                        viewModel.parakeetModelStore.clearError()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SettingsTheme.accent)
            }
        }
    }

    // MARK: - Modelo

    private var modelCard: some View {
        let downloaded = viewModel.isLocalModelDownloaded
        let downloading = viewModel.isLocalModelDownloading
        let progress = viewModel.detailedDownloadProgress

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Model.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.08)))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(Model.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        if downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.40, green: 0.90, blue: 0.62))
                        }
                    }

                    Text(Model.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(Model.sizeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 8)

                actionButton(downloaded: downloaded, downloading: downloading)
            }

            if downloading, let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .tint(SettingsTheme.accent)
                    HStack {
                        HStack(spacing: 8) {
                            Text(progress.percentLabel)
                            Text("·")
                                .foregroundStyle(.white.opacity(0.35))
                            Text(progress.speedLabel)
                        }
                        Spacer(minLength: 8)
                        Text(progress.sizeLabel)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(downloaded ? SettingsTheme.sidebarSelection(colorScheme) : SettingsTheme.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    downloaded ? SettingsTheme.accent.opacity(0.55) : SettingsTheme.cardStroke(colorScheme),
                    lineWidth: SettingsTheme.hairline
                )
        }
    }

    // MARK: - Modelo da substituição de palavras

    /// Card do CTC 110M — o modelo auxiliar da substituição de palavras.
    ///
    /// Fica separado do Parakeet de propósito: o ditado funciona sem ele, e quem
    /// não usa substituições não deve pagar o download nem a RAM.
    private var wordReplacementModelCard: some View {
        let downloaded = viewModel.isCtcModelDownloaded
        let downloading = viewModel.isCtcModelDownloading

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.08)))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Substituição de palavras")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        if downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.40, green: 0.90, blue: 0.62))
                        }
                    }

                    Text("Modelo extra que ouve o áudio para confirmar a troca antes de aplicá-la — é o que evita corrigir uma palavra que você realmente disse. Baixe separadamente do modelo principal; sem ele o ditado funciona igual, só não corrige o vocabulário cadastrado.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(viewModel.ctcStatusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 8)

                ctcActionButton(downloaded: downloaded, downloading: downloading)
            }

            if downloading, let progress = viewModel.detailedCtcDownloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .tint(SettingsTheme.accent)
                    HStack {
                        HStack(spacing: 8) {
                            Text(progress.percentLabel)
                            Text("·")
                                .foregroundStyle(.white.opacity(0.35))
                            Text(progress.speedLabel)
                        }
                        Spacer(minLength: 8)
                        Text(progress.sizeLabel)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = viewModel.ctcModelStore.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(downloaded ? SettingsTheme.sidebarSelection(colorScheme) : SettingsTheme.cardFill(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    downloaded ? SettingsTheme.accent.opacity(0.55) : SettingsTheme.cardStroke(colorScheme),
                    lineWidth: SettingsTheme.hairline
                )
        }
    }

    @ViewBuilder
    private func ctcActionButton(downloaded: Bool, downloading: Bool) -> some View {
        if downloading {
            Button("Cancelar") {
                viewModel.cancelCtcModelDownload()
            }
            .buttonStyle(GhostButtonStyle())
        } else if downloaded {
            Button("Excluir") {
                viewModel.deleteCtcModel()
            }
            .buttonStyle(GhostButtonStyle())
        } else {
            Button {
                viewModel.downloadCtcModel()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    @ViewBuilder
    private func actionButton(downloaded: Bool, downloading: Bool) -> some View {
        if downloading {
            Button("Cancelar") {
                viewModel.cancelLocalModelDownload()
            }
            .buttonStyle(GhostButtonStyle())
        } else if downloaded {
            Button("Excluir") {
                viewModel.deleteLocalModel()
            }
            .buttonStyle(GhostButtonStyle())
        } else {
            Button {
                viewModel.downloadLocalModel()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: - Rodapé

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = viewModel.parakeetModelStore.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
            }

            HStack {
                Text(viewModel.downloadsFooterLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                Spacer(minLength: 12)

                Button {
                    viewModel.openLocalModelsFolder()
                } label: {
                    Label("Pasta", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.top, 4)
    }
}
