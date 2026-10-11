/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// Native SwiftUI app picker, shown by src/environment/app_picker/swiftui.rs.
// The layout matches the picker drawn by src/environment/app_picker.rs.

import SwiftUI
import UIKit

// MARK: - Entry point

struct PickerInput: Decodable {
    struct App: Decodable {
        let name: String
        let iconWidth: Int
        let iconHeight: Int
        let hasIcon: Bool
    }
    /// A choice (`choices` set) or a switch. Values are a choice's index, or
    /// 1 for a switch that's on.
    struct QuickOption: Decodable {
        let label: String
        let footer: String
        let choices: [String]?
        let defaultValue: Int
    }
    let apps: [App]
    let error: String?
    let wallpaperPath: String?
    let branding: String
    let shortVersionText: String
    let copyright: String
    let fileManagerURL: String?
    let websiteURL: String
    let quickOptions: [QuickOption]
}

/// Called from Rust. Shows the picker until an app is picked, then returns
/// the app's index and the option arguments, one per line, from `strdup()`.
@_cdecl("idared_swiftui_app_picker")
public func idaredSwiftUIAppPicker(
    _ json: UnsafePointer<CChar>,
    _ icons: UnsafePointer<UnsafePointer<UInt8>?>,
    _ iconCount: Int
) -> UnsafeMutablePointer<CChar>? {
    let data = Data(bytes: json, count: strlen(json))
    guard let input = try? JSONDecoder().decode(PickerInput.self, from: data)
    else {
        return nil
    }
    var appIcons: [UIImage] = []
    for (i, app) in input.apps.enumerated() {
        guard i < iconCount, let pixels = icons[i],
              let icon = makeImage(pixels, app.iconWidth, app.iconHeight)
        else {
            return nil
        }
        appIcons.append(app.hasIcon ? icon : addQuestionMark(icon))
    }

    let model = PickerModel(input: input, icons: appIcons)
    let window: UIWindow
    if let scene = activeWindowScene() {
        window = UIWindow(windowScene: scene)
    } else {
        window = UIWindow(frame: UIScreen.main.bounds)
    }
    // Above SDL's launch screen, which fades out on its own.
    window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
    window.rootViewController = PickerHostingController(model: model)
    window.makeKeyAndVisible()

    // Rust is waiting on the main thread, so keep the run loop going here.
    while model.result == nil {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    // Let the picked icon's highlight show before the app starts.
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

    window.isHidden = true
    window.rootViewController = nil
    return strdup(model.result!)
}

private func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive }
        ?? scenes.first { $0.activationState == .foregroundInactive }
        ?? scenes.first
}

/// Rust's images are premultiplied RGBA, top row first.
private func makeImage(_ pixels: UnsafePointer<UInt8>, _ width: Int, _ height: Int) -> UIImage? {
    let data = Data(bytes: pixels, count: width * height * 4)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: true,
              intent: .defaultIntent
          )
    else {
        return nil
    }
    return UIImage(cgImage: image)
}

