import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // same starting size as the Windows/Linux builds, shrunk to fit a
    // small screen. the layout adapts down to phone width.
    var size = NSSize(width: 1280, height: 720)
    if let screen = NSScreen.main?.visibleFrame {
      size.width = min(size.width, screen.width * 0.95)
      size.height = min(size.height, screen.height * 0.95)
    }
    self.setContentSize(size)
    self.contentMinSize = NSSize(width: 360, height: 360)
    self.title = "OSCSlider"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
