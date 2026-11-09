import Cocoa
import SwiftUI
import ServiceManagement

// MARK: - Config (change with `defaults write com.omshah.DesktopLyrics <key> ...`)

let defs = UserDefaults.standard
let cfgMargin   = CGFloat(defs.object(forKey: "margin") as? Double ?? 70)
let cfgFontSize = CGFloat(defs.object(forKey: "fontSize") as? Double ?? 36)
let cfgWidth    = CGFloat(defs.object(forKey: "width") as? Double ?? 900)
var cfgOffset   = defs.object(forKey: "offset") as? Double ?? 0.25    // seconds to show lines early (right-click → Lyrics Timing)

let smallScale: CGFloat = 0.5
let spacing = cfgFontSize * 0.3
let bigRow = cfgFontSize * 1.3
let smallRow = cfgFontSize * smallScale * 1.3
let windowHeight = bigRow + smallRow * 3 + spacing * 3 + 20
let playerH = cfgFontSize * 1.2                        // mini "now playing" row under the lyrics
let playerGap = cfgFontSize * 0.9                      // breathing room between the lyrics and the player
let totalHeight = windowHeight + playerGap + playerH

// MARK: - Model

struct LyricLine { let time: Double; let text: String }

enum LyricsResult { case synced([LyricLine]), instrumental, none }

enum Status { case loading, lyrics, instrumental, noLyrics }

final class Model: ObservableObject {
    @Published var lines: [LyricLine] = []
    @Published var index = -1
    @Published var visible = false
    @Published var darkText = false
    @Published var fontFamily = cfgFont
    @Published var alignRight = false
    @Published var status: Status = .loading
    @Published var title = ""
    @Published var artist = ""
    @Published var trackKey = ""
    @Published var art: NSImage?
    @Published var running = false      // Spotify has a track loaded (playing or paused)
    @Published var playing = false
    var posBase = 0.0, posAt = Date()   // playback position at last poll, spins the vinyl
    var scrubbing = false
}

enum Control { case previous, playPause, next }
var onControl: ((Control) -> Void)?

/// Areas (in hosting-view coordinates) that are clickable buttons instead of drag handles.
var noDragRects: [CGRect] = []
struct NoDragKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

// MARK: - View

struct Slot: Identifiable { let id: String; let text: String; let off: Int }

/// Full-size height of `text` when wrapped to `width` in the heavy weight (the widest one), cached per line.
/// Long lines wrap onto more rows instead of shrinking, so every lyric keeps the same font size.
// MARK: Font family (right-click → Font). "rounded" / "system" / "serif" / "mono" are the built-in system designs,
// anything else is an installed font family name.

var cfgFont = defs.string(forKey: "fontFamily") ?? "rounded"

func lyricFont(_ size: CGFloat, _ weight: Font.Weight) -> Font {
    switch cfgFont {
    case "rounded": .system(size: size, weight: weight, design: .rounded)
    case "system":  .system(size: size, weight: weight, design: .default)
    case "serif":   .system(size: size, weight: weight, design: .serif)
    case "mono":    .system(size: size, weight: weight, design: .monospaced)
    default:        Font(lyricNSFont(size, nsWeight(weight)) as CTFont)
    }
}

func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
    switch w {
    case .ultraLight: .ultraLight; case .thin: .thin; case .light: .light; case .medium: .medium
    case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy; case .black: .black; default: .regular
    }
}

/// AppKit twin of `lyricFont`, used to measure how lines wrap.
func lyricNSFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let sys = NSFont.systemFont(ofSize: size, weight: weight)
    let design: NSFontDescriptor.SystemDesign? = switch cfgFont {
        case "rounded": .rounded; case "system": .default; case "serif": .serif; case "mono": .monospaced; default: nil
    }
    if let design {
        return sys.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? sys
    }
    // Variable fonts (like the bundled Manrope) also get the weight set on their 'wght' axis.
    let css: Double = switch weight {
        case .ultraLight: 200; case .thin: 100; case .light: 300; case .medium: 500; case .semibold: 600
        case .bold: 700; case .heavy: 800; case .black: 900; default: 400
    }
    let d = NSFontDescriptor(fontAttributes: [.family: cfgFont,
                                              .traits: [NSFontDescriptor.TraitKey.weight: weight],
                                              .variation: [NSNumber(value: 0x77676874): css]])
    return NSFont(descriptor: d, size: size) ?? sys
}

var heightCache: [String: CGFloat] = [:]
func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
    if let v = heightCache[text] { return v }
    let font = lyricNSFont(cfgFontSize, .heavy)
    let one = ("Ag" as NSString).size(withAttributes: [.font: font]).height
    let h = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: [.font: font]).height
    let rows = max(1, (h / one).rounded())
    let v = bigRow + (rows - 1) * one                  // one row = the usual bigRow, each extra wrapped row adds a line
    heightCache[text] = v
    return v
}

