import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // same starting size as the Windows/Linux builds, and a floor below
    // which the title bar actions would stop fitting.
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.contentMinSize = NSSize(width: 480, height: 400)
    self.title = "OSCSlider"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
