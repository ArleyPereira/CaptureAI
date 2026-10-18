# CaptureAI — Modelo Parakeet na RAM e o unload por ociosidade (10 min)

Documento de referência para retomar e melhorar depois.
Criado em: **2026-08-11**
Idioma: português
Projeto: `/Users/arley/Developer/CaptureAI`

---

> **Atualização (2026-10-18): a descarga por ociosidade foi removida.**
>
> Os modelos agora ficam carregados enquanto o app estiver aberto e só são
> liberados num aperto **crítico** de memória do macOS — voltando sozinhos
> quando ele normaliza.
>
> Motivos, medidos:
> - A volta depois da descarga às vezes refaz a preparação para o Neural
>   Engine e leva **15–30 s**; o sistema decide quando, o app não controla.
> - Manter carregado custa **~110 MB** de memória do sistema (queda de memória
>   *wired* na descarga). O processo fica em ~40 MB; os ~600 MB vistos logo
>   após a carga são temporários da preparação, não residentes.
> - O Spokenly, que usa o mesmo FluidAudio e o mesmo `.cpuAndNeuralEngine`,
>   faz assim: aquece ao abrir (~15–20 s nos logs dele) e não descarrega o
>   Parakeet — usado 3h30 depois do aquecimento com `already initialized`.
>
> O restante deste documento descreve a política antiga e fica como registro.

---

## 0. Resumo em uma frase

O Parakeet sai da RAM após **10 minutos** sem uso; a primeira ditagem depois disso
paga a recarga do Core ML, que já foi medida custando de **menos de 1 s até 5,1 s**
— e ainda não sabemos o que explica essa variação.

---

## 1. O que o app faz hoje

Arquivo: `CaptureAI/Transcription/Local/LocalParakeetTranscriptionService.swift`

| Peça | Comportamento |
|---|---|
| `idleUnloadDelay` | `.seconds(600)` — 10 minutos |
| `scheduleIdleUnload()` | Reagenda o descarte ao fim de cada ditagem |
| `cancelIdleUnload()` | Cancela quando uma nova ditagem começa |
| `unloadCachedModel()` | Libera o `AsrManager` e loga `Modelo Parakeet liberado da memória` |
| `warmUpIfNeeded()` | Carrega o modelo e roda 1 s de silêncio para especializar a ANE |
| `loadManager()` | Single-flight: aquecimento e ditagem compartilham a mesma carga |

O aquecimento é disparado em dois momentos (`AppState`):

1. **No launch do app**, via `warmLocalModelsIfNeeded()`.
2. **No início de cada ditagem** (`beginDictationSession`) — a ideia é carregar o
   modelo **enquanto o usuário fala**, para que o custo não apareça.

---

## 2. Por que o unload existe

O Parakeet residente leva a RAM do app para a casa de **~1 GB**. A referência que
usamos, o Spokenly, fica em **~220 MB**. Deixar 1 GB ocupado o dia inteiro num app
de barra de menu que é usado em rajadas não se justifica.

