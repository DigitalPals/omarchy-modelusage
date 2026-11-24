import QtQuick
import Quickshell.Wayland

// Whether the session is idle, so background polling can pause while nobody
// is at the machine. Panel.qml loads this through a Loader: on a host without
// IdleMonitor the widget keeps polling instead of failing to load.
Item {
  visible: false
  readonly property bool isIdle: monitor.isIdle

  IdleMonitor {
    id: monitor
    // Idle notification is a Wayland protocol; elsewhere nothing reports idle.
    enabled: Qt.platform.pluginName.startsWith("wayland")
    // Five minutes without input. Inhibitors (video, "stay awake") keep
    // readings live along with the screen.
    timeout: 300
    respectInhibitors: true
  }
}
