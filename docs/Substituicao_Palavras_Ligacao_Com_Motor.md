# CaptureAI — Substituição de palavras ligada ao motor Parakeet

Registro do que foi implementado e do que foi medido.
Criado em: **2026-08-13** · Atualizado em: **2026-08-15**
Idioma: português
Projeto: `/Users/arley/Developer/CaptureAI`

---

## 0. Resumo em uma frase

A ligação está feita e funciona, mas só depois de duas correções que o
FluidAudio não entrega por padrão — sem elas a lista não corrige nada ou
**destrói** o texto em português.

---

## 1. Como ficou

| Peça | Arquivo |
|---|---|
| Modelo e validação | `CaptureAI/Transcription/WordReplacement.swift` |
| Persistência (JSON) | `CaptureAI/Transcription/WordReplacementStore.swift` |
| Modal de CRUD | `CaptureAI/UI/Settings/WordReplacementsModal.swift` |
| Download do CTC | `CaptureAI/Transcription/Local/LocalCtcModelStore.swift` |
| Card em Modelos → Local | `CaptureAI/UI/Settings/LocalModelsSettingsView.swift` |
| Ligação com o motor | `CaptureAI/Transcription/Local/LocalParakeetTranscriptionService.swift` |

O boosting só entra quando **as duas** condições valem: existe substituição
cadastrada e o CTC está em disco. Fora disso o ditado segue no caminho batch
de sempre, sem custo nenhum.

---

## 2. Por que exigiu um modelo extra

`configureVocabularyBoosting` só existe no `SlidingWindowAsrManager`; o
`AsrManager` (batch) não tem parâmetro equivalente em nenhuma das quatro
sobrecargas de `transcribe`. E o Parakeet TDT 0.6B não tem *head* CTC — quem
confere no áudio se a palavra falada corresponde ao termo é um modelo auxiliar
de 110M (98 MB em disco), baixado à parte.

Como o áudio inteiro já está em memória quando a ditagem termina, entregamos
tudo de uma vez: `startStreaming()` → `streamAudio(buffer único)` → `finish()`.
A janela padrão é a mesma 11+2+2 do caminho batch — é streaming na forma e
batch no efeito.

---

## 3. As duas correções que o padrão não dá

### 3.1 Termos precisam de `ctcTokenIds`

`CustomVocabularyTerm(text:aliases:)` aceita os dois campos de token como
opcionais, mas o rescorer tem uma guarda:

```
guard let vocabTokens = term.ctcTokenIds ?? term.tokenIds, !vocabTokens.isEmpty
else { continue }
```

Sem tokens, **todo candidato é descartado em silêncio** — o log diz
`Replacements: 0` e a lista inteira vira enfeite. A tokenização vem do
`CtcTokenizer.encode(...)`, que o FluidAudio só aplica no caminho de arquivo
(`loadWithCtcTokens`). Fazemos isso em memória, sem escrever JSON.

### 3.2 O resgate acústico precisa de piso de similaridade

Com os tokens no lugar o rescorer passa a agir — e, em português, age errado.
O CTC 110M é um modelo inglês; num ditado de 36 s ele produziu:

| | Resultado |
|---|---|
| Correção legítima | `branche` → `branch` ✅ |
| Trocas destrutivas | `teste falhar` → `commit commit commit commit`, `código` → `commit`, `o` → `android` ❌ |

`VocabularyRescorer.Config` tem `spotterRescueMinSimilarity` /
`spotterRescueMultiWordMinSimilarity`, **ambos desligados por padrão**. Com
`0.60` nos dois, as cinco trocas destrutivas somem e a correção legítima
sobrevive (similaridade ~0,92). É o valor usado hoje.

### 3.3 Ditagens curtas nunca eram avaliadas

O rescorer só roda quando o texto é **confirmado**, e a confirmação exige
`minContextForConfirmation` — 10 s por padrão. O log diz
`VOLATILE: insufficient context (3.1s)` e o texto sai intocado.

Como a maioria das ditagens tem menos de 10 s, na prática a lista quase nunca
era consultada. O padrão de 10 s existe para streaming ao vivo, onde confirmar
cedo faz o texto na tela mudar depois; aqui o áudio chega inteiro e só lemos o
resultado final, então esperar não protege nada. Baixado para **1 s**.

### 3.4 O piso do caminho principal

Com a confirmação em 1 s o rescorer passou a agir nas frases curtas — e a
`minSimilarity` padrão (0,52) mostrou o mesmo problema da seção 3.2 em outro
caminho: `branch própria` virou `branch main` e um `e` sumiu no meio da frase.
Note que os pisos de 3.2 **não** cobrem isto: eles guardam só o resgate
acústico, não o caminho principal.

