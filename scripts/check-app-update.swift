import AppKit
import SwiftUI
import TVBoxCore

// Only this isolated validation executable defines its own small theme.
enum Theme {
    static let accent=Color.orange, muted=Color.gray, line=Color.gray.opacity(0.2)
    static let panel=Color(red:0.08,green:0.09,blue:0.12)
}

@main struct UpdateValidationApp: App {
    @StateObject private var updates: AppUpdateController
    @NSApplicationDelegateAdaptor(ValidationDelegate.self) var delegate
    init() {
        let feed=URL(string:Bundle.main.object(forInfoDictionaryKey:"ValidationFeedURL") as! String)!
        _updates=StateObject(wrappedValue:AppUpdateController(validationFeed:feed))
    }
    var body: some Scene {
        WindowGroup {
            VStack(alignment:.leading,spacing:18) {
                Text("TVBox 自动更新验证").font(.title2)
                Text("测试版本 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as! String)")
                AppUpdateView(updates:updates)
                HStack {
                    Button("退出测试") { NSApp.terminate(nil) }
                    if updates.readyOnQuit { Button("退出并安装（测试）") { NSApp.terminate(nil) } }
                }
            }.padding(24).frame(width:620).preferredColorScheme(.dark)
                .modifier(AppUpdateConfirmation(updates:updates))
                .task {
                    let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as! String
                    if build=="1",UserDefaults.standard.string(forKey:"validation.sentinel")==nil {UserDefaults.standard.set("preserved",forKey:"validation.sentinel")}
                    record("launch",["build":build,"sentinel":UserDefaults.standard.string(forKey:"validation.sentinel") ?? "missing"])
                    if build=="1" {
                        try? await Task.sleep(nanoseconds:700_000_000)
                        if Bundle.main.object(forInfoDictionaryKey:"ValidationMode") as? String=="manual" {updates.checkForUpdates()}
                        else {updates.checkInBackground()}
                    }
                }
                .onReceive(updates.$readyOnQuit) { value in if value {record("ready",[:])} }
                .onReceive(updates.$status) { value in
                    if value.hasPrefix("暂时无法") || value.hasPrefix("更新组件未能启动") {record("failure",["message":value])}
                    if value == "当前已是最新版本" {record("up-to-date",[:])}
                }
        }.windowStyle(.titleBar).defaultSize(width:670,height:430)
    }
}
func record(_ event:String,_ extra:[String:String]) {
    guard let directory=Bundle.main.object(forInfoDictionaryKey:"ValidationDirectory") as? String else{return}
    var value=extra;value["event"]=event
    let file=URL(fileURLWithPath:directory).appendingPathComponent(event+"-"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as! String)+".json")
    if let bytes=try? JSONSerialization.data(withJSONObject:value) {try? bytes.write(to:file,options:.atomic)}
}
final class ValidationDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)
        Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { _ in
            if let directory=Bundle.main.object(forInfoDictionaryKey:"ValidationDirectory") as? String,FileManager.default.fileExists(atPath:directory+"/allow-quit") {NSApp.terminate(nil)}
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if Bundle.main.object(forInfoDictionaryKey:"ValidationMode") as? String=="automatic",let directory=Bundle.main.object(forInfoDictionaryKey:"ValidationDirectory") as? String,!FileManager.default.fileExists(atPath:directory+"/allow-quit") {record("early-termination",[:]);return .terminateCancel}
        record("terminate",[:]);return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
