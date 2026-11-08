import SwiftUI

// MARK: - Модель: что маскот говорит и как себя чувствует

/// Маскот Shuttle — пиксельный дроид из логотипа. Сидит в шапке окна,
/// шутит по клику и реагирует на то, что происходит с устройством и передачами.
/// Приёмы юмора те же, что на сайте: пауза перед поворотом (‖),
/// опечатка с исправлением ({ошибка|верно}), повторы и «снежный ком» кликов.
@MainActor
final class Mascot: ObservableObject {
    static let shared = Mascot()

    enum Mood { case calm, happy, sad, hot }
    enum Event {
        case connected(console: Bool), disconnected, done(Int), failed, newPhotos(Int), error
    }

    /// Напечатанная часть реплики. nil — облачко скрыто.
    @Published private(set) var shown: String?
    @Published private(set) var talking = false
    @Published private(set) var mood: Mood = .calm
    /// Растёт на каждый прыжок — вид анимирует подскок.
    @Published private(set) var hops = 0
    /// Поднял ручки и машет (после удачной передачи).
    @Published private(set) var cheering = false

    private var task: Task<Void, Never>?
    private var bag: [Int] = []
    private var streak = 0
    private var streakReset: Task<Void, Never>?
    private var lastAuto = Date.distantPast
    private var greeted = false

    // MARK: Реплики

    private var jokes: [String] {
        [
            L("Я не облако. ‖ Я лучше."),
            L("Кабель — это любовь. ‖ Wi‑Fi — отношения на расстоянии."),
            L("Тащи файл. ‖ Я подержу."),
            L("Android File Transfer? ‖ Не слышал о таком."),
            L("Я никогда не делаю {ошипок|ошибок}."),
            L("Обожаю облака. ‖ Особенно когда их нет."),
            L("Сохранил твои сейвы. ‖ Тебя самого спасти не смогу."),
            L("Я разбираюсь в портах. ‖ Корабли не принимаю."),
            L("Почистил кэш. ‖ Кэша в кошельке не прибавилось."),
            L("Я не тормоз. ‖ Я терпеливый буфер."),
            L("Скачать + счастье = ‖ скачастье."),
            L("Почему файл перешёл дорогу? ‖ Его перетащили."),
            L("Загружаю шутку… ‖ 99%… ‖ 99%… ‖ Шутка не найдена."),
            L("Ошибка 418: ‖ я чайник. ‖ Шучу. Я шаттл."),
            L("Я робот. ‖ Бип. Буп. ‖ Извини, это было предустановлено."),
            L("12 новых фото. ‖ 11 — еда."),
            L("Мои антенны ничего не ловят. ‖ Они для красоты."),
            L("Я маленький. ‖ Зато сижу на логотипе. Это брендинг."),
            L("Ctrl+Z для жизни не завезли. ‖ Зато докачка после обрыва есть."),
            L("Мой IQ — {404|140}. ‖ Это был код ошибки."),
            L("Пробел — и Quick Look. ‖ Самая короткая шутка: « »."),
            L("Синхронизация ничего не удаляет. ‖ Я тоже. Я добрый."),
            L("Обновления приходят сами. ‖ Как кот. Но полезнее."),
            L("Терпеть не могу внимание. ‖ Кликни ещё раз."),
            L("Перетащи. ‖ Перетащи. ‖ Перетащи. ‖ Это мантра."),
            L("Встречаются Android и Switch. ‖ — Ты тоже по MTP? ‖ — Только с DBI. ‖ Любовь."),
            L("Тук-тук. ‖ — Кто там? ‖ — MTP. ‖ — MTP кто? ‖ — Разблокируй телефон — узнаешь."),
            L("Я в шапке окна. ‖ Тут тепло и видно все файлы."),
        ]
    }

    // MARK: Клик: шутка, а если кликать подряд — снежный ком

