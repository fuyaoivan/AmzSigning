import SwiftUI
import AppKit
import AmzSigningCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case projects = "我的项目", settings = "续签设置", result = "最近运行"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .projects: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        case .result: return "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @SwiftUI.State private var page = SettingsPage.projects
    private var enabled: [Project] { model.state.projects.filter { $0.enabled } }
    private var paused: Bool { model.state.mode == .away }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch page {
                    case .projects: projectsPage
                    case .settings: settingsPage
                    case .result: resultPage
                    }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 32).padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }.id(page)
        }
        .background(SigningStyle.canvas)
        .foregroundStyle(SigningStyle.ink)
        .tint(SigningStyle.blue)
        .frame(minWidth: 980, minHeight: 690)
        .task { model.activate() }
        .alert("AmzSigning", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: SigningStyle.mark).resizable().frame(width: 29, height: 29).accessibilityHidden(true)
                Text("AmzSigning").font(.system(size: 20, weight: .medium))
            }.padding(.leading, 20).padding(.top, 28).padding(.bottom, 32)
            VStack(spacing: 7) {
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol).font(.system(size: 16, weight: page == item ? .semibold : .regular)).frame(width: 20)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if item == .result, (model.state.recentRuns.first?.failureCount ?? 0) > 0 {
                                Circle().fill(SigningStyle.amber).frame(width: 6, height: 6)
                            }
                        }.padding(.horizontal, 16).frame(height: 44)
                            .foregroundStyle(page == item ? SigningStyle.ink : SigningStyle.secondary)
                            .background(page == item ? SigningStyle.selection : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }.padding(.horizontal, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(SigningStyle.line).frame(height: 1).padding(.bottom, 9)
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")).font(.system(size: 10)).foregroundStyle(SigningStyle.secondary.opacity(0.8))
            }.padding(22)
        }.frame(width: 206)
    }

    private var projectsPage: some View {
        Group {
            SectionHeading(title: "我的项目")
            renewalCard
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text("\(model.state.projects.count) 个项目").font(.system(size: 13)).foregroundStyle(SigningStyle.secondary)
                    Spacer()
                    Button { model.scanProjects() } label: { Label("扫描项目", systemImage: "plus") }
                        .buttonStyle(SigningButtonStyle(kind: .text, compact: true)).disabled(model.running)
                }
                if model.state.projects.isEmpty {
                    emptyProjects
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(model.state.projects) { project in
                            ProjectCard(project: project, canRenew: model.canRenew,
                                        running: model.running && model.state.activity?.hasPrefix(project.name + "：") == true,
                                        toggle: { model.toggle(project, enabled: $0) }, renew: { model.launch("renew", id: project.id) },
                                        remove: { model.removeProject(project) })
                        }
                    }
                }
                if !model.state.scanIssues.isEmpty {
                    DisclosureGroup("扫描提示 · \(model.state.scanIssues.count)") {
                        Text(model.state.scanIssues.joined(separator: "\n\n")).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    }.font(.system(size: 12)).foregroundStyle(SigningStyle.amber)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(SigningStyle.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(latestSummary).font(.system(size: 12, weight: .medium))
                    Text(model.state.recentRuns.first.map { dateText($0.finished ?? $0.started) } ?? "—")
                        .font(.system(size: 11)).foregroundStyle(SigningStyle.secondary)
                }
                Spacer()
                Button("查看详情") { page = .result }.buttonStyle(SigningButtonStyle(kind: .text, compact: true))
            }.padding(16).background(SigningStyle.soft, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var renewalStatus: (title: String, color: Color)? {
        if model.running { return ("正在执行", SigningStyle.blue) }
        guard !paused, !enabled.isEmpty else { return nil }
        return model.schedulerReady ? ("自动续签已就绪", SigningStyle.green) : ("正在检查调度", SigningStyle.blue)
    }

    private var renewalTitle: String {
        if paused { return model.state.mode.title }
        return enabled.isEmpty ? "未启用项目" : "\(enabled.count) 个项目已启用"
    }

    private var renewalCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if let status = renewalStatus { StatusLabel(title: status.title, color: status.color) }
                Text(renewalTitle).font(.system(size: 22, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let description = nextDescription {
                    Text(description).font(.system(size: 12)).foregroundStyle(SigningStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if model.running { ProgressView().controlSize(.small) }
            Button { model.launch("renew") } label: { Label("立即续签", systemImage: "arrow.clockwise") }
                .buttonStyle(SigningButtonStyle(kind: .primary)).disabled(!model.canRenew)
                .keyboardShortcut("r", modifiers: .command)
        }.frame(maxWidth: .infinity, alignment: .leading).signingCard(padding: 24)
    }

    private var nextDescription: String? {
        if model.running { return model.state.activity }
        if paused { return nil }
        guard let due = enabled.map(\.nextDue).min() else { return nil }
        return due <= Date() ? "等待执行" : "下次续签  \(dateText(due))"
    }

    private var emptyProjects: some View {
        VStack(spacing: 15) {
            Image(systemName: "folder.badge.plus").font(.system(size: 36, weight: .light))
                .foregroundStyle(SigningStyle.blue).padding(.bottom, 4)
            Text("暂无项目").font(.system(size: 18, weight: .medium))
        }.frame(maxWidth: .infinity).padding(.vertical, 22).signingCard()
    }

    private var settingsPage: some View {
        Group {
            SectionHeading(title: "续签设置")
            VStack(alignment: .leading, spacing: 20) {
                Label("运行模式", systemImage: "calendar.badge.clock").font(.system(size: 17, weight: .medium))
                HStack(spacing: 12) {
                    modeButton(.automatic, title: "自动模式", symbol: "arrow.triangle.2.circlepath")
                    modeButton(.away, title: "离开模式", symbol: "suitcase.rolling")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).signingCard()
        }
    }

    private func modeButton(_ mode: RunMode, title: String, symbol: String) -> some View {
        let selected = model.state.mode == mode
        return Button { model.setMode(mode) } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular)).frame(height: 22)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }.frame(maxWidth: .infinity).padding(.vertical, 17)
                .foregroundStyle(selected ? SigningStyle.blue : SigningStyle.secondary)
                .background(selected ? SigningStyle.blueSoft : SigningStyle.soft, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? SigningStyle.blue : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var latestSummary: String {
        guard let run = model.state.recentRuns.first else { return "尚未运行" }
        if run.failureCount > 0 { return "\(run.failureCount) 个项目未完成" }
        if run.successCount > 0 { return "\(run.successCount) 个项目续签成功" }
        return "检查完成"
    }

    private var resultPage: some View {
        Group {
            SectionHeading(title: "最近运行")
            if let run = model.state.recentRuns.first {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        Image(systemName: run.failureCount == 0 ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(run.failureCount == 0 ? SigningStyle.green : SigningStyle.amber)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(latestSummary).font(.system(size: 20, weight: .medium))
                            Text(dateText(run.finished ?? run.started)).font(.system(size: 12)).foregroundStyle(SigningStyle.secondary)
                        }
                    }
                    HStack(spacing: 24) {
                        Label("\(run.successCount) 个成功", systemImage: "checkmark").foregroundStyle(SigningStyle.green)
                        Label("\(run.failureCount) 个未完成", systemImage: "clock").foregroundStyle(run.failureCount > 0 ? SigningStyle.amber : SigningStyle.secondary)
                    }.font(.system(size: 13))
                    Divider().overlay(SigningStyle.line)
                    Text(run.messages.joined(separator: "\n\n")).font(.system(size: 13)).lineSpacing(4)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Text("触发方式  \(run.trigger)").font(.system(size: 11)).foregroundStyle(SigningStyle.secondary)
                        Spacer()
                        if let path = run.logPath, FileManager.default.fileExists(atPath: path) {
                            Button("查看运行日志") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .buttonStyle(SigningButtonStyle(kind: .text, compact: true))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).signingCard(padding: 26)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "clock").font(.system(size: 38, weight: .light)).foregroundStyle(SigningStyle.blue)
                    Text("暂无运行记录").font(.system(size: 18, weight: .medium))
                }.frame(maxWidth: .infinity).padding(.vertical, 30).signingCard()
            }
        }
    }
}

