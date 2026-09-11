# Mat Notes

Plugin de notas modal para o **Omarchy 4** (Quattro). Abre uma janela centralizada
(em camada de overlay) que edita um único arquivo Markdown. Faz autosave enquanto
você digita e **salva + fecha ao apertar `Esc`**. Reabre instantaneamente, por
atalho de teclado ou por um botão no menu do Omarchy.

## Recursos

- Modal central em layer‑shell, com o tema ativo do Omarchy (cores, borda, fonte).
- Um arquivo `.md` (padrão `~/notes.md`), editado em texto puro (Markdown fonte).
- Autosave ~400 ms após você parar de digitar, e também ao fechar/salvar.
- `Esc` fecha e salva; clicar fora da carta também fecha e salva.
- Abre por **atalho de teclado** e por **botão no menu** do Omarchy.
- `keepLoaded: true`: reabre na hora e reflete edições feitas fora (outro editor).

## Requisitos

- Omarchy 4 (Quattro). Testado na 4.0.3.

## Instalação

O plugin são apenas **dois arquivos**: `manifest.json` e `Overlay.qml` (mais este
README). Há duas formas de instalá‑lo.

### Método A — Manual (copiar arquivos)

1. Crie a pasta e copie os arquivos do plugin para lá:

   ```sh
   mkdir -p ~/.config/omarchy/plugins/mat-notes
   # copie manifest.json e Overlay.qml para ~/.config/omarchy/plugins/mat-notes/
   ```

   (via `scp`, pendrive, `git clone` de um repo próprio, ou qualquer meio.)

2. Registre e habilite o plugin:

   ```sh
   omarchy-shell shell rescanPlugins
   omarchy plugin enable mat-notes
   ```

   O `enable` adiciona `{ "id": "mat-notes" }` em `~/.config/omarchy/shell.json`
   (`plugins[]`).

3. Adicione o atalho de teclado — veja **Atalho de teclado** abaixo.
4. Adicione o botão no menu — veja **Botão no menu** abaixo.

### Método B — Via repositório git

Se o plugin estiver em um repositório git (ex.: GitHub/GitLab), em qualquer
máquina com acesso basta:

```sh
omarchy plugin add <url-do-repo> --enable
```

Isso clona o repositório para `~/.config/omarchy/plugins/mat-notes/` e já habilita o
plugin. Depois ainda é preciso adicionar o atalho e o botão (próximas seções), pois
esses são arquivos de usuário, fora da pasta do plugin.

## Atalho de teclado (`SUPER + N`)

Confira primeiro se a combinação está livre:

```sh
omarchy menu keybindings --print | grep -i "SUPER + N"
```

Se estiver livre, adicione ao **final** de `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + N", "Mat Notes", "omarchy-shell -q shell toggle mat-notes")
```

O Hyprland recarrega sozinho ao salvar o arquivo. Valide com:

```sh
hyprctl configerrors
```

> Se `SUPER + N` já estiver em uso, escolha outro chord (ex.: `SUPER + ALT + N`) e
> troque a mesma string nos passos abaixo. `SUPER + SHIFT + N` é o atalho do editor
> do Omarchy — não reuse.

## Botão no menu (Omarchy menu)

Edite `~/.config/omarchy/extensions/omarchy-menu.jsonc` e adicione a entry
`mat.notes`. Se o arquivo já tiver entradas suas, **funda** esta chave em vez de
sobrescrever o arquivo:

```jsonc
{
  "mat.notes": {
    "icon": "󰎞",
    "label": "Notes",
    "action": "omarchy-shell -q shell toggle mat-notes"
  }
}
```

O menu do Omarchy recarrega sozinho ao salvar.

## Uso

- `SUPER + N` (ou menu → **Notes**) abre o modal já apontando para o arquivo.
- Digite sua nota; o autosave grava sozinho.
- `Esc` salva e fecha a janela. Clicar fora da carta também salva e fecha.
- Reabra a qualquer momento — o arquivo reaparece carregado.

## Configuração: qual arquivo editar

Por padrão edita `~/notes.md`. Para apontar para outro arquivo (ex.: um `.md`
sincronizado no Dropbox), edite a entry em `~/.config/omarchy/shell.json`
(`plugins[]`):

```json
{
  "id": "mat-notes",
  "path": "/caminho/para/sua/nota.md"
}
```

O plugin lê esse `path` diretamente do `shell.json` e reage à mudança sozinho (não
precisa reiniciar). `~` e `$HOME` são expandidos; caminhos relativos ficam sob
`$HOME`.

## Como funciona (nota técnica)

- É um plugin `overlay` com `keepLoaded: true`. O shell injeta `root.shell` e
  `root.manifest`. A facade de terceiros no Omarchy 4 **não expõe `shellConfig`**
  para overlays, então o `path` é lido diretamente do entry em `shell.json` via
  `FileView` (com `watchChanges`, então reage a edições do próprio `shell.json`).
- A edição é texto puro (fonte Markdown), não um preview renderizado.
- Mudanças no código do plugin exigem `omarchy restart shell` para recarregar
  (primeira instalação só precisa do `enable`).

## Desinstalação

```sh
omarchy plugin remove mat-notes
```

O arquivo de nota (`~/notes.md` ou o `path` configurado) permanece no disco; apague
manualmente se desejar.
