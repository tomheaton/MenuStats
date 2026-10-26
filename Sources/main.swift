import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var lastTicks: CPUTicks?
    private var cpu = CPUUsage(user: 0, system: 0)
    private var memory: MemoryStats?
    private let sensors = Sensors()
    private var readings: SensorReadings?
    private var menuIsOpen = false

    // 90 samples at 2 seconds each is the last 3 minutes.
    private var cpuUserHistory = History(capacity: 90)
    private var cpuSystemHistory = History(capacity: 90)
    private var memoryAppHistory = History(capacity: 90)
    private var memoryWiredHistory = History(capacity: 90)
    private var memoryCompressedHistory = History(capacity: 90)
    private var cpuTemperatureHistory = History(capacity: 90)
    private var gpuTemperatureHistory = History(capacity: 90)
    private let cpuGraph = GraphView(frame: NSRect(x: 0, y: 0, width: 330, height: 66))
    private let temperatureGraph = GraphView(frame: NSRect(x: 0, y: 0, width: 330, height: 66))
    private let memoryGraph = GraphView(frame: NSRect(x: 0, y: 0, width: 330, height: 66))

    // Built once and updated in place: replacing items while the menu is open
    // leaves it drawn with stale rows.
    private let cpuRow = NSMenuItem()
    private lazy var sensorRows = (0..<(2 + (sensors?.fanCount ?? 0))).map { _ in NSMenuItem() }
    private let memoryRows = (0..<7).map { _ in NSMenuItem() }
    private let appRows = (0..<6).map { _ in NSMenuItem() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        buildMenu()
        lastTicks = readCPUTicks()
        refresh()

        // .common so the numbers keep updating while the menu is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func refresh() {
        if let ticks = readCPUTicks() {
            if let lastTicks {
                cpu = cpuUsage(from: lastTicks, to: ticks)
                cpuUserHistory.append(cpu.user)
                cpuSystemHistory.append(cpu.system)
            }
            lastTicks = ticks
        }
        memory = readMemory()
        if let memory {
            let total = Double(memory.total)
            memoryAppHistory.append(Double(memory.app) / total)
            memoryWiredHistory.append(Double(memory.wired) / total)
            memoryCompressedHistory.append(Double(memory.compressed) / total)
        }
        readings = sensors?.read()
        if let cpuAverage = readings?.cpuAverage { cpuTemperatureHistory.append(cpuAverage) }
        if let gpuAverage = readings?.gpuAverage { gpuTemperatureHistory.append(gpuAverage) }
        updateTitle()
        if menuIsOpen { updateMenu() }
    }

    // Plain text and a template image, not coloured attributed text, so the
    // menu bar can dim them like other items when it's inactive.
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let cpuHistory = zip(cpuUserHistory.values, cpuSystemHistory.values).map(+)
        button.image = sparkline(cpuHistory)
        button.imagePosition = .imageLeading

        var text = "CPU \(percent(cpu.total))"
        if let cpuAverage = readings?.cpuAverage {
            text += " \(Int(cpuAverage.rounded()))°"
        }
        if let memory {
            text += "  RAM \(gigabytes(memory.used, decimals: 1))"
        }
        if let memory, memory.pressure != .normal {
            text = "⚠︎ " + text
        }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        button.title = text
    }

    private func buildMenu() {
        cpuGraph.title = "CPU"
        cpuGraph.stacked = true
        temperatureGraph.title = "Temperature"
        temperatureGraph.range = 20...110
        memoryGraph.title = "Memory"
        memoryGraph.stacked = true

        menu.addItem(graphItem(cpuGraph))
        menu.addItem(cpuRow)
        let temperatureItem = graphItem(temperatureGraph)
        temperatureItem.isHidden = sensors == nil
        menu.addItem(temperatureItem)
        sensorRows.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(graphItem(memoryGraph))
        memoryRows.forEach(menu.addItem)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Top memory", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        appRows.forEach(menu.addItem)

        menu.addItem(.separator())
        let activityMonitor = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        activityMonitor.target = self
        menu.addItem(activityMonitor)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func graphItem(_ graph: GraphView) -> NSMenuItem {
        graph.autoresizingMask = [.width]
        let item = NSMenuItem()
        item.view = graph
        return item
    }

    private func updateMenu() {
        cpuGraph.series = [
            GraphSeries(name: "User", color: .systemBlue, values: cpuUserHistory.values),
            GraphSeries(name: "System", color: .systemRed, values: cpuSystemHistory.values),
        ]
        temperatureGraph.series = [
            GraphSeries(name: "CPU", color: .systemOrange, values: cpuTemperatureHistory.values),
            GraphSeries(name: "GPU", color: .systemPink, values: gpuTemperatureHistory.values),
        ]
        memoryGraph.series = [
            GraphSeries(name: "App", color: .systemBlue, values: memoryAppHistory.values),
            GraphSeries(name: "Wired", color: .systemOrange, values: memoryWiredHistory.values),
            GraphSeries(name: "Compressed", color: .systemPurple, values: memoryCompressedHistory.values),
        ]

        setRow(cpuRow,"CPU", "\(percent(cpu.total))  (user \(percent(cpu.user)), system \(percent(cpu.system)))")

        var sensorValues: [(String, String)] = []
        if let readings {
            if let cpuAverage = readings.cpuAverage, let cpuHottest = readings.cpuHottest {
                sensorValues.append(("  Temperature", "\(celsius(cpuAverage)), hottest \(celsius(cpuHottest))"))
            }
            if let gpuAverage = readings.gpuAverage {
                sensorValues.append(("GPU temperature", celsius(gpuAverage)))
            }
            for (index, fan) in readings.fans.enumerated() {
                let speed = fan.rpm < 1 ? "off" : "\(Int(fan.rpm.rounded())) rpm of \(Int(fan.maxRPM.rounded()))"
                sensorValues.append(("Fan \(index + 1)", speed))
            }
        }
        fill(sensorRows, with: sensorValues)

        let memoryValues: [(String, String)] = if let memory {
            [
                ("Memory", "\(gigabytes(memory.used)) of \(gigabytes(memory.total))"),
                ("  App", gigabytes(memory.app)),
                ("  Wired", gigabytes(memory.wired)),
                ("  Compressed", gigabytes(memory.compressed)),
                ("  Cached files", gigabytes(memory.cached)),
                ("Swap", "\(gigabytes(memory.swapUsed)) of \(gigabytes(memory.swapTotal))"),
                ("Pressure", memory.pressure.rawValue),
            ]
        } else {
            [("Memory", "unavailable")]
        }
        fill(memoryRows, with: memoryValues)

        fill(appRows, with: topAppsByMemory(limit: appRows.count).map { app in
            (app.name, gigabytes(app.bytes) + (app.processes > 1 ? "  (\(app.processes))" : ""))
        })
    }

    // Hides the rows left over when there are fewer values than rows.
    private func fill(_ rows: [NSMenuItem], with values: [(String, String)]) {
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= values.count
            if !row.isHidden { setRow(row, values[index].0, values[index].1) }
        }
    }

    private func setRow(_ item: NSMenuItem, _ label: String, _ value: String) {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
        item.attributedTitle = NSAttributedString(string: "\(label)\t\(value)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .paragraphStyle: style,
        ])
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

private func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

private func celsius(_ value: Double) -> String {
    "\(Int(value.rounded())) °C"
}

private func gigabytes(_ bytes: UInt64, decimals: Int = 2) -> String {
    String(format: "%.\(decimals)f GB", Double(bytes) / 1_073_741_824)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