    func click() {
        hop()
        streak += 1
        streakReset?.cancel()
        streakReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.streak = 0 }
        }
        switch streak {
        case 10...:
            streak = 0
            mood = .hot
            say(L("Перегрев! ‖ Включаю кулер… ‖ А, у меня нет кулера."))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.mood == .hot { self?.mood = .calm }
            }
        case 5:
            say(L("Эй, я не кнопка. ‖ Хотя сходство есть."))
        default:
            if !greeted {
                greeted = true
                say(L("Привет! Я Шаттл. ‖ Вожу файлы по кабелю. Облака не вожу — укачивает."))
            } else {
                if bag.isEmpty { bag = Array(jokes.indices).shuffled() }
                say(jokes[bag.removeLast()])
            }
        }
    }

    // MARK: Реакции на события

    func react(_ e: Event) {
        switch e {
        case .connected(let console):
            hop()
            auto(console ? L("Switch на связи. ‖ DBI, я тебя вижу.") : L("Телефон на связи. ‖ Обещаю не листать галерею."), .happy)
        case .disconnected:
            auto(L("Кабель отключили. ‖ Я подожду. Я умею."), .sad)
        case .done(let n):
            cheer()
            auto(n == 1 ? L("Готово! ‖ Файл на месте.") : L("Готово! ‖ Перенёс файлов: %d. Без облака.", n), .happy, force: true)
        case .failed:
            auto(L("Что-то не перенеслось. ‖ Не я. Наверное."), .sad, force: true)
        case .newPhotos(let n):
            auto(L("На телефоне новые фото: %d. ‖ Одна кнопка — и они на Mac.", n), .happy)
        case .error:
            mood = .sad
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.mood == .sad { self?.mood = .calm }
            }
        }
    }

    /// Сам по себе маскот говорит не чаще раза в 12 секунд и молчит, если его выключили.
    private func auto(_ text: String, _ mood: Mood, force: Bool = false) {
        guard AppSettings.shared.mascotTalks else { self.mood = mood; return }
        guard force || (Date().timeIntervalSince(lastAuto) > 12 && shown == nil) else { return }
        lastAuto = Date()
        say(text, mood: mood)
    }

    private func hop() { hops += 1 }

    private func cheer() {
        cheering = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            self?.cheering = false
        }
    }

    // MARK: Печать с паузами и опечатками

    private enum Op { case type(String), pause(Double), typo(String, String) }

    private func parse(_ text: String) -> [Op] {
        var ops: [Op] = []
        for (i, raw) in text.components(separatedBy: "‖").enumerated() {
            var part = raw.trimmingCharacters(in: .whitespaces)
            if i > 0 {
                ops.append(.pause(0.6))
                part = (part.hasPrefix("—") ? "\n" : " ") + part
            }
            var rest = Substring(part)
            while let open = rest.firstIndex(of: "{"), let bar = rest[open...].firstIndex(of: "|"),
                  let close = rest[bar...].firstIndex(of: "}") {
                if open > rest.startIndex { ops.append(.type(String(rest[..<open]))) }
                ops.append(.typo(String(rest[rest.index(after: open)..<bar]), String(rest[rest.index(after: bar)..<close])))
                rest = rest[rest.index(after: close)...]
            }
            if !rest.isEmpty { ops.append(.type(String(rest))) }
        }
        return ops
    }

    func say(_ text: String, mood: Mood? = nil) {
        task?.cancel()
        if let mood { self.mood = mood }
        let ops = parse(text)
        task = Task { [weak self] in
            guard let self else { return }
            self.buffer = ""
            self.shown = ""
            self.talking = true
            for op in ops {
                if Task.isCancelled { return }
                switch op {
                case .type(let s): await self.put(s)
                case .pause(let d):
                    self.talking = false
                    try? await Task.sleep(for: .seconds(d))
                    self.talking = true
                case .typo(let wrong, let right):
                    await self.put(wrong)
                    self.talking = false
                    try? await Task.sleep(for: .milliseconds(380))
                    self.talking = true
                    for _ in wrong where !self.buffer.isEmpty {
                        self.buffer.removeLast(); self.shown = self.buffer
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    await self.put(right)
                }
            }
            self.talking = false
            try? await Task.sleep(for: .seconds(max(3.2, Double(self.buffer.count) * 0.05)))
            if Task.isCancelled { return }
            self.shown = nil
            if self.mood != .hot { self.mood = .calm }
        }
    }

    private var buffer = ""

    /// Печатает по букве; на знаках препинания — чуть дольше, как живая речь.
    private func put(_ s: String) async {
        for ch in s {
            if Task.isCancelled { return }
            buffer.append(ch)
            shown = buffer
            try? await Task.sleep(for: .milliseconds(".,!?…".contains(ch) ? 120 : 28))
        }
    }

    func hush() { task?.cancel(); shown = nil; talking = false }
}

// MARK: - Спрайт

/// Пиксельный маскот: та же сетка 32×30, что на сайте. В шапке ручки и ножки спрятаны,
/// ручки появляются, когда он радуется.
struct MascotSprite: View {
    var scale: CGFloat = 1
    var blink = false
    var antennaUp = false
    var talking = false
    var arms: CGFloat = 0          // 0 — спрятаны, 1 — подняты
    var waveUp = false
    var mood: Mascot.Mood = .calm
    var legs = false

    private typealias R = (Int, Int, Int, Int)
    private static func mir(_ r: [R]) -> [R] { r.map { (32 - $0.0 - $0.2, $0.1, $0.2, $0.3) } }

