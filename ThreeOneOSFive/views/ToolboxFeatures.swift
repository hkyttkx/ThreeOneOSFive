//
// ToolboxFeatures.swift
// AzTuT 工具箱：应用管理 / 设备伪装（可还原）/ 进程管理
//
// ★ 安全铁律（用户要求）：
//   · 绝不写任何系统文件 → 不可能白苹果
//   · 绝不卸载系统 App、绝不动系统目录
//   · 所有"伪装"只保存在 App 自己的 UserDefaults，改前先备份原始值
//

import SwiftUI
import Foundation
import Darwin

// proc_pidpath 不在公开 SDK，手动声明（运行时由 libsystem 提供）
@_silgen_name("proc_pidpath")
func az_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

// ═══════════════════════════════════════════════════════════
// MARK: - 1. 应用管理
// ═══════════════════════════════════════════════════════════

struct ManagedApp: Identifiable, Hashable {
    let id: String
    let name: String
    let containerPath: String
    let version: String
    let isSystem: Bool

    var displaySize: String {
        let bytes = AppManager.directorySize(containerPath)
        if bytes == 0 { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}

enum AppManager {

    /// 系统 App 判定（三重检查）
    static func isSystemApp(bundleID: String) -> Bool {
        if bundleID.hasPrefix("com.apple.") { return true }
        if bundleID.hasPrefix("com.apple") { return true }
        // 系统内置的公开 App 白名单外，其余按前缀判定
        return false
    }

    static func installedApps() -> [ManagedApp] {
        var result: [ManagedApp] = []
        var seen = Set<String>()
        for item in ContainerStore.containersFromFilesystem() {
            guard !seen.contains(item.bundleID) else { continue }
            seen.insert(item.bundleID)
            result.append(ManagedApp(
                id: item.bundleID,
                name: item.displayName,
                containerPath: item.containerPath,
                version: item.version,
                isSystem: isSystemApp(bundleID: item.bundleID)
            ))
        }
        return result.sorted {
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func directorySize(_ path: String) -> UInt64 {
        guard !path.isEmpty else { return 0 }
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        for case let f as String in e {
            let full = (path as NSString).appendingPathComponent(f)
            if let a = try? fm.attributesOfItem(atPath: full),
               let sz = a[.size] as? NSNumber {
                total += sz.uint64Value
            }
        }
        return total
    }

    /// 卸载（★ 只允许用户 App，系统 App 一律拒绝）
    static func uninstall(bundleID: String) -> (ok: Bool, message: String) {
        guard !isSystemApp(bundleID: bundleID) else {
            return (false, "系统应用不可卸载（已拦截）")
        }
        // 从枚举结果再确认一次
        if let app = installedApps().first(where: { $0.id == bundleID }), app.isSystem {
            return (false, "系统应用不可卸载（已拦截）")
        }

        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
            RTLD_LAZY) else {
            return (false, "无法加载服务")
        }
        defer { dlclose(handle) }

        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("defaultWorkspace")) else {
            return (false, "此 iOS 版本不支持")
        }
        let workspace = cls.perform(NSSelectorFromString("defaultWorkspace"))!.takeUnretainedValue() as AnyObject
        let sel = NSSelectorFromString("uninstallApplication:withOptions:")
        guard workspace.responds(to: sel) else { return (false, "卸载接口不可用") }
        _ = workspace.perform(sel, with: bundleID as NSString, with: nil)
        return (true, "已请求卸载 \(bundleID)")
    }

    /// 备份数据容器（复制到 App 沙盒，不碰原目录）
    static func backupContainer(of app: ManagedApp) -> (path: String?, message: String) {
        guard !app.containerPath.isEmpty else { return (nil, "没有数据容器") }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return (nil, "无法访问沙盒")
        }
        let dir = docs.appendingPathComponent("AzBackups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = app.id.replacingOccurrences(of: "/", with: "_")
        let out = dir.appendingPathComponent("\(safe)_\(Int(Date().timeIntervalSince1970))")
        do {
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            try fm.copyItem(atPath: app.containerPath, toPath: out.path)
            return (out.path, "已备份到 AzBackups/")
        } catch {
            return (nil, "备份失败：\(error.localizedDescription)")
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 2. 设备伪装（可还原 / 零系统写入）
// ═══════════════════════════════════════════════════════════

struct DeviceIdentity: Codable, Equatable {
    var model: String = ""
    var serialNumber: String = ""
    var udid: String = ""
    var idfv: String = ""
    var idfa: String = ""
    var wifiMAC: String = ""
    var deviceName: String = ""
}

enum DeviceSpoof {
    private static let activeKey = "az.spoof.active"
    private static let backupKey = "az.spoof.backup"

    // ── 读取真实值（只读，不修改任何东西）──
    static func current() -> DeviceIdentity {
        let d = UIDevice.current
        return DeviceIdentity(
            model: AppInfo.displayMachineName,
            serialNumber: sysctlString("hw.serialnumber") ?? "不可读",
            udid: sysctlString("kern.uuid") ?? "不可读",
            idfv: d.identifierForVendor?.uuidString ?? "—",
            idfa: "—",
            wifiMAC: sysctlString("net.en0.ether") ?? "不可读",
            deviceName: d.name
        )
    }

    static func active() -> DeviceIdentity? {
        guard let raw = UserDefaults.standard.data(forKey: activeKey) else { return nil }
        return try? JSONDecoder().decode(DeviceIdentity.self, from: raw)
    }

    /// ★ 备份原始值（第一次生成时才备份，之后再生成不覆盖备份）
    static func backupIfNeeded() {
        guard UserDefaults.standard.data(forKey: backupKey) == nil else { return }
        if let d = try? JSONEncoder().encode(current()) {
            UserDefaults.standard.set(d, forKey: backupKey)
        }
    }

    static func backup() -> DeviceIdentity? {
        guard let raw = UserDefaults.standard.data(forKey: backupKey) else { return nil }
        return try? JSONDecoder().decode(DeviceIdentity.self, from: raw)
    }

    static func activate(_ identity: DeviceIdentity) {
        if let d = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(d, forKey: activeKey)
        }
    }

    /// ★ 一键还原：清空伪装，回到原始标识
    static func restore() {
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    /// 生成一套新的随机标识
    static func generate() -> DeviceIdentity {
        backupIfNeeded()
        var id = current()
        id.serialNumber = randomAlphaNum(12)
        id.udid = randomHex(40).uppercased()
        id.idfv = UUID().uuidString
        id.idfa = UUID().uuidString
        id.wifiMAC = randomMAC()
        return id
    }

    // ── 只读 sysctl 辅助 ──
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func randomHex(_ n: Int) -> String {
        let c = "0123456789abcdef"
        return String((0..<n).map { _ in c.randomElement()! })
    }
    private static func randomAlphaNum(_ n: Int) -> String {
        let c = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"
        return String((0..<n).map { _ in c.randomElement()! })
    }
    private static func randomMAC() -> String {
        let c = "0123456789ABCDEF"
        return (0..<6).map { _ in String((0..<2).map { _ in c.randomElement()! }) }.joined(separator: ":")
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 3. 进程管理
// ═══════════════════════════════════════════════════════════

struct RunningProcess: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let path: String
    let isSystem: Bool
    let isSelf: Bool
    var id: Int32 { pid }
}

enum ProcessManager {

    static func list() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        var out: [RunningProcess] = []
        let myPid = getpid()

        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let kp = base.advanced(by: i * stride).assumingMemoryBound(to: kinfo_proc.self).pointee
                let pid = kp.kp_proc.p_pid
                if pid <= 0 { continue }

                var comm = kp.kp_proc.p_comm
                let name = withUnsafePointer(to: &comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
                }
                let path = processPath(pid: pid) ?? ""
                let sys = path.isEmpty || path.hasPrefix("/System/") || path.hasPrefix("/usr/")
                out.append(RunningProcess(
                    pid: pid,
                    name: name.isEmpty ? "pid \(pid)" : name,
                    path: path,
                    isSystem: sys,
                    isSelf: pid == myPid
                ))
            }
        }
        // 去重（同名同 pid）
        var seen = Set<Int32>()
        return out.filter { seen.insert($0.pid).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func processPath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let r = az_proc_pidpath(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    /// 结束进程（★ 拒绝系统进程 / PID<=1 / 自身）
    static func killProcess(pid: Int32) -> (ok: Bool, message: String) {
        if pid <= 1 { return (false, "受保护进程，已拒绝") }
        if pid == getpid() { return (false, "不能结束自身") }
        if let p = list().first(where: { $0.pid == pid }), p.isSystem {
            return (false, "系统进程不可结束（已拦截）")
        }
        return kill(pid, SIGKILL) == 0 ? (true, "已结束") : (false, "失败 errno=\(errno)")
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - UI：应用管理
// ═══════════════════════════════════════════════════════════

struct AppManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [ManagedApp] = []
    @State private var query = ""
    @State private var showSystem = false
    @State private var message = ""
    @State private var pending: ManagedApp?

    var filtered: [ManagedApp] {
        apps.filter { a in
            (showSystem || !a.isSystem) &&
            (query.isEmpty || a.name.localizedCaseInsensitiveContains(query)
                          || a.id.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("显示系统应用（仅查看）", isOn: $showSystem)
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(filtered) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(app.name).font(.headline)
                                Spacer()
                                if app.isSystem {
                                    Text("系统")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.18), in: Capsule())
                                } else {
                                    Text(app.displaySize).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text("\(app.id)  v\(app.version)")
                                .font(.caption2).foregroundStyle(.secondary)

                            if !app.isSystem {
                                HStack(spacing: 14) {
                                    Button("备份数据") {
                                        let r = AppManager.backupContainer(of: app)
                                        message = r.message
                                    }
                                    .font(.caption)
                                    Button("卸载", role: .destructive) { pending = app }
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("共 \(filtered.count) 个")
                } footer: {
                    Text("系统应用已锁定，无法卸载或修改。")
                }
            }
            .searchable(text: $query, prompt: "搜索应用")
            .navigationTitle("应用管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("确认卸载", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } })) {
                Button("取消", role: .cancel) { pending = nil }
                Button("卸载", role: .destructive) {
                    if let a = pending {
                        message = AppManager.uninstall(bundleID: a.id).message
                        pending = nil
                        apps = AppManager.installedApps()
                    }
                }
            } message: {
                Text("将卸载 \(pending?.name ?? "")。该操作不可撤销。")
            }
            .onAppear { if apps.isEmpty { apps = AppManager.installedApps() } }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - UI：设备伪装（可还原）
// ═══════════════════════════════════════════════════════════

struct DeviceSpoofView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = DeviceSpoof.current()
    @State private var backup = DeviceSpoof.backup()
    @State private var active = DeviceSpoof.active()
    @State private var draft: DeviceIdentity?
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("本机真实标识（只读）") {
                    row("型号", current.model)
                    row("序列号", current.serialNumber)
                    row("UDID", current.udid)
                    row("IDFV", current.idfv)
                    row("WiFi MAC", current.wifiMAC)
                    row("设备名", current.deviceName)
                }

                if let d = draft {
                    Section("待应用的伪装标识") {
                        row("序列号", d.serialNumber)
                        row("UDID", d.udid)
                        row("IDFV", d.idfv)
                        row("IDFA", d.idfa)
                        row("WiFi MAC", d.wifiMAC)
                    }
                }

                if let a = active {
                    Section("当前生效的伪装") {
                        row("序列号", a.serialNumber)
                        row("UDID", a.udid)
                        row("IDFV", a.idfv)
                    }
                }

                Section {
                    Button("生成一套新标识") {
                        draft = DeviceSpoof.generate()
                        status = "已生成待确认"
                    }
                    if draft != nil {
                        Button("应用伪装") {
                            if let d = draft {
                                DeviceSpoof.activate(d)
                                active = d
                                backup = DeviceSpoof.backup()
                                status = "已应用（本地生效）"
                            }
                        }
                    }
                    if active != nil {
                        Button("还原为原始标识", role: .destructive) {
                            DeviceSpoof.restore()
                            active = nil
                            draft = nil
                            status = "已还原"
                        }
                    }
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("""
                    安全说明：
                    · 全程不写入任何系统文件，不会白苹果
                    · 应用前自动备份原始标识，随时可一键还原
                    · 伪装值保存在本机 App 内，需注入模块读取才会对目标 App 生效
                    """)
                }
            }
            .navigationTitle("设备伪装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .onAppear {
                current = DeviceSpoof.current()
                backup = DeviceSpoof.backup()
                active = DeviceSpoof.active()
            }
        }
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
            Spacer()
            Text(v.isEmpty ? "—" : v)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - UI：进程管理
// ═══════════════════════════════════════════════════════════

struct ProcessListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var procs: [RunningProcess] = []
    @State private var query = ""
    @State private var status = ""
    @State private var pending: RunningProcess?
    @State private var showSystem = false

    var filtered: [RunningProcess] {
        procs.filter { p in
            (showSystem || !p.isSystem) &&
            (query.isEmpty || p.name.localizedCaseInsensitiveContains(query)
                          || p.path.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("显示系统进程", isOn: $showSystem)
                    Button("刷新列表") { procs = ProcessManager.list() }
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(filtered) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(p.name).font(.headline)
                                Spacer()
                                Text("PID \(p.pid)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if !p.path.isEmpty {
                                Text(p.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if !p.isSystem && !p.isSelf {
                                Button("结束进程", role: .destructive) { pending = p }
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("共 \(filtered.count) 个")
                }
            }
            .searchable(text: $query, prompt: "搜索进程")
            .navigationTitle("进程管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("确认结束", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } })) {
                Button("取消", role: .cancel) { pending = nil }
                Button("结束", role: .destructive) {
                    if let p = pending {
                        status = "\(p.name)：\(ProcessManager.killProcess(pid: p.pid).message)"
                        pending = nil
                        procs = ProcessManager.list()
                    }
                }
            } message: {
                Text("结束 \(pending?.name ?? "")（PID \(pending?.pid ?? 0)）？系统进程会被拒绝。")
            }
            .onAppear { if procs.isEmpty { procs = ProcessManager.list() } }
        }
    }
}
