//
//  TNT go Touchpad — macOS 用户态触摸板驱动(菜单栏 App)
//
//  Smartisan TNT go (deltainno, USB VID 0x31ce / PID 0x5101) 的触摸板
//  是一个 HID 多点触控数字化器(Usage Page 0x0D / Touch Pad,report ID 2),
//  macOS 不会为第三方 digitizer 触摸板创建指针服务,所以原生无法使用。
//
//  本程序直接读取原始多点触控报告并翻译成 CGEvent 鼠标事件:
//    单指移动(带速度加速) / 物理按下点击 / 双指滚动(跟随系统"自然滚动"设置)
//    单指轻点 = 左键,双指轻点 = 右键,两次轻点 = 双击
//    双指捏合 = 缩放(合成原生 magnify 手势)
//    三指轻扫 = 横滑切换桌面 / 上滑调度中心 / 下滑应用曝光(经 System Events 发快捷键)
//  同时兼容设备可能输出的相对鼠标模式(report ID 10)。
//
//  需要辅助功能权限(首次运行时通过菜单引导授权)。
//

import AppKit
import ApplicationServices
import IOKit
import IOKit.hid
import CoreGraphics
import ServiceManagement

// MARK: - 设置(持久化到 UserDefaults,改动即时生效)

final class Settings: NSObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private override init() { super.init() }

    /// 指针速度倍率(0.2 ~ 2.5)
    var moveSpeed: Double {
        get { d.object(forKey: "moveSpeed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "moveSpeed") }
    }
    /// 滚动速度倍率(0.2 ~ 3.0)
    var scrollSpeed: Double {
        get { d.object(forKey: "scrollSpeed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "scrollSpeed") }
    }
    /// 手动反转滚动方向
    var reverseScroll: Bool {
        get { d.bool(forKey: "reverseScroll") }
        set { d.set(newValue, forKey: "reverseScroll") }
    }
    /// 轻点点击
    var tapEnabled: Bool {
        get { d.object(forKey: "tapEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "tapEnabled") }
    }
    /// 系统自然滚动方向
    var naturalScroll: Bool {
        d.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }
    func reset() {
        for k in ["moveSpeed", "scrollSpeed", "reverseScroll", "tapEnabled"] { d.removeObject(forKey: k) }
    }
}

private let kMoveBaseGain = 0.55     // 基础:每触摸板单位对应的像素(乘以 moveSpeed)
private let kMoveAccel = 0.6         // 速度加速系数
private let kScrollBaseGain = 2.2    // 滚动:每单位对应的像素(乘以 scrollSpeed)
private let kTapMaxDuration = 0.18   // 轻点最长按压时间(秒)
private let kTapMaxTravel = 45.0     // 轻点最大位移(触摸板单位)
private let kTwoFingerSettle = 0.05  // 双指状态需持续的稳定时间,过后才开始滚动/捏合
private let kZoomStart = 30.0        // 捏合触发所需的双指间距净变化(触摸板单位,约 1mm)

// IOHID 手势事件相位(kIOHIDEventPhase*,私有头文件,值为逆向确认)
private let kHIDPhaseBegan = 1
private let kHIDPhaseChanged = 2
private let kHIDPhaseEnded = 4

// 三指轻扫通过合成系统默认快捷键实现:⌃←/⌃→ 切桌面、⌃↑ 调度中心、⌃↓ 应用曝光

// MARK: - 每个 HID 接口的上下文

final class DeviceBox {
    let device: IOHIDDevice
    weak var driver: TouchpadDriver?
    let buf: UnsafeMutableRawPointer   // 输入报告缓冲(64 字节)

    init(device: IOHIDDevice, driver: TouchpadDriver) {
        self.device = device
        self.driver = driver
        self.buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    }

    deinit { buf.deallocate() }
}

// MARK: - 驱动核心

final class TouchpadDriver: NSObject {

    let debug: Bool
    private var boxes: [DeviceBox] = []
    private var managers: [IOHIDManager] = []
    private(set) var lastError: String?

    var deviceCount: Int { boxes.count }

    // 手势状态
    struct Contact {
        var x: Double, y: Double        // 当前位置
        var sx: Double, sy: Double      // 起始位置
        var start: Double, last: Double // 起始/最近时间
        var travel: Double              // 累计位移
        var sawButton = false           // 存活期间是否按下过物理按键(用于排除误判轻点)
    }
    private var contacts: [UInt8: Contact] = [:]
    private var moveRef: (x: Double, y: Double)?
    private var scrollRef: (x: Double, y: Double)?
    private var scrollMode = false
    private var scrollTravel: Double = 0
    private var scrollEndGrace: Double = 0   // 滚动结束后的短暂静默,忽略残指微动
    private var pinchRef: Double?                    // 双指间距基准(捏合识别)
    private var lastPinchDist: Double = 0            // 上一帧指距(缩放增量)
    private var pinchTrans: Double = 0               // 基准以来质心累计平移(区分滚动与捏合)
    private var pinchResidual: Double = 0            // 缩放增量余数(慢速捏合不丢动作)
    private var zoomStarted = false
    private var zoomPending = false                  // 捏合触发确认:连续两帧满足条件才真正开始
    private var twoFingerSince: Double?              // 连续双指状态起点(滚动/捏合的起判延时)
    private var swipeBase: (x: Double, y: Double)?   // 三指横滑起点质心
    private var swipeArmed = true                    // 滞回:触发后须移回起点附近才重新武装,一次滑动只切一格
    private var swipeCount = 0                       // 上一帧手指数,变化时作废所有手势基准
    private struct TapCandidate {
        var start: Double, end: Double, travel: Double, sawButton: Bool
    }
    private var tapCandidates: [TapCandidate] = []
    private var buttonDown = false
    private var leftPending = false
    private var mouseButtons: UInt8 = 0
    private var boundsCache: (rect: CGRect, at: Double)?
    private(set) var reportCount = 0

    init(debug: Bool = false) {
        self.debug = debug
        super.init()
    }

    // MARK: HID 管理

    func start() -> Bool {
        // 触摸板(报告 2)、键盘(报告 1)、鼠标模式(报告 10)在同一个复合接口上,
        // 该接口主用途是键盘(UsagePage 0x01 / Usage 0x06),打开它必须持有
        // 「输入监控」权限(TCC ListenEvent,无法绕开)。
        // 只精确匹配这一个接口(排除触摸屏 digitizer 接口和厂商接口,让它们保持原生);
        // 权限的稳定性由 build.sh 用固定开发证书签名保证(重编译后 TCC 授权不再失效)。
        var matchings: [[String: Any]] = [[kIOHIDVendorIDKey: 0x31CE, kIOHIDProductIDKey: 0x5101,
                                           kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06]]
        if ProcessInfo.processInfo.environment["TNTGO_DEBUG_ALL"] != nil {
            // 对照实验:同时匹配罗技 M585,验证报告回调管道是否工作
            matchings.append([kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xB01B])
        }
        for matching in matchings {
            guard startManager(matching: matching) else {
                stop()   // 清理半成品 manager,让 start() 可安全重试
                return false
            }
        }
        lastError = nil
        if debug { NSLog("[tntgo] driver started") }
        return true
    }

    /// 停止驱动,释放全部 HID 资源(用于启动失败后重试)
    func stop() {
        for box in boxes {
            IOHIDDeviceRegisterInputReportCallback(box.device, box.buf.assumingMemoryBound(to: UInt8.self), 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(box.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)
            IOHIDDeviceClose(box.device, IOOptionBits(0))
        }
        boxes.removeAll()
        for mgr in managers {
            IOHIDManagerClose(mgr, IOOptionBits(0))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)
        }
        managers.removeAll()
        contacts.removeAll()
        scrollMode = false
        scrollEndGrace = 0
        pinchRef = nil
        pinchTrans = 0
        pinchResidual = 0
        zoomStarted = false
        zoomPending = false
        twoFingerSince = nil
        swipeBase = nil
        swipeArmed = true
        buttonDown = false
        leftPending = false
    }

    private func startManager(matching: [String: Any]) -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        managers.append(mgr)
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<TouchpadDriver>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<TouchpadDriver>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)

        // 先调度 runloop,再打开(参考 Apple HID 示例代码顺序)。
        // 必须注册到 commonModes:菜单/滑条等 UI 追踪期间 runloop 会切到
        // eventTracking 模式,只注册 defaultMode 的话 HID 回调会停,
        // 表现为"菜单一打开触摸板就死了,只能靠真鼠标"
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)

        let openRes = IOHIDManagerOpen(mgr, IOOptionBits(0))
        guard openRes == kIOReturnSuccess else {
            lastError = "IOHIDManagerOpen 失败: 0x\(String(openRes, radix: 16))"
            return false
        }
        if debug { NSLog("[tntgo] driver started") }
        return true
    }

    private func attach(_ device: IOHIDDevice) {
        guard !boxes.contains(where: { ObjectIdentifier($0.device) == ObjectIdentifier(device) }) else { return }
        let box = DeviceBox(device: device, driver: self)
        boxes.append(box)
        let bctx = Unmanaged.passUnretained(box).toOpaque()

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)

        let openRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if debug {
            NSLog("[tntgo] open device 0x\(String(openRes, radix: 16)) (\(openRes == kIOReturnSuccess ? "ok" : "FAIL"))")
        }
        if openRes != kIOReturnSuccess {
            // 非独占打开失败时,尝试以独占方式打开(系统 hidd 可能已占用)
            let seizeRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if debug {
                NSLog("[tntgo] seize device 0x\(String(seizeRes, radix: 16)) (\(seizeRes == kIOReturnSuccess ? "ok" : "FAIL"))")
            }
        }

        IOHIDDeviceRegisterInputReportCallback(device, box.buf.assumingMemoryBound(to: UInt8.self), 64,
            { ctx, result, _, _, reportID, report, length in
                guard let ctx, length > 0 else { return }
                let box = Unmanaged<DeviceBox>.fromOpaque(ctx).takeUnretainedValue()
                if result != kIOReturnSuccess {
                    NSLog("[tntgo] report callback error 0x\(String(result, radix: 16))")
                    return
                }
                var data = [UInt8](repeating: 0, count: Int(length))
                for i in 0..<Int(length) { data[i] = report[i] }
                box.driver?.handle(data, reportID: reportID)
            }, bctx)

        if debug { NSLog("[tntgo] HID interface attached (total \(boxes.count))") }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let idx = boxes.firstIndex(where: { ObjectIdentifier($0.device) == ObjectIdentifier(device) }) else { return }
        let box = boxes.remove(at: idx)
        IOHIDDeviceRegisterInputReportCallback(device, box.buf.assumingMemoryBound(to: UInt8.self), 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue as CFString)
        contacts.removeAll()
        scrollMode = false
        scrollEndGrace = 0
        pinchRef = nil
        pinchTrans = 0
        pinchResidual = 0
        zoomStarted = false
        zoomPending = false
        twoFingerSince = nil
        swipeBase = nil
        swipeArmed = true
        buttonDown = false
        leftPending = false
        if debug { NSLog("[tntgo] HID interface detached (total \(boxes.count))") }
    }

    // MARK: 报告分发

    func handle(_ data: [UInt8], reportID: UInt32) {
        reportCount += 1
        if debug {
            let hex = data.map { String(format: "%02x", $0) }.joined()
            NSLog("[tntgo] report id=\(reportID) len=\(data.count): \(hex)")
        }

        var id = Int(reportID)
        var payload = data
        if id == 0, let f = data.first, f != 0 {
            id = Int(f)
        }
        if id != 0 {
            // IOKit 的报告缓冲可能带也可能不带 report ID 字节,按已知长度判断
            let firstIsID = Int(data.first ?? 0) == id
            let withID: [Int: Int] = [2: 8, 10: 5]
            let withoutID: [Int: Int] = [2: 7, 10: 4]
            if firstIsID, withID[id] == data.count {
                payload = Array(data.dropFirst())
            } else if withoutID[id] != data.count, firstIsID {
                payload = Array(data.dropFirst())
            }
        }

        switch id {
        case 2:
            guard payload.count >= 7 else { return }
            touchpad(payload)
        case 10:
            guard payload.count >= 4 else { return }
            mouseReport(payload)
        default:
            break
        }
    }

    // MARK: 触摸板(多点触控 digitizer,report 2)
    //
    // 布局(HID 小端位打包):
    //   byte0: bit0=Confidence bit1=TipSwitch bit4-7=ContactID
    //   byte1-2: X 12bit | byte2-3: Y 12bit
    //   byte3-4(即第4/5字节): ScanTime 16bit
    //   byte6: bit0-3=ContactCount bit7=物理按键
    private func touchpad(_ p: [UInt8]) {
        let tip = (p[0] & 0x02) != 0
        let conf = (p[0] & 0x01) != 0
        let cid = p[0] >> 4
        let x = Double(UInt16(p[1]) | (UInt16(p[2] & 0x0F) << 8))
        let y = Double(UInt16(p[2] >> 4) | (UInt16(p[3]) << 4))
        let count = Int(p[6] & 0x0F)
        let button = (p[6] & 0x80) != 0
        let now = ProcessInfo.processInfo.systemUptime

        if debug {
            NSLog("[tntgo] tp id=\(cid) tip=\(tip ? 1 : 0) conf=\(conf ? 1 : 0) x=\((x)) y=\(y) n=\(count) btn=\(button ? 1 : 0)")
        }

        var moved = false
        var moveDt = 0.001

        if tip {
            if var c = contacts[cid] {
                moveDt = max(now - c.last, 0.001)
                c.travel = max(c.travel, hypot(x - c.sx, y - c.sy))
                if button || buttonDown { c.sawButton = true }
                c.x = x; c.y = y
                c.last = now
                contacts[cid] = c
                moved = true
            } else {
                contacts[cid] = Contact(x: x, y: y, sx: x, sy: y, start: now, last: now, travel: 0, sawButton: button)
                moveRef = nil
            }
        } else if let c = contacts.removeValue(forKey: cid) {
            tapCandidates.append(TapCandidate(start: c.start, end: now, travel: c.travel, sawButton: c.sawButton))
        }

        // 串行协议可能不发 tip=0 的收尾报告,按超时清理
        let staleKeys = contacts.filter { now - $0.value.last > 0.08 }.map(\.key)
        for k in staleKeys {
            if let c = contacts.removeValue(forKey: k) {
                tapCandidates.append(TapCandidate(start: c.start, end: now, travel: c.travel, sawButton: c.sawButton))
            }
        }

        let active = contacts.count

        // 模式切换只看真实存活的接触点:count 字节在按压物理按键时可能
        // 毛刺(瞬间报 2),拿它当依据会让拖拽期间的移动被当滚动吞掉
        if active >= 2, !scrollMode {
            scrollMode = true
            scrollTravel = 0
            scrollRef = nil
            moveRef = nil
            pinchRef = nil
            swipeBase = nil
            twoFingerSince = nil
            zoomPending = false
        }
        if scrollMode, active <= 1 {
            scrollMode = false
            scrollRef = nil
            moveRef = nil
            scrollEndGrace = now + 0.15
            if zoomStarted {
                postZoom(0, phase: kHIDPhaseEnded)
                zoomStarted = false
            }
            pinchRef = nil
            swipeBase = nil
            twoFingerSince = nil
            zoomPending = false
        }
        if active == 0 {
            evaluateTaps(now: now)
        }

        // 物理按键边沿
        if button != buttonDown {
            buttonDown = button
            if button {
                if active >= 2 {
                    postClick(right: true)          // 双指 + 按下 = 右键
                } else {
                    postLeft(down: true)
                    leftPending = true
                }
            } else if leftPending {
                postLeft(down: false)
                leftPending = false
            }
        }

        // 移动 / 滚动 / 缩放 / 三指轻扫
        if scrollMode {
            if contacts.count != swipeCount {
                swipeCount = contacts.count
                scrollRef = nil             // 手指数变化瞬间质心/间距会跳,基准全部作废
                pinchRef = nil
                swipeBase = nil
                twoFingerSince = nil
                zoomPending = false
                pinchResidual = 0
            }
            let n = Double(contacts.count)
            let cx = contacts.values.reduce(0.0) { $0 + $1.x } / n
            let cy = contacts.values.reduce(0.0) { $0 + $1.y } / n
            if contacts.count == 2 {
                // 双指:滚动(质心位移)+ 捏合缩放(间距变化)。
                // 起滚/起捏都要求双指状态已持续片刻:三指手势落指/抬指时会短暂
                // 经过双指状态,立刻起滚会把三指轻扫误判成滚动
                if twoFingerSince == nil { twoFingerSince = now }
                let settled = now - twoFingerSince! >= kTwoFingerSettle
                var ddx = 0.0, ddy = 0.0
                if let ref = scrollRef {
                    ddx = cx - ref.x
                    ddy = cy - ref.y
                }
                scrollRef = (cx, cy)

                // 捏合识别:指距相对基准的"净变化"要够大,且径向变化须主导
                // 质心平移 —— 纯滚动时两指不完全平行的指距漂移既不够大也不占
                // 主导,不会累积成缩放;触发还需连续两帧满足,挡住抬指瞬间跳变
                let pts = Array(contacts.values)
                let dist = hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
                if let ref = pinchRef {
                    pinchTrans += hypot(ddx, ddy)
                    let radial = dist - ref
                    let dd = dist - lastPinchDist
                    if zoomStarted {
                        pinchResidual += dd
                        if abs(pinchResidual) > 0.4 {
                            scrollTravel += abs(pinchResidual)
                            postZoom(pinchResidual / max(lastPinchDist, 1), phase: kHIDPhaseChanged)
                            pinchResidual = 0
                        }
                    } else {
                        scrollTravel += abs(dd)   // 有过指距变化就不误判成轻点
                        if settled, dist > 30, abs(radial) > kZoomStart, abs(radial) > pinchTrans * 0.5 {
                            if zoomPending {
                                postZoom(0, phase: kHIDPhaseBegan)
                                zoomStarted = true
                                zoomPending = false
                            } else {
                                zoomPending = true   // 第一帧只登记,下一帧仍满足才触发
                            }
                        } else {
                            zoomPending = false
                            if pinchTrans > 120, abs(radial) < pinchTrans * 0.4 {
                                // 平移主导 = 纯滚动:重置捏合基准,
                                // 滚动一段时间后接着捏合仍然能触发
                                pinchRef = dist
                                pinchTrans = 0
                            }
                        }
                    }
                    lastPinchDist = dist
                } else {
                    pinchRef = dist
                    lastPinchDist = dist
                    pinchTrans = 0
                }

                if settled {
                    scrollTravel += hypot(ddx, ddy)
                    postScroll(dx: ddx, dy: ddy)
                }
            } else {
                twoFingerSince = nil
                // 三指及以上轻扫,与原生触摸板一致;此时不滚动:
                //   左右滑 = 切换桌面(⌃←/⌃→)  上滑 = 调度中心(⌃↑)  下滑 = 应用曝光(⌃↓)
                if let base = swipeBase {
                    let dx = cx - base.x, dy = cy - base.y
                    let horiz = abs(dx) > 180 && abs(dx) > abs(dy) * 1.5
                    let vert = abs(dy) > 180 && abs(dy) > abs(dx) * 1.5
                    if swipeArmed, horiz || vert {
                        if vert { postHotkey(dy < 0 ? 126 : 125) }
                        else { postSpaceSwitch(left: dx < 0) }
                        swipeArmed = false
                    } else if !swipeArmed, abs(dx) < 60, abs(dy) < 60 {
                        swipeArmed = true   // 移回起点附近可再次触发(不必抬手)
                    }
                } else {
                    swipeBase = (cx, cy)
                    swipeArmed = true
                }
            }
        } else if active == 1, moved, now > scrollEndGrace, let c = contacts[cid] {
            if let ref = moveRef {
                postMove(dx: c.x - ref.x, dy: c.y - ref.y, dt: moveDt)
            }
            moveRef = (c.x, c.y)
        }
    }

    // MARK: 轻点判定(全部手指抬起时)

    private func evaluateTaps(now: Double) {
        tapCandidates.removeAll { now - $0.end > 0.3 }
        guard !tapCandidates.isEmpty else {
            scrollTravel = 0
            return
        }
        let taps = tapCandidates
        tapCandidates.removeAll()
        defer { scrollTravel = 0 }

        guard Settings.shared.tapEnabled, !buttonDown, scrollTravel < 25 else { return }
        let good = taps.filter { !$0.sawButton && ($0.end - $0.start) < kTapMaxDuration && $0.travel < kTapMaxTravel }
        if good.count == 1 {
            postClick(right: false)
        } else if good.count == 2 {
            let overlap = max(good[0].start, good[1].start) < min(good[0].end, good[1].end) + 0.05
            if overlap {
                postClick(right: true)             // 双指轻点 = 右键
            } else {
                postClick(right: false)            // 先后两次轻点 = 双击
                postClick(right: false)
            }
        }
    }

    // MARK: 兼容相对鼠标模式(report 10)

    private func mouseReport(_ p: [UInt8]) {
        let buttons = p[0] & 0x07
        let dx = Double(Int8(bitPattern: p[1]))
        let dy = Double(Int8(bitPattern: p[2]))
        let wheel = Int8(bitPattern: p[3])
        if debug {
            NSLog("[tntgo] mouse dx=\(dx) dy=\(dy) wheel=\(wheel) buttons=\(buttons)")
        }
        if dx != 0 || dy != 0 {
            var loc = cursorLocation()
            loc.x += dx
            loc.y += dy
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: loc, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        if wheel != 0 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                    wheel1: Int32(wheel) * 3, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
        }
        for i in 0..<3 {
            let mask = UInt8(1 << i)
            let was = mouseButtons & mask != 0
            let pressed = buttons & mask != 0
            if pressed != was {
                let loc = cursorLocation()
                switch i {
                case 0:
                    CGEvent(mouseEventSource: nil, mouseType: pressed ? .leftMouseDown : .leftMouseUp,
                            mouseCursorPosition: loc, mouseButton: .left)?.post(tap: .cghidEventTap)
                case 1:
                    CGEvent(mouseEventSource: nil, mouseType: pressed ? .rightMouseDown : .rightMouseUp,
                            mouseCursorPosition: loc, mouseButton: .right)?.post(tap: .cghidEventTap)
                default:
                    CGEvent(mouseEventSource: nil, mouseType: pressed ? .otherMouseDown : .otherMouseUp,
                            mouseCursorPosition: loc, mouseButton: .center)?.post(tap: .cghidEventTap)
                }
            }
        }
        mouseButtons = buttons
    }

    // MARK: CGEvent 辅助

    private func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func displayBounds() -> CGRect {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = boundsCache, now - c.at < 5 { return c.rect }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        var rect = CGRect.null
        if CGGetActiveDisplayList(16, &ids, &n) == .success {
            for i in 0..<Int(n) { rect = rect.union(CGDisplayBounds(ids[i])) }
        }
        if rect.isNull || rect.isEmpty { rect = CGDisplayBounds(CGMainDisplayID()) }
        boundsCache = (rect, now)
        return rect
    }

    private func postMove(dx: Double, dy: Double, dt: Double) {
        let dist = hypot(dx, dy)
        guard dist > 0.05 else { return }
        let speed = dist / max(dt, 0.001)                    // 单位/秒
        // 按住拖拽时不加速,指针 1:1 跟随手指(与原生触摸板一致)
        let boost = buttonDown ? 1.0 : 1 + kMoveAccel * min(speed / 800, 3)
        let gain = kMoveBaseGain * Settings.shared.moveSpeed
        var loc = cursorLocation()
        loc.x += dx * gain * boost
        loc.y += dy * gain * boost
        let b = displayBounds()
        loc.x = min(max(loc.x, b.minX + 1), b.maxX - 1)
        loc.y = min(max(loc.y, b.minY + 1), b.maxY - 1)
        if debug { NSLog("[tntgo] move dx=\(dx) dy=\(dy) drag=\(buttonDown ? 1 : 0) loc=\(loc.x),\(loc.y)") }
        // 按住拖拽时必须发 leftMouseDragged:新版 macOS 不会把合成事件里的
        // mouseMoved 自动转译成拖拽,发 mouseMoved 会导致窗口不跟手、
        // 松开时才跳到终点
        let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double) {
        if debug { NSLog("[tntgo] scroll dx=\(dx) dy=\(dy)") }
        // 实测该触摸板 Y 轴方向与常规 HID 相反,此处已翻正;
        // 用户还可用「反转滚动方向」再翻一次
        let natural = Settings.shared.naturalScroll != Settings.shared.reverseScroll
        let sign: Double = natural ? 1 : -1
        let gain = kScrollBaseGain * Settings.shared.scrollSpeed
        let vy = dy * gain * sign
        let vx = dx * gain * sign
        let iy = Int32(vy.rounded()), ix = Int32(vx.rounded())
        guard iy != 0 || ix != 0 else { return }
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: iy, wheel2: ix, wheel3: 0) {
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            ev.post(tap: .cghidEventTap)
        }
    }

    /// 合成原生 magnify(捏合缩放)手势。方案同 mac-mouse-fix(源自
    /// CalfTrail 逆向):在 type=29(gesture)的事件上设置私有 IOHID 字段
    ///   110 = 子类型(8 = Zoom)  113 = 缩放增量  132 = 相位
    private func postZoom(_ mag: Double, phase: Int) {
        if debug { NSLog("[tntgo] zoom mag=\(String(format: "%.4f", mag)) phase=\(phase)") }
        guard let ev = CGEvent(source: nil) else { return }
        ev.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        ev.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase))
        ev.setDoubleValueField(CGEventField(rawValue: 113)!, value: mag)
        ev.post(tap: .cghidEventTap)
    }

    /// 三指横滑 → 切换桌面:合成系统默认快捷键 ⌃←/⌃→(纯公开 API)。
    /// 原生手势通道是私有接口且各版本行为不稳,快捷键方案最可靠。
    private func postSpaceSwitch(left: Bool) {
        postHotkey(left ? 123 : 124)   // ⌃← / ⌃→
    }

    /// 发送带 ⌃ 修饰键的按键(调度中心/应用曝光/切桌面等系统快捷键)。
    /// 必须经 System Events(AppleScript)转发:新版 macOS(macOS 26 实测)对普通
    /// 进程直接 CGEventPost 的键盘事件不再触发系统快捷键 —— 事件带修饰键正常
    /// 进入会话事件流,但 Dock 不认领;System Events 的特权通道仍然有效。
    /// AppleScript 失败时退回直接 CGEventPost(旧系统上这条路是好使的)。
    private func postHotkey(_ key: CGKeyCode) {
        let names = [123: "⌃←", 124: "⌃→", 125: "⌃↓", 126: "⌃↑"]
        if debug { NSLog("[tntgo] hotkey \(names[Int(key)] ?? "\(key)")") }
        let script = NSAppleScript(source: "tell application \"System Events\" to key code \(key) using control down")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err {
            if debug { NSLog("[tntgo] applescript error: \(err),退回 CGEvent 直发") }
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                if let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
                    ev.flags = .maskControl
                    ev.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private func postLeft(down: Bool) {
        if debug { NSLog("[tntgo] left button down=\(down)") }
        let loc = cursorLocation()
        CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: loc, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func postClick(right: Bool) {
        if debug { NSLog("[tntgo] click right=\(right)") }
        let loc = cursorLocation()
        let button: CGMouseButton = right ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown,
                mouseCursorPosition: loc, mouseButton: button)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp,
                mouseCursorPosition: loc, mouseButton: button)?.post(tap: .cghidEventTap)
    }
}

