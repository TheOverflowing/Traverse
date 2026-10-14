import Foundation

public struct LauncherFolder: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var applicationIDs: [String]

    public init(id: String, name: String, applicationIDs: [String]) {
        self.id = id
        self.name = name
        self.applicationIDs = applicationIDs
    }
}

public struct LauncherLayout: Codable, Sendable, Equatable {
    public static let columns = 6
    public static let rows = 3
    public static let capacity = columns * rows

    public private(set) var placements: [String: Int]
    public private(set) var folders: [LauncherFolder]

    public init(placements: [String: Int] = [:], folders: [LauncherFolder] = []) {
        self.placements = placements
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey { case placements, folders }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        placements = try values.decode([String: Int].self, forKey: .placements)
        folders = try values.decodeIfPresent([LauncherFolder].self, forKey: .folders) ?? []
    }

    @discardableResult
    public mutating func reconcile(applicationIDs: [String]) -> Bool {
        var seenIDs = Set<String>()
        let ids = applicationIDs.filter { !$0.hasPrefix("folder:") && seenIDs.insert($0).inserted }
        let available = Set(ids)
        var folderIDs = Set<String>()
        var members = Set<String>()
        var updatedFolders: [LauncherFolder] = []
        for folder in folders where folder.id.hasPrefix("folder:") && folderIDs.insert(folder.id).inserted {
            let existingMembers = folder.applicationIDs.filter { available.contains($0) && members.insert($0).inserted }
            if !existingMembers.isEmpty {
                updatedFolders.append(LauncherFolder(id: folder.id, name: folder.name, applicationIDs: existingMembers))
            }
        }
        let itemIDs = ids.filter { !members.contains($0) } + updatedFolders.map(\.id)
        var updated: [String: Int] = [:]
        var occupied = Set<Int>()

        for id in itemIDs {
            if let slot = placements[id], slot >= 0, occupied.insert(slot).inserted {
                updated[id] = slot
            }
        }

        var nextSlot = 0
        for id in itemIDs where updated[id] == nil {
            while occupied.contains(nextSlot) { nextSlot += 1 }
            updated[id] = nextSlot
            occupied.insert(nextSlot)
        }

        let changed = placements != updated || folders != updatedFolders
        placements = updated
        folders = updatedFolders
        return changed
    }

    public mutating func move(applicationID: String, to slot: Int) {
        move(itemID: applicationID, to: slot)
    }

    public mutating func move(itemID: String, to slot: Int) {
        guard slot >= 0 else { return }
        if let source = placements[itemID], source >= 0 {
            guard source != slot else { return }
            if let occupant = self.itemID(at: slot) {
                placements[occupant] = source
            }
            placements[itemID] = slot
        } else if !itemID.hasPrefix("folder:"), folderID(containing: itemID) != nil {
            detachApplication(itemID)
            let occupant = self.itemID(at: slot)
            if let occupant { placements.removeValue(forKey: occupant) }
            placements[itemID] = slot
            if let occupant { placements[occupant] = firstVacantSlot() }
        }
    }

    public func folder(id: String) -> LauncherFolder? {
        folders.first { $0.id == id }
    }

    public func folderID(containing applicationID: String) -> String? {
        folders.first { $0.applicationIDs.contains(applicationID) }?.id
    }

    public func position(of applicationID: String) -> Int? {
        if let folderID = folderID(containing: applicationID) { return placements[folderID] }
        return placements[applicationID]
    }

    @discardableResult
    public mutating func createFolder(applicationID: String, on targetID: String, name: String = "Folder") -> String? {
        guard applicationID != targetID, !applicationID.hasPrefix("folder:"), !targetID.hasPrefix("folder:"),
              placements[applicationID] != nil || folderID(containing: applicationID) != nil,
              let slot = placements[targetID], slot >= 0 else { return nil }
        detachApplication(applicationID)
        placements.removeValue(forKey: targetID)
        let id = "folder:\(UUID().uuidString.lowercased())"
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders.append(LauncherFolder(id: id, name: title.isEmpty ? "Folder" : title,
            applicationIDs: [targetID, applicationID]))
        placements[id] = slot
        return id
    }

    public mutating func add(applicationID: String, toFolder folderID: String) {
        guard !applicationID.hasPrefix("folder:"), folder(id: folderID) != nil,
              self.folderID(containing: applicationID) != folderID,
              placements[applicationID] != nil || self.folderID(containing: applicationID) != nil else { return }
        detachApplication(applicationID)
        if let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].applicationIDs.append(applicationID)
        }
    }

    public mutating func renameFolder(id: String, name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = title
    }

    public mutating func reorder(applicationID: String, inFolder folderID: String, to index: Int) {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              let source = folders[folderIndex].applicationIDs.firstIndex(of: applicationID) else { return }
        folders[folderIndex].applicationIDs.remove(at: source)
        let destination = min(max(0, index), folders[folderIndex].applicationIDs.count)
        folders[folderIndex].applicationIDs.insert(applicationID, at: destination)
    }

    public mutating func dissolveFolder(id: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let applications = folders.remove(at: index).applicationIDs
        let slot = placements.removeValue(forKey: id)
        for (index, applicationID) in applications.enumerated() {
            if index == 0, let slot, slot >= 0, itemID(at: slot) == nil {
                placements[applicationID] = slot
            } else {
                placements[applicationID] = firstVacantSlot()
            }
        }
    }

    public func pageCount(for applicationIDs: [String]) -> Int {
        let lastSlot = applicationIDs.compactMap { position(of: $0) }.filter { $0 >= 0 }.max() ?? 0
        return lastSlot / Self.capacity + 1
    }

    public func isPageEmpty(_ page: Int) -> Bool {
        !placements.values.contains { $0 / Self.capacity == page }
    }

    public mutating func deleteEmptyPage(_ page: Int) {
        guard page >= 0, isPageEmpty(page) else { return }
        for (id, slot) in placements where slot / Self.capacity > page {
            placements[id] = slot - Self.capacity
        }
    }

    public func applicationID(at slot: Int) -> String? {
        guard let id = itemID(at: slot), !id.hasPrefix("folder:") else { return nil }
        return id
    }

    public func itemID(at slot: Int) -> String? {
        guard slot >= 0 else { return nil }
        return placements.first { $0.value == slot }?.key
    }

    private mutating func detachApplication(_ applicationID: String) {
        placements.removeValue(forKey: applicationID)
        for index in folders.indices.reversed() {
            folders[index].applicationIDs.removeAll { $0 == applicationID }
            if folders[index].applicationIDs.isEmpty {
                placements.removeValue(forKey: folders[index].id)
                folders.remove(at: index)
            }
        }
    }

    private func firstVacantSlot() -> Int {
        let occupied = Set(placements.values)
        var slot = 0
        while occupied.contains(slot) { slot += 1 }
        return slot
    }

    public static func load(from paths: TraversePaths) throws -> Self {
        let url = storageURL(in: paths)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to paths: TraversePaths) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.storageURL(in: paths), options: .atomic)
    }

    private static func storageURL(in paths: TraversePaths) -> URL {
        paths.root.appendingPathComponent("launcher-layout.json")
    }
}
