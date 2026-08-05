#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 1320
private let canvasHeight = 2868
private let canvasSize = NSSize(width: canvasWidth, height: canvasHeight)
private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let arguments = CommandLine.arguments
private let isEnglish = arguments.contains("--english")

private func argumentValue(named name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private let requestedSize = argumentValue(named: "--size") ?? "1284x2778"
private let exportWidth = requestedSize == "1242x2688" ? 1242 : 1284
private let exportHeight = requestedSize == "1242x2688" ? 2688 : 2778
private let exportSize = NSSize(width: exportWidth, height: exportHeight)

private let backgroundURL = root.appendingPathComponent(
    "AppStore/screenshots/assets/automotive-background-v2.png"
)
private let iconURL = root.appendingPathComponent(
    "App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
)
private let sourceDirectory = root.appendingPathComponent("AppStore/screenshots/it-IT")
private let outputDirectory = root.appendingPathComponent(
    argumentValue(named: "--output")
        ?? (isEnglish ? "AppStore/screenshots/en-GB-v2" : "AppStore/screenshots/it-IT-v2")
)
private let carPlayDashboardURL = root.appendingPathComponent(
    "AppStore/screenshots/assets/carplay-dashboard-current.png"
)
private let carPlayNotificationStartURL = root.appendingPathComponent(
    "AppStore/screenshots/assets/carplay-notification-start.png"
)
private let carPlayNotificationEndURL = root.appendingPathComponent(
    "AppStore/screenshots/assets/carplay-notification-end.png"
)

private let white = NSColor(calibratedWhite: 0.98, alpha: 1)
private let secondary = NSColor(calibratedWhite: 0.78, alpha: 1)
private let red = NSColor(calibratedRed: 1.0, green: 0.20, blue: 0.24, alpha: 1)
private let orange = NSColor(calibratedRed: 1.0, green: 0.53, blue: 0.12, alpha: 1)
private let cyan = NSColor(calibratedRed: 0.05, green: 0.74, blue: 1.0, alpha: 1)
private let green = NSColor(calibratedRed: 0.12, green: 0.88, blue: 0.35, alpha: 1)
private let yellow = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.08, alpha: 1)
private let blue = NSColor(calibratedRed: 0.08, green: 0.58, blue: 1.0, alpha: 1)

private func copy(_ italian: String, _ english: String) -> String {
    isEnglish ? english : italian
}

private func image(at url: URL) -> NSImage {
    guard let image = NSImage(contentsOf: url) else {
        fatalError("Cannot load image: \(url.path)")
    }
    return image
}

private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded),
          let rounded = NSFont(descriptor: descriptor, size: size)
    else {
        return base
    }
    return rounded
}

private func topRect(
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    height: CGFloat
) -> NSRect {
    NSRect(
        x: x,
        y: CGFloat(canvasHeight) - top - height,
        width: width,
        height: height
    )
}

private func aspectFillSource(imageSize: NSSize, destination: NSRect) -> NSRect {
    let targetRatio = destination.width / destination.height
    let imageRatio = imageSize.width / imageSize.height
    if imageRatio > targetRatio {
        let width = imageSize.height * targetRatio
        return NSRect(
            x: (imageSize.width - width) / 2,
            y: 0,
            width: width,
            height: imageSize.height
        )
    }
    let height = imageSize.width / targetRatio
    return NSRect(
        x: 0,
        y: (imageSize.height - height) / 2,
        width: imageSize.width,
        height: height
    )
}

private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left,
    lineHeight: CGFloat? = nil,
    tracking: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    (text as NSString).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking,
        ]
    )
}

private func drawRoundedPanel(
    _ rect: NSRect,
    radius: CGFloat,
    fill: NSColor = NSColor(calibratedWhite: 0.08, alpha: 0.90),
    stroke: NSColor = NSColor.white.withAlphaComponent(0.16),
    shadowBlur: CGFloat = 32
) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    stroke.setStroke()
    path.lineWidth = 2
    path.stroke()
}