    private static let body: [R] = [(10, 7, 12, 1), (8, 8, 16, 1), (7, 9, 18, 1), (6, 10, 20, 10), (7, 20, 18, 1), (8, 21, 16, 1), (10, 22, 12, 1)]
    private static let shade: [R] = [(6, 18, 20, 2), (7, 20, 18, 1), (8, 21, 16, 1), (10, 22, 12, 1)]
    private static let shine: [R] = [(10, 8, 4, 1), (8, 9, 2, 1), (7, 10, 1, 3)]
    private static let stem: [R] = [(10, 4, 1, 1), (11, 5, 1, 2)] + mir([(10, 4, 1, 1), (11, 5, 1, 2)])
    private static let ball: [R] = [(7, 1, 3, 3)] + mir([(7, 1, 3, 3)])
    private static let glint: [R] = [(8, 1, 1, 1), (23, 1, 1, 1)]
    private static let eyeL: [R] = [(13, 11, 2, 1), (12, 12, 2, 1), (11, 13, 2, 1), (12, 14, 2, 1), (13, 15, 2, 1)]
    private static let eyes = eyeL + mir(eyeL)
    // грустные глаза — опущенные полоски
    private static let sadEyes: [R] = [(11, 13, 4, 1), (12, 14, 2, 1)] + mir([(11, 13, 4, 1), (12, 14, 2, 1)])
    private static let cheeks: [R] = [(8, 16, 2, 1)] + mir([(8, 16, 2, 1)])
    private static let smile: [R] = [(14, 17, 1, 1), (15, 18, 2, 1), (17, 17, 1, 1)]
    private static let frown: [R] = [(14, 18, 1, 1), (15, 17, 2, 1), (17, 18, 1, 1)]
    private static let talk: [R] = [(14, 17, 4, 2)]
    private static let tongue: [R] = [(15, 18, 2, 1)]
    private static let arm: [R] = [(5, 12, 1, 2), (4, 13, 1, 2), (3, 14, 1, 2)]
    private static let cuff: [R] = [(2, 16, 3, 1)]
    private static let glove: [R] = [(1, 17, 4, 3), (0, 18, 1, 1), (2, 20, 2, 1)]
    // поднятая ручка: вверх-наружу
    private static let armUp: [R] = [(5, 11, 1, 2), (4, 9, 1, 2), (3, 7, 1, 2)]
    private static let cuffUp: [R] = [(2, 6, 3, 1)]
    private static let gloveUp: [R] = [(1, 3, 4, 3), (0, 4, 1, 1), (2, 2, 2, 1)]
    private static let leg: [R] = [(12, 23, 2, 3)]
    private static let sock: [R] = [(12, 26, 2, 1)]
    private static let shoe: [R] = [(9, 27, 5, 2)]
    private static let sole: [R] = [(9, 29, 5, 1)]

    private static let gold = Color(hex: 0xE9B949), goldDark = Color(hex: 0xC99632), goldLight = Color(hex: 0xF8DC8B)
    private static let ink = Color(hex: 0x1F1822), blush = Color(hex: 0xE8796E)
    private static let white = Color(hex: 0xF6F0E6), cuffC = Color(hex: 0xD9CFC2), shoeC = Color(hex: 0x3A2A3F), soleC = Color(hex: 0x6B5470)

    var body: some View {
        Canvas { ctx, _ in
            let s = scale
            func fill(_ rects: [R], _ c: Color, dx: CGFloat = 0, dy: CGFloat = 0) {
                for r in rects {
                    ctx.fill(Path(CGRect(x: (CGFloat(r.0) + dx) * s, y: (CGFloat(r.1) + dy) * s,
                                         width: CGFloat(r.2) * s, height: CGFloat(r.3) * s)), with: .color(c))
                }
            }
            if legs {
                for side in [false, true] {
                    let m: ([R]) -> [R] = side ? Self.mir : { $0 }
                    fill(m(Self.leg), Self.goldDark); fill(m(Self.sock), Self.white)
                    fill(m(Self.shoe), Self.shoeC); fill(m(Self.sole), Self.soleC)
                }
            }
            // ручки: выдвигаются из корпуса
            if arms > 0 {
                let pull = (1 - arms) * 4
                fill(Self.arm, Self.goldDark, dx: pull); fill(Self.cuff, Self.cuffC, dx: pull); fill(Self.glove, Self.white, dx: pull)
                let up = waveUp
                fill(Self.mir(up ? Self.armUp : Self.arm), Self.goldDark, dx: -pull)
                fill(Self.mir(up ? Self.cuffUp : Self.cuff), Self.cuffC, dx: -pull)
                fill(Self.mir(up ? Self.gloveUp : Self.glove), Self.white, dx: -pull)
            }
            let ay: CGFloat = antennaUp ? -1 : 0
            fill(Self.stem, Self.goldDark, dy: ay); fill(Self.ball, Self.gold, dy: ay); fill(Self.glint, Color(hex: 0xFFF1C4), dy: ay)
            let bodyC = mood == .hot ? Color(hex: 0xF0874A) : Self.gold
            fill(Self.body, bodyC); fill(Self.shade, mood == .hot ? Color(hex: 0xC9622E) : Self.goldDark); fill(Self.shine, Self.goldLight)
            if blink {
                fill([(11, 13, 4, 1)] + Self.mir([(11, 13, 4, 1)]), Self.ink)
            } else {
                fill(mood == .sad ? Self.sadEyes : Self.eyes, Self.ink)
            }
            fill(Self.cheeks, Self.blush.opacity(mood == .happy || mood == .hot ? 0.9 : 0.55))
            if talking {
                fill(Self.talk, Self.ink); fill(Self.tongue, Self.blush)
            } else {
                fill(mood == .sad ? Self.frown : Self.smile, Self.ink)
            }
        }
        .frame(width: 32 * scale, height: 30 * scale)
    }
}

