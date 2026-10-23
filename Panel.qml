import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.Panel {
  id: root
  moduleName: "xmanig.dictations"
  ipcTarget: "xmanig.dictations"
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  readonly property color ink: Commons.Color.popups.text
  readonly property color muted: Qt.darker(ink, 1.5)
  readonly property color accentInk: Commons.Color.accent
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/dictations.py")).replace(/^file:\/\//, ""))
  property string dictationStatus: "unavailable"
  property bool expanded: false
  property string page: "history"
  property bool loaded: false
  property bool busy: false
  property bool requestInFlight: false
  property var queuedRequest: null
  property bool refreshPending: false
  property string failure: ""
  property bool focusSearchPending: false
  property string notice: ""
  property var inboxState: ({enabled: true, active_collection: "Inbox", retention_days: 0, provider: "codex", model: "", endpoint: "", api_key_env: "OPENAI_API_KEY"})
  property var entries: []
  property var collections: ["Inbox"]
  property var summaries: []
  property int total: 0
  property int offset: 0
  readonly property int pageSize: 100
  property string query: ""
  property string collectionFilter: ""
  property string dayFilter: ""
  property var selectedEntries: ({})
  readonly property var selectedIds: Object.keys(selectedEntries).map(function(k) { return Number(k) })
  property var readerEntry: null
  property int summaryId: 0
  readonly property var currentSummary: {
    for (var i = 0; i < summaries.length; i++)
      if (summaries[i].id === summaryId) return summaries[i]
    return null
  }
  property string summaryKind: "handoff"
  property string assignCollection: "Inbox"
  property string savePath: "~/dictations.md"
  property string confirmAction: ""
  property var confirmationIds: []
  property int confirmationSummary: 0
  property var settingsDraft: ({})
  property var settingsChanges: ({})
  property bool settingsReady: false

  component Label: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
  }

  component Action: Ui.Button {
    foreground: root.ink
    fontFamily: Style.font.family
    fontSize: Style.font.bodySmall
    bordered: true
    focusable: true
    enabled: !root.busy
    opacity: enabled ? 1 : 0.45
  }

  component Field: Ui.TextField {
    foreground: root.ink
    font.pixelSize: Style.font.bodySmall
    enabled: !root.busy
    selectByMouse: true
  }

  function request(payload) {
    if (requestInFlight) {
      if (payload.action === "state") refreshPending = true
      else if (!queuedRequest) {
        queuedRequest = payload
        busy = true
      }
      return
    }
    requestInFlight = true
    busy = payload.action !== "state" || !loaded
    if (payload.action !== "state") {
      failure = ""
      notice = ""
    }
    rpc.payload = payload
    rpc.stdinEnabled = true
    rpc.running = true
  }

  function refresh() {
    if (!opened && loaded) return
    if (requestInFlight) { refreshPending = true; return }
    request({action: "state", query: query, collection: collectionFilter, day: dayFilter, limit: pageSize, offset: offset})
  }

  function filtersChanged() {
    offset = 0
    filterDelay.restart()
  }

  function setSelected(entry) {
    var next = Object.assign({}, selectedEntries)
    if (next[entry.id]) delete next[entry.id]
    else next[entry.id] = entry
    selectedEntries = next
  }

  function selectedText() {
    return selectedIds.map(function(id) { return selectedEntries[id] })
      .sort(function(a, b) { return a.id - b.id })
      .map(function(entry) { return entry.text }).join("\n\n")
  }

  function copyText(text) {
    if (copyProc.running) return
    copyProc.payload = String(text)
    copyProc.stdinEnabled = true
    copyProc.running = true
  }

  function editSetting(name, value) {
    var draft = Object.assign({}, settingsDraft)
    var changes = Object.assign({}, settingsChanges)
    draft[name] = value
    if (value === inboxState[name]) delete changes[name]
    else changes[name] = value
    settingsDraft = draft
    settingsChanges = changes
  }

  function loadSettings() {
    settingsDraft = Object.assign({}, inboxState)
    settingsChanges = ({})
    settingsReady = true
  }

  function showPage(name) {
    expanded = true
    page = name
    confirmAction = ""
    if (name === "settings" && !settingsReady) loadSettings()
  }

  function exportPayload(action) {
    var payload = {action: action}
    if (page === "summaries" && currentSummary) payload.summary_id = currentSummary.id
    else payload.ids = selectedIds
    if (action === "export_file") payload.path = savePath
    return payload
  }

  function askDeleteEntries() {
    confirmationIds = selectedIds.slice()
    confirmAction = "entries"
  }

  function askDeleteSummary() {
    if (!currentSummary) return
    confirmationSummary = currentSummary.id
    confirmAction = "summary"
  }

  function confirmDelete() {
    if (confirmAction === "entries") request({action: "delete", ids: confirmationIds})
    else if (confirmAction === "summary") request({action: "delete_summary", id: confirmationSummary})
    confirmAction = ""
  }

  function applyResponse(response, payload) {
    if (response.entries !== undefined) {
      if (JSON.stringify(inboxState) !== JSON.stringify(response)) inboxState = response
      if (JSON.stringify(collections) !== JSON.stringify(response.collections || ["Inbox"]))
        collections = response.collections || ["Inbox"]
      if (JSON.stringify(summaries) !== JSON.stringify(response.summaries || []))
        summaries = response.summaries || []
      loaded = true
      if (!settingsReady) loadSettings()
      if (response.retention_days > 0) {
        var cutoff = Date.now() - response.retention_days * 86400000
        var retainedSelection = Object.assign({}, selectedEntries)
        Object.keys(retainedSelection).forEach(function(id) {
          if (Date.parse(retainedSelection[id].created_at) < cutoff) delete retainedSelection[id]
        })
        if (JSON.stringify(selectedEntries) !== JSON.stringify(retainedSelection)) selectedEntries = retainedSelection
        if (readerEntry && Date.parse(readerEntry.created_at) < cutoff) readerEntry = null
      }
      if (payload.action === "state") {
        if (JSON.stringify(entries) !== JSON.stringify(response.entries)) entries = response.entries
        total = response.total
        var selection = Object.assign({}, selectedEntries)
        for (var i = 0; i < entries.length; i++) {
          if (selection[entries[i].id]) selection[entries[i].id] = entries[i]
          if (readerEntry && readerEntry.id === entries[i].id && JSON.stringify(readerEntry) !== JSON.stringify(entries[i]))
            readerEntry = entries[i]
        }
        if (JSON.stringify(selectedEntries) !== JSON.stringify(selection)) selectedEntries = selection
      }
    }
    if (payload.action === "settings") {
      if (Object.keys(payload).some(function(key) { return key !== "action" && key !== "enabled" && key !== "active_collection" }))
        loadSettings()
      notice = "Settings saved. Right Alt dictation is unchanged."
    }
    if (payload.action === "collection") {
      newCollection.text = ""
      notice = "Collection created. Choose Capture into to use it for new dictations."
    }
    if (payload.action === "delete") {
      var remaining = Object.assign({}, selectedEntries)
      for (var j = 0; j < payload.ids.length; j++) delete remaining[payload.ids[j]]
      selectedEntries = remaining
      if (readerEntry && payload.ids.indexOf(readerEntry.id) >= 0) readerEntry = null
      notice = "Entries deleted. Saved summaries and their source snapshots remain until separately deleted or expired."
    }
    if (payload.action === "delete_summary") {
      summaryId = 0
      notice = "Saved summary and its source snapshots deleted."
    }
    if (payload.action === "summarize") {
      summaryId = response.summary.id
      summaries = [response.summary].concat(summaries.filter(function(s) { return s.id !== response.summary.id }))
      showPage("summaries")
    }
    if (payload.action === "export") copyText(response.text)
    if (payload.action === "export_file") notice = "Markdown saved to " + response.path
    if (payload.action !== "state" && payload.action !== "export" && payload.action !== "export_file") refreshPending = true
  }

  onOpenedChanged: {
    if (opened) {
      page = "history"
      refresh()
      focusSearchPending = true
      Qt.callLater(function() { searchField.forceActiveFocus() })
    } else confirmAction = ""
  }

  Process {
    id: rpc
    property var payload: ({})
    command: ["python3", root.helperPath, "rpc"]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(payload) + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: rpcOutput; waitForEnd: true }
    stderr: StdioCollector { id: rpcError; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.requestInFlight = false
      try {
        var response = JSON.parse(rpcOutput.text)
        if (!response.ok) root.failure = String(response.error || "The operation failed.")
        else if (exitCode !== 0) root.failure = "The backend exited with status " + exitCode
        else root.applyResponse(response, payload)
      } catch (error) {
        root.failure = "Could not read the inbox response. " + (String(rpcError.text || "").trim() || String(error))
      }
      if (root.focusSearchPending && root.opened) {
        root.focusSearchPending = false
        Qt.callLater(function() { searchField.forceActiveFocus() })
      }
      if (root.queuedRequest) {
        var nextRequest = root.queuedRequest
        root.queuedRequest = null
        root.busy = true
        Qt.callLater(function() { root.request(nextRequest) })
      } else if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(function() { root.refresh() })
      }
    }
  }

  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy", "--type", "text/plain;charset=utf-8"]
    stdinEnabled: true
    onStarted: { write(payload); stdinEnabled = false; payload = "" }
    stderr: StdioCollector { id: copyError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.notice = "Copied to clipboard."
      else root.failure = "Clipboard copy failed. " + String(copyError.text || "").trim()
    }
  }

  Component.onCompleted: root.refresh()

  FileView {
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/voxtype/state"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.dictationStatus = String(text()).trim() || "unavailable"
    onLoadFailed: root.dictationStatus = "unavailable"
  }

  Timer { id: filterDelay; interval: 250; onTriggered: root.refresh() }
  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  Ui.BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: root.dictationStatus === "recording" ? "󰑋" : root.dictationStatus === "transcribing" ? "󰔟" : root.loaded && !root.inboxState.enabled ? "󰏤" : "󰍬"
    active: root.opened || root.dictationStatus === "recording"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { root.showPage("history"); root.open() }
      else root.toggle()
    }
  }

  Ui.KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: fittedContentWidth(Style.space(root.expanded ? 1000 : 460))
    contentHeight: cappedContentHeight(Style.space(root.expanded ? 760 : 540))

    FocusScope {
      anchors.fill: parent
      Keys.onEscapePressed: function(event) {
        if (root.confirmAction !== "") root.confirmAction = ""
        else root.close()
        event.accepted = true
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          Label { text: "Dictation Inbox"; font.pixelSize: Style.font.title; font.bold: true; Layout.fillWidth: true }
          Action {
            text: root.expanded ? "Recent" : "Open history"
            onClicked: { root.expanded = !root.expanded; root.page = "history"; root.confirmAction = "" }
          }
          Action { text: "×"; tooltipText: "Close (Escape)"; onClicked: root.close() }
        }

        RowLayout {
          Layout.fillWidth: true
          Label {
            Layout.fillWidth: true
            text: !root.loaded ? "Loading local text history…" : (root.inboxState.enabled ? "History capture on · local text only" : "History PAUSED · dictation still works") + " · Voxtype " + root.dictationStatus
            color: root.dictationStatus === "recording" || (root.loaded && !root.inboxState.enabled) ? Commons.Color.urgent : root.muted
            font.pixelSize: Style.font.caption
          }
          Action {
            text: root.inboxState.enabled ? "Pause capture" : "Resume capture"
            enabled: root.loaded && !root.busy
            onClicked: root.request({action: "settings", enabled: !root.inboxState.enabled})
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.expanded
          Action { text: "History"; selected: root.page === "history"; onClicked: root.showPage("history") }
          Action { text: "Saved summaries (" + root.summaries.length + ")"; selected: root.page === "summaries"; onClicked: root.showPage("summaries") }
          Action { text: "Settings"; selected: root.page === "settings"; onClicked: root.showPage("settings") }
          Item { Layout.fillWidth: true }
          Action { text: "Refresh"; onClicked: { root.failure = ""; root.refresh() } }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.page === "history"
          Field {
            id: searchField
            Layout.fillWidth: true
            enabled: true
            placeholderText: "Search dictation words…"
            text: root.query
            onTextEdited: { root.query = text; root.filtersChanged() }
          }
          Field {
            Layout.preferredWidth: Style.space(140)
            visible: root.expanded
            placeholderText: "YYYY-MM-DD"
            text: root.dayFilter
            onEditingFinished: {
              if (text !== "" && !/^\d{4}-\d{2}-\d{2}$/.test(text)) { root.failure = "Use YYYY-MM-DD, or clear the date to see all days."; return }
              root.dayFilter = text
              root.filtersChanged()
            }
            onAccepted: editingFinished()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.page === "history"
          Ui.Dropdown {
            Layout.fillWidth: true
            label: "Filter collection"
            foreground: root.ink
            options: [{value: "", label: "All collections"}].concat(root.collections)
            value: root.collectionFilter
            onChanged: function(value) { root.collectionFilter = value; root.filtersChanged() }
          }
          Ui.Dropdown {
            Layout.fillWidth: true
            label: "Capture into"
            foreground: root.ink
            options: root.collections
            value: root.inboxState.active_collection
            enabled: !root.busy
            onChanged: function(value) { root.request({action: "settings", active_collection: value}) }
          }
        }

        Label {
          Layout.fillWidth: true
          visible: root.failure !== "" || root.notice !== "" || root.busy
          text: root.failure !== "" ? root.failure : root.busy ? (rpc.payload.action === "summarize" ? "Summarizing selected entries… This may take a moment." : "Working…") : root.notice
          color: root.failure !== "" ? Commons.Color.urgent : root.muted
          font.pixelSize: Style.font.caption
          maximumLineCount: 4
          elide: Text.ElideRight
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.page === "history"
          spacing: Style.space(12)

          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: root.expanded ? Style.space(410) : Style.space(440)
            spacing: Style.space(6)
            RowLayout {
              Layout.fillWidth: true
              Label {
                Layout.fillWidth: true
                text: root.total + " matching · " + root.selectedIds.length + " selected"
                color: root.muted
                font.pixelSize: Style.font.caption
              }
              Action {
                visible: root.expanded
                text: "Select page"
                enabled: !root.busy && root.entries.length > 0
                onClicked: {
                  var next = Object.assign({}, root.selectedEntries)
                  root.entries.forEach(function(entry) { next[entry.id] = entry })
                  root.selectedEntries = next
                }
              }
              Action { visible: root.selectedIds.length > 0; text: "Clear"; onClicked: root.selectedEntries = ({}) }
            }

            ListView {
              id: entryList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: Style.space(6)
              model: root.entries
              Controls.ScrollBar.vertical: Controls.ScrollBar {}
              delegate: Rectangle {
                id: entryRow
                required property var modelData
                width: entryList.width
                height: rowContents.implicitHeight + Style.space(16)
                color: root.readerEntry && root.readerEntry.id === modelData.id ? Style.selectedFillFor(root.ink, root.accentInk) : Style.controlFill(false, rowMouse.containsMouse, root.ink, root.accentInk)
                radius: Style.cornerRadius
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: { root.readerEntry = entryRow.modelData; root.expanded = true }
                }
                RowLayout {
                  id: rowContents
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)
                  Action {
                    text: root.selectedEntries[entryRow.modelData.id] ? "☑" : "☐"
                    tooltipText: "Select entry " + entryRow.modelData.id
                    selected: !!root.selectedEntries[entryRow.modelData.id]
                    onClicked: { root.setSelected(entryRow.modelData); root.readerEntry = entryRow.modelData }
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(3)
                    Label {
                      Layout.fillWidth: true
                      text: entryRow.modelData.created_at.replace("T", " · ").slice(0, 22) + " · " + entryRow.modelData.collection
                      color: root.muted
                      font.pixelSize: Style.font.caption
                      maximumLineCount: 1
                      elide: Text.ElideRight
                    }
                    Label {
                      Layout.fillWidth: true
                      text: entryRow.modelData.text.replace(/\s+/g, " ")
                      maximumLineCount: 2
                      elide: Text.ElideRight
                    }
                  }
                  Action { text: "Read"; visible: root.expanded; onClicked: root.readerEntry = entryRow.modelData }
                }
              }
              Label {
                anchors.centerIn: parent
                width: parent.width - Style.space(24)
                horizontalAlignment: Text.AlignHCenter
                visible: !root.busy && root.entries.length === 0
                text: !root.loaded ? "The inbox is unavailable. See the error above and try Refresh." : root.query || root.collectionFilter || root.dayFilter ? "No matching dictations. Try clearing your search or filters." : "Your dictations will appear here. Hold Right Alt and speak; only the resulting text is saved. No audio is stored."
                color: root.muted
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Action { text: "Previous"; enabled: !root.busy && root.offset > 0; onClicked: { root.offset = Math.max(0, root.offset - root.pageSize); root.refresh() } }
              Label { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.total ? (root.offset + 1) + "–" + Math.min(root.offset + root.entries.length, root.total) + " / " + root.total : "0 entries"; color: root.muted; font.pixelSize: Style.font.caption }
              Action { text: "Next"; enabled: !root.busy && root.offset + root.entries.length < root.total; onClicked: { root.offset += root.pageSize; root.refresh() } }
            }
          }

          ColumnLayout {
            visible: root.expanded
            Layout.preferredWidth: Style.space(520)
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(8)
            Label {
              Layout.fillWidth: true
              text: root.readerEntry ? "Entry #" + root.readerEntry.id + " · " + root.readerEntry.collection + "\n" + root.readerEntry.created_at : "Choose an entry to read"
              font.pixelSize: Style.font.caption
              color: root.muted
            }
            Controls.ScrollView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: availableWidth
              Controls.TextArea {
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                selectionColor: Style.selectionFillFor(root.ink, root.accentInk)
                text: root.readerEntry ? root.readerEntry.text : "Select with the checkboxes to copy, organize, export or summarize only those entries."
                background: Rectangle { color: Style.controlFill(false, false, root.ink, root.accentInk); radius: Style.cornerRadius }
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Action { text: "Copy entry"; enabled: !!root.readerEntry && !root.busy; onClicked: root.copyText(root.readerEntry.text) }
              Action { text: "Copy selected"; enabled: root.selectedIds.length > 0 && !root.busy; onClicked: root.copyText(root.selectedText()) }
              Item { Layout.fillWidth: true }
              Action { text: "Delete selected…"; enabled: root.selectedIds.length > 0 && !root.busy; onClicked: root.askDeleteEntries() }
            }
            RowLayout {
              Layout.fillWidth: true
              Ui.Dropdown {
                Layout.fillWidth: true
                label: "Move selected into"
                options: root.collections
                value: root.assignCollection
                foreground: root.ink
                onChanged: function(value) { root.assignCollection = value }
              }
              Action { Layout.alignment: Qt.AlignBottom; text: "Move"; enabled: root.selectedIds.length > 0 && !root.busy; onClicked: root.request({action: "assign", ids: root.selectedIds, collection: root.assignCollection}) }
            }
            RowLayout {
              Layout.fillWidth: true
              Ui.Dropdown {
                Layout.fillWidth: true
                label: "Summary of selected entries only"
                options: [{value: "handoff", label: "Agent handoff"}, {value: "ideas", label: "Ideas"}, {value: "daily", label: "Daily digest"}]
                value: root.summaryKind
                foreground: root.ink
                onChanged: function(value) { root.summaryKind = value }
              }
              Action {
                Layout.alignment: Qt.AlignBottom
                text: "Summarize " + root.selectedIds.length
                enabled: root.selectedIds.length > 0 && !root.busy
                onClicked: root.request({action: "summarize", ids: root.selectedIds, kind: root.summaryKind})
              }
            }
            Label {
              Layout.fillWidth: true
              text: root.inboxState.provider === "codex" ? "Cloud · ChatGPT/Codex: clicking Summarize sends only the selected text to your authenticated Codex account. No tools are enabled." : root.inboxState.provider === "openai" ? "Cloud / configured endpoint: clicking Summarize sends only the selected text to " + (root.inboxState.endpoint || "https://api.openai.com/v1") + "." : "Ollama: clicking Summarize sends only the selected text to " + (root.inboxState.endpoint || "http://127.0.0.1:11434") + "."
              color: root.muted
              font.pixelSize: Style.font.caption
            }
          }
        }

        RowLayout {
          visible: root.expanded && root.page === "summaries"
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(12)
          ColumnLayout {
            Layout.preferredWidth: Style.space(280)
            Layout.fillHeight: true
            Label { text: "Saved summaries · newest 50"; color: root.muted; font.pixelSize: Style.font.caption }
            ListView {
              id: summaryList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: Style.space(6)
              model: root.summaries
              Controls.ScrollBar.vertical: Controls.ScrollBar {}
              delegate: Action {
                required property var modelData
                width: summaryList.width
                text: "#" + modelData.id + " · " + modelData.kind + "\n" + modelData.created_at.slice(0, 16).replace("T", " ") + " · " + modelData.entry_ids.length + " sources"
                selected: root.summaryId === modelData.id
                leftAlign: true
                onClicked: root.summaryId = modelData.id
              }
              Label { anchors.centerIn: parent; width: parent.width; visible: root.summaries.length === 0; text: "No saved summaries yet. Select entries in History and explicitly press Summarize."; color: root.muted }
            }
          }
          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Label {
              Layout.fillWidth: true
              text: root.currentSummary ? root.currentSummary.kind + " · " + root.currentSummary.created_at : "Choose a saved summary"
              font.bold: true
            }
            Controls.ScrollView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: availableWidth
              Controls.TextArea {
                textFormat: TextEdit.PlainText
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                selectionColor: Style.selectionFillFor(root.ink, root.accentInk)
                text: root.currentSummary ? root.currentSummary.text + "\n\n── Original source snapshots ──\n\n" + root.currentSummary.sources.map(function(source) { return "#" + source.id + " · " + source.created_at + " · " + source.collection + "\n" + source.text }).join("\n\n") : "Summaries retain the original selected source text for traceability, even if the inbox entries are deleted. Delete a saved summary to remove its snapshots. Retention also expires summaries."
                background: Rectangle { color: Style.controlFill(false, false, root.ink, root.accentInk); radius: Style.cornerRadius }
              }
            }
            RowLayout {
              Action { text: "Copy summary"; enabled: !!root.currentSummary && !root.busy; onClicked: root.copyText(root.currentSummary.text) }
              Item { Layout.fillWidth: true }
              Action { text: "Delete summary + snapshots…"; enabled: !!root.currentSummary && !root.busy; onClicked: root.askDeleteSummary() }
            }
          }
        }

        Controls.ScrollView {
          visible: root.expanded && root.page === "settings"
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          contentWidth: availableWidth
          ColumnLayout {
            width: parent.width
            spacing: Style.space(14)
            Label { text: "Local capture & collections"; font.bold: true }
            Label { Layout.fillWidth: true; text: "Only final transcript text is kept on this machine. Pausing history does not disable Voxtype or change Right Alt typing. No model runs during capture."; color: root.muted }
            RowLayout {
              Layout.fillWidth: true
              Field { id: newCollection; Layout.fillWidth: true; placeholderText: "New collection or named agent session"; onAccepted: if (text.trim()) root.request({action: "collection", name: text.trim()}) }
              Action { text: "Create collection"; enabled: !root.busy && newCollection.text.trim() !== ""; onClicked: root.request({action: "collection", name: newCollection.text.trim()}) }
            }
            Label { Layout.fillWidth: true; text: "Use Capture into in History for new entries. Select existing entries and Move to organize earlier dictations. Collections can be named for projects, agents or sessions."; color: root.muted; font.pixelSize: Style.font.caption }
            Label { text: "Retention (days; 0 = forever)"; font.bold: true }
            Field {
              Layout.fillWidth: true
              id: retentionField
              text: String(root.settingsDraft.retention_days === undefined ? 0 : root.settingsDraft.retention_days)
              validator: IntValidator { bottom: 0; top: 365000 }
              onTextEdited: if (acceptableInput) root.editSetting("retention_days", Number(text))
            }
            Label { Layout.fillWidth: true; text: "Retention automatically removes expired entries AND saved summaries/source snapshots on capture or refresh. Lowering this value can permanently delete older data."; color: root.muted; font.pixelSize: Style.font.caption }
            Label { text: "Explicit summary provider"; font.bold: true }
            Ui.Dropdown {
              Layout.fillWidth: true
              foreground: root.ink
              options: [{value: "codex", label: "Codex · ChatGPT cloud (authenticated CLI)"}, {value: "ollama", label: "Ollama · local / configured server"}, {value: "openai", label: "OpenAI-compatible · cloud / configured endpoint"}]
              value: root.settingsDraft.provider || "codex"
              onChanged: function(value) { root.editSetting("provider", value) }
            }
            Label { Layout.fillWidth: true; text: "Nothing is sent until you select entries and click Summarize. Codex uses the existing ChatGPT login with tools disabled. Ollama requires a running server and an installed model. Provider failures are shown; there is no fallback summary."; color: root.muted; font.pixelSize: Style.font.caption }
            Label { text: root.settingsDraft.provider === "openai" ? "Model (required for OpenAI-compatible)" : "Model (blank = provider default)" }
            Field { Layout.fillWidth: true; text: root.settingsDraft.model || ""; placeholderText: "Codex default / llama3.2 for Ollama"; onTextEdited: root.editSetting("model", text) }
            Label { text: "Endpoint (blank = provider default; not used by Codex)" }
            Field { Layout.fillWidth: true; text: root.settingsDraft.endpoint || ""; placeholderText: "http://127.0.0.1:11434 or https://api.openai.com/v1"; onTextEdited: root.editSetting("endpoint", text) }
            Label { text: "API key environment variable NAME (OpenAI-compatible only)" }
            Field { Layout.fillWidth: true; text: root.settingsDraft.api_key_env || ""; placeholderText: "OPENAI_API_KEY"; onTextEdited: root.editSetting("api_key_env", text) }
            Label { Layout.fillWidth: true; text: "Enter the variable name, never the secret key. The backend reads it from the shell process environment. No API secret is saved in these settings."; color: root.muted; font.pixelSize: Style.font.caption }
            RowLayout {
              Action {
                text: "Save changed settings"
                enabled: root.loaded && !root.busy && retentionField.acceptableInput && Object.keys(root.settingsChanges).length > 0
                onClicked: root.request(Object.assign({action: "settings"}, root.settingsChanges))
              }
              Action { text: "Discard changes"; onClicked: root.loadSettings() }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.expanded && (root.page === "history" || root.page === "summaries")
          spacing: Style.space(5)
          RowLayout {
            Layout.fillWidth: true
            Label { text: root.page === "summaries" ? "Export summary" : "Export selected"; font.pixelSize: Style.font.caption }
            Action {
              text: "Copy Markdown"
              enabled: !root.busy && (root.page === "summaries" ? !!root.currentSummary : root.selectedIds.length > 0)
              onClicked: root.request(root.exportPayload("export"))
            }
            Field { Layout.fillWidth: true; text: root.savePath; placeholderText: "~/dictations.md"; onTextEdited: root.savePath = text }
            Action {
              text: "Save file"
              enabled: !root.busy && root.savePath.trim() !== "" && (root.page === "summaries" ? !!root.currentSummary : root.selectedIds.length > 0)
              onClicked: root.request(root.exportPayload("export_file"))
            }
          }
          Label { Layout.fillWidth: true; text: "Markdown includes source text. Save creates a new file only; existing files are never overwritten. Choose a different path if it already exists."; font.pixelSize: Style.font.caption; color: root.muted }
        }

        Rectangle {
          visible: root.confirmAction !== ""
          Layout.fillWidth: true
          implicitHeight: confirmationColumn.implicitHeight + Style.space(20)
          color: Qt.rgba(Commons.Color.urgent.r, Commons.Color.urgent.g, Commons.Color.urgent.b, 0.12)
          radius: Style.cornerRadius
          ColumnLayout {
            id: confirmationColumn
            anchors.fill: parent
            anchors.margins: Style.space(10)
            Label {
              Layout.fillWidth: true
              text: root.confirmAction === "entries" ? "Permanently delete " + root.confirmationIds.length + " selected entries? Saved summaries keep their original source snapshots. To remove those too, open Saved summaries and delete each relevant summary." : "Permanently delete saved summary #" + root.confirmationSummary + " and all of its source snapshots? The original inbox entries are not deleted."
            }
            RowLayout {
              Action { text: "Cancel"; onClicked: root.confirmAction = "" }
              Action { text: "Confirm permanent deletion"; foreground: Commons.Color.urgent; onClicked: root.confirmDelete() }
            }
          }
        }
      }
    }
  }
}
