import AppKit
import SwiftUI

/// Aba Área de Transferência: textos copiados e capturas de tela.
struct ClipboardSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var section: Section = .text
    @State private var kindFilter: KindFilter = .all
    @State private var period: ClipboardPeriod = .all
    @State private var search = ""
    @State private var editing: ClipboardEntry?
    @State private var showClearConfirmation = false
    @State private var showDeleteAllImagesConfirmation = false
    @State private var hasScreenPermission = ScreenRecordingPermission.isGranted
    @Environment(\.colorScheme) private var colorScheme

    enum Section: String, CaseIterable, Identifiable {
        case text, images
        var id: String { rawValue }
        var title: String { self == .text ? "Texto" : "Imagens" }
        var icon: String { self == .text ? "text.alignleft" : "photo.on.rectangle" }
    }

    /// Filtro de tipo. Separado de `ClipboardKind` porque precisa do "Todos",
    /// que não é um tipo de conteúdo e não deve existir no modelo gravado.
    enum KindFilter: String, CaseIterable, Identifiable {
        case all, text, link
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Todos"
            case .text: return "Texto"
            case .link: return "Links"
            }
        }
        var kind: ClipboardKind? {
            switch self {
            case .all: return nil
            case .text: return .text
            case .link: return .link
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            sectionPicker

            switch section {
            case .text: textSection
            case .images: imagesSection
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: section)
        .sheet(item: $editing) { entry in
            ClipboardEditSheet(entry: entry) { updated in
                viewModel.updateClipboardEntry(entry.id, content: updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .onAppear {
            viewModel.reloadScreenshots()
            refreshPermission()
        }
    }

    // MARK: - Seletor de seção

    private var sectionPicker: some View {
        SettingsSegmentedTabs(
            items: Section.allCases,
            selection: $section,
            title: \.title,
            icon: \.icon
        )
    }

    // MARK: - Texto

    private var filteredEntries: [ClipboardEntry] {
        viewModel.filteredClipboardEntries(
            kind: kindFilter.kind,
            period: period,
            search: search
        )
    }

    private var textSection: some View {
        VStack(spacing: 14) {
            SettingsCard(title: "Captura automática") {
                SettingsRow(
                    title: "Guardar o que eu copiar",
                    description: "Cada cópia entra na lista abaixo, pronta para reusar."
                ) {
                    Toggle("", isOn: $viewModel.isClipboardHistoryEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsTheme.accent)
                }
            }

            filterBar

            if filteredEntries.isEmpty {
                emptyState(
                    title: viewModel.clipboardEntries.isEmpty ? "Nada copiado ainda" : "Nenhum resultado",
                    message: viewModel.clipboardEntries.isEmpty
                        ? (viewModel.isClipboardHistoryEnabled
                            ? "Copie algo em qualquer app e o item aparece aqui."
                            : "Ligue “Guardar o que eu copiar” para começar.")
                        : "Tente outro termo ou amplie o período."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredEntries) { entry in
                        ClipboardEntryCard(
                            entry: entry,
                            onCopy: { viewModel.copyClipboardEntry(entry) },
                            onEdit: { editing = entry },
                            onPin: { viewModel.toggleClipboardPin(entry.id) },
                            onDelete: { viewModel.deleteClipboardEntry(entry.id) }
                        )
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
                TextField("Buscar no histórico", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .fill(SettingsTheme.fieldFill(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsTheme.fieldCornerRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.fieldStroke(colorScheme), lineWidth: SettingsTheme.hairline)
            }

            HStack(spacing: 8) {
                Picker("", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Picker("", selection: $period) {
                    ForEach(ClipboardPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                Spacer(minLength: 8)

                Text(countLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                Button("Limpar tudo") { showClearConfirmation = true }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(viewModel.clipboardEntries.isEmpty)
            }
        }
        .alert("Limpar o histórico de texto?", isPresented: $showClearConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Limpar", role: .destructive) { viewModel.clearClipboardHistory() }
        } message: {
            Text("Os itens fixados são mantidos. Esta ação não pode ser desfeita.")
        }
    }

    private var countLabel: String {
        let total = filteredEntries.count
        if total == 1 { return "1 item" }
        return "\(total) itens"
    }

    // MARK: - Imagens

    private var imagesSection: some View {
        VStack(spacing: 14) {
            if !hasScreenPermission {
                permissionCard
            }

            SettingsCard(title: "Captura de tela") {
                VStack(spacing: 12) {
                    SettingsRow(
                        title: "Pasta das capturas",
                        description: viewModel.screenshotDirectoryLabel
                    ) {
                        HStack(spacing: 6) {
                            Button("Alterar…") { viewModel.chooseScreenshotDirectory() }
                                .buttonStyle(GhostButtonStyle())
                            Button {
                                viewModel.openScreenshotDirectory()
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(GhostButtonStyle())
                            .help("Abrir no Finder")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                Text(imageCountLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.tertiaryLabel(colorScheme))

                Button("Excluir tudo") { showDeleteAllImagesConfirmation = true }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(viewModel.screenshotEntries.isEmpty)
            }

            if let message = viewModel.captureCoordinator.lastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 11.5))
                    Spacer(minLength: 4)
                    Button {
                        viewModel.captureCoordinator.lastMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsTheme.fieldFill(colorScheme))
                }
            }

            if viewModel.screenshotEntries.isEmpty {
                emptyState(
                    title: "Nenhuma captura ainda",
                    message: "Use \(viewModel.captureHotkey.displayName) para capturar. As capturas que você salvar aparecem aqui."
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(viewModel.screenshotEntries) { entry in
                        ScreenshotCard(
                            entry: entry,
                            onOpen: { viewModel.openScreenshot(entry) },
                            onCopy: { viewModel.copyScreenshot(entry) },
                            onReveal: { viewModel.revealScreenshot(entry) },
                            onDelete: { viewModel.deleteScreenshot(entry) }
                        )
                    }
                }
            }
        }
        .alert(deleteAllImagesTitle, isPresented: $showDeleteAllImagesConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir", role: .destructive) { viewModel.deleteAllScreenshots() }
        } message: {
            Text(deleteAllImagesMessage)
        }
    }

    /// Aviso da permissão de Gravação de Tela.
    ///
    /// Sem ela a seleção até abre, mas a imagem sai com o papel de parede no
    /// lugar das janelas. Avisar antes evita uma captura inútil e a impressão
    /// de que a função está quebrada.
    private var permissionCard: some View {
        SettingsCard(
            title: "Permissão necessária",
            subtitle: "O macOS exige autorização de Gravação de Tela para capturar o conteúdo das janelas. Sem ela, a captura sai só com o fundo da área de trabalho."
        ) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Abrir Ajustes") {
                    ScreenRecordingPermission.openSystemSettings()
                }
                .buttonStyle(GhostButtonStyle())

                Button("Permitir…") {
                    ScreenRecordingPermission.request()
                    refreshPermission()
                }
                .buttonStyle(GradientButtonStyle())
            }
        }
    }

    private func refreshPermission() {
        hasScreenPermission = ScreenRecordingPermission.isGranted
    }

    /// O número vai no título: é a informação que decide se a pessoa
    /// confirma, e numa exclusão em massa ela precisa vê-lo antes do botão.
    private var deleteAllImagesTitle: String {
        let total = viewModel.screenshotEntries.count
        return total == 1 ? "Excluir 1 arquivo?" : "Excluir \(total) arquivos?"
    }

    private var deleteAllImagesMessage: String {
        let total = viewModel.screenshotEntries.count
        let subject = total == 1 ? "O arquivo será apagado" : "Os \(total) arquivos serão apagados"
        return "\(subject) da pasta de capturas. Esta ação não pode ser desfeita."
    }

    private var imageCountLabel: String {
        let total = viewModel.screenshotEntries.count
        if total == 1 { return "1 captura" }
        return "\(total) capturas"
    }

    // MARK: - Vazio

    private func emptyState(title: String, message: String) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.primaryLabel(colorScheme))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.secondaryLabel(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
