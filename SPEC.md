# Mat Notes — Especificação Técnica

Documento de referência para **recriar este plugin do zero** ou **evoluí‑lo** em
outro Omarchy 4. Descreve o contrato do shell, cada arquivo, cada função, as decisões
de implementação e as armadilhas descobertas na construção.

> Ambiente alvo: **Omarchy 4 (Quattro)**, testado em 4.0.3. Shell = um processo
> Quickshell (`omarchy-shell`) que hospeda a barra, overlays e plugins. UI em QML
> (`QtQuick` / `Quickshell`), tema e primitivas em `qs.Commons` e `qs.Ui`.

---

## 1. Visão geral

`mat-notes` é um plugin `overlay` que abre um modal central em camada (layer‑shell)
editando **um único arquivo Markdown** (`~/notes.md` por padrão). Comportamento:

- Abre por atalho de teclado ou por botão no menu do Omarchy.
- Autosave ~400 ms após parar de digitar, e também ao fechar.
- `Esc` **salva e fecha**; clicar fora da carta também salva e fecha.
- Reabre instantaneamente (o overlay fica carregado) e reflete edições externas.
- Edição em **texto puro** (fonte Markdown), sem preview renderizado.

IDs e nomes usados: `mat-notes` (plugin id), `Mat Notes` (nome), `Notes` (rótulo de menu).

---

## 2. Inventário de arquivos

Dentro de `~/.config/omarchy/plugins/mat-notes/`:

| Arquivo | Papel |
|---------|-------|
| `manifest.json` | Declara o plugin ao shell (kind `overlay`, entry point, settings). |
| `Overlay.qml` | Toda a lógica e a UI do overlay. |
| `README.md` | Instruções de instalação para o usuário final. |
| `.gitignore` | Ignora ruído de editor/OS. |

Arquivos de **integração fora** da pasta do plugin (são do usuário, não vêm no repo):

| Arquivo | O que adicionar |
|---------|-----------------|
| `~/.config/hypr/bindings.lua` | Atalho `SUPER + N` → `omarchy-shell -q shell toggle mat-notes`. |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | Entry `mat.notes` (botão no menu). |
| `~/.config/omarchy/shell.json` | `plugins[]` ganha `{ "id": "mat-notes" }` (via `omarchy plugin enable`). Opcional: `"path"`. |

---

## 3. Contrato de plugin `overlay` (Omarchy 4)

O shell descobre o plugin pelo `manifest.json` e instancia o QML apontado por
`entryPoints.overlay`. O objeto raiz (`Item { id: root }`) **deve** expor estes
métodos — o shell os chama via IPC:

| Método | Chamado quando | Deve fazer |
|--------|----------------|------------|
| `open(payloadJson)` | `shell toggle` abre, ou `shell call <id> open` | tornar visível, focar o editor. |
| `close()` | `shell hide` (geralmente indireto) | salvar e ocultar. |
| `dismiss()` | ação de fechar (Esc, clique fora) | salvar, `opened=false`, `root.shell.hide(id)`. |
| `toggle()` | `omarchy-shell shell toggle <id>` | `dismiss()` se aberto, senão `open("{}")`. |

O shell injeta no root:
- `root.shell` — **facade escopada** de terceiro (ver §6).
- `root.manifest` — cópia do manifest (sem settings do `shell.json` mesclados).

A visibilidade é controlada pela propriedade `root.opened` ligada a
`PanelWindow.visible`. `dismiss()` chama `root.shell.hide(pluginId)` para o shell
desmontar a superfície de forma oficial (além de `opened=false`).

**IPC útil:**
```
omarchy-shell -q shell toggle mat-notes   # abre/fecha
omarchy-shell shell listPlugins            # lista plugins (enabled/active)
omarchy-shell shell rescanPlugins          # reescaneia/disponibiliza código
omarchy plugin enable mat-notes           # adiciona entry em shell.json plugins[]
```

