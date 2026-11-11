import QtQuick
import Quickshell.Io
import qs.Ui

BarIconButton {
  id: root
  property string iconMarkup: ""
  tooltipText: "DAEMON Music · Super+M"
  useActiveColor: false
  onPressed: function(button) {
    if (button === Qt.LeftButton && root.bar && root.bar.shell)
      root.bar.shell.toggle("daemon0.music", "{}");
  }
  FileView {
    id: iconFile
    path: decodeURIComponent(String(Qt.resolvedUrl("icons/daemon-music.svg")).replace(/^file:\/\//, ""))
    printErrors: false
    onLoaded: root.iconMarkup = text()
  }
  iconComponent: Component {
    Image {
      anchors.fill: parent
      source: root.iconMarkup ? "data:image/svg+xml," + encodeURIComponent(root.iconMarkup.replace(/#FFFFFF/g, String(root.foreground))) : ""
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.round(width * 2)
      sourceSize.height: Math.round(height * 2)
    }
  }
}