private func drawImageClipped(
    _ source: NSImage,
    in destination: NSRect,
    radius: CGFloat,
    sourceRect: NSRect? = nil
) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: destination, xRadius: radius, yRadius: radius).addClip()
    source.draw(
        in: destination,
        from: sourceRect ?? aspectFillSource(imageSize: source.size, destination: destination),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()
}

private func drawPhone(
    screenshotURL: URL,
    x: CGFloat = 118,
    top: CGFloat = 715,
    width: CGFloat = 1084
) {
    let screenshot = image(at: screenshotURL)
    let screenHeight = width * screenshot.size.height / screenshot.size.width
    let outer = topRect(x: x - 15, top: top - 15, width: width + 30, height: screenHeight + 30)
    drawRoundedPanel(
        outer,
        radius: 76,
        fill: NSColor(calibratedWhite: 0.01, alpha: 1),
        stroke: NSColor.white.withAlphaComponent(0.22),
        shadowBlur: 46
    )
    drawImageClipped(
        screenshot,
        in: topRect(x: x, top: top, width: width, height: screenHeight),
        radius: 62
    )
}

private func drawTintedSymbol(
    _ name: String,
    in rect: NSRect,
    color: NSColor,
    pointSize: CGFloat,
    weight: NSFont.Weight
) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return
    }
    let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: color)
    let configuration = sizeConfiguration.applying(colorConfiguration)
    let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
    configured.draw(
        in: rect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
}

private func drawWideScreenshot(
    _ screenshotURL: URL,
    top: CGFloat,
    label: String,
    accent: NSColor
) {
    let card = topRect(x: 82, top: top, width: 1156, height: 450)
    drawRoundedPanel(card, radius: 48, fill: .black, shadowBlur: 46)
    drawImageClipped(
        image(at: screenshotURL),
        in: card.insetBy(dx: 12, dy: 12),
        radius: 38
    )

    let labelRect = NSRect(x: card.minX + 30, y: card.maxY - 78, width: 340, height: 50)
    let labelPath = NSBezierPath(roundedRect: labelRect, xRadius: 25, yRadius: 25)
    NSColor.black.withAlphaComponent(0.78).setFill()
    labelPath.fill()
    accent.withAlphaComponent(0.72).setStroke()
    labelPath.lineWidth = 2
    labelPath.stroke()
    drawText(
        label,
        in: NSRect(x: labelRect.minX + 20, y: labelRect.minY + 11, width: labelRect.width - 40, height: 31),
        font: roundedFont(size: 21, weight: .bold),
        color: white,
        alignment: .center,
        tracking: 2
    )
}

private func drawPill(
    _ text: String,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    color: NSColor,
    symbol: String? = nil
) {
    let rect = topRect(x: x, top: top, width: width, height: 82)
    let path = NSBezierPath(roundedRect: rect, xRadius: 41, yRadius: 41)
    color.withAlphaComponent(0.16).setFill()
    path.fill()
    color.withAlphaComponent(0.58).setStroke()
    path.lineWidth = 2
    path.stroke()

    var textX = rect.minX + 28
    if let symbol {
        drawTintedSymbol(
            symbol,
            in: NSRect(x: rect.minX + 23, y: rect.minY + 23, width: 36, height: 36),
            color: color,
            pointSize: 28,
            weight: .semibold
        )
        textX = rect.minX + 72
    }
    drawText(
        text,
        in: NSRect(x: textX, y: rect.minY + 20, width: rect.maxX - textX - 18, height: 42),
        font: roundedFont(size: 25, weight: .semibold),
        color: white
    )
}

