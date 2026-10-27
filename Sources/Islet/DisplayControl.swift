import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

// MARK: - External displays (DDC/CI)

/// DDC/CI control of external monitors.
///
/// Two transports are supported and picked per display at runtime:
///  * Intel / AMD GPUs: `IOFramebuffer` → `IOFramebufferI2CInterface` (public IOKit i2c API).
///  * Apple Silicon: `DCPAVServiceProxy` via the private `IOAVService*` functions (dlsym).
///
/// All functions are synchronous and block for tens of milliseconds (DDC needs delays);
/// call them off the main thread. They are safe to call from any queue: every I2C
/// transaction is serialized by an internal lock.
enum ExternalDisplays {

    // MARK: Public API

    /// Active, non built-in displays.
    static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count))).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Reads VCP 0x10 (luminance). Returns nil if the display has no DDC path or doesn't answer.
    static func brightness(_ display: CGDirectDisplayID) -> (current: Int, max: Int)? {
        readVCP(display, code: 0x10)
    }

    /// Writes VCP 0x10 (luminance). `value` is clamped to 0...65535; callers should keep it within the max reported by `brightness`.
    @discardableResult
    static func setBrightness(_ display: CGDirectDisplayID, _ value: Int) -> Bool {
        writeVCP(display, code: 0x10, value: value)
    }

    /// Reads VCP 0x12 (contrast).
    static func contrast(_ display: CGDirectDisplayID) -> (current: Int, max: Int)? {
        readVCP(display, code: 0x12)
    }

    /// Writes VCP 0x12 (contrast).
    @discardableResult
    static func setContrast(_ display: CGDirectDisplayID, _ value: Int) -> Bool {
        writeVCP(display, code: 0x12, value: value)
    }

    /// Which transport serves a display (diagnostics): "IOFramebuffer", "IOAVService", or nil.
    static func transportName(_ display: CGDirectDisplayID) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch service(for: display) {
        case .framebuffer?: return "IOFramebuffer"
        case .avService?: return "IOAVService"
        case nil: return nil
        }
    }

    /// Drops cached service lookups (e.g. after a display reconfiguration).
    static func invalidateCache() {
        lock.lock(); defer { lock.unlock() }
        for (_, entry) in cache { entry.service?.release() }
        cache.removeAll()
    }

    /// Generic VCP read. Returns (current, max).
    static func readVCP(_ display: CGDirectDisplayID, code: UInt8) -> (current: Int, max: Int)? {
        lock.lock(); defer { lock.unlock() }
        for attempt in 0..<3 {
            guard let svc = service(for: display) else { return nil }
            waitForBusIdle(display)
            let reply: [UInt8]?
            switch svc {
            case .framebuffer(let fb): reply = framebufferRead(fb, display: display, vcp: code)
            case .avService(let av): reply = avRead(av, vcp: code)
            }
            markBusUsed(display)
            if let r = reply, let parsed = parseVCPReply(r, vcp: code) { return parsed }
            // Monitors frequently NAK or return garbage on the first try; back off and retry.
            if attempt == 1 { dropCache(display) } // service may be stale after hot-plug
            usleep(40_000)
        }
        return nil
    }

    /// Generic VCP write.
    @discardableResult
    static func writeVCP(_ display: CGDirectDisplayID, code: UInt8, value: Int) -> Bool {
        let v = UInt16(clamping: max(0, value))
        lock.lock(); defer { lock.unlock() }
        for attempt in 0..<2 {
            guard let svc = service(for: display) else { return false }
            waitForBusIdle(display)
            let ok: Bool
            switch svc {
            case .framebuffer(let fb): ok = framebufferWrite(fb, vcp: code, value: v)
            case .avService(let av): ok = avWrite(av, vcp: code, value: v)
            }
            markBusUsed(display)
            if ok { return true }
            if attempt == 0 { dropCache(display) }
            usleep(50_000)
        }
        return false
    }

    // MARK: Service cache

    private enum Service {
        case framebuffer(io_service_t)
        case avService(CFTypeRef)

        func release() {
            if case .framebuffer(let s) = self { IOObjectRelease(s) }
            // CFTypeRef is ARC-managed in Swift.
        }
    }

    private struct CacheEntry {
        var service: Service?
        var lookedUp: Date
    }

    private static let lock = NSRecursiveLock()
    private static var cache: [CGDirectDisplayID: CacheEntry] = [:]
    private static var lastBusUse: [CGDirectDisplayID: UInt64] = [:]
    /// How long to remember a failed lookup before trying again.
    private static let negativeCacheTTL: TimeInterval = 10

    /// Must hold `lock`.
    private static func service(for display: CGDirectDisplayID) -> Service? {
        if let entry = cache[display] {
            if entry.service != nil || Date().timeIntervalSince(entry.lookedUp) < negativeCacheTTL {
                return entry.service
            }
        }
        let found = findFramebuffer(for: display).map(Service.framebuffer)
            ?? findAVService(for: display).map(Service.avService)
        cache[display] = CacheEntry(service: found, lookedUp: Date())
        return found
    }

    private static func dropCache(_ display: CGDirectDisplayID) {
        cache[display]?.service?.release()
        cache[display] = nil
    }

    // DDC/CI requires ~50 ms between the end of one command and the start of the next.
    private static func waitForBusIdle(_ display: CGDirectDisplayID) {
        guard let last = lastBusUse[display] else { return }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- last
        let minGapNs: UInt64 = 50_000_000
        if elapsedNs < minGapNs { usleep(useconds_t((minGapNs - elapsedNs) / 1000)) }
    }

    private static func markBusUsed(_ display: CGDirectDisplayID) {
        lastBusUse[display] = DispatchTime.now().uptimeNanoseconds
    }

    // MARK: DDC/CI framing

    /// DDC/CI addresses (8-bit form). Monitor is 0x6E (write) / 0x6F (read); host is 0x51 (and 0x50 for reply checksums).
    private static let ddcDest: UInt8 = 0x6E
    private static let ddcSource: UInt8 = 0x51

    /// Body after the destination address: [src, 0x80|len, payload..., checksum].
    /// Checksum XORs the destination address and every preceding byte.
    private static func ddcPacket(_ payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [ddcSource, 0x80 | UInt8(payload.count)] + payload
        p.append(p.reduce(ddcDest, ^))
        return p
    }

    private static func getVCPPacket(_ vcp: UInt8) -> [UInt8] { ddcPacket([0x01, vcp]) }

    private static func setVCPPacket(_ vcp: UInt8, _ value: UInt16) -> [UInt8] {
        ddcPacket([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Expected reply: [0x6E, 0x88, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]
    /// with checksum = 0x50 ^ bytes[0..<10].
    private static func parseVCPReply(_ r: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        guard r.count >= 11 else { return nil }
        let checksum = r[0..<10].reduce(UInt8(0x50), ^)
        guard r[0] == ddcDest,
              r[1] == 0x88,
              r[2] == 0x02,
              r[3] == 0x00,          // 0 = no error, 1 = unsupported VCP code
              r[4] == vcp,
              r[10] == checksum else { return nil }
        let maxV = Int(r[6]) << 8 | Int(r[7])
        let cur = Int(r[8]) << 8 | Int(r[9])
        guard maxV > 0 else { return nil }
        return (cur, maxV)
    }

    // MARK: IOFramebuffer (Intel / AMD) transport

    /// Finds the IOFramebuffer driving `display`. Primary match is the OpenGL display mask
    /// (unique per framebuffer); the EDID vendor/model/serial is checked as well, and used
    /// alone (as ddcctl does) when the OpenGL index isn't available.
    private static func findFramebuffer(for display: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        let glMask = CGDisplayIDToOpenGLDisplayMask(display)

        var edidMatches: [io_service_t] = []
        var best: io_service_t?

        while case let fb = IOIteratorNext(iterator), fb != 0 {
            var keep = false
            defer { if !keep { IOObjectRelease(fb) } }

            // Must expose at least one I2C bus.
            var busCount: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(fb, &busCount) == KERN_SUCCESS, busCount > 0 else { continue }

            // EDID-derived identity of the display attached to this framebuffer.
            guard let info = IODisplayCreateInfoDictionary(fb, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as? [String: Any] else { continue }
            let fbVendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let fbModel = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            let fbSerial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0
            guard fbVendor == vendor, fbModel == model else { continue }
            if serial != 0, fbSerial != 0, fbSerial != serial { continue }

            if glMask != 0,
               let idx = registryInt(fb, "IOFramebufferOpenGLIndex"),
               idx >= 0, idx < 32,
               (UInt32(1) << UInt32(idx)) == glMask {
                keep = true
                best = fb
                break
            }
            keep = true
            edidMatches.append(fb)
        }

        if let best {
            edidMatches.forEach { IOObjectRelease($0) }
            return best
        }
        // Fallback: unique EDID match.
        if edidMatches.count == 1 { return edidMatches[0] }
        edidMatches.forEach { IOObjectRelease($0) }
        return nil
    }

    private static func registryInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let v = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (v as? NSNumber)?.intValue
    }

    /// Performs one I2C request on the first framebuffer bus that accepts it.
    private static func framebufferSend(_ fb: io_service_t, _ build: (inout IOI2CRequest) -> Void) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(fb, &busCount) == KERN_SUCCESS else { return false }
        for bus in 0..<busCount {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, IOOptionBits(bus), &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else { continue }
            defer { IOI2CInterfaceClose(connect, 0) }

            var request = IOI2CRequest()
            build(&request)
            if IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS {
                return true
            }
        }
        return false
    }

    /// Reply transaction types advertised by the framebuffer's I2C bus, in the order to try.
    /// Simple is tried first: some GPU/monitor combinations (e.g. AMD over DisplayPort with an
    /// MSI panel) fail DDC/CI-typed replies with kIOReturnError but answer simple reads, while
    /// monitors that work with DDC/CI replies also answer simple reads. Whichever type succeeds
    /// is remembered per display.
    private static func replyTransactionTypes(_ fb: io_service_t) -> [IOOptionBits] {
        let simple = IOOptionBits(kIOI2CSimpleTransactionType)
        let ddcci = IOOptionBits(kIOI2CDDCciReplyTransactionType)
        guard let infos = IORegistryEntryCreateCFProperty(fb, kIOFBI2CInterfaceInfoKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]],
              let types = (infos.first?[kIOI2CTransactionTypesKey] as? NSNumber)?.uint32Value else {
            return [simple, ddcci]
        }
        let supported = [simple, ddcci].filter { types & (1 << $0) != 0 }
        return supported.isEmpty ? [simple, ddcci] : supported
    }

    /// Reply type that last worked per display (guarded by `lock`).
    private static var workingReplyType: [CGDirectDisplayID: IOOptionBits] = [:]

    private static func framebufferRead(_ fb: io_service_t, display: CGDirectDisplayID, vcp: UInt8) -> [UInt8]? {
        var order = replyTransactionTypes(fb)
        if let known = workingReplyType[display], let i = order.firstIndex(of: known) {
            order.remove(at: i)
            order.insert(known, at: 0)
        }
        for (i, replyType) in order.enumerated() {
            if i > 0 { usleep(50_000) } // inter-command gap before retrying with another type
            var send = getVCPPacket(vcp)
            var reply = [UInt8](repeating: 0, count: 11)
            let ok = send.withUnsafeMutableBytes { sendBuf -> Bool in
                reply.withUnsafeMutableBytes { replyBuf -> Bool in
                    framebufferSend(fb) { req in
                        req.commFlags = 0
                        req.sendAddress = UInt32(ddcDest)
                        req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                        req.sendBuffer = vm_address_t(UInt(bitPattern: sendBuf.baseAddress))
                        req.sendBytes = UInt32(sendBuf.count)
                        // DDC/CI: host must wait >= 40 ms after a Get VCP before reading the reply.
                        req.minReplyDelay = 40_000_000 // ns
                        req.replyAddress = UInt32(ddcDest | 1)   // 0x6F
                        req.replySubAddress = ddcSource          // 0x51
                        req.replyTransactionType = replyType
                        req.replyBuffer = vm_address_t(UInt(bitPattern: replyBuf.baseAddress))
                        req.replyBytes = UInt32(replyBuf.count)
                    }
                }
            }
            if ok, parseVCPReply(reply, vcp: vcp) != nil {
                workingReplyType[display] = replyType
                return reply
            }
        }
        return nil
    }

    private static func framebufferWrite(_ fb: io_service_t, vcp: UInt8, value: UInt16) -> Bool {
        var send = setVCPPacket(vcp, value)
        return send.withUnsafeMutableBytes { sendBuf -> Bool in
            framebufferSend(fb) { req in
                req.commFlags = 0
                req.sendAddress = UInt32(ddcDest)
                req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                req.sendBuffer = vm_address_t(UInt(bitPattern: sendBuf.baseAddress))
                req.sendBytes = UInt32(sendBuf.count)
                req.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                req.replyBytes = 0
            }
        }
    }

    // MARK: IOAVService (Apple Silicon) transport

    private typealias AVCreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct AVFunctions {
        let create: AVCreateFn
        let read: AVI2CFn
        let write: AVI2CFn
    }

    private static let avFunctions: AVFunctions? = {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) // -2 == RTLD_DEFAULT
        }
        guard let c = sym("IOAVServiceCreateWithService"),
              let r = sym("IOAVServiceReadI2C"),
              let w = sym("IOAVServiceWriteI2C") else { return nil }
        return AVFunctions(create: unsafeBitCast(c, to: AVCreateFn.self),
                           read: unsafeBitCast(r, to: AVI2CFn.self),
                           write: unsafeBitCast(w, to: AVI2CFn.self))
    }()

    /// Walks the IOService plane in order. Each external `DCPAVServiceProxy` follows the
    /// `AppleCLCD2` / `IOMobileFramebufferShim` node that carries its display's EDID attributes
    /// (the approach MonitorControl uses). Match those attributes against CoreGraphics.
    private static func findAVService(for display: CGDirectDisplayID) -> CFTypeRef? {
        guard let fns = avFunctions else { return nil }

        struct Candidate { var service: io_service_t; var vendor: UInt32?; var model: UInt32?; var serial: UInt32?; var name: String? }
        var candidates: [Candidate] = []

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var pendingAttrs: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            let entryName = String(cString: name)

            if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    pendingAttrs = attrs["ProductAttributes"] as? [String: Any]
                }
                IOObjectRelease(entry)
            } else if entryName == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if location == "External" {
                    let a = pendingAttrs
                    candidates.append(Candidate(service: entry,
                                                vendor: (a?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                                                model: (a?["ProductID"] as? NSNumber)?.uint32Value,
                                                serial: (a?["SerialNumber"] as? NSNumber)?.uint32Value,
                                                name: a?["ProductName"] as? String))
                } else {
                    IOObjectRelease(entry)
                }
                pendingAttrs = nil
            } else {
                IOObjectRelease(entry)
            }
        }
        defer { candidates.forEach { IOObjectRelease($0.service) } }
        guard !candidates.isEmpty else { return nil }

        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)

        func score(_ c: Candidate) -> Int {
            var s = 0
            if let v = c.vendor { if v == vendor { s += 1 } else { return -1 } }
            if let m = c.model { if m == model { s += 1 } else { return -1 } }
            if let sn = c.serial, sn != 0, serial != 0 { if sn == serial { s += 2 } else { return -1 } }
            return s
        }
        let scored = candidates.map { ($0, score($0)) }.filter { $0.1 >= 0 }
        guard let top = scored.map(\.1).max() else { return nil }
        let best = scored.filter { $0.1 == top }.map(\.0)

        let chosen: Candidate
        if best.count == 1 {
            chosen = best[0]
        } else {
            // Identical monitors: disambiguate by order among identical CG displays.
            let twins = displays().filter {
                CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model && CGDisplaySerialNumber($0) == serial
            }.sorted()
            guard let idx = twins.firstIndex(of: display), idx < best.count else { return nil }
            chosen = best[idx]
        }
        return fns.create(kCFAllocatorDefault, chosen.service)?.takeRetainedValue()
    }

    private static let avChipAddress: UInt32 = 0x37 // 7-bit DDC/CI address
    private static let avDataAddress: UInt32 = UInt32(0x51)

    /// IOAVService takes the payload without the source byte (it is sent as the data address);
    /// the checksum still covers dest ^ source ^ payload, which `ddcPacket` already computes.
    private static func avPayload(_ packet: [UInt8]) -> [UInt8] { Array(packet.dropFirst()) }

    private static func avRead(_ service: CFTypeRef, vcp: UInt8) -> [UInt8]? {
        guard let fns = avFunctions else { return nil }
        var send = avPayload(getVCPPacket(vcp))
        var wrote = false
        // Some displays drop the first write after idle; send twice with a short gap.
        for _ in 0..<2 {
            usleep(10_000)
            let rc = send.withUnsafeMutableBytes { fns.write(service, avChipAddress, avDataAddress, $0.baseAddress!, UInt32($0.count)) }
            if rc == kIOReturnSuccess { wrote = true }
        }
        guard wrote else { return nil }
        usleep(50_000) // DDC/CI reply delay (>= 40 ms)
        var reply = [UInt8](repeating: 0, count: 11)
        let rc = reply.withUnsafeMutableBytes { fns.read(service, avChipAddress, avDataAddress, $0.baseAddress!, UInt32($0.count)) }
        return rc == kIOReturnSuccess ? reply : nil
    }

    private static func avWrite(_ service: CFTypeRef, vcp: UInt8, value: UInt16) -> Bool {
        guard let fns = avFunctions else { return false }
        var send = avPayload(setVCPPacket(vcp, value))
        var wrote = false
        for _ in 0..<2 {
            usleep(10_000)
            let rc = send.withUnsafeMutableBytes { fns.write(service, avChipAddress, avDataAddress, $0.baseAddress!, UInt32($0.count)) }
            if rc == kIOReturnSuccess { wrote = true }
        }
        return wrote
    }
}