// MARK: - Маскот в шапке

/// Маленький маскот вместо значка в шапке. Моргает, шевелит антеннами,
/// подпрыгивает от радости и отвечает в облачке по клику.
struct HeaderMascot: View {
    @ObservedObject private var m = Mascot.shared
    @Environment(\.isSnapshot) private var snap
    @State private var blink = false
    @State private var antenna = false
    @State private var lift: CGFloat = 0
    @State private var wave = false
    @State private var hover = false

    var body: some View {
        MascotSprite(scale: 1, blink: blink, antennaUp: antenna, talking: m.talking && !snap,
                     arms: m.cheering ? 1 : 0, waveUp: wave, mood: snap ? .calm : m.mood)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: m.cheering)
            .offset(y: lift)
            .rotationEffect(.degrees(hover && !snap ? -6 : 0), anchor: .bottom)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: hover)
            // корпус занимает середину сетки — поджимаем пустые поля по бокам и сверху
            .padding(.horizontal, -6).padding(.top, -2).padding(.bottom, -6)
            .contentShape(Rectangle())
            .onTapGesture { Mascot.shared.click() }
            .onHover { hover = $0 }
            .help(L("Это Шаттл. Нажми — он что-нибудь скажет."))
            .accessibilityLabel(L("Маскот Shuttle"))
            .accessibilityAddTraits(.isButton)
            .onChange(of: m.hops) { _, _ in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { lift = -6 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.45).delay(0.14)) { lift = 0 }
            }
            .task {
                guard !snap else { return }
                // моргание и антенны — в своём ритме, пока окно живо
                async let b: Void = loop(every: 3.6) {
                    blink = true
                    try? await Task.sleep(for: .milliseconds(130))
                    blink = false
                }
                async let a: Void = loop(every: 0.9) { antenna.toggle() }
                async let w: Void = loop(every: 0.35) { if m.cheering { wave.toggle() } else { wave = false } }
                _ = await (b, a, w)
            }
    }

    private func loop(every seconds: Double, _ tick: @escaping @MainActor () async -> Void) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            await tick()
        }
    }
}

// MARK: - Ретро-облачко

/// Прямоугольник со ступенчатыми «пиксельными» углами.
struct StepRect: Shape {
    var step: CGFloat = 3
    func path(in r: CGRect) -> Path {
        let s = step
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY + s))
        p.closeSubpath()
        return p
    }
}

/// Облачко с репликой под шапкой, хвостиком к маскоту.
struct MascotBubble: View {
    @ObservedObject private var m = Mascot.shared
    @Environment(\.palette) private var p

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let text = m.shown {
                VStack(alignment: .leading, spacing: 0) {
                    // пиксельный хвостик вверх, к маскоту
                    VStack(spacing: 0) {
                        Rectangle().fill(p.accent).frame(width: 3, height: 3)
                        Rectangle().fill(p.accent).frame(width: 6, height: 3)
                        Rectangle().fill(p.accent).frame(width: 9, height: 3)
                    }
                    .padding(.leading, 14)
                    (Text(text) + Text(m.talking ? "▌" : "").foregroundColor(p.accent))
                        .font(AppFont.pixel(12))
                        .foregroundStyle(p.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 250, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(StepRect().fill(p.surface))
                        .overlay(StepRect().stroke(p.accent, lineWidth: 2))
                        .background(StepRect().fill(Color.black.opacity(0.3)).offset(x: 4, y: 4))
                }
                .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
                .onTapGesture { m.hush() }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: m.shown == nil)
    }
}
