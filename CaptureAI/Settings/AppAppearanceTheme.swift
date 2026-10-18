import AppKit
import SwiftUI

/// Preferência de aparência da janela de configurações.
enum AppAppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    /// Esquema SwiftUI concreto (nunca `nil`).
    ///
    /// `preferredColorScheme(nil)` após claro/escuro não reaplica o tema do
    /// macOS enquanto a janela continua key — por isso “Sistema” resolve na
    /// hora para claro/escuro atual.
    func resolvedColorScheme() -> ColorScheme {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return Self.macOSIsDark ? .dark : .light
        }
    }

    /// Aparência AppKit correspondente ao tema (sempre concreta).
    func resolvedNSAppearance() -> NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .system:
            return NSAppearance(named: Self.macOSIsDark ? .darkAqua : .aqua)
        }
    }

    /// Lê o tema real do macOS (não o da janela, que pode estar forçado).
    private static var macOSIsDark: Bool {
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return true
        }
        // Fallback se a chave ainda não estiver publicada.
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
