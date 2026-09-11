import SwiftUI
import AppKit
import AmzSigningCore
import Darwin

@MainActor final class SettingsModel: ObservableObject {
    @Published var state = AmzSigningCore.State()
    @Published var error: String?
    @Published var starting = false
    @Published var schedulerReady = false
    private(set) var store: StateStore?
    private var watcher: DispatchSourceFileSystemObject?
    private var child: Process?
    var worker: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AmzSigningAgent") }
    var running: Bool {
        starting || (state.activityPID.map { kill($0, 0) == 0 } ?? false)
    }
    var canRenew: Bool { !running && state.mode == .automatic && state.projects.contains(where: \.enabled) }
    init() {
        do {
            let store = try StateStore(); self.store = store
            try store.bootstrap()
            reload()
            let descriptor = open(store.paths.base.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
                source.setEventHandler { [weak self] in self?.reload() }
                source.setCancelHandler { close(descriptor) }
                source.resume(); watcher = source
            }
        } catch { self.store = nil; self.error = error.localizedDescription }
    }
    deinit { watcher?.cancel() }

    func activate() {
        guard let paths = store?.paths else { return }
        let path = worker.path
        Task {
            do {
                try await Task.detached { try Scheduler.install(worker: path, paths: paths) }.value
                schedulerReady = true; reload()
            } catch { self.error = error.localizedDescription }
        }
    }
    func reload() {
        do { if let store { state = try store.read() } }
        catch { self.error = error.localizedDescription }
    }
    func change(_ mutation: (inout AmzSigningCore.State) -> Void) {
        do { if let store { state = try store.update(mutation) } }
        catch { self.error = error.localizedDescription }
    }
    func toggle(_ project: Project, enabled: Bool) {
        change { state in
            guard let index = state.projects.firstIndex(where: { $0.id == project.id && $0.managementID == project.managementID }) else { return }
            state.projects[index].approve(enabled)
        }
        if enabled { launch("tick") }
    }
    func setMode(_ mode: RunMode) {
        change { $0.mode = mode }
        if mode == .automatic { launch("tick") }
    }
    func scanProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = "扫描项目"
        guard panel.runModal() == .OK else { return }
        change { $0.requestScan(roots: panel.urls.map(\.path)) }
        launch("scan")
    }
    func removeProject(_ project: Project) {
        change { $0.removeProject(project) }
    }
    func launch(_ command: String, id: String? = nil) {
        guard !running else { return }
        starting = true
        let process = Process(); process.executableURL = worker
        process.arguments = [command] + (id.map { [$0] } ?? [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.starting = false; self?.child = nil; self?.reload()
                if finished.terminationStatus != 0 { self?.error = "本次任务未完成，请查看最近运行结果。" }
            }
        }
        do { try process.run(); child = process }
        catch { starting = false; self.error = error.localizedDescription }
    }
}
