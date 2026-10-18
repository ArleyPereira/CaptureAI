# CaptureAI — Foco capturado no início da gravação vs. foco atual na inserção

Documento de referência para retomar e decidir depois.
Criado em: **2026-08-11**
Idioma: português
Projeto: `/Users/arley/Developer/CaptureAI`

---

## 0. Resumo em uma frase

O CaptureAI guarda o campo em foco **quando a gravação começa** e dá preferência a ele
na hora de inserir; se o usuário trocar de campo **durante** a fala, a ditagem vai
para o campo antigo, não para o que ele escolheu por último.

---

## 1. Como funciona hoje

### 1.1 A captura

`AppState.beginDictationSession` chama `captureFocusBeforeRecordingBestEffort()`
(`CaptureAI/App/AppState.swift:274`) **antes** de iniciar a gravação. O elemento vai
para `capturedFocusedElement` sem nenhum filtro de editabilidade — pode ser um campo
de texto, uma janela, ou um `AXGroup` do Finder.

### 1.2 A escolha do alvo

No fim da ditagem, `AppState` passa esse elemento adiante
(`textInsertionService.insert(text:into:)`), e
`DefaultTextInsertionService.performInsertion` monta os candidatos:

```swift
let liveTarget = await resolveTargetWithRetry()
let candidates = [captured, liveTarget].compactMap { $0 }

guard let target = candidates.compactMap({ resolveEditableTarget(from: $0) }).first
```

**O capturado vem primeiro na lista.** Como o `guard` pega o *primeiro editável*, o
foco atual só é usado quando o capturado não é editável.

### 1.3 A reativação do app capturado

Antes de reler o foco, o serviço traz o app capturado de volta para frente:

```swift
if let captured, resolveEditableTarget(from: captured) != nil {
    try? await activateAndWait(pid: captured.processID)
}
```

Isso existe porque, depois de uma transcrição longa, o app alvo pode ter perdido o
frontmost — reativar evita inserir num alvo fantasma.

A condição `resolveEditableTarget(from: captured) != nil` não é decorativa: reativar
um app cujo elemento capturado **não** é editável rouba o foco que o usuário tenha
escolhido durante a fala, e ainda faz o CaptureAI ler como "sem campo editável" uma
janela que ele mesmo trouxe para frente. Como um capturado não-editável nunca passa
pelo `guard` da seção 1.2, ativá-lo não traz ganho em cenário nenhum.

---

## 2. O caso que continua em aberto

**Cenário:** começar a ditar com o **Cursor** em foco e, durante a gravação, clicar
no input do **Claude**.

**O que acontece:** o capturado (Cursor) é editável, então o CaptureAI reativa o Cursor
e insere lá. A escolha mais recente do usuário é ignorada.

Segue em aberto por escolha: mudar isso mexe num caminho que hoje funciona.

### Por que o capturado tem prioridade

A prioridade não é arbitrária. O foco na hora da inserção é frágil:

- A barra flutuante do CaptureAI pode perturbar o foco ao aparecer/sumir.
- Apps Electron demoram a republicar `kAXFocusedUIElement`, e uma leitura precoce
  devolve a janela em vez do campo.
- Depois de uma transcrição longa o app alvo pode ter perdido o frontmost.

O capturado é uma referência estável tirada num momento calmo. Trocar a prioridade
sem cuidado reintroduz a classe de bug que ele existe para evitar.

---

## 3. Opções para mudar (nenhuma implementada)

### Opção A — Foco atual ganha quando é editável

Inverter a ordem dos candidatos: `[liveTarget, captured]`.

- **A favor:** respeita a última escolha do usuário, que é a intenção mais recente.
- **Contra:** volta a depender de uma leitura de foco frágil justamente no momento
  mais instável do fluxo. É a troca que precisa ser medida, não presumida.

### Opção B — Foco atual ganha só quando muda de aplicativo

Usar o foco atual quando `liveTarget.processID != captured.processID` e o alvo atual
é editável; caso contrário, manter o capturado.

- **A favor:** cobre exatamente o cenário relatado (trocar de app durante a fala) e
  preserva o comportamento estável dentro do mesmo app, que é onde o foco costuma
  oscilar por conta da barra flutuante.
- **Contra:** não cobre a troca entre dois campos do **mesmo** app.
- **Avaliação:** parece o melhor custo-benefício, mas não foi testado.

### Opção C — Recapturar o foco ao fim da gravação

Além da captura inicial, capturar de novo no instante em que o atalho encerra a
gravação, antes da transcrição.

- **A favor:** pega a intenção do usuário sem depender do foco pós-transcrição, que é
  o momento realmente instável.
- **Contra:** mais uma consulta AX no caminho crítico (hoje ~4 ms em `gates`), e não
  resolve se o usuário trocar de campo *durante* a transcrição.

### Opção D — Perguntar quando houver conflito

Se o capturado e o atual forem ambos editáveis e diferentes, oferecer a escolha.

- **Contra:** transforma o caso comum em interrupção. Contraria o objetivo do produto,
  que é ditar e seguir. Registrada só para descartar de forma explícita.

---

## 4. Onde mexer

| Arquivo | O quê |
|---|---|
| `CaptureAI/Input/DefaultTextInsertionService.swift` | `performInsertion` — ordem de `candidates`, reativação, `resolveEditableTarget` |
| `CaptureAI/App/AppState.swift` | `captureFocusBeforeRecordingBestEffort()` e o ponto da captura (`beginDictationSession`) |

---

## 5. Como testar qualquer mudança aqui

Os quatro cenários precisam passar **juntos**. Os dois primeiros puxam para lados
opostos — um quer que o foco atual vença, o outro que o capturado vença — e já houve
correção aqui que resolveu um e quebrou o outro.

1. **Sem foco → clica num input durante a fala.** Texto entra onde o usuário clicou.
2. **Input em foco desde o início, fala longa (>30 s).** Texto entra no mesmo campo.
   É o caso que a reativação protege.
3. **Troca entre dois apps editáveis durante a fala.** Hoje vai para o primeiro;
   qualquer mudança precisa declarar qual passa a ser o comportamento esperado.
4. **Foco no Finder o tempo todo.** A barra de resgate **deve** aparecer.

Log para acompanhar:

```bash
rtk proxy log show --predicate 'subsystem == "dev.arley.santana.CaptureAI"' --last 20m --style compact --info
```

A linha que revela a decisão é a `Alvo: ... capturado=... ao-vivo=...`, que mostra os
dois candidatos lado a lado e qual foi escolhido.
