import AppKit
import Charts
import DuckDiskCore
import SwiftUI

/// CPU, memory, ports and battery, live. Sampling runs only while the room is open.
struct MonitorRoom: View {
    @State private var live = MonitorModel()

    var body: some View {
        RoomScroll {
            VStack(alignment: .leading, spacing: 16) {
                RoomHeader(title: "Monitor", subtitle: "Updated every second while this room is open")
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        CPUCard(live: live).frame(maxHeight: .infinity, alignment: .top)
                        MemoryCard(live: live).frame(maxHeight: .infinity, alignment: .top)
                    }
                    GridRow {
                        ProcessesCard(live: live).frame(maxHeight: .infinity, alignment: .top)
                        BatteryCard(live: live).frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                PortsCard(live: live)
            }
            .padding(24)
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }
}

@MainActor
@Observable
final class MonitorModel {
    var cpu = CPUSample(total: 0, user: 0, system: 0, cores: [])
    var cpuHistory: [Double] = []
    var memory: MemorySample?
    var memoryHistory: [Double] = []
    var processes: [ProcessSample] = []
    var ports: [ListeningPort] = []
    var battery: BatteryStatus?
    var hasBattery = true

    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tick = 0

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample() async {
        let monitor = monitor
        let includePorts = tick % 3 == 0
        let includeBattery = tick % 5 == 0
        tick += 1
        let (cpu, mem, procs, ports, battery) = await Task.detached(priority: .utility) {
            (monitor.sampleCPU(), monitor.sampleMemory(), monitor.sampleProcesses(),
             includePorts ? PortScanner.listening() : nil, includeBattery ? Battery.read() : nil)
        }.value
        self.cpu = cpu
        cpuHistory = Array((cpuHistory + [cpu.total]).suffix(60))
        memory = mem
        memoryHistory = Array((memoryHistory + [Double(mem.used) / Double(max(1, mem.total))]).suffix(60))
        processes = procs
        if let ports { self.ports = ports }
        if includeBattery {
            self.battery = battery
            hasBattery = battery != nil
        }
    }

    func quit(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            kill(pid, SIGTERM)
        }
    }
}

private struct HistoryChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let offset = 60 - values.count
        return Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("t", point.offset + offset), y: .value("v", point.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", point.offset + offset), y: .value("v", point.element))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...1)
        .chartXScale(domain: 0...59)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 70)
    }
}

private struct CPUCard: View {
    let live: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "CPU")
                Spacer()
                Text("User \(percent(live.cpu.user)) · System \(percent(live.cpu.system))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(percent(live.cpu.total)).font(Theme.figure(30))
            HistoryChart(values: live.cpuHistory, color: Theme.color(.developer))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(live.cpu.cores.enumerated()), id: \.offset) { _, load in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(.developer).opacity(0.4 + 0.6 * load))
                            .frame(height: max(2, 30 * load))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Theme.track, in: RoundedRectangle(cornerRadius: 2))
                }
            }
            Text("\(live.cpu.cores.count) cores").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