private func drawFeaturePanel(
    top: CGFloat,
    title: String,
    body: String,
    accent: NSColor,
    symbol: String,
    pills: [(String, String?)] = []
) {
    let height: CGFloat = pills.isEmpty ? 300 : 410
    let rect = topRect(x: 82, top: top, width: 1156, height: height)
    drawRoundedPanel(rect, radius: 48)

    drawTintedSymbol(
        symbol,
        in: NSRect(x: rect.minX + 42, y: rect.maxY - 102, width: 58, height: 58),
        color: accent,
        pointSize: 44,
        weight: .bold
    )
    drawText(
        title,
        in: NSRect(x: rect.minX + 120, y: rect.maxY - 112, width: rect.width - 165, height: 72),
        font: roundedFont(size: 43, weight: .bold),
        color: white
    )
    drawText(
        body,
        in: NSRect(x: rect.minX + 42, y: rect.maxY - 245, width: rect.width - 84, height: 112),
        font: roundedFont(size: 31, weight: .medium),
        color: secondary,
        lineHeight: 40
    )

    guard !pills.isEmpty else { return }
    let gap: CGFloat = 16
    let totalGap = gap * CGFloat(pills.count - 1)
    let width = (rect.width - 84 - totalGap) / CGFloat(pills.count)
    for (index, pill) in pills.enumerated() {
        drawPill(
            pill.0,
            x: rect.minX + 42 + CGFloat(index) * (width + gap),
            top: CGFloat(canvasHeight) - rect.minY - 92,
            width: width,
            color: accent,
            symbol: pill.1
        )
    }
}

private func drawStatusLegend(top: CGFloat) {
    let rect = topRect(x: 82, top: top, width: 1156, height: 340)
    drawRoundedPanel(rect, radius: 48)
    drawText(
        copy("UN COLORE. UNA DECISIONE.", "ONE COLOUR. ONE DECISION."),
        in: NSRect(x: rect.minX + 42, y: rect.maxY - 88, width: rect.width - 84, height: 48),
        font: roundedFont(size: 28, weight: .bold),
        color: white,
        tracking: 2.5
    )

    let items: [(String, NSColor)] = [
        (copy("BASSO", "LOW"), green),
        (copy("VICINO", "NEAR"), yellow),
        (copy("IMMINENTE", "IMMINENT"), red),
        (copy("ATTIVA", "ACTIVE"), blue),
    ]
    let itemWidth = (rect.width - 84) / 4
    for (index, item) in items.enumerated() {
        let x = rect.minX + 42 + CGFloat(index) * itemWidth
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + 128, width: 58, height: 58))
        item.1.setFill()
        dot.fill()
        drawText(
            item.0,
            in: NSRect(x: x, y: rect.minY + 64, width: itemWidth - 12, height: 44),
            font: roundedFont(size: 23, weight: .bold),
            color: secondary
        )
    }
}