struct LineText: View {
    let text: String, current: Bool, right: Bool, fg: Color, shadow: Color, width: CGFloat, font: String
    var body: some View {
        // Two weights stacked and cross-faded so the bold/regular change animates smoothly.
        // Both wrap at the full width; the frame height comes from the (widest) heavy weight.
        // Keyed by font family so switching fonts cross-fades every line, current or not.
        ZStack(alignment: right ? .topTrailing : .topLeading) {
            ZStack(alignment: right ? .topTrailing : .topLeading) {
                Text(text).font(lyricFont(cfgFontSize, .heavy))
                    .opacity(current ? 1 : 0)
                Text(text).font(lyricFont(cfgFontSize, .medium))
                    .opacity(current ? 0 : 1)
            }
            .id(font)
            .transition(.opacity)
        }
        .multilineTextAlignment(right ? .trailing : .leading)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width - 4, alignment: right ? .topTrailing : .topLeading)
        .foregroundColor(fg)
        .shadow(color: shadow, radius: current ? 8 : 5, x: 0, y: 1)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.01))   // invisible, but makes the whole text line grabbable
    }
}

struct LyricsView: View {
    @ObservedObject var m: Model
    let innerW = cfgWidth - 20

    var slots: [Slot] {
        var texts: [(String, String)] = []
        var idx = 0
        if m.status == .lyrics {
            // Song title sits before the first lyric, so it's shown until the first line starts, then scrolls up.
            texts = [("\(m.trackKey)#title", m.title)]
                + m.lines.enumerated().map { ("\(m.trackKey)#\($0.offset)", $0.element.text.isEmpty ? "♪" : $0.element.text) }
            idx = m.index + 1
        } else {
            texts = [("\(m.trackKey)#title", m.title), ("\(m.trackKey)#artist", m.artist)]
            let s = m.status == .instrumental ? "♪ instrumental" : m.status == .noLyrics ? "no synced lyrics" : ""
            if !s.isEmpty { texts.append(("\(m.trackKey)#status", s)) }
        }
        // Keep a couple of off-screen lines mounted so they glide in/out instead of popping.
        let lo = max(0, idx - 3), hi = min(texts.count - 1, idx + 4)
        guard lo <= hi else { return [] }
        return (lo...hi).map { Slot(id: texts[$0].0, text: texts[$0].1, off: $0 - idx) }
    }

    /// Top y of every slot. The current line stays put; earlier lines stack upward from it, later ones downward,
    /// each taking as many rows as it wraps to (small lines are the full-size layout scaled by `smallScale`).
    func layout(_ slots: [Slot]) -> [String: CGFloat] {
        var ys: [String: CGFloat] = [:]
        let h = { (s: Slot) in wrappedHeight(s.text, width: innerW - 4) }
        let curY = smallRow + spacing
        var y = curY
        for s in slots.filter({ $0.off < 0 }).sorted(by: { $0.off > $1.off }) {
            y -= spacing + h(s) * smallScale
            ys[s.id] = y
        }
        y = curY
        for s in slots.filter({ $0.off >= 0 }).sorted(by: { $0.off < $1.off }) {
            ys[s.id] = y
            y += h(s) * (s.off == 0 ? 1 : smallScale) + spacing
        }
        return ys
    }

    func alpha(_ s: Slot, y: CGFloat) -> Double {
        let base: Double = switch s.off { case -1: 0.35; case 0: 1; case 1: 0.6; case 2: 0.35; default: 0 }
        // Neighbours that no longer fit in the box (because a line wrapped) fade out instead of overlapping.
        let bottom = y + wrappedHeight(s.text, width: innerW - 4) * (s.off == 0 ? 1 : smallScale)
        return s.off != 0 && (y < -1 || bottom > windowHeight - 20 + 1) ? 0 : base
    }