> `keepLoaded: true` mantém a instância montada entre aberturas (reabre na hora).
> **Armadilha:** mudanças de *código* num plugin `keepLoaded` **não** entram por
> hot‑reload — exige `omarchy restart shell`. Hot‑reload só vale para plugins sem
> `keepLoaded` ou para edição de arquivos já carregados sem essa flag.

---

## 4. `manifest.json`

```json
{
  "schemaVersion": 1,
  "id": "mat-notes",
  "name": "Mat Notes",
  "version": "1.0.0",
  "author": "mat",
  "license": "MIT",
  "description": "A modal Markdown note editor: one file, autosaved, reopened by shortcut or menu.",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "Overlay.qml" },
  "overlay": {
    "defaults": { "path": "" },
    "schema": [
      { "key": "path", "type": "string", "label": "Note file" }
    ]
  }
}
```

Campos obrigatórios por `PluginRegistry.validateManifest`: `id`, `name`, `version`,
`kinds` (array não vazio), `entryPoints`. `id` não pode conter `/` ou `..`.

- `kinds: ["overlay"]` + `entryPoints.overlay` → contrato de overlay (§3).
- `keepLoaded: true` → instância persiste; reabre instantâneo.
- `overlay.defaults` / `overlay.schema` → metadados de settings (usados aqui apenas
  como documentação; a leitura real do `path` é feita diretamente — ver §7).
- `id` e `name` devem ser únicos; `omarchy plugin enable` cria `{ "id": "mat-notes" }`
  em `shell.json` `plugins[]` se ausente.

---

## 5. `Overlay.qml` — estrutura

Imports: `QtQuick`, `Quickshell`, `Quickshell.Io`, `Quickshell.Wayland`, `qs.Commons`,
`qs.Ui`.

### 5.1 Propriedades de estado (raiz)

| Propriedade | Tipo | Papel |
|-------------|------|-------|
| `shell`, `manifest` | var | injetados pelo shell. |
| `opened` | bool | controla `PanelWindow.visible`. |
| `dirty` | bool | há texto não salvo. |
| `pendingText` | string | texto a salvar (espelho do editor). |
| `diskText` | string | último conteúdo confirmado em disco. |
| `diskReady` | bool | `FileView` já carregou o arquivo. |
| `pluginId` | readonly string | `root.manifest.id || "mat-notes"`. |
| `home` | readonly string | `Quickshell.env("HOME")`. |
| `configuredPath` | string | `path` lido de `shell.json` (vazio ⇒ default). |
| `notePath` | readonly string | arquivo alvo (reativo a `configuredPath`). |
| `noteDirectory` | readonly string | diretório de `notePath` (criado no start). |

### 5.2 Settings (leitura de `shell.json`)

```js
function expandPath(p) {
  var s = String(p || "").trim()
  if (s === "" || s === "~") return root.home
  if (s.indexOf("~/") === 0) return root.home + s.slice(1)
  if (s.indexOf("$HOME/") === 0) return root.home + s.slice(5)
  return s
}

function readConfigPath(raw) {
  try {
    var cfg = JSON.parse(String(raw || ""))
    if (cfg && Array.isArray(cfg.plugins)) {
      for (var i = 0; i < cfg.plugins.length; i++) {
        var e = cfg.plugins[i]
        if (e && String(e.id) === "mat-notes") return String(e.path || "")
      }
    }
  } catch (e) {}
  return ""
}

property string configuredPath: ""
readonly property string notePath: (root.configuredPath || "") === ""
  ? (root.home + "/notes.md")
  : root.expandPath(root.configuredPath)

function dirOf(p) {
  var s = String(p || "")
  var idx = s.lastIndexOf("/")
  return idx <= 0 ? root.home : s.slice(0, idx)
}
readonly property string noteDirectory: root.dirOf(root.notePath)

FileView {
  id: configFile
  path: root.home + "/.config/omarchy/shell.json"
  watchChanges: true
  onLoaded: root.configuredPath = root.readConfigPath(text())
  onLoadFailed: root.configuredPath = ""
  onFileChanged: reload()
}
```

