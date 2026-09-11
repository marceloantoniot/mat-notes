import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// mat-notes — a single-file Markdown note modal for Omarchy.
// One file, autosaved, reopened by shortcut or menu.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool dirty: false
  property string pendingText: ""
  property string diskText: ""
  property bool diskReady: false

  readonly property string pluginId: (root.manifest && root.manifest.id) || "mat-notes"
  readonly property string home: Quickshell.env("HOME")

  // --- settings: read this plugin's entry from shell.json. The scoped plugin
  // facade omits shellConfig in Omarchy 4, so we read the inline plugins[]
  // entry directly. This matches the documented storage model and reacts to
  // edits live (watchChanges reloads on save). ---
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

  onNotePathChanged: root.diskReady = false

  // --- theme tokens (follow the active Omarchy theme) ---
  property color background: Color.popups.background
  property color foreground: Color.popups.text
  property color scrim: Color.menu.scrim
  property var borderSpec: Border.hyprlandActiveSpec(Color.accent, Math.max(1, Style.space(2)))
  property string fontFamily: Style.font.family

  readonly property int cardWidth: Math.min(
    Math.max(Style.space(280), Math.min(Style.space(900), Math.round(panel.width * 0.60))),
    Math.max(Style.space(280), panel.width - Style.gapsOut * 2))
  readonly property int cardHeight: Math.min(
    Math.max(Style.space(260), Math.min(Style.space(700), Math.round(panel.height * 0.70))),
    Math.max(Style.space(200), panel.height - Style.gapsOut * 2))
  readonly property int notePadding: Style.space(28)

  // --- lifecycle: open/close/dismiss/toggle (overlay contract) ---
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
    if (root.opened) {
      root.dismiss()
    } else {
      root.open("{}")
    }
  }

  // --- persistence ---
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

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: root.flush()
  }

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

  // --- modal surface ---
  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "mat-notes"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Shortcut {
      sequence: "Escape"
      context: Qt.WindowShortcut
      enabled: root.opened
      onActivated: root.dismiss()
    }

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.notePadding

      MouseArea { anchors.fill: parent; onClicked: editor.forceActiveFocus() }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset + pathLabel.height + Style.space(10)
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(8)

        Flickable {
          id: flick
          width: parent.width
          height: parent.height
          clip: true
          contentWidth: width
          contentHeight: editor.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          function ensureVisible(r) {
            if (contentY >= r.y) contentY = r.y
            else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
          }
          TextEdit {
            id: editor
            width: flick.width
            property bool restored: false
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
            selectionColor: Color.menu.selectedBackground
            selectedTextColor: Color.menu.selectedText
            selectByMouse: true
            persistentSelection: true
            focus: true
            onTextChanged: if (restored) root.noteEdited(text)
            onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              visible: editor.length === 0
              text: "Type your note…"
              textFormat: Text.PlainText
              color: Qt.alpha(root.foreground, 0.35)
              font: editor.font
              wrapMode: Text.Wrap
            }
          }
        }
      }

      Text {
        id: pathLabel
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        text: root.notePath
        textFormat: Text.PlainText
        color: Qt.alpha(root.foreground, 0.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
  }
}
