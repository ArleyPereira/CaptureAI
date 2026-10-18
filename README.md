# CaptureAI

Ditado por voz para macOS. Você segura um atalho, fala, e o texto aparece no
campo em que estava — em qualquer app, sem copiar e colar.

A transcrição pode rodar **inteiramente no seu Mac**, sem enviar áudio para
lugar nenhum.

---

## O que ele faz

- **Ditado em qualquer app.** O texto vai para o campo em foco, seja um editor
  de código, um navegador ou o Mail.
- **Barra flutuante** com forma de onda e duração, e botões para pausar,
  retomar e descartar a gravação.
- **Substituição de palavras.** Uma lista sua de correções de vocabulário
  (`brand → branch`, `PR → pull request`). Não é troca cega de texto: um modelo
  auxiliar confere no áudio se a palavra falada corresponde ao termo antes de
  trocar, então `brand` no sentido de marca continua `brand`.
- **Histórico local** das transcrições, com opção de guardar o áudio de cada
  ditagem e ouvi-lo depois na própria barra flutuante.
- **Nada no clipboard.** A ditagem não passa pela área de transferência, então
  não polui seu histórico de cópia.
- Roda na barra de status, com atalho global padrão **⇧ Tab** (configurável).

## Modelos disponíveis

| | Local | API |
|---|---|---|
| Modelo | NVIDIA Parakeet TDT 0.6B V3 | `gpt-4o-mini-transcribe` |
| Onde roda | neste Mac, via Core ML / Neural Engine | servidores da OpenAI |
| Áudio sai da máquina? | **não** | sim |
| Custo | nenhum | consumo de créditos |
| Download | ~496 MB, uma vez | — |
| Requer | — | chave de API |

O modelo local é multilíngue (europeu) e é o caminho recomendado: além de
privado, é mais rápido, porque não depende de rede.

**Modelo auxiliar opcional (~98 MB):** só é necessário para a substituição de
palavras. Sem ele o ditado funciona igual — apenas não corrige o vocabulário
cadastrado. Baixa-se à parte, em *Modelos → Local*.

Os modelos ficam em `~/Library/Application Support/FluidAudio/Models/` e saem
da memória após 10 minutos ociosos, para o app não ocupar ~1 GB de RAM parado.

## Rodando o projeto

**Requisitos:** macOS 26.5+, Xcode 26+ e um Mac com Apple Silicon (o modelo
local usa o Neural Engine).

```bash
git clone https://github.com/ArleyPereira/CaptureAI.git
cd CaptureAI
open CaptureAI.xcodeproj
```

Em seguida, no Xcode: selecione o esquema **CaptureAI** e rode (**⌘R**). A
dependência ([FluidAudio](https://github.com/FluidInference/FluidAudio)) é
resolvida automaticamente via Swift Package Manager.

Para gerar uma build de release pela linha de comando:

```bash
xcodebuild -project CaptureAI.xcodeproj -scheme CaptureAI -configuration Release build
```

### Primeiro uso

1. Conceda as duas permissões que o macOS pede — **Microfone** (para gravar) e
   **Acessibilidade** (para escrever no app em foco). O app mostra o estado das
   duas em *Configurações → Geral*.
2. Em *Modelos → Local*, baixe o Parakeet e ligue **"Usar no ditado"**.
   Alternativamente, em *Modelos → API*, salve sua chave da OpenAI.
3. Segure **⇧ Tab**, fale, solte. O texto aparece no campo em foco.

## Onde ficam seus dados

Tudo é local e fica **fora** do repositório, em
`~/Library/Application Support/CaptureAI/`:

| Arquivo | Conteúdo |
|---|---|
| `transcription-history.json` | histórico de transcrições |
| `word-replacements.json` | sua lista de substituições |
| `Recordings/` | áudios, quando você opta por mantê-los |

A chave da API, quando usada, fica no **Keychain** — nunca em arquivo nem em log.

## Estrutura

```
CaptureAI/
├─ App/              estado central e ciclo de vida
├─ Audio/            captura, medição de nível e reprodução
├─ Hotkey/           atalho global
├─ Transcription/    motores (local e API) e substituição de palavras
├─ Input/            inserção do texto no app em foco
├─ Accessibility/    resolução do campo em foco
├─ History/          histórico local
└─ UI/               barra flutuante, configurações e menu da barra de status
```

A pasta [`docs/`](docs/) documenta as decisões menos óbvias — política de
memória dos modelos, comportamento do foco capturado e o que foi preciso
descobrir para ligar a substituição de palavras ao motor.

## Tecnologias

Swift · SwiftUI · AppKit · Core ML · AVFoundation · Accessibility API ·
[FluidAudio 0.15.5](https://github.com/FluidInference/FluidAudio)
