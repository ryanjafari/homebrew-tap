class Btscan < Formula
  desc "Bluetooth LE scanner CLI for macOS (works from Claude Code / scripts)"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  version "1.0.0"
  license "MIT"

  # Source is inlined below; compiled with swiftc at install time.
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  depends_on :macos

  def install
    # CoreBluetooth access is gated by TCC on the *responsible process*. A bare
    # `swift script.swift` run from a non-Terminal host (e.g. Claude Code's
    # Bash helper) is killed instead of prompted. Building a real .app bundle
    # with NSBluetoothAlwaysUsageDescription and launching it with `open`
    # makes the bundle its own responsible process, so it gets a normal prompt.
    app = libexec/"BTScan.app/Contents"
    (app/"MacOS").mkpath

    (app/"Info.plist").write <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>com.ryanjafari.btscan</string>
      <key>CFBundleName</key><string>BTScan</string>
      <key>CFBundleExecutable</key><string>BTScan</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>#{version}</string>
      <key>LSUIElement</key><true/>
      <key>NSBluetoothAlwaysUsageDescription</key><string>btscan lists nearby Bluetooth LE devices.</string>
      </dict></plist>
    EOS

    (buildpath/"main.swift").write <<~'EOS'
      import CoreBluetooth
      import Foundation

      // Usage (via the btscan wrapper): BTScan [seconds] [--json] [--filter substring]
      var seconds = 10.0
      var json = false
      var filter: String? = nil
      var args = Array(CommandLine.arguments.dropFirst())
      while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--json": json = true
        case "--filter", "-f": filter = args.isEmpty ? nil : args.removeFirst().lowercased()
        default: if let s = Double(a) { seconds = s }
        }
      }

      struct Dev { var name: String; var rssi: Int; var mfg: String; var services: [String]; var id: String; var seen: Int }

      final class Scanner: NSObject, CBCentralManagerDelegate {
        var devs: [String: Dev] = [:]
        var order: [String] = []
        func centralManagerDidUpdateState(_ c: CBCentralManager) {
          switch c.state {
          case .poweredOn:
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
          case .unauthorized:
            FileHandle.standardError.write("btscan: Bluetooth access denied. Allow it in System Settings > Privacy & Security > Bluetooth.\n".data(using: .utf8)!)
            exit(2)
          case .poweredOff:
            FileHandle.standardError.write("btscan: Bluetooth is powered off.\n".data(using: .utf8)!)
            exit(3)
          default: break
          }
        }
        func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
          let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
          let mfg = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
          let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
          let id = p.identifier.uuidString
          if var d = devs[id] {
            d.rssi = rssi.intValue; d.seen += 1
            if d.name.isEmpty { d.name = name }
            if d.mfg.isEmpty { d.mfg = mfg }
            if d.services.isEmpty { d.services = svcs }
            devs[id] = d
          } else {
            devs[id] = Dev(name: name, rssi: rssi.intValue, mfg: mfg, services: svcs, id: id, seen: 1)
            order.append(id)
          }
        }
      }

      let s = Scanner()
      let central = CBCentralManager(delegate: s, queue: nil)
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
      central.stopScan()

      var list = s.order.compactMap { s.devs[$0] }
      if let f = filter {
        list = list.filter { $0.name.lowercased().contains(f) || $0.mfg.contains(f) || $0.services.joined().lowercased().contains(f) }
      }
      list.sort { $0.rssi > $1.rssi }

      if json {
        let arr: [[String: Any]] = list.map { ["name": $0.name, "rssi": $0.rssi, "manufacturer_data": $0.mfg, "services": $0.services, "id": $0.id, "adverts": $0.seen] }
        let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
      } else {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        print(pad("RSSI", 6) + pad("NAME", 30) + pad("ADVERTS", 9) + "MFG / SERVICES")
        for d in list {
          let extra = d.mfg.isEmpty ? d.services.joined(separator: ",") : d.mfg
          let name = d.name.isEmpty ? "(no name)" : d.name
          print(pad(String(d.rssi), 6) + pad(String(name.prefix(28)), 30) + pad(String(d.seen), 9) + extra)
        }
        print("\(list.count) device(s) in \(Int(seconds))s")
      }
    EOS

    system "swiftc", "-O", "-o", app/"MacOS/BTScan", buildpath/"main.swift"
    system "codesign", "-s", "-", "--force", libexec/"BTScan.app"

    (bin/"btscan").write <<~EOS
      #!/bin/bash
      # btscan [seconds] [--json] [--filter TEXT]
      # Scans for Bluetooth LE advertisements. Runs the bundled BTScan.app via
      # `open` so macOS attributes the Bluetooth permission to the app itself.
      set -e
      if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "usage: btscan [seconds=10] [--json] [--filter TEXT]"
        echo "  Lists nearby Bluetooth LE devices. First run prompts for Bluetooth access."
        exit 0
      fi
      APP="#{opt_libexec}/BTScan.app"
      OUT=$(mktemp -t btscan)
      trap 'rm -f "$OUT"' EXIT
      open -W -n --stdout "$OUT" --stderr "$OUT" "$APP" --args "$@"
      cat "$OUT"
    EOS
    chmod 0755, bin/"btscan"
  end

  def caveats
    <<~EOS
      First run triggers a macOS Bluetooth permission prompt for "BTScan".
      Reinstalling re-signs the bundle and may prompt again.

        btscan            # 10 second scan, table
        btscan 20 --json  # 20 seconds, JSON
        btscan --filter remote
    EOS
  end

  test do
    system bin/"btscan", "--help"
  end
end