private func addQuestionMark(_ icon: UIImage) -> UIImage {
    UIGraphicsImageRenderer(size: icon.size).image { _ in
        icon.draw(at: .zero)
        let text = "?" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40),
            .foregroundColor: UIColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: (icon.size.width - size.width) / 2, y: (icon.size.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - Model

final class PickerModel: ObservableObject {
    let input: PickerInput
    let icons: [UIImage]
    let wallpaper: UIImage?

    @Published var safeInsets = UIEdgeInsets.zero
    @Published var page = 0
    @Published var pressedApp: Int?
    @Published var showingQuickOptions = false
    @Published var showingCopyright = false
    @Published var copyrightPage = 0
    var copyrightPages: [String] = []

    /// The value of each of the quick options.
    @Published var quickOptionValues: [Int]

    /// Set when an app is picked: what's returned to Rust.
    var result: String?

    init(input: PickerInput, icons: [UIImage]) {
        self.input = input
        self.icons = icons
        quickOptionValues = input.quickOptions.map(\.defaultValue)
        wallpaper = input.wallpaperPath.flatMap { UIImage(contentsOfFile: $0) }
    }

    /// Rust turns the quick option values into option arguments.
    func pick(_ app: Int) {
        let lines = [String(app)] + quickOptionValues.map(String.init)
        result = lines.joined(separator: "\n")
    }

    func open(_ url: String?) {
        guard let url = url.flatMap({ URL(string: $0) }) else {
            return
        }
        UIApplication.shared.open(url)
    }
}

final class PickerHostingController: UIHostingController<PickerView> {
    private let model: PickerModel

    init(model: PickerModel) {
        self.model = model
        super.init(rootView: PickerView(model: model))
        view.backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        model.safeInsets = view.safeAreaInsets
    }
}

// MARK: - Layout

/// When the app became free. The Upgrade button only shows after this, so
/// it's hidden while this is nil.
let freeSince: Date? = nil

/// The logo's background colour, so it blends in.
let headerBlue = Color(red: 0, green: 77 / 255, blue: 215 / 255)
let logoYellow = Color(red: 253 / 255, green: 224 / 255, blue: 22 / 255)
let labelFontSize: CGFloat = 14
let labelLineHeight: CGFloat = 17

/// Everything is placed by its frame, as in the Rust picker.
extension View {
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct PickerLayout {
    let size: CGSize
    let header: CGRect
    /// The row inside the header with the logo and buttons.
    let headerContent: CGRect
    let insets: UIEdgeInsets
    let bar: CGRect
    let gridFrame: CGRect
    let pageControlFrame: CGRect
    let columns: Int
    let rows: Int
    let iconSize: CGFloat
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    let labelWidth: CGFloat
    /// About two characters wider, used when the neighbouring names leave room.
    let labelMaxWidth: CGFloat

    init(size: CGSize, insets: UIEdgeInsets) {
        self.size = size
        self.insets = insets
        headerContent = CGRect(x: 0, y: max(insets.top, 8), width: size.width, height: 72)
        header = CGRect(x: 0, y: 0, width: size.width, height: headerContent.maxY + 6)

        // Sized and placed like the iOS 26 tab bar.
        let barBottom = size.height - (insets.bottom > 0 ? max(insets.bottom - 15, 12) : 12)
        let barWidth = min(size.width - 32, 330)
        bar = CGRect(
            x: (size.width - barWidth) / 2,
            y: barBottom - 64,
            width: barWidth,
            height: 64
        )
        pageControlFrame = CGRect(x: 0, y: bar.minY - 30, width: size.width, height: 26)
        gridFrame = CGRect(
            x: 0,
            y: header.maxY + 18,
            width: size.width,
            height: pageControlFrame.minY - header.maxY - 18
        )

        // 4 columns on a phone, more on something wider.
        let margin: CGFloat = 12
        columns = max(Int(((size.width - margin * 2) / 100).rounded(.down)), 4)
        columnWidth = (size.width - margin * 2) / CGFloat(columns)
        iconSize = min(columnWidth * 0.76, 84).rounded()
        labelWidth = columnWidth - 4
        labelMaxWidth = (labelWidth * 1.19).rounded()
        rowHeight = iconSize + 4 + labelLineHeight + 14
        let lastRowHeight = iconSize + 4 + labelLineHeight
        rows = max(Int(((gridFrame.height - lastRowHeight) / rowHeight).rounded(.down)) + 1, 1)
    }

    var appsPerPage: Int { columns * rows }

    func iconFrame(slot: Int) -> CGRect {
        let col = CGFloat(slot % columns)
        let row = CGFloat(slot / columns)
        return CGRect(
            x: (12 + col * columnWidth + (columnWidth - iconSize) / 2).rounded(),
            y: (gridFrame.minY + row * rowHeight).rounded(),
            width: iconSize,
            height: iconSize
        )
    }

    func buttonFrames(count: Int, center: CGFloat, width: CGFloat) -> [CGRect] {
        let margin: CGFloat = 10
        let buttonWidth = (width - margin) / CGFloat(count) - margin
        return (0..<count).map { i in
            CGRect(
                x: margin + CGFloat(i) * (buttonWidth + margin),
                y: center - 15,
                width: buttonWidth,
                height: 30
            )
        }
    }
}

/// Works out each name's width and text, letting a name grow past
/// `labelWidth` only while it can't touch the names either side of it.
func layOutLabels(
    names: [String],
    layout: PickerLayout,
    font: UIFont
) -> [(text: String, width: CGFloat)] {
    func measure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    let columns = layout.columns
    let textWidths = names.map { min(measure($0), layout.labelMaxWidth) }
    return names.indices.map { i -> (text: String, width: CGFloat) in
        var width = textWidths[i]
        if i % columns > 0 {
            width = min(width, 2 * layout.labelWidth - textWidths[i - 1])
        }
        if i % columns + 1 < columns && i + 1 < names.count {
            width = min(width, 2 * layout.labelWidth - textWidths[i + 1])
        }
        width = max(width, layout.labelWidth).rounded(.up)

        let name = names[i]
        guard measure(name) > width else {
            return (name, width)
        }
        // Like iOS, end names that still don't fit with an ellipsis.
        let chars = Array(name)
        var truncated = "…"
        for n in stride(from: chars.count - 1, through: 0, by: -1) {
            let candidate = String(chars[..<n]).trimmingCharacters(in: .whitespaces) + "…"
            if measure(candidate) <= width {
                truncated = candidate
                break
            }
        }
        // Rather than cut into the first word, drop the words after it.
        let firstWord = String(name.split(separator: " ", omittingEmptySubsequences: false)[0])
        if truncated.count - 1 < firstWord.count && measure(firstWord) <= width {
            truncated = firstWord
        }
        return (truncated, width)
    }
}

// MARK: - Views

struct PickerView: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        content
            .statusBarHidden(true)
            .sheet(isPresented: $model.showingQuickOptions) {
                QuickOptionsView(model: model)
            }
    }

    private var content: some View {
        GeometryReader { geometry in
            let layout = PickerLayout(size: geometry.size, insets: model.safeInsets)
            ZStack(alignment: .topLeading) {
                Color.black
                if let wallpaper = model.wallpaper {
                    Image(uiImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: layout.size.width, height: layout.size.height)
                        .clipped()
                        .opacity(0.8)
                }
                BrandingLabels(branding: model.input.branding, size: layout.size)
                if let error = model.input.error {
                    Text(error)
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .multilineTextAlignment(.center)
                        .place(layout.gridFrame.insetBy(dx: 10, dy: 10))
                } else {
                    IconGrid(model: model, layout: layout)
                }
                Header(model: model, layout: layout)
                ActionBar(model: model)
                    .place(layout.bar)
                if model.showingCopyright {
                    CopyrightView(model: model, layout: layout)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct Header: View {
    @ObservedObject var model: PickerModel
    let layout: PickerLayout

    var body: some View {
        let content = layout.headerContent
        let side: CGFloat = 124
        ZStack(alignment: .topLeading) {
            headerBlue
                .place(layout.header)
            Text("v" + model.input.shortVersionText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .place(CGRect(x: 16, y: content.minY, width: 60, height: content.height))
            // The logo fills the space between the version and the buttons.
            Image("AppPickerLogo")
                .resizable()
                .scaledToFit()
                .place(CGRect(
                    x: 80,
                    y: content.minY + 2,
                    width: content.maxX - side - 84,
                    height: content.height - 4
                ))
            HStack(spacing: 8) {
                if let freeSince, Date() >= freeSince {
                    HeaderButton(
                        title: "Upgrade",
                        symbol: "crown.fill",
                        color: logoYellow,
                        fill: Color(red: 0.08, green: 0.12, blue: 0.35),
                        action: {}
                    )
                }
                HeaderButton(
                    title: "About",
                    symbol: "info",
                    color: .white,
                    fill: .clear,
                    action: {
                        model.copyrightPage = 0
                        model.showingCopyright = true
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .place(CGRect(
                x: content.maxX - side,
                y: content.minY,
                width: side - 12,
                height: content.height
            ))
        }
    }
}

struct HeaderButton: View {
    let title: String
    let symbol: String
    let color: Color
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(fill)
                    Circle().stroke(color, lineWidth: 2)
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(color)
                }
                .frame(width: 40, height: 40)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// File Manager, Quick Options and the website, in one bar like the iOS 26
/// tab bar. A real toolbar's height is fixed too short for the labels.
struct ActionBar: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        HStack(spacing: 0) {
            item("folder.fill", "File Manager") {
                model.open(model.input.fileManagerURL)
            }
            item("gearshape.fill", "Quick Options") {
                model.showingQuickOptions = true
            }
            item("safari.fill", "Website") {
                model.open(model.input.websiteURL)
            }
        }
        .padding(.horizontal, 10)
        .modifier(BarBackground())
        .environment(\.colorScheme, .dark)
    }

    private func item(
        _ symbol: String,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        // Plain, or iOS underlines the titles when Button Shapes is on.
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Liquid Glass on iOS 26, the translucent bar material before that.
struct BarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

struct BrandingLabels: View {
    let branding: String
    let size: CGSize

    var body: some View {
        if !branding.isEmpty {
            ForEach(1...7, id: \.self) { i in
                Text(branding)
                    .font(.system(size: 48))
                    .foregroundColor(branding == "UNOFFICIAL" ? .red : Color(white: 0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: i % 2 == 0 ? .leading : .trailing)
                    .place(CGRect(
                        x: 0,
                        y: size.height / 8 * CGFloat(i) - 25,
                        width: size.width,
                        height: 50
                    ))
            }
        }
    }
}

struct IconGrid: View {
    @ObservedObject var model: PickerModel
    let layout: PickerLayout
    @State private var dragStart: CGPoint?

    private var pageCount: Int {
        (model.input.apps.count + layout.appsPerPage - 1) / layout.appsPerPage
    }

    private var pageRange: Range<Int> {
        let page = min(model.page, pageCount - 1)
        let start = page * layout.appsPerPage
        return start..<min(start + layout.appsPerPage, model.input.apps.count)
    }

    var body: some View {
        let range = pageRange
        let font = UIFont.systemFont(ofSize: labelFontSize, weight: .medium)
        // Empty slots still count as neighbours, with no name.
        let names = (0..<layout.appsPerPage).map { slot in
            range.contains(range.lowerBound + slot) ? model.input.apps[range.lowerBound + slot].name : ""
        }
        let labels = layOutLabels(names: names, layout: layout, font: font)

        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(range.enumerated()), id: \.element) { slot, app in
                let iconFrame = layout.iconFrame(slot: slot)
                Image(uiImage: model.icons[app])
                    .resizable()
                    .opacity(model.pressedApp == app ? 0.5 : 1)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .place(iconFrame)
                Text(labels[slot].text)
                    .font(.system(size: labelFontSize, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                    .lineLimit(1)
                    .fixedSize()
                    .place(CGRect(
                        x: (iconFrame.midX - labels[slot].width / 2).rounded(),
                        y: (iconFrame.maxY + 4).rounded(),
                        width: labels[slot].width,
                        height: labelLineHeight
                    ))
            }
            PageControl(model: model, pageCount: pageCount)
                .place(layout.pageControlFrame)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(touchMoved).onEnded(touchEnded))
    }

    private func app(at point: CGPoint) -> Int? {
        let range = pageRange
        for (slot, app) in range.enumerated() where layout.iconFrame(slot: slot).contains(point) {
            return app
        }
        return nil
    }

    private func touchMoved(_ value: DragGesture.Value) {
        if dragStart == nil {
            // Only touches that start in the grid, not on the page control.
            guard layout.gridFrame.contains(value.startLocation),
                  !layout.pageControlFrame.contains(value.startLocation)
            else {
                return
            }
            dragStart = value.startLocation
            model.pressedApp = app(at: value.startLocation)
        }
        if abs(value.location.x - value.startLocation.x) > 50 {
            model.pressedApp = nil
        }
    }

    private func touchEnded(_ value: DragGesture.Value) {
        defer {
            dragStart = nil
        }
        guard dragStart != nil else {
            return
        }
        let dx = value.location.x - value.startLocation.x
        let pressed = model.pressedApp
        if dx > 50 {
            model.pressedApp = nil
            model.page = max(model.page - 1, 0)
        } else if dx < -50 {
            model.pressedApp = nil
            model.page = min(model.page + 1, pageCount - 1)
        } else if let pressed, app(at: value.location) == pressed {
            // Stays highlighted while the app starts.
            model.pick(pressed)
        } else {
            model.pressedApp = nil
        }
    }
}

struct PageControl: View {
    @ObservedObject var model: PickerModel
    let pageCount: Int
    private let dotSpacing: CGFloat = 15

    var body: some View {
        // Like UIPageControl's hidesForSinglePage: one dot says nothing.
        if pageCount > 1 {
            GeometryReader { geometry in
                let startX = geometry.size.width / 2 - CGFloat(pageCount - 1) * dotSpacing / 2
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(0..<pageCount, id: \.self) { i in
                        let current = i == model.page
                        Circle()
                            .fill(Color.white.opacity(current ? 1 : 0.5))
                            .frame(width: current ? 7 : 5, height: current ? 7 : 5)
                            .position(
                                x: (startX + CGFloat(i) * dotSpacing).rounded(),
                                y: (geometry.size.height / 2).rounded()
                            )
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    tapped(at: value.location.x, startX: startX)
                })
            }
        }
    }

    // A tap on a dot goes to its page. The dots are too small to hit
    // reliably, so like UIPageControl, a tap anywhere else goes one page
    // back or forward, depending on which side of the current dot it's on.
    private func tapped(at x: CGFloat, startX: CGFloat) {
        let nearest = ((x - startX) / dotSpacing).rounded()
        if nearest >= 0 && Int(nearest) < pageCount
            && abs(x - (startX + nearest * dotSpacing)) <= dotSpacing / 2 {
            model.page = Int(nearest)
        } else if x < startX + CGFloat(model.page) * dotSpacing {
            model.page = max(model.page - 1, 0)
        } else {
            model.page = min(model.page + 1, pageCount - 1)
        }
    }
}

/// White rounded rectangles, like UIButtonTypeRoundedRect.
struct ButtonRow: View {
    let titles: [String]
    let frames: [CGRect]
    let actions: [() -> Void]
    var fontSize: CGFloat = 17
    var colors: [Color]? = nil
    var hidden: [Bool]? = nil
    var textColor: Color = .black

    var body: some View {
        ForEach(titles.indices, id: \.self) { i in
            if !(hidden?[i] ?? false) {
                Button(action: actions[i]) {
                    Text(titles[i])
                        .font(.system(size: fontSize))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .frame(width: frames[i].width, height: frames[i].height)
                        .background(colors?[i] ?? .white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .place(frames[i])
            }
        }
    }
}

/// A standard iOS settings sheet. The options apply to the next app opened.
struct QuickOptionsView: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        NavigationStack {
            Form {
                ForEach(model.input.quickOptions.indices, id: \.self) { i in
                    section(i)
                }
            }
            .navigationTitle("Quick Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Since iOS 26, Done is a checkmark in a glass circle.
                    if #available(iOS 26, *) {
                        Button(role: .confirm) {
                            model.showingQuickOptions = false
                        }
                    } else {
                        Button("Done") {
                            model.showingQuickOptions = false
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section(_ i: Int) -> some View {
        let option = model.input.quickOptions[i]
        let value = $model.quickOptionValues[i]
        if let choices = option.choices {
            Section {
                Picker(option.label, selection: value) {
                    ForEach(choices.indices, id: \.self) { j in
                        Text(choices[j]).tag(j)
                    }
                }
                .modifier(ChoiceStyle(choices: choices))
                .labelsHidden()
            } header: {
                Text(option.label)
            } footer: {
                footer(option)
            }
        } else {
            Section {
                Toggle(option.label, isOn: Binding(
                    get: { value.wrappedValue != 0 },
                    set: { value.wrappedValue = $0 ? 1 : 0 }
                ))
            } footer: {
                footer(option)
            }
        }
    }

    @ViewBuilder
    private func footer(_ option: PickerInput.QuickOption) -> some View {
        if !option.footer.isEmpty {
            Text(option.footer)
        }
    }
}

/// Short choices fit side by side; longer ones are a list with a checkmark.
struct ChoiceStyle: ViewModifier {
    let choices: [String]

    func body(content: Content) -> some View {
        if choices.allSatisfy({ $0.count <= 7 }) {
            content.pickerStyle(.segmented)
        } else {
            content.pickerStyle(.inline)
        }
    }
}

struct CopyrightView: View {
    @ObservedObject var model: PickerModel
    let layout: PickerLayout

    private static let font = UIFont.systemFont(ofSize: 16)

    var body: some View {
        // The background covers the whole screen, but the contents stay in
        // the safe area, clear of the Dynamic Island and home indicator.
        let insets = layout.insets
        let safeHeight = layout.size.height - insets.top - insets.bottom
        let width = layout.size.width
        let divider = safeHeight - 40
        let textFrame = CGRect(x: 10, y: insets.top + 10, width: width - 20, height: divider - 20)
        let pages = copyrightPages(for: textFrame.size)
        let page = min(model.copyrightPage, pages.count - 1)

        ZStack(alignment: .topLeading) {
            Color.black
            Text(pages[page])
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: textFrame.width, height: textFrame.height, alignment: .topLeading)
                .place(textFrame)
            ButtonRow(
                titles: ["↑", "↓", "×"],
                frames: layout.buttonFrames(
                    count: 3,
                    center: insets.top + (safeHeight + divider) / 2,
                    width: width
                ),
                actions: [
                    { model.copyrightPage = max(page - 1, 0) },
                    { model.copyrightPage = min(page + 1, pages.count - 1) },
                    { model.showingCopyright = false },
                ],
                fontSize: 30,
                colors: [.clear, .clear, .clear],
                hidden: [page == 0, page == pages.count - 1, false],
                textColor: .white
            )
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func copyrightPages(for size: CGSize) -> [String] {
        if model.copyrightPages.isEmpty {
            model.copyrightPages = paginate(model.input.copyright, size: size)
        }
        return model.copyrightPages
    }

    /// Splits the text into pages that fit, breaking before "###" headings
    /// and after "---" dividers.
    private func paginate(_ text: String, size: CGSize) -> [String] {
        func height(_ line: Substring) -> CGFloat {
            let line = line.hasSuffix("\n") ? line.dropLast() : line
            if line.isEmpty {
                return Self.font.lineHeight
            }
            return (String(line) as NSString).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin,
                attributes: [.font: Self.font],
                context: nil
            ).height.rounded(.up)
        }

        var lines: [Substring] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n").map { text.index(after: $0) }
                ?? text.endIndex
            lines.append(text[lineStart..<lineEnd])
            lineStart = lineEnd
        }

        var pages: [String] = []
        var i = 0
        while i < lines.count {
            // Pages don't start with blank lines.
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
            }
            var page = ""
            var pageHeight: CGFloat = 0
            let pageStart = i
            while i < lines.count {
                let line = lines[i]
                let isFirstLine = i == pageStart
                if !isFirstLine && line.hasPrefix("###") {
                    break
                }
                let lineHeight = height(line)
                if !isFirstLine && pageHeight + lineHeight > size.height {
                    break
                }
                page += line
                pageHeight += lineHeight
                i += 1
                if !isFirstLine && line.hasPrefix("---") {
                    break
                }
            }
            if !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(page)
            }
        }
        return pages.isEmpty ? [""] : pages
    }
}