// MARK: - Keyboard backlight (CoreBrightness, private)

/// MacBook keyboard backlight via CoreBrightness' private `KeyboardBrightnessClient`.
/// Returns nil/false on machines without a backlit keyboard; never traps.
enum KeyboardBacklight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias CopyIDsFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

    private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private static let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")

    private static let lock = NSLock()

    /// (client, keyboard ID), resolved once.
    private static let resolved: (client: NSObject, keyboard: UInt64)? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = cls.init()
        guard client.responds(to: getSel), client.responds(to: setSel) else { return nil }

        var keyboard: UInt64?
        if client.responds(to: idsSel), let imp = client.method(for: idsSel) {
            let fn = unsafeBitCast(imp, to: CopyIDsFn.self)
            // "copy" → +1 retained.
            if let ids = fn(client, idsSel)?.takeRetainedValue() as? [NSNumber] {
                keyboard = ids.first?.uint64Value
            }
        }
        guard let keyboard else { return nil } // no backlit keyboard present
        return (client, keyboard)
    }()

    static var isAvailable: Bool { resolved != nil }

    /// 0...1, or nil if unavailable.
    static func level() -> Float? {
        guard let r = resolved, let imp = r.client.method(for: getSel) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let value = unsafeBitCast(imp, to: GetFn.self)(r.client, getSel, r.keyboard)
        return value.isFinite ? max(0, min(1, value)) : nil
    }

    @discardableResult
    static func setLevel(_ level: Float) -> Bool {
        guard let r = resolved, let imp = r.client.method(for: setSel), level.isFinite else { return false }
        lock.lock(); defer { lock.unlock() }
        return unsafeBitCast(imp, to: SetFn.self)(r.client, setSel, max(0, min(1, level)), r.keyboard)
    }
}