- `notePath` e `noteDirectory` são **bindings reativos** (não IIFE) — dependem de
  `configuredPath`, que por sua vez vem do `FileView` `configFile`. Assim, quando o
  `shell.json` muda, o caminho reavalia e o arquivo de nota é trocado.
- `configFile` lê `shell.json` diretamente. **Por quê:** a facade de terceiro **não
  expõe `shellConfig`** no Omarchy 4 (ver §7). Esta é a fonte canônica das settings
  inline em `plugins[]`.

`onNotePathChanged: root.diskReady = false` — trocar o caminho zera `diskReady`,
forçando o `FileView` da nota a recarregar o novo arquivo.

### 5.3 Lifecycle (contrato §3)

```js
function open(payloadJson) {
  if (!root.diskReady) { Qt.callLater(function() { root.open(payloadJson) }); return }
  root.opened = true
  Qt.callLater(function() {
    editor.forceActiveFocus()
    editor.cursorPosition = editor.length
  })
}
function close() { root.flush(); root.opened = false }
function dismiss() {
  root.flush()
  root.opened = false
  if (root.shell && typeof root.shell.hide === "function")
    root.shell.hide(root.pluginId)
}
function toggle() {
  if (root.opened) { root.dismiss() }
  else { root.open("{}") }
}
```

- `open` espera `diskReady` (o `FileView` carrega async); `Qt.callLater` repete até
  pronto. Ao abrir, foca o editor e põe o cursor no fim.
- `dismiss` é o caminho de fechamento real: **salva** (`flush`) e pede ao shell para
  esconder (`root.shell.hide`). `close` é simétrico sem o `hide` (usado se o shell
  chamar `hide` por fora).
- `toggle` é o que `omarchy-shell shell toggle mat-notes` invoca.

> **Armadilha (QML):** `if (a) x() else y()` numa linha única **não parseia** no
> engine QML/V4 deste ambiente — erro `Expected token ','`. Use chaves em ambos os
> ramos (forma acima).

### 5.4 Persistência

```js
function noteEdited(text) {
  root.pendingText = text
  root.dirty = true
  saveTimer.restart()
}
function flush() {
  if (!root.dirty) return
  saveTimer.stop()
  noteFile.setText(root.pendingText)
}
function applyFromDisk(text) {
  if (root.dirty) return
  var value = String(text || "")
  if (root.diskText === value && editor.text === value) { editor.restored = true; return }
  root.diskText = value
  if (editor.text === value) { editor.restored = true; return }
  var pos = editor.cursorPosition
  editor.restored = false
  editor.text = value
  editor.restored = true
  editor.cursorPosition = Math.min(pos, editor.length)
}

Timer { id: saveTimer; interval: 400; onTriggered: root.flush() }

FileView {
  id: noteFile
  path: root.notePath
  watchChanges: true
  atomicWrites: true
  printErrors: false
  onLoaded: { root.diskReady = true; root.applyFromDisk(text()) }
  onLoadFailed: { root.diskReady = true; root.applyFromDisk("") }
  onFileChanged: reload()
  onSaved: { root.dirty = false; root.diskText = root.pendingText }
  onSaveFailed: console.warn("mat-notes: could not save", root.notePath)
}

Component.onCompleted: {
  if (root.noteDirectory) Quickshell.execDetached(["mkdir", "-p", root.noteDirectory])
}
```

Fluxo de salvamento:
1. `editor.onTextChanged` → `if (restored) root.noteEdited(text)` (texto digitado).
2. `noteEdited` marca `dirty` e reinicia o timer de 400 ms (debounce).
3. `flush` (timer ou `dismiss`) → `noteFile.setText(pendingText)` → escrita atômica.
4. `onSaved` zera `dirty` e sincroniza `diskText`.

`applyFromDisk` aplica o conteúdo do disco no editor. A flag `editor.restored`
 impede que o `onTextChanged` gerado por *nossa* atribuição `editor.text = value`
 marque `dirty` (ela só é `true` durante a atribuição programática e volta a `true`
depois). **Armadilha:** o early‑return quando arquivo está vazio (`diskText === value
&& editor.text === value`) deve também setar `editor.restored = true`, senão a
primeira digitação num arquivo novo não dispara autosave.