// MARK: - 菜单栏界面

final class AppDelegate: NSObject, NSApplicationDelegate {

    var driver: TouchpadDriver!
    var statusItem: NSStatusItem!
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        driver = TouchpadDriver(debug: ProcessInfo.processInfo.environment["TNTGO_DEBUG"] != nil)
        if !driver.start() {
            // 不退出:设备可能尚未就绪,留在菜单栏自动重试
            NSLog("[tntgo] start failed: \(driver.lastError ?? "未知错误"),将自动重试")
            startRetryTimer()
        }

        // 诊断日志:权限状态 + 定期报告接收计数
        if driver.debug {
            NSLog("[tntgo] AX trusted: \(AXIsProcessTrusted())")
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                NSLog("[tntgo] status devices=\(self.driver.deviceCount) reports=\(self.driver.reportCount)")
            }
        }

        // 未授权时弹系统提示,把本应用预填到辅助功能列表,用户只需打开开关
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "trackpad", accessibilityDescription: "TNT go Touchpad") {
                button.image = img
            } else {
                button.title = "TP"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let connected = driver.deviceCount > 0
        let item = NSMenuItem(title: "TNT go 触摸板:" + (connected ? "已连接" : "未连接"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)

        if !connected, let err = driver.lastError {
            let errItem = NSMenuItem(title: "错误:" + err + "(重试中…)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }

        let trusted = AXIsProcessTrusted()
        let perm = NSMenuItem(title: "辅助功能权限:" + (trusted ? "已授予" : "未授予"), action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        if !trusted {
            let grant = NSMenuItem(title: "去系统设置授权…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())

        // --- 设置 ---
        let s = Settings.shared

        let moveTitle = NSMenuItem(title: "指针速度", action: nil, keyEquivalent: "")
        moveTitle.isEnabled = false
        menu.addItem(moveTitle)
        menu.addItem(sliderItem(value: s.moveSpeed, min: 0.2, max: 2.5,
                                action: #selector(moveSpeedChanged(_:))))

        let scrollTitle = NSMenuItem(title: "滚动速度", action: nil, keyEquivalent: "")
        scrollTitle.isEnabled = false
        menu.addItem(scrollTitle)
        menu.addItem(sliderItem(value: s.scrollSpeed, min: 0.2, max: 3.0,
                                action: #selector(scrollSpeedChanged(_:))))

        let reverse = NSMenuItem(title: "反转滚动方向", action: #selector(toggleReverseScroll), keyEquivalent: "")
        reverse.target = self
        reverse.state = s.reverseScroll ? .on : .off
        menu.addItem(reverse)

        let tap = NSMenuItem(title: "轻点点击", action: #selector(toggleTap), keyEquivalent: "")
        tap.target = self
        tap.state = s.tapEnabled ? .on : .off
        menu.addItem(tap)

        let reset = NSMenuItem(title: "重置设置", action: #selector(resetSettings), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.addItem(.separator())
        let uninstall = NSMenuItem(title: "卸载并移到废纸篓…", action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
    }

    /// 一键卸载:注销登录项 → 清理 TCC 辅助功能授权记录 → 把 .app 移到废纸篓
    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "卸载 TNT go Touchpad?"
        alert.informativeText = "将注销登录项、清理辅助功能与输入监控的权限记录、删除开发签名证书,并把应用移到废纸篓,系统无残留。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 1. 注销登录项
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }

        // 2. 清理本应用在 TCC 数据库中的授权记录(辅助功能 + 输入监控)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tntgo.touchpad"
        for service in ["Accessibility", "ListenEvent"] {
            let tcc = Process()
            tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tcc.arguments = ["reset", service, bundleID]
            try? tcc.run()
            tcc.waitUntilExit()
        }

        // 3. 删除构建用的开发签名证书(登录钥匙串,不存在时忽略)
        let sec = Process()
        sec.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        sec.arguments = ["delete-identity", "-c", "TNTgo Touchpad Dev"]
        try? sec.run()
        sec.waitUntilExit()

        // 4. 把 .app 移到废纸篓(废纸篓未清空前可随时恢复)
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundleURL]) { _, _ in }
        NSApp.terminate(nil)
    }

    // MARK: 设置界面

    private func sliderItem(value: Double, min: Double, max: Double, action: Selector) -> NSMenuItem {
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 220, height: 20)
        let item = NSMenuItem()
        item.view = slider
        return item
    }

    @objc private func moveSpeedChanged(_ sender: NSSlider) {
        Settings.shared.moveSpeed = sender.doubleValue
    }

    @objc private func scrollSpeedChanged(_ sender: NSSlider) {
        Settings.shared.scrollSpeed = sender.doubleValue
    }

    @objc private func toggleReverseScroll() {
        Settings.shared.reverseScroll.toggle()
        if let menu = statusItem.menu { rebuildMenu(menu) }
    }

    @objc private func toggleTap() {
        Settings.shared.tapEnabled.toggle()
        if let menu = statusItem.menu { rebuildMenu(menu) }
    }

    @objc private func resetSettings() {
        Settings.shared.reset()
        if let menu = statusItem.menu { rebuildMenu(menu) }
    }

    /// 启动失败时每 5 秒重试,直到成功(设备可能稍后才就绪)
    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.driver.start() else { return }
            self.retryTimer?.invalidate()
            self.retryTimer = nil
            NSLog("[tntgo] retry start succeeded")
        }
    }

    @objc private func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for s in urls {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[tntgo] login item error: \(error.localizedDescription)")
        }
        if let menu = statusItem.menu { rebuildMenu(menu) }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 无 Dock 图标,仅菜单栏
app.run()