    var body: some View {
        let fg: Color = m.darkText ? .black : .white
        let shadow: Color = m.darkText ? .white.opacity(0.35) : .black.opacity(0.5)
        let corner: UnitPoint = m.alignRight ? .topTrailing : .topLeading
        let hAlign: Alignment = m.alignRight ? .trailing : .leading

        VStack(alignment: m.alignRight ? .trailing : .leading, spacing: playerGap) {
            let slots = self.slots
            let ys = layout(slots)
            ZStack(alignment: m.alignRight ? .topTrailing : .topLeading) {
                ForEach(slots) { s in
                    let cur = s.off == 0
                    let y = ys[s.id] ?? 0
                    LineText(text: s.text, current: cur, right: m.alignRight, fg: fg, shadow: shadow, width: innerW, font: m.fontFamily)
                        .frame(width: innerW, height: wrappedHeight(s.text, width: innerW - 4),
                               alignment: m.alignRight ? .topTrailing : .topLeading)
                        .scaleEffect(cur ? 1 : smallScale, anchor: corner)
                        .offset(y: y)
                        .opacity(alpha(s, y: y))
                        .transition(.opacity)
                }
            }
            .frame(width: innerW, height: windowHeight - 20, alignment: m.alignRight ? .topTrailing : .topLeading)
            .opacity(m.visible ? 1 : 0)

            // Stays up while paused so the play button is still reachable.
            NowPlaying(m: m, fg: fg, shadow: shadow)
                .frame(width: innerW, height: playerH, alignment: hAlign)
                .opacity(m.running && !m.title.isEmpty ? 1 : 0)
        }
        .padding(10)
        .onPreferenceChange(NoDragKey.self) { noDragRects = $0 }
        .animation(.easeInOut(duration: 0.6), value: m.running)
        .animation(m.scrubbing ? .spring(response: 0.28, dampingFraction: 1) : .spring(response: 0.55, dampingFraction: 1), value: m.index)
        .animation(.easeInOut(duration: 0.5), value: m.trackKey)
        .animation(.easeInOut(duration: 0.5), value: m.status)
        .animation(.easeInOut(duration: 0.6), value: m.visible)
        .animation(.easeInOut(duration: 0.6), value: m.darkText)
        .animation(.easeInOut(duration: 0.5), value: m.fontFamily)   // cross-fade + glide to the new line heights
    }
}

// MARK: - Mini player

struct Vinyl: View {
    @ObservedObject var m: Model
    let d: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !m.playing)) { ctx in
            let pos = m.posBase + (m.playing ? ctx.date.timeIntervalSince(m.posAt) : 0)
            disc.rotationEffect(.degrees(pos * 200))          // 33⅓ rpm, follows seeks/pauses
        }
        .overlay(   // light sheen stays still while the record turns underneath it
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.10), .clear],
                                          center: .center))
                .allowsHitTesting(false)
        )
        .frame(width: d, height: d)
    }

    var disc: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.04)], center: .center,
                                         startRadius: d * 0.2, endRadius: d / 2))
            ForEach(1..<4) { i in    // grooves
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 0.5).padding(d * (0.05 + CGFloat(i) * 0.045))
            }
            Group {
                if let a = m.art { Image(nsImage: a).resizable().scaledToFill() } else { Color(white: 0.35) }
            }
            .frame(width: d * 0.52, height: d * 0.52)
            .clipShape(Circle())
            Circle().fill(Color.black).frame(width: d * 0.07, height: d * 0.07)   // spindle hole
        }
        .frame(width: d, height: d)
    }
}

struct NowPlaying: View {
    @ObservedObject var m: Model
    let fg: Color, shadow: Color

    let titleSize = cfgFontSize * 0.36
    let artistSize = cfgFontSize * 0.29