### 5.5 Superfície modal (UI)

```
PanelWindow (id: panel)
  visible: root.opened
  WlrLayershell.namespace: "mat-notes"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  Shortcut { sequence: "Escape"; context: Qt.WindowShortcut; enabled: root.opened; onActivated: root.dismiss() }
  Rectangle (scrim, cor root.scrim)         // fundo escurecido
  MouseArea (preenche tudo) onClicked: root.dismiss()   // clicar fora fecha
  BorderSurface (id: card)                  // carta central
    MouseArea onClicked: editor.forceActiveFocus()
    Column
      Flickable > TextEdit (id: editor)     // o editor (PlainText, wrap)
        Text (placeholder "Type your note…" quando vazio)
    Text (id: pathLabel)                     // rodapé: caminho do arquivo
```

Tokens de tema (seguem o tema ativo do Omarchy):
- `Color.popups.background` / `Color.popups.text` — fundo/texto da carta.
- `Color.menu.scrim` — escurecimento de fundo.
- `Border.hyprlandActiveSpec(Color.accent, Math.max(1, Style.space(2)))` — borda.
- `Style.font.family` / `Style.font.body` / `Style.font.caption` — fontes.
- `Style.space(...)`, `Style.gapsOut`, `Style.cornerRadius` — métricas.

Dimensões: `cardWidth`/`cardHeight` são `Math.min/max` de frações do `panel` e
limites mínimos — o `panel` (PanelWindow) é referenciado nas expressões, então a
largura só existe após o `PanelWindow` ser criado (bindings avaliam em tempo de
execução; OK).

`Shortcut` com `sequence: "Escape"` + `context: Qt.WindowShortcut` captura o Esc
inclusive com foco no editor e chama `dismiss()` (salva + fecha).

---

## 6. Facade `root.shell` (o que existe / não existe)

Injetada para plugins de terceiro (`createScopedPluginShell` em `shell.qml`).
**Disponível:** `pluginId`, `appLibrary` (só kind `menu`), `bar`, `barConfig`,
`idleConfig`, `hide`, `toggle`, `summon`, `isPluginOpen`, `updateEntryInline`,
`mutateShellConfig`, `serviceFor`, `pluginShellForBarEntry`, … .

**NÃO disponível para terceiros:** `shellConfig`. (A leitura de settings que plugins
como `vt.quicknote` fazem via `root.shell.shellConfig.plugins` **não funciona** no
Omarchy 4 — a facade é escopada e omite `shellConfig`.) Por isso `mat-notes` lê o
entry em `shell.json` diretamente (§5.2 / §7).

`root.manifest` traz o manifest, mas **não** mescla os campos extras do entry em
`plugins[]` (ex.: `path`). Logo, nem `shellConfig` nem `manifest` trazem as settings
do usuário.

---

## 7. Modelo de configurações (`path`)

Decisão: ler o entry do plugin em `~/.config/omarchy/shell.json` via `FileView`
(`configFile`) e extrair `path` para `id === "mat-notes"`. Vantagens:
- Independe da facade (funciona em qualquer Omarchy 4).
- `watchChanges: true` → reage a edições do próprio `shell.json` ao vivo.
- `path` vazio ⇒ default `~/notes.md`; `~`/`$HOME` expandidos; relativos caem em `$HOME`.

Para **escrever** settings a partir do plugin (ex.: UI de config), use
`root.shell.updateEntryInline(id, entry)` ou `root.shell.mutateShellConfig(fn)`
(estes sim existem na facade). `mat-notes` não edita settings (apenas as lê); o
usuário define `path` manualmente em `shell.json`.

---

## 8. Como é acionado (atalho, menu, IPC)

1. **Atalho** — `~/.config/hypr/bindings.lua`:
   ```lua
   o.bind("SUPER + N", "Mat Notes", "omarchy-shell -q shell toggle mat-notes")
   ```
   (verifique `SUPER + N` livre com `omarchy menu keybindings --print` antes;
   `SUPER + SHIFT + N` é o editor do Omarchy.)