private struct MemoryCard: View {
    let live: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = live.memory {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Memory")
                    Spacer()
                    Text("Pressure: \(m.pressureTitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(m.pressureLevel >= 4 ? Theme.negative
                                         : m.pressureLevel >= 2 ? Theme.color(.caches) : Theme.positive)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ByteFormat.string(m.used)).font(Theme.figure(30))
                    Text("of \(ByteFormat.string(m.total))").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                HistoryChart(values: live.memoryHistory, color: Theme.color(.downloads))
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        segment(m.app, m.total, Theme.color(.downloads), geo.size.width)
                        segment(m.wired, m.total, Theme.color(.leftovers), geo.size.width)
                        segment(m.compressed, m.total, Theme.color(.caches), geo.size.width)
                        segment(m.cached, m.total, Theme.kept, geo.size.width)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 8)
                .background(Theme.track, in: Capsule())
                .clipShape(Capsule())
                HStack(spacing: 12) {
                    legend("App", m.app, Theme.color(.downloads))
                    legend("Wired", m.wired, Theme.color(.leftovers))
                    legend("Compressed", m.compressed, Theme.color(.caches))
                    legend("Cached", m.cached, Theme.kept)
                }
                if m.swapUsed > 0 {
                    Text("Swap used: \(ByteFormat.string(m.swapUsed))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                SectionLabel(text: "Memory")
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func segment(_ v: Int64, _ total: Int64, _ color: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, width * CGFloat(v) / CGFloat(max(1, total))))
    }

    private func legend(_ label: String, _ v: Int64, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(ByteFormat.string(v))").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ProcessesCard: View {
    let live: MonitorModel
    @State private var byMemory = false
    @State private var toQuit: ProcessSample?

    var body: some View {
        let top = live.processes
            .sorted { byMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            .prefix(8)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Top processes")
                Spacer()
                Picker("", selection: $byMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            ForEach(Array(top)) { p in
                HStack(spacing: 8) {
                    if p.path.contains(".app/") {
                        FileIcon(path: String(p.path[..<p.path.range(of: ".app/")!.upperBound].dropLast()), size: 16)
                    } else {
                        Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            .frame(width: 16)
                    }
                    Text(p.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(byMemory ? ByteFormat.string(p.memory) : String(format: "%.1f%%", p.cpu))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Quit \(p.name)…") { toQuit = p }
                    if !p.path.isEmpty { Button("Reveal in Finder") { Actions.reveal(p.path) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .alert("Quit \(toQuit?.name ?? "")?", isPresented: Binding(get: { toQuit != nil },
                                                                  set: { if !$0 { toQuit = nil } })) {
            Button("Quit", role: .destructive) { if let p = toQuit { live.quit(pid: p.pid) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved work in this process may be lost.")
        }
    }
}

private struct BatteryCard: View {
    let live: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Battery")
            if let b = live.battery {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(b.percent)%").font(Theme.figure(30))
                    Text(stateText(b)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                SizeBar(fraction: Double(b.percent) / 100,
                        color: b.percent <= 20 ? Theme.negative : Theme.positive)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if let h = b.healthPercent { row("Health", "\(h)% of original capacity") }
                    if let c = b.condition { row("Condition", c) }
                    if let n = b.cycleCount { row("Cycles", "\(n)") }
                    if let t = b.temperatureC { row("Temperature", String(format: "%.1f °C", t)) }
                    if let w = b.adapterWatts { row("Charger", "\(w) W") }
                }
            } else if !live.hasBattery {
                Text("This Mac has no battery.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stateText(_ b: BatteryStatus) -> String {
        if b.isCharging { return b.minutesToFull.map { "charging, full in \(duration($0))" } ?? "charging" }
        if b.onAC { return "on power adapter" }
        return b.minutesToEmpty.map { "\(duration($0)) left" } ?? "on battery"
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 12))
        }
    }
}

private struct PortsCard: View {
    let live: MonitorModel
    @State private var toQuit: ListeningPort?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Listening ports")
                Spacer()
                Text("\(live.ports.count) open").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            if live.ports.isEmpty {
                Text("No open ports in your apps.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Port", "Protocol", "Address", "Process", "PID"], id: \.self) {
                            Text($0).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    ForEach(live.ports) { port in
                        GridRow {
                            Text(verbatim: String(port.port)).font(.system(size: 12, design: .monospaced))
                            Text(port.proto).font(.system(size: 12))
                            Text(port.address).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            Text(port.process).font(.system(size: 12)).lineLimit(1)
                            HStack {
                                Text(verbatim: String(port.pid)).font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button("Quit") { toQuit = port }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            Text("Only processes running as you are listed; system services need administrator rights to inspect.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .alert("Quit \(toQuit?.process ?? "")?", isPresented: Binding(get: { toQuit != nil },
                                                                     set: { if !$0 { toQuit = nil } })) {
            Button("Quit", role: .destructive) { if let p = toQuit { live.quit(pid: p.pid) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "This closes port \(toQuit.map { String($0.port) } ?? "") by quitting the process that owns it.")
        }
    }
}