    func button(_ icon: String, _ c: Control) -> some View {
        Button { onControl?(c) } label: {
            Image(systemName: icon)
                .font(.system(size: titleSize, weight: .semibold))
                .frame(width: titleSize * 1.4, height: titleSize * 1.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        let align: HorizontalAlignment = m.alignRight ? .trailing : .leading
        let info = ZStack(alignment: m.alignRight ? .trailing : .leading) {
            VStack(alignment: align, spacing: 1) {
                Text(m.title).font(lyricFont(titleSize, .semibold))
                Text(m.artist).font(lyricFont(artistSize, .medium)).opacity(0.7)
            }
            .id(m.fontFamily)
            .transition(.opacity)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: cfgFontSize * 6, alignment: m.alignRight ? .trailing : .leading)

        let controls = HStack(spacing: titleSize * 0.2) {
            button("backward.fill", .previous)
            button(m.playing ? "pause.fill" : "play.fill", .playPause)
            button("forward.fill", .next)
        }
        .background(GeometryReader { g in Color.clear.preference(key: NoDragKey.self, value: [g.frame(in: .global)]) })

        let vinyl = Vinyl(m: m, d: playerH)

        HStack(spacing: cfgFontSize * 0.3) {
            if m.alignRight { controls; info; vinyl } else { vinyl; info; controls }
        }
        .foregroundColor(fg)
        .shadow(color: shadow, radius: 4, x: 0, y: 1)
    }
}

// MARK: - Spotify

struct SpotifyState {
    var playing: Bool, id: String, name: String, artist: String, album: String
    var duration: Double, position: Double, art: String
}

let spotifyScript: NSAppleScript = {
    let s = NSAppleScript(source: """
    tell application id "com.spotify.client"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set d to (ASCII character 31)
        set a to ""
        try
            set a to (artwork url of t) as string
        end try
        return s & d & (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as string) & d & ((player position) as string) & d & a
    end tell
    """)!
    var err: NSDictionary?
    s.compileAndReturnError(&err)
    return s
}()

func readSpotify() -> SpotifyState? {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return nil }
    var err: NSDictionary?
    guard let out = spotifyScript.executeAndReturnError(&err).stringValue else { return nil }
    let p = out.components(separatedBy: "\u{1F}")
    guard p.count == 8 else { return nil }
    let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    return SpotifyState(playing: p[0] == "playing", id: p[1], name: p[2], artist: p[3], album: p[4],
                        duration: num(p[5]) / 1000, position: num(p[6]), art: p[7].hasPrefix("http") ? p[7] : "")
}

// MARK: - Lyrics (LRCLIB)

func parseLRC(_ s: String) -> [LyricLine] {
    let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
    var out: [LyricLine] = []
    for raw in s.components(separatedBy: .newlines) {
        let ns = raw as NSString
        let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard let last = ms.last else { continue }
        let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
        for m in ms {
            let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
            out.append(LyricLine(time: mm * 60 + ss, text: text))
        }
    }
    return out.sorted { $0.time < $1.time }
}

func lrclib(_ path: String, _ q: [String: String]) async -> Any? {
    var c = URLComponents(string: "https://lrclib.net/api/" + path)!
    c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
    var req = URLRequest(url: c.url!)
    req.setValue("DesktopLyrics/1.0 (personal desktop widget)", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 10
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func cleanTitle(_ s: String) -> String {
    var t = s
    if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }          // "Song - Remastered 2011"
    if let r = t.range(of: #"\s*[\(\[](feat|with|ft)\.?[^\)\]]*[\)\]]"#, options: [.regularExpression, .caseInsensitive]) {
        t.removeSubrange(r)
    }
    return t.trimmingCharacters(in: .whitespaces)
}

func fetchLyrics(_ s: SpotifyState) async -> LyricsResult {
    var primary: [LyricLine]?
    if let o = await lrclib("get", ["track_name": s.name, "artist_name": s.artist,
                                    "album_name": s.album, "duration": String(Int(s.duration.rounded()))]) as? [String: Any] {
        if let l = o["syncedLyrics"] as? String, !l.isEmpty { primary = parseLRC(l) }
        else if o["instrumental"] as? Bool == true { return .instrumental }
    }
    // Other uploads of the same song (same edit), used to vote on the timing of each line.
    var others: [[LyricLine]] = []
    for title in Set([s.name, cleanTitle(s.name)]) {
        guard let arr = await lrclib("search", ["track_name": title, "artist_name": s.artist]) as? [[String: Any]] else { continue }
        let dur = { (o: [String: Any]) in (o["duration"] as? Double) ?? 0 }
        let near = arr
            .filter { ($0["syncedLyrics"] as? String)?.isEmpty == false && abs(dur($0) - s.duration) < 8 }
            .sorted { abs(dur($0) - s.duration) < abs(dur($1) - s.duration) }
        others += near.compactMap { ($0["syncedLyrics"] as? String).map(parseLRC) }
    }
    guard let base = primary ?? others.first else { return .none }
    return .synced(consensusTiming(base, others))
}

/// Hand-made LRC files are often off by half a second or more on individual lines. When several uploads share the
/// same lines, take the median time per line across them; uploads of a different edit (or badly shifted) are ignored.
func consensusTiming(_ base: [LyricLine], _ others: [[LyricLine]]) -> [LyricLine] {
    let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
    let baseIdx = base.indices.filter { !norm(base[$0].text).isEmpty }
    let baseKey = baseIdx.map { norm(base[$0].text) }
    guard baseIdx.count >= 4 else { return base }
    var times = baseIdx.map { [base[$0].time] }
    var seen = Set<[Double]>()
    for o in others {
        let lines = o.filter { !norm($0.text).isEmpty }
        guard lines.count == baseIdx.count else { continue }
        let same = zip(lines, baseKey).filter { norm($0.0.text) == $0.1 }.count
        guard Double(same) >= Double(lines.count) * 0.8 else { continue }
        let t = lines.map(\.time)
        guard seen.insert(t).inserted, t != times.map({ $0[0] }) else { continue }     // skip exact duplicates
        let diffs = zip(t, times).map { abs($0.0 - $0.1[0]) }.sorted()
        guard diffs[diffs.count / 2] < 1.5, diffs.last! < 6 else { continue }           // different edit / shifted
        for i in times.indices { times[i].append(t[i]) }
    }
    guard times[0].count > 1 else { return base }
    var out = base
    for (k, i) in baseIdx.enumerated() {
        let v = times[k].sorted(), n = v.count
        out[i] = LyricLine(time: n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2, text: base[i].text)
    }
    return out.sorted { $0.time < $1.time }
}

// MARK: - Audio output latency (AirPods etc. play ~150–250 ms behind Spotify's reported position)

private typealias AOGetProp = @convention(c) (UInt32, UnsafeRawPointer, UInt32, UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> Int32
private let aoGet: AOGetProp? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY),
          let f = dlsym(h, "AudioObjectGetPropertyData") else { return nil }
    return unsafeBitCast(f, to: AOGetProp.self)
}()
private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
private func aoProp<T>(_ obj: UInt32, _ sel: String, _ scope: String, _ v: inout T) -> Bool {
    guard let aoGet else { return false }
    var addr: [UInt32] = [fourCC(sel), fourCC(scope), 0]
    var size = UInt32(MemoryLayout<T>.size)
    return addr.withUnsafeBytes { a in withUnsafeMutableBytes(of: &v) { aoGet(obj, a.baseAddress!, 0, nil, &size, $0.baseAddress!) } } == 0
}

/// Seconds between Spotify's playback position and sound reaching your ears on the default output device.
func outputLatency() -> Double {
    var dev: UInt32 = 0, lat: UInt32 = 0, safety: UInt32 = 0, buf: UInt32 = 0, rate: Float64 = 0
    guard aoProp(1, "dOut", "glob", &dev), aoProp(dev, "nsrt", "outp", &rate), rate > 0 else { return 0 }
    _ = aoProp(dev, "ltnc", "outp", &lat); _ = aoProp(dev, "saft", "outp", &safety); _ = aoProp(dev, "fsiz", "outp", &buf)
    return min(0.5, Double(lat + safety + buf) / rate)
}

// MARK: - Wallpaper analysis

/// The wallpaper as it appears on one screen ("Fill Screen" scaling), downsampled to a grid of cells.
final class WallpaperMap {
    let cell: CGFloat = 8
    let w: Int, h: Int
    let frame: NSRect
    private var gray: [Double]            // perceptual brightness 0…1, row 0 = top of screen
    private var iG: [Double], iG2: [Double], iE: [Double]   // integral images: brightness, brightness², edges

