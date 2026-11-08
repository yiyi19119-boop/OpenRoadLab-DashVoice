// 大声说 DashVoice — App 入口
import AppKit

let app = NSApplication.shared
let state = AppState()
app.delegate = state
app.setActivationPolicy(.accessory)
app.run()
