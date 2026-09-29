import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Glassy Desk bar widget: one icon, one panel listing paired Macs with live
// reachability. Click a Mac to connect (or focus its open viewer); nearby
// unpaired Macs open the pairing flow in a floating terminal.
//
// Mouse: left = panel · right = connect to the most recent Mac · middle = refresh
Panel {
  id: root
  moduleName: "glassydesk.macs"
  ipcTarget: "glassydesk.macs"

  property var machines: []
  property var nearby: []
  property bool loaded: false
  property bool refreshing: false
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property string command: String(setting("command", "glassy-desk"))
  readonly property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 30)))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property int onlineCount: machines.filter(function(m) { return m.online }).length
  readonly property int connectedCount: machines.filter(function(m) { return m.connected }).length
  // Rows the keyboard cursor walks: paired Macs, then nearby ones.
  readonly property var rows: machines.map(function(m) { return { kind: "machine", data: m } })
    .concat(nearby.map(function(h) { return { kind: "nearby", data: h } }))

  readonly property string iconGlyph: "󰢹"   // nf-md-remote_desktop
  readonly property string statusText: {
    if (!loaded) return "Checking your Macs…"
    if (machines.length === 0) return "No paired Macs"
    if (connectedCount > 0) return connectedCount + " connected · " + onlineCount + " of " + machines.length + " online"
    return onlineCount + " of " + machines.length + " online"
  }

  function refresh() {
    if (!bar || !statusProc || statusProc.running) return
    refreshing = true
    statusProc.command = ["bash", "-c", quote(command) + " status --json" + (opened ? " --nearby" : "")]
    statusProc.running = true
  }

  function applyStatus(text) {
    refreshing = false
    try {
      var parsed = JSON.parse(String(text || "{}"))
      machines = parsed.machines || []
      // Keep nearby results from the last open-panel scan during quiet refreshes.
      if (opened || parsed.nearby && parsed.nearby.length > 0) nearby = parsed.nearby || []
      loaded = true
    } catch (e) {
      loaded = true
    }
    cursorIndex = Math.max(0, Math.min(cursorIndex, rows.length - 1))
  }

  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function run(args) {
    if (!bar) return
    bar.run(args)
    refreshSoon.restart()
  }

  function escapeRegex(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function activateMachine(machine) {
    if (!machine) return
    if (machine.connected) {
      run("hyprctl dispatch focuswindow " + quote("title:^" + escapeRegex(machine.name) + " — Glassy Desk"))
    } else {
      run("uwsm-app -- " + quote(command) + " connect " + quote(machine.name))
    }
    close()
  }

  function disconnectMachine(machine) {
    run(quote(command) + " disconnect " + quote(machine.name))
  }

  function pair(address) {
    var target = address ? " pair " + quote(address) : " pair"
    run("omarchy-launch-floating-terminal-with-presentation " + quote(command) + target)
    close()
  }

  function activateRow(index) {
    var row = rows[index]
    if (!row) return
    if (row.kind === "machine") activateMachine(row.data)
    else pair(row.data.address)
  }

  function connectMostRecent() {
    var candidates = machines.slice().sort(function(a, b) { return (b.lastConnected || 0) - (a.lastConnected || 0) })
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].online || candidates[i].connected) { activateMachine(candidates[i]); return }
    }
    if (candidates.length > 0) activateMachine(candidates[0])
  }

  onOpenedChanged: if (opened) { cursorActive = false; refresh() }
  onBarChanged: refresh()
  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(exitCode) { if (exitCode !== 0) root.refreshing = false }
  }

  Timer { interval: root.opened ? 5000 : root.refreshIntervalSec * 1000; running: true; repeat: true; onTriggered: root.refresh() }
  // Viewers take a moment to authenticate and write their session marker.
  Timer { id: refreshSoon; interval: 2500; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    foreground: root.connectedCount > 0 || root.onlineCount > 0 ? root.barForeground : Qt.darker(root.barForeground, 1.55)
    active: root.connectedCount > 0
    useActiveColor: false
    tooltipText: root.opened ? "" : "Glassy Desk · " + root.statusText
    onPressed: function(b) {
      if (b === Qt.RightButton) root.connectMostRecent()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.rows.length === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        var delta = dy !== 0 ? dy : dx
        root.cursorIndex = (root.cursorIndex + delta + root.rows.length) % root.rows.length
      }
      onActivateRequested: if (root.cursorActive) root.activateRow(root.cursorIndex)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          iconComponent: Component {
            Text {
              text: root.iconGlyph
              color: root.foreground
              opacity: root.onlineCount > 0 ? 1.0 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          title: "Glassy Desk"
          meta: root.statusText
          foreground: root.foreground
          fontFamily: root.fontFamily
          trailingControl: Component {
            PanelActionButton {
              iconText: "󰑐"   // refresh
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "MY MACS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.loaded && root.machines.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Pair a Mac running Glassy Desk to see it here."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          Repeater {
            model: root.machines
            MachineRow {
              required property var modelData
              required property int index
              machine: modelData
              rowIndex: index
            }
          }
        }

        Column {
          visible: root.nearby.length > 0
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.foreground }
          PanelSectionHeader {
            text: "NEARBY · NOT PAIRED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Repeater {
            model: root.nearby
            MachineRow {
              required property var modelData
              required property int index
              machine: modelData
              nearbyRow: true
              rowIndex: root.machines.length + index
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Button {
          width: parent.width
          iconText: "󰐕"   // plus
          text: "Pair a Mac…"
          leftAlign: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.pair("")
        }
      }
    }
  }

  // One Mac: status dot · name / detail · trailing action.
  component MachineRow: Rectangle {
    id: row
    property var machine: ({})
    property bool nearbyRow: false
    property int rowIndex: 0
    readonly property bool hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    readonly property string rowState: nearbyRow ? "nearby" : (machine.connected ? "connected" : (machine.online ? "online" : "offline"))

    width: parent ? parent.width : 0
    implicitHeight: Style.space(44)
    radius: Style.space(6)
    color: hasCursor ? root.selectedFill : (mouse.containsMouse ? root.hoverFill : "transparent")

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = row.rowIndex }
      onClicked: row.nearbyRow ? root.pair(row.machine.address) : root.activateMachine(row.machine)
    }

    Rectangle {
      id: dot
      width: Style.space(8)
      height: width
      radius: width / 2
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      color: row.rowState === "connected" ? Color.accent
        : row.rowState === "online" ? root.foreground
        : "transparent"
      border.width: row.rowState === "offline" || row.rowState === "nearby" ? 1 : 0
      border.color: root.dim
    }

    Column {
      anchors.left: dot.right
      anchors.leftMargin: Style.space(12)
      anchors.right: action.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: row.machine.name || ""
        elide: Text.ElideRight
        color: row.rowState === "offline" ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.rowState === "connected"
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        text: {
          var address = row.nearbyRow ? (row.machine.address || "") : (row.machine.host || "")
          if (row.rowState === "connected") return "Connected · " + address
          if (row.rowState === "nearby") return "Click to pair · " + address
          if (row.rowState === "offline") return "Offline · " + address
          return address + (row.machine.quality ? " · " + row.machine.quality : "")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    PanelActionButton {
      id: action
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: !row.nearbyRow && row.machine.connected === true
      iconText: "󰅖"   // close
      tooltipText: "Disconnect"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.disconnectMachine(row.machine)
    }
  }
}