    init?(screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        frame = screen.frame
        w = Int(ceil(frame.width / cell)); h = Int(ceil(frame.height / cell))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = max(CGFloat(w) / iw, CGFloat(h) / ih)
        ctx.draw(cg, in: CGRect(x: (CGFloat(w) - iw * s) / 2, y: (CGFloat(h) - ih * s) / 2, width: iw * s, height: ih * s))

        var g = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r: Double = Double(px[i * 4]), gr: Double = Double(px[i * 4 + 1]), b: Double = Double(px[i * 4 + 2])
            g[i] = (0.2126 * r + 0.7152 * gr + 0.0722 * b) / 255
        }
        gray = g
        let W = w + 1
        iG = [Double](repeating: 0, count: W * (h + 1)); iG2 = iG; iE = iG
        for y in 0..<h {
            for x in 0..<w {
                let g = gray[y * w + x]
                let gx = x + 1 < w ? abs(gray[y * w + x + 1] - g) : 0
                let gy = y + 1 < h ? abs(gray[(y + 1) * w + x] - g) : 0
                let a = (y + 1) * W + x + 1, up = y * W + x + 1, left = (y + 1) * W + x, diag = y * W + x
                iG[a]  = g + iG[up] + iG[left] - iG[diag]
                iG2[a] = g * g + iG2[up] + iG2[left] - iG2[diag]
                iE[a]  = gx + gy + iE[up] + iE[left] - iE[diag]
            }
        }
    }

    private func sum(_ t: [Double], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
        let W = w + 1
        return t[y1 * W + x1] - t[y0 * W + x1] - t[y1 * W + x0] + t[y0 * W + x0]
    }

    /// Global screen rect → cell range (x0, y0 from top, x1, y1 exclusive).
    private func cells(_ r: NSRect) -> (Int, Int, Int, Int)? {
        let x0 = max(0, Int((r.minX - frame.minX) / cell)), x1 = min(w, Int(ceil((r.maxX - frame.minX) / cell)))
        let y0 = max(0, Int((frame.maxY - r.maxY) / cell)), y1 = min(h, Int(ceil((frame.maxY - r.minY) / cell)))
        return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
    }

    func meanBrightness(_ r: NSRect) -> Double? {
        guard let (x0, y0, x1, y1) = cells(r) else { return nil }
        return sum(iG, x0, y0, x1, y1) / Double((x1 - x0) * (y1 - y0))
    }