private struct ProjectCard: View {
    let project: Project
    let canRenew: Bool
    let running: Bool
    let toggle: (Bool) -> Void
    let renew: () -> Void
    let remove: () -> Void
    private var problem: String? { FileManager.default.isReadableFile(atPath: project.container) ? project.issue : "项目文件无法读取" }
    private var expired: Bool { project.expiration.map { $0 <= Date() } ?? false }
    private var statusColor: Color {
        if problem != nil || expired || project.nextRetry != nil { return SigningStyle.amber }
        if !project.enabled { return SigningStyle.secondary }
        return project.installedExpiration != nil ? SigningStyle.green : SigningStyle.blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "app").font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 44).foregroundStyle(SigningStyle.blue)
                    .background(SigningStyle.blueSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.system(size: 17, weight: .medium)).lineLimit(1).help(project.name)
                    StatusLabel(title: status, color: statusColor)
                }
                Spacer(minLength: 0)
                Toggle("启用 \(project.name)", isOn: Binding(get: { project.enabled }, set: toggle))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("启用 \(project.name)")
            }
            Text(project.bundleID).font(.system(size: 11)).foregroundStyle(SigningStyle.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(project.bundleID)
            VStack(alignment: .leading, spacing: 8) {
                Text(project.installedExpiration == nil ? "本机签名到期" : "签名到期")
                    .font(.system(size: 11)).foregroundStyle(SigningStyle.secondary).help(project.expirationSource)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.expiration.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))) } ?? "等待确认")
                        .font(.system(size: 21, weight: .regular)).foregroundStyle(expired ? SigningStyle.amber : SigningStyle.ink)
                    if let expiry = project.expiration {
                        Text(expiry.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                            .font(.system(size: 12)).foregroundStyle(SigningStyle.secondary)
                    }
                }
            }.padding(.vertical, 2)
            Divider().overlay(SigningStyle.line)
            VStack(spacing: 11) {
                metadata("Scheme", project.scheme + " · " + project.configuration)
                metadata("签名 Team", project.teamName.isEmpty ? "未识别" : project.teamName)
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(SigningStyle.amber).fixedSize(horizontal: false, vertical: true) }
            if let result = project.lastResult, project.nextRetry != nil, !running {
                Text(result).font(.system(size: 11)).foregroundStyle(SigningStyle.amber).lineLimit(3).help(result)
            }
            HStack(alignment: .top, spacing: 6) {
                DisclosureGroup("项目详情") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(project.container)
                        Text("Target：\(project.target)")
                        Text("Team ID：\(project.teamID)")
                        Text("签名：\(project.automatic ? "Automatic" : "Manual")\nTeam 来源：\(project.teamSource)")
                        Text("上次成功：\(dateText(project.lastSuccess))")
                        Text("下次续签：\(project.nextDue == .distantPast ? "首次执行待完成" : dateText(project.nextDue))")
                        if let name = project.deviceName { Text("绑定设备：\(name) · \(project.lastTransport ?? "等待安装")") }
                    }.font(.system(size: 11)).foregroundStyle(SigningStyle.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }.font(.system(size: 11)).foregroundStyle(SigningStyle.secondary).padding(.top, 8)
                Spacer(minLength: 0)
                Button(action: remove) { Image(systemName: "trash").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(SigningStyle.secondary)
                    .help("移除项目，不删除源码或手机 App").accessibilityLabel("移除项目 \(project.name)")
                Button("续签", action: renew).buttonStyle(SigningButtonStyle(kind: .text, compact: true))
                    .disabled(!canRenew || !project.enabled).accessibilityLabel("续签 \(project.name)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).signingCard(padding: 20)
    }

    private var status: String {
        if running { return "正在续签" }
        if problem != nil { return "需检查" }
        if !project.enabled { return "未启用" }
        if project.nextRetry != nil { return "等待重试" }
        if expired { return "已到期" }
        return project.installedExpiration != nil ? "签名有效" : "待首次续签"
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(SigningStyle.secondary).frame(width: 64, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11))
    }
}
