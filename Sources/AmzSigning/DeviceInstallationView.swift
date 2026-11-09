import SwiftUI
import AmzSigningCore

struct DeviceInstallationView: View {
    @ObservedObject var model: SettingsModel
    // Capture the authorized project identities when the sheet opens.
    @SwiftUI.State private var projects: [Project]
    @SwiftUI.State private var selectedProjects: Set<String>
    @SwiftUI.State private var selectedUDID = ""
    @Environment(\.dismiss) private var dismiss

    init(model: SettingsModel, projects: [Project]) {
        self.model = model
        _projects = SwiftUI.State(initialValue: projects)
        _selectedProjects = SwiftUI.State(initialValue: Set(projects.map(\.id)))
    }
    private var selectedDevice: Device? { model.availableDevices.first { $0.udid == selectedUDID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionHeading(title: "安装到 iPhone")
                Button { model.discoverDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SigningButtonStyle(kind: .text, compact: true))
                    .help("刷新设备").accessibilityLabel("刷新设备")
                    .disabled(model.loadingDevices || model.running)
            }
            if model.loadingDevices {
                HStack { ProgressView().controlSize(.small); Text("正在查找 iPhone…") }.font(.system(size: 13))
            } else if let error = model.deviceError {
                Text(error).font(.system(size: 12)).foregroundStyle(SigningStyle.amber).textSelection(.enabled)
            } else if model.availableDevices.isEmpty {
                Text("用 USB 连接并解锁新 iPhone，完成信任与开发者模式设置后刷新。").font(.system(size: 13)).foregroundStyle(SigningStyle.secondary)
                Button("打开 Xcode") { model.openXcode() }.buttonStyle(SigningButtonStyle(kind: .text, compact: true))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.availableDevices) { device in
                            Button { selectedUDID = device.udid } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedUDID == device.udid ? "checkmark.circle.fill" : "circle").foregroundStyle(SigningStyle.blue)
                                    Image(systemName: "iphone").font(.system(size: 24))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.system(size: 14, weight: .medium)).lineLimit(1).help(device.name)
                                        Text("\(device.transportTitle) · 标识尾号 \(device.udid.suffix(6))\(device.paired ? "" : " · 需要配对")\(device.developerMode == false ? " · 开发者模式未开启" : "")")
                                            .font(.system(size: 11)).foregroundStyle(SigningStyle.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.frame(minHeight: 52).padding(12).background(selectedUDID == device.udid ? SigningStyle.blueSoft : SigningStyle.soft, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).accessibilityAddTraits(selectedUDID == device.udid ? .isSelected : [])
                        }
                    }
                }.frame(height: min(CGFloat(model.availableDevices.count) * 84, 200))
                if model.availableDevices.contains(where: { !$0.paired || $0.developerMode == false }) {
                    Button("打开 Xcode 配对设备") { model.openXcode() }.buttonStyle(SigningButtonStyle(kind: .text, compact: true))
                }
            }
            Divider()
            Text("安装项目").font(.system(size: 13, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(projects) { project in
                        Toggle(project.name, isOn: Binding(get: { selectedProjects.contains(project.id) }, set: {
                            if $0 { selectedProjects.insert(project.id) } else { selectedProjects.remove(project.id) }
                        })).toggleStyle(.checkbox).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(CGFloat(projects.count) * 30, 140))
            Text("成功后在所选 iPhone 自动续签；旧设备 App 保留。App 数据由其自身备份或同步恢复。")
                .font(.system(size: 12)).foregroundStyle(SigningStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(SigningButtonStyle(kind: .text))
                Spacer()
                Button("安装并绑定") {
                    guard let device = selectedDevice else { return }
                    model.install(on: device, projects: projects.filter { selectedProjects.contains($0.id) })
                    dismiss()
                }.buttonStyle(SigningButtonStyle())
                    .disabled(selectedDevice == nil || selectedDevice?.paired != true || selectedDevice?.developerMode == false || selectedProjects.isEmpty || model.loadingDevices || !model.canRenew)
            }
        }.padding(28).frame(width: 500).background(SigningStyle.canvas).foregroundStyle(SigningStyle.ink)
            .task { model.discoverDevices() }
    }
}