O valor começou em **120 s** e subiu para **600 s** no PR de latência
(PR #4), por escolha explícita do usuário: 10 minutos cobrem uma sessão de trabalho
contínua sem recarregar, e ainda liberam a memória quando o app realmente para de
ser usado.

---

## 3. O custo medido (2026-08-11)

Sequência real, com o unload disparando às 09:45:37:

| ditagem | asr | inserção | total |
|---|---|---|---|
| **09:49:39** (1ª após o unload) | **5107 ms** | 965 ms | 6080 ms |
| 09:50:19 | 224 ms | 973 ms | 1203 ms |
| 09:50:41 | 195 ms | 1018 ms | 1221 ms |
| 09:51:02 | 193 ms | 1012 ms | 1212 ms |

Observações importantes:

- **Todo o excesso está no `asr`.** `captura`, `gates` e `inserção` ficaram
  idênticos aos das ditagens rápidas — não é regressão do pipeline de inserção.
- A ~1 s constante em `inserção` é o settle do clipboard, **não** latência
  percebida: o texto aparece na tela em ~40 ms, quando o ⌘V é enviado.
- Com o modelo quente, a ASR fica na faixa de **~200 ms**, inclusive para áudios
  longos (51 s de áudio já foram transcritos em 276 ms).

### O custo não é constante

Um caso anterior no mesmo dia teve carga a frio **muito** mais barata:

- 09:15:02 — `Modelo Parakeet liberado da memória`
- 09:25:07 — ditagem começa
- 09:25:08 — `Parakeet aquecido` (menos de 1 s depois)

Ou seja: a mesma operação custou **< 1 s** às 09:25 e cerca de **15 s** às 09:49
(10,5 s escondidos pela gravação + 5,1 s cobrados do usuário).

Hipóteses ainda **não verificadas** para essa variação:

- Pressão de memória (no teste lento havia Cursor com agente, Chrome e YouTube abertos).
- Disputa pela ANE com outro processo.
- Cache de página do sistema: os ~461 MB do modelo podem estar ou não em RAM.
- Estado térmico da máquina.

---

## 4. Por que o aquecimento não escondeu o custo

O aquecimento deveria tornar isso invisível, já que começa junto com a gravação.
No caso das 09:49 o usuário falou **10,5 s** e ainda assim sobraram 5,1 s — a carga
foi mais lenta que a fala.

Além disso, o log `Parakeet aquecido` **não apareceu** nessa ditagem. A explicação
provável está em `transcribe()`, que faz `warmTask?.cancel()` logo depois de
`loadManager()` retornar — para a ditagem real não ficar na fila do actor atrás da
inferência de silêncio do aquecimento. Como `loadManager()` é single-flight, a
ditagem entrou na mesma carga que o aquecimento iniciou, esperou por ela e cancelou
o aquecimento antes que ele chegasse a logar.

Isso é esperado, mas tem um efeito colateral: **o log deixa de registrar o
aquecimento justamente nos casos em que ele foi insuficiente**, que são os que mais
interessam.

---

## 5. Limitação de medição (resolver primeiro)

A linha que responderia "os 5,1 s foram carga ou inferência?" está censurada:

```
Parakeet OK — load <private> ms, infer <private> ms, total <private> ms
```

Os valores são interpolados sem anotação de privacidade, então o OSLog os oculta.
O `LatencyTrace` não tem esse problema porque usa `privacy: .public`.

**Antes de mexer em qualquer política de memória, tornar esses três números
públicos.** É uma linha, e sem ela qualquer ajuste é chute.

---

## 6. Caminhos de melhoria (com trade-offs)

Nenhum foi implementado. Ordem sugerida:

1. **Tornar `load`/`infer` públicos no log** (pré-requisito, ver seção 5).

2. **Aquecer antes da ditagem, não junto com ela.** Hoje a carga concorre com a
   fala. Alternativas: aquecer quando o app volta a ficar em foco, quando o usuário
   pressiona o modificador do atalho, ou logo após o unload se a máquina estiver
   ociosa. Custa RAM em momentos que talvez não virem ditagem.

3. **Unload em dois estágios.** Descartar primeiro o que é barato de reconstruir e
   manter o encoder residente por mais tempo. Exige entender o que o `AsrManager` do
   FluidAudio segura — não foi investigado.

4. **Tornar o tempo configurável.** Expor na aba Modelos um seletor (5 / 10 / 30 min
   / nunca). Simples, e transfere a escolha para quem conhece o próprio uso.

5. **Nunca descartar enquanto o app estiver em foco.** Casa a política com o uso
   real em vez de com um relógio fixo.

6. **Investigar a variação de 1 s → 15 s.** É o item de maior retorno, porque hoje
   nem sabemos se o problema é a política de 10 minutos ou uma lentidão pontual de
   carga que aconteceria com qualquer valor.

---

## 7. Onde mexer

| Arquivo | O quê |
|---|---|
| `CaptureAI/Transcription/Local/LocalParakeetTranscriptionService.swift` | `idleUnloadDelay`, `scheduleIdleUnload`, `warmUpIfNeeded`, `loadManager`, logs de `load`/`infer` |
| `CaptureAI/App/AppState.swift` | `warmLocalModelsIfNeeded()` e o ponto em que o aquecimento é disparado |
| `CaptureAI/Transcription/CompositeTranscriptionService.swift` | Roteamento e `unloadCachedLocalModel()` |
| `CaptureAI/Diagnostics/LatencyTrace.swift` | Marcos `asr` / `gates` usados nas medições acima |

---

## 8. Como medir de novo

```bash
rtk proxy log show --predicate 'subsystem == "dev.arley.santana.CaptureAI"' --last 45m --style compact --info
```

Roteiro:

1. Esperar o log `Modelo Parakeet liberado da memória` (ou aguardar 10 min ocioso).
2. Fazer uma ditagem **curta** (~5 s) — quanto menos fala, menos carga fica
   escondida, e mais visível fica o custo real.
3. Anotar o `asr` da linha `ditado:` e comparar com as ditagens seguintes.
4. Repetir com a máquina ociosa e com a máquina carregada (Cursor + navegador), para
   testar a hipótese de pressão de memória.

Números de referência atuais: **~200 ms** com modelo quente, **5107 ms** no pior caso
a frio já observado.