private func drawBase(
    kicker: String,
    title: String,
    subtitle: String,
    accent: NSColor
) {
    let background = image(at: backgroundURL)
    let destination = NSRect(origin: .zero, size: canvasSize)
    background.draw(
        in: destination,
        from: aspectFillSource(imageSize: background.size, destination: destination),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSColor.black.withAlphaComponent(0.25).setFill()
    destination.fill()

    let topWash = NSGradient(colors: [accent.withAlphaComponent(0.23), .clear])!
    topWash.draw(
        in: topRect(x: 0, top: 0, width: CGFloat(canvasWidth), height: 970),
        angle: -90
    )

    let iconRect = topRect(x: 82, top: 70, width: 74, height: 74)
    drawImageClipped(image(at: iconURL), in: iconRect, radius: 17)
    drawText(
        "ALPHA DPF MONITOR",
        in: topRect(x: 181, top: 84, width: 720, height: 48),
        font: roundedFont(size: 29, weight: .bold),
        color: white,
        tracking: 3.8
    )

    drawText(
        kicker.uppercased(),
        in: topRect(x: 82, top: 205, width: 1156, height: 44),
        font: roundedFont(size: 28, weight: .bold),
        color: accent,
        tracking: 4.2
    )
    drawText(
        title,
        in: topRect(x: 82, top: 272, width: 1156, height: 220),
        font: roundedFont(size: 86, weight: .heavy),
        color: white,
        lineHeight: 92
    )
    drawText(
        subtitle,
        in: topRect(x: 82, top: 515, width: 1156, height: 120),
        font: roundedFont(size: 38, weight: .medium),
        color: secondary,
        lineHeight: 49
    )
}

private func render(
    filename: String,
    kicker: String,
    title: String,
    subtitle: String,
    accent: NSColor,
    content: () -> Void
) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasWidth,
        pixelsHigh: canvasHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create screenshot canvas")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawBase(kicker: kicker, title: title, subtitle: subtitle, accent: accent)
    content()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let renderedImage = NSImage(size: canvasSize)
    renderedImage.addRepresentation(bitmap)
    guard let exportBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: exportWidth,
        pixelsHigh: exportHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let exportContext = NSGraphicsContext(bitmapImageRep: exportBitmap) else {
        fatalError("Unable to resize \(filename)")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = exportContext
    exportContext.imageInterpolation = .high
    renderedImage.draw(
        in: NSRect(origin: .zero, size: exportSize),
        from: NSRect(origin: .zero, size: canvasSize),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    exportContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = exportBitmap.representation(
        using: .jpeg,
        properties: [.compressionFactor: 0.95]
    ) else {
        fatalError("Unable to encode \(filename)")
    }
    try! data.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

render(
    filename: "01-dpf-finalmente-chiaro.jpg",
    kicker: copy("DPF in tempo reale", "Live DPF data"),
    title: copy("Il DPF,\nfinalmente chiaro.", "Your DPF,\nmade clear."),
    subtitle: copy("Carico, temperatura e rigenerazione in un solo colpo d’occhio.", "Load, temperature and regeneration in one clear view."),
    accent: green
) {
    drawPhone(screenshotURL: sourceDirectory.appendingPathComponent("01-dashboard-pulito.jpg"))
    drawFeaturePanel(
        top: 2368,
        title: copy("I dati che servono davvero", "The data that matters"),
        body: copy("Letture essenziali dalla centralina, organizzate per capire subito cosa sta succedendo.", "Essential ECU readings, organised to show what is happening straight away."),
        accent: cyan,
        symbol: "gauge.with.dots.needle.67percent",
        pills: [
            (copy("CARICO", "LOAD"), "circle.dotted"),
            (copy("SCARICO", "EXHAUST"), "thermometer.medium"),
            ("REGEN", "arrow.triangle.2.circlepath"),
        ]
    )
}

render(
    filename: "02-sai-quando-rigenera.jpg",
    kicker: copy("Stato immediato", "Instant status"),
    title: copy("Sai prima\nquando rigenera.", "Know when\nregen is near."),
    subtitle: copy("Il colore cambia con il carico e rende ogni stato impossibile da ignorare.", "Colour follows DPF load, making every state easy to recognise."),
    accent: red
) {
    drawPhone(screenshotURL: sourceDirectory.appendingPathComponent("02-carico-elevato.jpg"))
    drawStatusLegend(top: 2415)
}

render(
    filename: "03-avvisi-rigenerazione.jpg",
    kicker: copy("Avvisi reali, anche su CarPlay", "Real alerts, also on CarPlay"),
    title: copy("La rigenerazione\nnon passa inosservata.", "Regeneration\nnever goes unnoticed."),
    subtitle: copy("Sai quando inizia e quando termina, senza distogliere lo sguardo dalla strada.", "Know when it starts and ends, without taking your eyes off the road."),
    accent: orange
) {
    drawWideScreenshot(
        carPlayNotificationStartURL,
        top: 735,
        label: copy("INIZIO REGEN", "REGEN STARTED"),
        accent: orange
    )
    drawWideScreenshot(
        carPlayNotificationEndURL,
        top: 1275,
        label: copy("REGEN TERMINATA", "REGEN COMPLETE"),
        accent: green
    )
    drawFeaturePanel(
        top: 1820,
        title: copy("Ti avvisa nel momento giusto", "Alerts at the right time"),
        body: copy("Notifiche locali di inizio e fine, con stato disponibile anche tramite Live Activity e Dynamic Island.", "Local start and finish alerts, with status also visible through Live Activity and Dynamic Island."),
        accent: orange,
        symbol: "bell.badge.fill",
        pills: [
            (copy("NOTIFICHE", "ALERTS"), "bell.fill"),
            ("LIVE ACTIVITY", "bolt.horizontal.fill"),
            ("DYNAMIC ISLAND", "capsule.fill"),
        ]
    )
}

render(
    filename: "04-carplay.jpg",
    kicker: copy("Dashboard dedicata", "Dedicated dashboard"),
    title: copy("Il DPF arriva\nsu CarPlay.", "Your DPF,\non CarPlay."),
    subtitle: copy("Informazioni essenziali, grandi e leggibili sul display dell’auto.", "Essential information, large and readable on your car display."),
    accent: cyan
) {
    drawWideScreenshot(
        carPlayDashboardURL,
        top: 755,
        label: "CARPLAY DASHBOARD",
        accent: cyan
    )

    drawFeaturePanel(
        top: 1320,
        title: copy("Pensata per uno sguardo", "Made for a glance"),
        body: copy("DPF con un decimale, distanza dall’ultima rigenerazione, scarico, olio e batteria in una sola schermata.", "One-decimal DPF load, distance since regeneration, exhaust, oil and battery in one view."),
        accent: cyan,
        symbol: "car.fill",
        pills: [
            (copy("DPF A COLORI", "DPF COLOUR"), "circle.hexagongrid.fill"),
            (copy("AVVISI", "ALERTS"), "bell.fill"),
            (copy("CONNESSIONE", "CONNECTION"), "link"),
        ]
    )

    drawFeaturePanel(
        top: 1850,
        title: copy("Prima la sicurezza", "Safety first"),
        body: copy("DPF a colori, rigenerazione illuminata e avvisi progettati per mostrare solo ciò che serve durante la guida.", "Colour DPF, illuminated regeneration and alerts designed to show only what you need while driving."),
        accent: orange,
        symbol: "exclamationmark.triangle.fill"
    )
}

render(
    filename: "05-provala-senza-auto.jpg",
    kicker: copy("Laboratorio integrato", "Built-in test lab"),
    title: copy("Provala anche\nsenza automobile.", "Try it,\neven without a car."),
    subtitle: copy("Verifica interfaccia, banner, suono e ciclo completo prima di collegarti.", "Check the interface, banner, sound and full cycle before you connect."),
    accent: cyan
) {
    drawPhone(screenshotURL: sourceDirectory.appendingPathComponent("04-laboratorio-test.jpg"))
    drawFeaturePanel(
        top: 2370,
        title: copy("Testa tutto in otto secondi", "Test it all in eight seconds"),
        body: copy("Scenari ripetibili per conoscere l’app e controllare gli avvisi con calma.", "Repeatable scenarios to get to know the app and check alerts at your own pace."),
        accent: cyan,
        symbol: "play.circle.fill",
        pills: [
            (copy("CICLO", "CYCLE"), "arrow.clockwise"),
            ("BANNER", "rectangle.topthird.inset.filled"),
            (copy("SUONO", "SOUND"), "speaker.wave.2.fill"),
        ]
    )
}

render(
    filename: "06-privacy-compatibilita.jpg",
    kicker: copy("Semplice per davvero", "Simple by design"),
    title: copy("Nessun account.\nNessun tracking.", "No account.\nNo tracking."),
    subtitle: copy("I dati diagnostici restano sul dispositivo. Senza pubblicità né analytics.", "Diagnostic data stays on your device. No ads, no analytics."),
    accent: red
) {
    drawPhone(screenshotURL: sourceDirectory.appendingPathComponent("05-sicurezza-privacy-supporto.jpg"))
    drawFeaturePanel(
        top: 2295,
        title: copy("Compatibilità dichiarata", "Compatibility, stated clearly"),
        body: copy("Per veicoli diesel FCA compatibili, incluse Giulia e Stelvio 2.2 con adattatore ELM327 Bluetooth LE supportato.", "For compatible FCA diesel vehicles, including Giulia and Stelvio 2.2 with a supported ELM327 Bluetooth LE adapter."),
        accent: red,
        symbol: "checkmark.shield.fill",
        pills: [
            (copy("LOCALE", "LOCAL"), "iphone"),
            (copy("NO ADV", "NO ADS"), "hand.raised.fill"),
            ("NO ACCOUNT", "person.crop.circle.badge.xmark"),
        ]
    )
}

let languageName = isEnglish ? "English" : "Italian"
print("Generated 6 \(languageName) App Store screenshots in \(outputDirectory.path) at \(exportWidth)×\(exportHeight)")