Em **0,85** os dois estragos somem e nenhuma correção legítima é perdida. O
preço é recall: `branch meio` deixa de virar `branch main`.

| minSimilarity | `brand main` | `branch própria` | `e roda` |
|---|---|---|---|
| 0,52 | → `branch main` ✅ | → `branch main` ❌ | perdido ❌ |
| 0,75 | → `branch main` ✅ | preservado ✅ | perdido ❌ |
| **0,85** | → `branch main` ✅ | preservado ✅ | preservado ✅ |

### 3.5 A grafia cadastrada não era respeitada

`VocabularyRescorer+TokenEvaluation.swift:142` chama `preserveCapitalization`:
se a palavra que o **modelo** escreveu começa com maiúscula, a primeira letra
do termo cadastrado é maiusculizada. O Parakeet escreve `Brand` com maiúscula,
então `branch` voltava `Branch` sem existir nenhum cadastro assim.

Numa substituição de palavras a grafia cadastrada é o contrato, então o texto
do caminho com boosting passa por uma normalização final que devolve a forma
exata da lista. Como não dá para saber quais ocorrências vieram de uma troca, a
normalização vale para todas — o efeito colateral é o termo ficar minúsculo
mesmo começando frase.

---

## 4. Bug do FluidAudio contornado no nosso lado

Com vocabulário ligado, `finish()` remonta o texto de `confirmado + volátil`
em vez dos tokens (comentário no código: a remontagem por token desfaria o
rescoring). Se a **última janela sai vazia** — silêncio no fim da fala, que é
exatamente o que acontece ao soltar o atalho —, os dois campos ficam vazios e o
método devolve string vazia, perdendo a ditagem inteira.

Reproduzido de forma consistente com um áudio de 13,6 s: o mesmo áudio sem
boosting devolve 258 caracteres; com boosting, 0.

Contorno: quando o boosting devolve vazio, repetimos no caminho batch. O log
`local-parakeet` registra `boosting recuado para batch`.

---

## 5. Custos medidos

Áudio sintetizado com `say`, modelo quente, Apple Silicon.

| Áudio | Batch | Streaming sem boosting | Com boosting |
|---|---|---|---|
| 3,1 s | 91 ms | 65 ms | 172 ms |
| 5,3 s | 75 ms | 66 ms | 171 ms |
| 8,9 s | 77 ms | 76 ms | 191 ms |
| 36,5 s | 160 ms | 320 ms | 805 ms |

Com a confirmação em 1 s o rescorer roda também nas frases curtas, e elas
passam a custar ~100 ms a mais — o preço de a lista finalmente ser consultada.
Em 36 s a janela deslizante cobra ~2× e o boosting ~5× sobre o batch. A carga
inicial do CTC compila o Core ML e
leva ~12 s — por isso ele fica quente no cache e sai da RAM no mesmo idle
unload de 10 min do TDT (ver `Parakeet_Modelo_Em_Memoria_10min.md`).

---

## 6. Limitação que permanece

A janela deslizante degrada o texto em ditagens longas, **independente do
boosting**: nas emendas entre janelas aparecem repetições e trechos inventados.
No mesmo áudio de 36,5 s, comparado ao batch:

- `a revisão do código` → `a revisão do curso código`
- `voltamos atrás` → `volta a desplaz voltamos atrás`
- `para não o perder` → `para não operar. o perder`

Isso é do `SlidingWindowAsrManager`, não do CTC — aparece igual com o boosting
desligado. Ou seja: **quem liga a substituição de palavras troca qualidade de
emenda em ditagens longas por correção de vocabulário.** Por isso o recurso
exige dois passos deliberados (cadastrar a lista e baixar o modelo) e nunca
liga sozinho.

---

## 7. Como validar

1. Cadastrar `brand → branch`, `gridle → Gradle`, `anroid → Android`.
2. Baixar o modelo em Modelos → Local (card "Substituição de palavras").
3. Ditar as três palavras em frases naturais, com o modelo quente.
4. Conferir no log `local-parakeet` que aparece `boosting aplicado` e comparar
   o tempo com os números da tabela acima.
5. Ditar com a lista **vazia** e confirmar que o CTC nem é carregado.
6. Ditar "brand" no sentido de marca e confirmar que **não** vira "branch" —
   é o teste que separa boosting por áudio de find-replace cego.
7. Ditar 40 s ou mais e conferir as emendas (seção 6).
