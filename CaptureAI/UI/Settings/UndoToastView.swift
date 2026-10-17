import SwiftUI

/// Aviso flutuante na base do painel: "Texto excluído · Desfazer".
///
/// Fica sobre o conteúdo, não dentro da lista, para continuar visível mesmo
/// com a lista rolada — a exclusão pode ter sido do último item lá embaixo.
struct UndoToastView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let toast = viewModel.undoToast {
                HStack(spacing: 14) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(toast.message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))

                    Button("Desfazer") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            viewModel.performUndo()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
                    .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.leading, 16)
                .padding(.trailing, 18)
                .frame(height: 40)
                .background {
                    Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.72 : 0.82))
                }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .onHover { viewModel.setUndoToastHovered($0) }
                // O id muda a cada exclusão: uma nova substitui a anterior com
                // a mesma animação, em vez de só trocar o texto no lugar.
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 22)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: viewModel.undoToast?.id)
    }
}
