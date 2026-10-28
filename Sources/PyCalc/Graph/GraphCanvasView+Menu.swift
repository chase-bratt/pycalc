import AppKit
import PyCalcCore
import UniformTypeIdentifiers

/// Right-click menu: copy or save the graph as an image, copy a point, reset.
extension GraphCanvasView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let point = coordinate(near: location) {
            let item = NSMenuItem(title: "Copy Point \(point)", action: #selector(copyPointFromMenu(_:)), keyEquivalent: "")
            item.representedObject = point
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(item("Copy Image", #selector(copyImage)))
        menu.addItem(item("Save as PNG…", #selector(saveImage)))
        menu.addItem(.separator())
        let showAll = item("Show All Plots", #selector(showAllPlots))
        showAll.isEnabled = !hiddenPlots.isEmpty
        menu.addItem(showAll)
        menu.addItem(item("Reset View", #selector(resetViewFromMenu)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// "(x, y)" of the point of interest or curve under the pointer, if any.
    private func coordinate(near location: CGPoint) -> String? {
        if let poi = nearestPOI(to: location) {
            return "(\(NumberFormat.coordinate(poi.x)), \(NumberFormat.coordinate(poi.y)))"
        }
        if let hit = hitTest(location, geometry: visibleFunctionGeometry()) {
            return "(\(NumberFormat.coordinate(hit.x)), \(NumberFormat.coordinate(hit.y)))"
        }
        return nil
    }

    @objc private func copyPointFromMenu(_ sender: NSMenuItem) {
        guard let point = sender.representedObject as? String else { return }
        controller?.onCopy?(point)
    }

    /// The graph as rendered, without the hover marker.
    func snapshot() -> NSImage? {
        let savedHover = hover
        hover = nil
        defer { hover = savedHover; needsDisplay = true }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    @objc private func copyImage() {
        guard let image = snapshot() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        controller?.onToast?("Copied graph")
    }

    @objc private func saveImage() {
        guard let image = snapshot(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Graph.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func showAllPlots() {
        controller?.onShowAll?()
    }

    @objc private func resetViewFromMenu() {
        animateHome()
    }
}
