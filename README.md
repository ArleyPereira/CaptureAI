# CaptureAI

Um app de barra de status para macOS que junta três coisas que você faz o dia
inteiro: **ditar texto**, **lembrar o que copiou** e **capturar a tela**. Tudo
por atalho global, em qualquer app, sem trocar de janela.

O ditado pode rodar **inteiramente no seu Mac**, sem enviar áudio para lugar
nenhum, e o histórico e as capturas ficam só no seu disco.

---

## O que ele faz

### Ditado por voz

Segure **⇧ Tab**, fale e solte: o texto aparece no campo em foco, seja um
editor de código, um navegador, o Slack ou o Mail.

- **Transcrição local ou via API.** O modelo local (Parakeet) roda no Neural
  Engine e fica carregado na memória, então até a primeira ditagem do dia sai
  sem espera.
- **Barra flutuante** com forma de onda e duração, e botões para pausar,
  retomar e descartar a gravação.
- **Substituição de palavras.** Uma lista sua de correções de vocabulário
  (`brand → branch`, `PR → pull request`). Não é troca cega de texto: um modelo
  auxiliar confere no áudio se a palavra falada corresponde ao termo antes de
  trocar, então `brand` no sentido de marca continua `brand`.
- **Histórico local** das transcrições, com opção de guardar o áudio de cada
  ditagem e ouvi-lo depois na própria barra flutuante.
- **Seu clipboard fica intacto.** Quando o texto precisa ser colado, ele passa
  pela área de transferência marcado como transitório e o conteúdo anterior
  volta assim que o app de destino termina de colar.

### Histórico da área de transferência

Tudo o que você copia entra num histórico pesquisável, na aba *Área de
Transferência*.

- **Busca e filtros** por tipo (texto ou link) e por período.
- **Copiar, editar, fixar e excluir** cada item. Os fixados sobrevivem ao
  "limpar tudo" e ao limite de 500 itens.
- Mostra o **app de origem** de cada cópia e o domínio dos links.
- Exclusões podem ser **desfeitas** pelo aviso que aparece logo depois.

### Captura de tela

Aperte **Print Screen** (F13) e a tela congela para você escolher o que capturar.

- **Área:** arraste para selecionar; a seleção pode ser movida e
  redimensionada pelas alças.
- **Janela:** com **W**, passe o mouse sobre qualquer janela (inclusive modais
  e a área de trabalho) e clique. A imagem sai com o papel de parede ao fundo,
  margem e sombra, como num print de apresentação.
- **Tela inteira:** com **F**.
- **Editor no lugar.** Sem abrir outra janela: retângulo, elipse, seta, marca-
  texto e balão de texto, com seletor de cor e desfazer.
- **Miniatura flutuante** depois da captura, com *Copy* e *Save*. Dá para
  **arrastar** a miniatura direto para uma pasta do Finder ou para outro app
  (Slack, WhatsApp, Claude...). Várias capturas se empilham, com um contador
  quando passam de cinco.
- **Galeria das capturas salvas**, na aba *Área de Transferência → Imagens*:
  abrir, copiar, mostrar no Finder e excluir (vai para a Lixeira, com desfazer).
  As capturas ficam numa pasta que você escolhe.

## Atalhos

| Atalho | Ação |
|---|---|
| **⇧ Tab** (segurar) | ditar; solte para transcrever |
| **Print Screen** | captura de área (ao soltar a tecla) |
| **Print Screen + W** | captura de janela |
| **Print Screen + F** | captura de tela inteira |

Dentro do editor de captura: **W** alterna o modo janela, **F** captura a tela
inteira, **⌘C** ou **Enter** copia, **⌘S** salva, **⌘Z** desfaz e **Esc**
cancela. Os atalhos de ditado e de captura podem ser trocados nas
configurações.

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

Os modelos ficam em `~/Library/Application Support/FluidAudio/Models/`. Depois
de carregados, ficam residentes (cerca de 110 MB) para que nenhuma ditagem
pague o carregamento de novo; só são liberados se o macOS avisar que a memória
está criticamente baixa, e voltam sozinhos quando ela normaliza.

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

1. Conceda as permissões que o macOS pede — **Microfone** (para gravar),
   **Acessibilidade** (para escrever no app em foco e para os atalhos de
   captura) e **Gravação de Tela** (para capturar o conteúdo das janelas). O
   app mostra o estado de cada uma nas configurações.
2. Em *Modelos → Local*, baixe o Parakeet e ligue **"Usar no ditado"**.
   Alternativamente, em *Modelos → API*, salve sua chave da OpenAI.
3. Segure **⇧ Tab**, fale, solte. O texto aparece no campo em foco.
4. Aperte **Print Screen** para a primeira captura.

## Onde ficam seus dados

Tudo é local e fica **fora** do repositório, em
`~/Library/Application Support/CaptureAI/`:

| Arquivo | Conteúdo |
|---|---|
| `transcription-history.json` | histórico de transcrições |
| `clipboard-history.json` | histórico da área de transferência |
| `word-replacements.json` | sua lista de substituições |
| `Recordings/` | áudios, quando você opta por mantê-los |

As capturas salvas ficam em `~/Documents/CaptureAI/` (ou na pasta que você
escolher), como PNG comum: apagar um arquivo pelo Finder o tira da galeria.

A chave da API, quando usada, fica no **Keychain** — nunca em arquivo nem em log.

## Documentação técnica

A pasta [`docs/`](docs/) documenta as decisões menos óbvias — política de
memória dos modelos, comportamento do foco capturado e o que foi preciso
descobrir para ligar a substituição de palavras ao motor.

## Tecnologias

Swift · SwiftUI · AppKit · Core ML · AVFoundation · ScreenCaptureKit ·
Accessibility API ·
[FluidAudio 0.15.5](https://github.com/FluidInference/FluidAudio)
