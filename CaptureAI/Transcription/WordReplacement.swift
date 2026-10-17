import Foundation

/// Um par "o que o modelo escreveu" → "o que deveria sair".
///
/// No motor local, cada par vira um termo de vocabulário do FluidAudio, onde a
/// substituição é a grafia canônica e o original entra como *alias*. Não é
/// find-replace no texto pronto: o reconhecimento usa o áudio como evidência,
/// então "brand" só vira "branch" quando o som combina.
struct WordReplacement: Identifiable, Codable, Equatable {
    let id: UUID
    /// O que o modelo costuma escrever, separado por vírgula quando há mais de
    /// uma variante (`brand, brant, brent`).
    ///
    /// Continua sendo uma `String` e não `[String]` porque é assim que o arquivo
    /// já está em disco, e porque é o texto que o campo mostra e edita. Quem
    /// precisa das variantes soltas usa `originals`.
    var original: String
    /// A grafia desejada (`branch`, `Gradle`, `Android`).
    var replacement: String
    /// Posição na lista. A ordem importa: é a ordem enviada ao motor, e é ela
    /// que desempata conflitos raros (`git` contra `GitHub`).
    var sortIndex: Int

    init(id: UUID = UUID(), original: String, replacement: String, sortIndex: Int) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.sortIndex = sortIndex
    }
}

/// Por que um par foi recusado, com a mensagem que a UI mostra.
enum WordReplacementValidationError: Equatable {
    case emptyField
    case tooShort(minimum: Int)
    case duplicated(original: String)

    var message: String {
        switch self {
        case .emptyField:
            return "Preencha os dois campos."
        case .tooShort(let minimum):
            return "Use pelo menos \(minimum) caracteres — termos curtos geram troca errada."
        case .duplicated(let original):
            return "Já existe uma substituição para “\(original)”."
        }
    }
}

extension WordReplacement {
    /// Mínimo de caracteres aceito nos dois lados.
    ///
    /// O padrão do FluidAudio é 3, porque pedaço curto casa com qualquer coisa
    /// (o exemplo do paper é `or` → `VR`). Só que isso barrava sigla legítima —
    /// `PR` → `pull request` é o caso real. O motor mede apenas o lado da
    /// substituição, então uma sigla curta na origem nunca correu esse risco.
    ///
    /// O que o paper protege continua valendo para uma substituição de dois
    /// caracteres; ali quem segura são os pisos de similaridade (0,85 no
    /// caminho principal), bem acima do padrão da biblioteca.
    static let minimumLength = 2

    /// As variantes do lado original, já separadas e limpas.
    ///
    /// Um cadastro só vira um termo do FluidAudio com vários *aliases* — que é
    /// exatamente como a biblioteca modela isso. Sem isto, cada variante exigia
    /// uma linha própria repetindo a mesma substituição.
    var originals: [String] {
        Self.parseOriginals(original)
    }

    /// Quebra por vírgula, tira espaços e descarta vazios e repetidos.
    ///
    /// Repetido sai porque `brand, Brand` mandaria o mesmo alias duas vezes ao
    /// motor; a comparação ignora caixa, como no resto da substituição.
    ///
    /// Quebra de linha separa igual à vírgula: o campo é multilinha, então
    /// Enter é um jeito natural de listar as variantes uma por linha.
    static func parseOriginals(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { piece in
                guard !piece.isEmpty else { return false }
                return seen.insert(piece.lowercased()).inserted
            }
    }

    /// Forma canônica para gravar: variantes separadas por vírgula e espaço.
    static func normalizedOriginal(_ text: String) -> String {
        parseOriginals(text).joined(separator: ", ")
    }
}