    /// Picks the calmest spot for a box of `size` inside `area`, steering away from `avoid` rects.
    func bestOrigin(size: NSSize, area: NSRect, avoid: [NSRect]) -> NSPoint {
        var best = NSPoint(x: area.minX, y: area.minY), bestScore = Double.infinity
        let step = cell * 2
        var x = area.minX
        while x + size.width <= area.maxX {
            var y = area.minY
            while y + size.height <= area.maxY {
                let r = NSRect(x: x, y: y, width: size.width, height: size.height)
                if let (x0, y0, x1, y1) = cells(r) {
                    let n = Double((x1 - x0) * (y1 - y0))
                    let mean = sum(iG, x0, y0, x1, y1) / n
                    let std = sqrt(max(0, sum(iG2, x0, y0, x1, y1) / n - mean * mean))
                    let edges = sum(iE, x0, y0, x1, y1) / n
                    let midGray = max(0, 0.3 - abs(mean - 0.62))            // hard to read with black OR white
                    let overlap = avoid.reduce(0.0) { acc, a in
                        let i = a.intersection(r); return acc + (i.isNull ? 0 : Double(i.width * i.height / (r.width * r.height)))
                    }
                    let dx = (r.midX - frame.midX) / (frame.width / 2), dy = (r.midY - frame.midY) / (frame.height / 2)
                    let centerBias = 0.03 * (1 - min(1, Double(sqrt(dx * dx + dy * dy))))   // tie-break: subjects tend to be centered
                    let score = edges * 4 + std * 2 + midGray + overlap * 2 + centerBias
                    if score < bestScore { bestScore = score; best = r.origin }
                }
                y += step
            }
            x += step
        }
        return best
    }
}

/// Rough area occupied by Finder desktop icons (right-hand columns), so we don't sit under them.
func desktopIconArea(_ vf: NSRect) -> NSRect? {
    if (UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool) == false { return nil }
    let items = ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Desktop")) ?? [])
        .filter { !$0.hasPrefix(".") }
    guard !items.isEmpty else { return nil }
    let perCol = max(1, Int(vf.height / 100))
    let cols = min(4, (items.count + perCol - 1) / perCol)
    return NSRect(x: vf.maxX - CGFloat(cols) * 110, y: vf.minY, width: CGFloat(cols) * 110, height: vf.height)
}

// MARK: - Draggable host

var onDoubleClick: (() -> Void)?
var makeContextMenu: (() -> NSMenu)?
var onScroll: ((NSEvent) -> Void)?

/// NSMenuItem that runs a closure, so menus can be built without @objc targets.
final class BlockItem: NSMenuItem {
    let block: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func run() { block() }
}