2. **Botão no menu** — `~/.config/omarchy/extensions/omarchy-menu.jsonc`:
   ```jsonc
   {
     "mat.notes": {
       "icon": "󰎞",
       "label": "Notes",
       "action": "omarchy-shell -q shell toggle mat-notes"
     }
   }
   ```
3. **IPC direto:** `omarchy-shell -q shell toggle mat-notes`.

Todos os três roteiam para o mesmo `toggle()` do overlay. O menu e o atalho são
configurações de usuário — **não** vêm no repo do plugin.

---

## 9. Verificação realizada (referência)

Feita com `wtype` (injeção de teclado via virtual‑keyboard) + `hyprctl layers`
(confirmar montagem/desmonte da camada `mat-notes`) + `cat` do arquivo:

- Toggle abre/fecha a camada `mat-notes` (visível em `hyprctl layers`).
- Digitação → autosave escreve `~/notes.md`.
- `Esc` salva o texto ainda não gravado **e** fecha (camada some; arquivo contém o texto).
- Reabrir carrega o arquivo; edição externa é refletida ao reabrir.
- `path` customizado em `shell.json` direciona para o arquivo correto.
- Sem erros de QML no log (`journalctl --user`).

> `wtype` digita texto; `wtype -k Escape` envia a tecla Escape (necessário para
> testar o fechamento por Esc headless).

---

## 10. Guia de evolução

Pontos de extensão e ideias, com onde tocar:

- **Preview renderizado de Markdown:** substituir `TextEdit` (PlainText) por um
  visualizador (ex.: `qs.Ui`/`Markdown` se houver, ou WebView/QML) e manter edição
  em modo alternável. Cuidado: nunca tratar conteúdo de nota como rich text
  automaticamente (XSS/remote‑image via markup — ver `vt.quicknote` sobre
  `Text.PlainText`).
- **Múltiplas notas / seletor de arquivo:** trocar `notePath` fixo por um estado de
  nota atual; adicionar lista (semelhante a `harbefas.vault`). `path` em `shell.json`
  vira uma "vault root".
- **UI de configuração dentro do overlay:** campo para mudar o arquivo; ao confirmar,
  usar `root.shell.updateEntryInline("mat-notes", { id, path })` para persistir.
- **Botão na barra:** exigiria `kind` adicional `bar-widget` + entry point
  `BarWidget.qml` que chama `omarchy-shell shell toggle mat-notes` — fora do escopo
  deste overlay puro.
- **Formatação/atalhos:** capturar teclas em `editor.Keys.onPressed` e aplicar
  markdown (lista, negrito) inserindo texto — respeitando `restored`.
- **Sincronização:** apontar `path` para arquivo em Dropbox/Syncthing; funciona
  nativamente pois é só um arquivo.

Mudanças de **código** exigem `omarchy restart shell` (por `keepLoaded`). Mudanças
só de `path` em `shell.json` são ao vivo.

---

## 11. Recriação do zero (checklist)

1. Criar `~/.config/omarchy/plugins/mat-notes/`.
2. Escrever `manifest.json` (§4).
3. Escrever `Overlay.qml` (§5): imports, estado, settings via `configFile`+`readConfigPath`,
   lifecycle (`open/close/dismiss/toggle` com chaves no `if/else`), persistência
   (`noteEdited/flush/applyFromDisk` + `FileView` + timer), e a `PanelWindow` com
   `WlrLayershell` overlay, `Shortcut` Escape e o `TextEdit`.
4. `omarchy-shell shell rescanPlugins && omarchy plugin enable mat-notes`.
5. Adicionar atalho em `bindings.lua` e entry em `omarchy-menu.jsonc` (§8).
6. `omarchy restart shell` para garantir código carregado; testar via `SUPER + N`,
   digitar, `Esc`, `cat ~/notes.md`.

Evite os erros de §9/§5.3/§5.4 (if/else de linha única, IIFE vs binding, flag
`restored`, `shellConfig` ausente).