final class DragHostingView<V: View>: NSHostingView<V> {
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let q = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)   // SwiftUI frames are top-left based
        if noDragRects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(q) }) { super.mouseDown(with: event); return }
        if event.clickCount == 2 { onDoubleClick?() } else { window?.performDrag(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

final class Controller {
    let m = Model()
    var window: NSWindow!
    var lastPos = 0.0, lastPollAt = Date(), playing = false
    var audioLatency = 0.0
    var cache: [String: LyricsResult] = [:]
    var map: WallpaperMap?
    var wallpaperSig = ""
    var movingProgrammatically = false
    var manual: Bool { defs.object(forKey: "originX") != nil }   // set once you drag it

    func start() {
        window = DesktopWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false   // transparent areas still click through; text is the drag handle
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)  // just above desktop icons (so it's grabbable), below all app windows
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = DragHostingView(rootView: LyricsView(m: m))
        let vf = homeScreen.visibleFrame
        setFrame(NSPoint(x: vf.minX + cfgMargin, y: vf.minY + cfgMargin))
        if manual, let sx = defs.object(forKey: "originX") as? Double, let sy = defs.object(forKey: "originY") as? Double {
            setFrame(NSPoint(x: sx, y: sy))
        }
        window.orderFront(nil)

        onDoubleClick = { [weak self] in   // double-click the text → back to automatic placement
            defs.removeObject(forKey: "originX"); defs.removeObject(forKey: "originY")
            self?.refreshWallpaper(force: true)
        }

        makeContextMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        onScroll = { [weak self] e in self?.scroll(e) }
        onControl = { [weak self] c in self?.control(c) }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshWallpaper() }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, !self.movingProgrammatically else { return }
            defs.set(Double(self.window.frame.minX), forKey: "originX")   // user dragged it → manual mode
            defs.set(Double(self.window.frame.minY), forKey: "originY")
            self.updateAppearance()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWallpaper(force: true)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWallpaper(force: true)
        }
        refreshWallpaper(force: true)
        poll()
    }

    /// Auto mode lives on the main display; manual mode follows wherever you dragged it.
    var homeScreen: NSScreen {
        if manual, let s = window?.screen { return s }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    func setFrame(_ origin: NSPoint) {
        movingProgrammatically = true
        window.setFrame(NSRect(origin: origin, size: NSSize(width: cfgWidth, height: totalHeight)), display: true)
        movingProgrammatically = false
    }

    /// Reloads the wallpaper map when the wallpaper/space/display changes, then re-places (auto mode) and recolors.
    func refreshWallpaper(force: Bool = false) {
        let scr = homeScreen
        let url = NSWorkspace.shared.desktopImageURL(for: scr)
        let mod = (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date })?.timeIntervalSince1970 ?? 0
        let sig = "\(url?.path ?? "")|\(mod)|\(scr.frame)|\(scr.visibleFrame)"
        guard force || sig != wallpaperSig else { return }
        wallpaperSig = sig
        let auto = !manual
        DispatchQueue.global(qos: .utility).async {
            let map = WallpaperMap(screen: scr)
            var origin: NSPoint?
            if auto, let map {
                let area = scr.visibleFrame.insetBy(dx: 30, dy: 30)
                origin = map.bestOrigin(size: NSSize(width: cfgWidth, height: totalHeight), area: area,
                                        avoid: [desktopIconArea(scr.visibleFrame)].compactMap { $0 })
            }
            DispatchQueue.main.async {
                self.map = map
                if let origin, !self.manual { self.setFrame(origin) }
                self.updateAppearance()
            }
        }
    }

    /// Text color from the wallpaper behind the box; alignment from which half of the screen it's on.
    func updateAppearance() {
        let f = window.frame
        if let s = window.screen ?? NSScreen.screens.first { m.alignRight = f.midX > s.frame.midX }
        switch defs.string(forKey: "textColor") ?? "auto" {
        case "light": m.darkText = false
        case "dark": m.darkText = true
        default: if let b = map?.meanBrightness(f) { m.darkText = b > 0.62 }
        }
    }

    // MARK: Right-click menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !m.title.isEmpty {
            menu.addItem(BlockItem("\(m.title) — \(m.artist)", enabled: false) {})
            menu.addItem(.separator())
        }

        menu.addItem(BlockItem("Reset to Automatic Position", enabled: manual) { onDoubleClick?() })

        let color = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let cur = defs.string(forKey: "textColor") ?? "auto"
        for (key, title) in [("auto", "Automatic (match wallpaper)"), ("light", "Light"), ("dark", "Dark")] {
            colorMenu.addItem(BlockItem(title, checked: cur == key) { [weak self] in
                defs.set(key, forKey: "textColor"); self?.updateAppearance()
            })
        }
        color.submenu = colorMenu
        menu.addItem(color)

        let font = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        for (key, title) in [("rounded", "SF Rounded (default)"), ("system", "SF Pro"), ("serif", "New York (serif)"), ("mono", "SF Mono")] {
            fontMenu.addItem(BlockItem(title, checked: cfgFont == key) { [weak self] in self?.setFont(key) })
        }
        fontMenu.addItem(.separator())
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let picks = ["Manrope", "Avenir Next", "Helvetica Neue", "Futura", "Gill Sans", "Optima", "Didot", "Georgia",
                     "Baskerville", "American Typewriter", "Menlo", "Chalkboard SE", "Marker Felt"]
        var families = picks.filter(installed.contains)
        if !["rounded", "system", "serif", "mono"].contains(cfgFont), !families.contains(cfgFont) { families.append(cfgFont) }
        for f in families {
            let item = BlockItem(f, checked: cfgFont == f) { [weak self] in self?.setFont(f) }
            item.attributedTitle = NSAttributedString(string: f, attributes: [.font: NSFont(name: f, size: 13) ?? NSFont.menuFont(ofSize: 13)])
            fontMenu.addItem(item)
        }
        fontMenu.addItem(.separator())
        fontMenu.addItem(BlockItem("Other…") { [weak self] in self?.askForFont() })
        font.submenu = fontMenu
        menu.addItem(font)

        let timing = NSMenuItem(title: "Lyrics Timing", action: nil, keyEquivalent: "")
        let timingMenu = NSMenu()
        timingMenu.autoenablesItems = false
        timingMenu.addItem(BlockItem(String(format: "Current: %+.2f s early", cfgOffset), enabled: false) {})
        timingMenu.addItem(BlockItem("Show Lines Earlier (+0.25 s)") { [weak self] in self?.setOffset(cfgOffset + 0.25) })
        timingMenu.addItem(BlockItem("Show Lines Later (−0.25 s)") { [weak self] in self?.setOffset(cfgOffset - 0.25) })
        timingMenu.addItem(BlockItem("Reset") { [weak self] in self?.setOffset(0.25) })
        timing.submenu = timingMenu
        menu.addItem(timing)

        menu.addItem(BlockItem("Reload Lyrics") { [weak self] in
            guard let self else { return }
            self.cache.removeValue(forKey: self.m.trackKey); self.m.trackKey = ""; self.poll()
        })

        menu.addItem(.separator())
        let loginOn = SMAppService.mainApp.status == .enabled
        menu.addItem(BlockItem("Open at Login", checked: loginOn) {
            defs.set(!loginOn, forKey: "launchAtLogin")
            if loginOn { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        })
        menu.addItem(BlockItem("Quit DesktopLyrics") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: Scroll to seek

    var scrubIndex: Int?            // line picked by scrolling; playback timing is ignored until the seek lands
    var scrubAccum: CGFloat = 0
    var seekWork: DispatchWorkItem?

    /// Scrolling over the lyrics moves line by line (scroll down = later), then seeks Spotify to that line.
    func scroll(_ e: NSEvent) {
        guard m.status == .lyrics, !m.lines.isEmpty, e.momentumPhase.isEmpty else { return }
        if e.phase == .began { scrubAccum = 0 }
        // One line per "notch": a trackpad needs a deliberate 55pt of travel per line, a mouse wheel click is one line.
        let notch: CGFloat = 55
        scrubAccum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * notch
        let step = scrubAccum <= -notch ? 1 : scrubAccum >= notch ? -1 : 0
        guard step != 0 else { return }
        scrubAccum = 0
        let n = min(m.lines.count - 1, max(-1, (scrubIndex ?? m.index) + step))   // -1 = song title
        guard n != (scrubIndex ?? m.index) else { return }                        // at either end: no tick
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        scrubIndex = n
        m.scrubbing = true
        m.index = n
        seekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.seek(toLine: n) }
        seekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func seek(toLine n: Int) {
        let t = n < 0 ? 0 : max(0, m.lines[n].time - cfgOffset + audioLatency + 0.05)
        let src = "tell application id \"com.spotify.client\" to set player position to " + String(format: "%.3f", t)
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        lastPos = t
        lastPollAt = Date()
        scrubIndex = nil
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.scrubIndex == nil { self?.m.scrubbing = false }
        }
    }

    // MARK: Playback controls

    func control(_ c: Control) {
        let cmd = c == .playPause ? "playpause" : c == .next ? "next track" : "previous track"
        var err: NSDictionary?
        NSAppleScript(source: "tell application id \"com.spotify.client\" to \(cmd)")?.executeAndReturnError(&err)
        if c == .playPause {   // flip the icon right away; the poll below confirms
            let now = Date()
            if m.playing { m.posBase += now.timeIntervalSince(m.posAt) }
            m.posAt = now
            m.playing.toggle()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }

    func setFont(_ family: String) {
        cfgFont = family
        defs.set(family, forKey: "fontFamily")
        heightCache.removeAll()          // wrapping depends on the font
        m.fontFamily = family
    }

    /// Type any installed font family name (e.g. "Inter", "Times New Roman").
    func askForFont() {
        let alert = NSAlert()
        alert.messageText = "Font Family"
        alert.informativeText = "Enter the name of an installed font family."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Inter"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Font")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        // Match case-insensitively against what's installed.
        if let match = NSFontManager.shared.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
            setFont(match)
        } else {
            let a = NSAlert()
            a.messageText = "“\(typed)” isn't installed."
            a.runModal()
        }
    }

    func setOffset(_ v: Double) {
        cfgOffset = (v * 100).rounded() / 100
        defs.set(cfgOffset, forKey: "offset")
        tick()
    }

    func poll() {
        guard let s = readSpotify() else {
            playing = false; m.visible = false; m.running = false; m.playing = false; return
        }
        playing = s.playing
        audioLatency = outputLatency()
        lastPos = s.position
        lastPollAt = Date()
        m.visible = s.playing
        m.running = true
        m.posBase = s.position; m.posAt = lastPollAt
        if m.playing != s.playing { m.playing = s.playing }

        if s.id != m.trackKey {
            m.trackKey = s.id
            m.title = s.name
            m.artist = s.artist
            m.index = -1
            m.art = nil
            if let u = URL(string: s.art) {
                let id = s.id
                Task {
                    guard let (data, _) = try? await URLSession.shared.data(from: u) else { return }
                    await MainActor.run { if self.m.trackKey == id { self.m.art = NSImage(data: data) } }
                }
            }
            if let cached = cache[s.id] { apply(cached) } else {
                m.status = .loading
                m.lines = []
                let id = s.id
                Task {
                    let r = await fetchLyrics(s)
                    await MainActor.run {
                        if case .none = r {} else { self.cache[id] = r }
                        if self.m.trackKey == id { self.apply(r) }
                    }
                }
            }
        }
        tick()
    }

    func apply(_ r: LyricsResult) {
        switch r {
        case .synced(let l) where !l.isEmpty: m.lines = l; m.status = .lyrics
        case .instrumental: m.lines = []; m.status = .instrumental
        default: m.lines = []; m.status = .noLyrics
        }
        tick()
    }

    func tick() {
        guard m.status == .lyrics, scrubIndex == nil else { return }
        let pos = lastPos + (playing ? Date().timeIntervalSince(lastPollAt) : 0) + cfgOffset - audioLatency
        var lo = 0, hi = m.lines.count - 1, idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if m.lines[mid].time <= pos { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if idx != m.index { m.index = idx }
    }
}

// MARK: - Main

// Fonts bundled in DesktopLyrics.app/Contents/Resources/Fonts (e.g. Manrope), usable only by this app.
for url in (Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Fonts") ?? [])
    where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if defs.object(forKey: "launchAtLogin") as? Bool ?? true {
    try? SMAppService.mainApp.register()
}
let controller = Controller()
controller.start()
app.run()
