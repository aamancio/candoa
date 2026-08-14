import CloudKit
import CoreData
import Foundation
import Security

struct PersistenceSyncConfiguration: Equatable {
    static let cloudKitContainerIdentifier = "iCloud.app.candoa.browser"

    var syncsWorkspaceWithICloud: Bool
    var syncsHistoryWithICloud: Bool
    var cloudKitContainerIdentifier: String

    /// Sync is not a choice: whenever the build carries the CloudKit
    /// entitlement, workspace and history mirror to the person's private
    /// iCloud database. No iCloud account signed in simply means the
    /// container has nothing to talk to. Not wanting a history record is
    /// what private windows are for.
    static var current: PersistenceSyncConfiguration {
        let canUseICloud = CloudKitEntitlements.hasConfiguredContainer
        return PersistenceSyncConfiguration(
            syncsWorkspaceWithICloud: canUseICloud,
            syncsHistoryWithICloud: canUseICloud,
            cloudKitContainerIdentifier: cloudKitContainerIdentifier
        )
    }

    static var localOnly: PersistenceSyncConfiguration {
        PersistenceSyncConfiguration(
            syncsWorkspaceWithICloud: false,
            syncsHistoryWithICloud: false,
            cloudKitContainerIdentifier: cloudKitContainerIdentifier
        )
    }
}

enum CloudKitEntitlements {
    static var hasConfiguredContainer: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CANDOA_UI_TESTING"] == "1" {
            return environment["CANDOA_UI_TESTING_CLOUDKIT_ENTITLEMENT"] == "1"
        }

        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) else {
            return false
        }

        if let containers = value as? [String] {
            return containers.contains(PersistenceSyncConfiguration.cloudKitContainerIdentifier)
        }

        return false
    }
}

struct PersistenceService: @unchecked Sendable {
    static let shared = makeSharedService()
    static let remoteStoreDidChange = Notification.Name("Candoa.PersistenceService.RemoteStoreDidChange")

    private static let appName = "Candoa"

    private let container: NSPersistentContainer
    private let syncConfiguration: PersistenceSyncConfiguration
    private let remoteChangeObserver: NSObjectProtocol?

    var syncsWorkspaceWithICloud: Bool {
        syncConfiguration.syncsWorkspaceWithICloud
    }

    var syncsHistoryWithICloud: Bool {
        syncConfiguration.syncsHistoryWithICloud
    }

    private static func makeSharedService() -> PersistenceService {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CANDOA_UI_TESTING"] == "1" else {
            return PersistenceService()
        }

        let storeID = environment["CANDOA_UI_TESTING_STORE_ID"] ?? UUID().uuidString
        let safeStoreID = storeID.replacingOccurrences(of: "/", with: "-")
        let storeURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("CandoaUITests", isDirectory: true)
            .appendingPathComponent(safeStoreID, isDirectory: true)
            .appendingPathComponent("Candoa.sqlite")

        // Relaunch-persistence tests reuse the prior launch's store instead
        // of starting from an empty one.
        if environment["CANDOA_UI_TESTING_PRESERVES_STORE"] != "1" {
            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        }

        return PersistenceService(
            storeURL: storeURL,
            syncConfiguration: .localOnly
        )
    }

    init(
        storeURL: URL? = nil,
        syncConfiguration: PersistenceSyncConfiguration = .current
    ) {
        self.syncConfiguration = syncConfiguration
        let model = Self.makeModel()
        let usesCloudKit = syncConfiguration.syncsWorkspaceWithICloud || syncConfiguration.syncsHistoryWithICloud
        let container: NSPersistentContainer = usesCloudKit
            ? NSPersistentCloudKitContainer(name: "Candoa", managedObjectModel: model)
            : NSPersistentContainer(name: "Candoa", managedObjectModel: model)
        let storeURLs = Self.storeURLs(from: storeURL)

        container.persistentStoreDescriptions = [
            Self.storeDescription(
                url: storeURLs.session,
                configuration: StoreConfiguration.session,
                cloudKitContainerIdentifier: syncConfiguration.syncsWorkspaceWithICloud
                    ? syncConfiguration.cloudKitContainerIdentifier
                    : nil
            ),
            Self.storeDescription(
                url: storeURLs.history,
                configuration: StoreConfiguration.history,
                cloudKitContainerIdentifier: syncConfiguration.syncsHistoryWithICloud
                    ? syncConfiguration.cloudKitContainerIdentifier
                    : nil
            )
        ]

        do {
            try FileManager.default.createDirectory(
                at: storeURLs.session.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: storeURLs.history.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("\(Self.appName) failed to create persistence folder: \(error.localizedDescription)")
        }

        container.loadPersistentStores { _, error in
            if let error {
                NSLog("\(Self.appName) failed to load Core Data store: \(error.localizedDescription)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.transactionAuthor = Self.localTransactionAuthor

        self.container = container
        let tokenBox = HistoryTokenBox()
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { _ in
            Self.forwardRemoteChangeIfForeign(container: container, tokenBox: tokenBox)
        }

    }

    static let localTransactionAuthor = "app.candoa.browser.local"

    /// Reference holder for the history position: the service is a struct,
    /// so the observer closure needs shared mutable state across firings.
    private final class HistoryTokenBox: @unchecked Sendable {
        /// Transactions older than launch are already reflected in the
        /// initial load, so the first fetch never scans the full history.
        let startedAt = Date()

        private let lock = NSLock()
        private var token: NSPersistentHistoryToken?

        var current: NSPersistentHistoryToken? {
            lock.lock()
            defer { lock.unlock() }
            return token
        }

        func advance(to newToken: NSPersistentHistoryToken?) {
            guard let newToken else { return }
            lock.lock()
            defer { lock.unlock() }
            token = newToken
        }
    }

    /// NSPersistentStoreRemoteChange fires for this process's own saves as
    /// well as CloudKit imports. Forwarding our own saves as "remote state"
    /// made `applyRemoteStateIfNeeded` replay a just-stale workspace
    /// snapshot over live navigation — a click-driven page commit could be
    /// stomped back to the tab's previous URL within a second (the visible
    /// "click bounces back" bug). Filter through persistent history: only
    /// transactions authored by someone other than this app (CloudKit
    /// mirroring) count as remote.
    private static func forwardRemoteChangeIfForeign(
        container: NSPersistentContainer,
        tokenBox: HistoryTokenBox
    ) {
        let context = container.newBackgroundContext()
        context.transactionAuthor = localTransactionAuthor
        context.perform {
            let request = tokenBox.current.map(NSPersistentHistoryChangeRequest.fetchHistory(after:))
                ?? NSPersistentHistoryChangeRequest.fetchHistory(after: tokenBox.startedAt)
            guard
                let result = try? context.execute(request) as? NSPersistentHistoryResult,
                let transactions = result.result as? [NSPersistentHistoryTransaction]
            else {
                // History is unreadable — fail open so a real remote change
                // is never dropped; a spurious apply is a no-op when state
                // matches.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.remoteStoreDidChange, object: nil)
                }
                return
            }

            tokenBox.advance(to: transactions.last?.token)
            let hasForeignTransactions = transactions.contains {
                $0.author != localTransactionAuthor
            }
            guard hasForeignTransactions else { return }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.remoteStoreDidChange, object: nil)
            }
        }
    }

    private func makeBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.transactionAuthor = Self.localTransactionAuthor
        return context
    }

    private static func storeURLs(from baseStoreURL: URL?) -> (session: URL, history: URL) {
        guard let baseStoreURL else {
            return (
                applicationSupportURL.appendingPathComponent("CandoaSession.sqlite"),
                applicationSupportURL.appendingPathComponent("CandoaHistory.sqlite")
            )
        }

        let directory = baseStoreURL.deletingLastPathComponent()
        let baseName = baseStoreURL.deletingPathExtension().lastPathComponent
        return (
            directory.appendingPathComponent("\(baseName)-Session.sqlite"),
            directory.appendingPathComponent("\(baseName)-History.sqlite")
        )
    }

    private static func storeDescription(
        url: URL,
        configuration: String,
        cloudKitContainerIdentifier: String?
    ) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if let cloudKitContainerIdentifier {
            let options = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudKitContainerIdentifier
            )
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
        }

        return description
    }

    private static var applicationSupportURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(appName, isDirectory: true)
    }

    func loadState() -> BrowserWindowState? {
        loadCoreDataState()
    }

    func saveState(_ state: BrowserWindowState) {
        let context = makeBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        context.performAndWait {
            do {
                try upsert(state, in: context)
                try context.save()
            } catch {
                context.rollback()
                NSLog("\(Self.appName) failed to save session: \(error.localizedDescription)")
            }
        }
    }

    func recordVisit(title: String, url: URL, tabID: UUID, spaceID: UUID, visitedAt: Date = Date()) {
        let context = makeBackgroundContext()
        let visit = HistoryVisit(
            id: UUID(),
            title: title,
            url: url,
            tabID: tabID,
            spaceID: spaceID,
            visitedAt: visitedAt
        )

        context.perform {
            Self.insert(visit, in: context)

            do {
                try context.save()
            } catch {
                context.rollback()
                NSLog("\(Self.appName) failed to record history visit: \(error.localizedDescription)")
            }
        }
    }

    func recentHistory(
        matching rawQuery: String = "",
        in spaceID: UUID? = nil,
        limit: Int = 8
    ) -> [HistoryVisit] {
        guard limit > 0 else { return [] }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = container.viewContext

        return context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: Entity.historyVisit)
                request.sortDescriptors = [NSSortDescriptor(key: Key.visitedAt, ascending: false)]
                request.fetchLimit = max(limit * 4, limit)

                var predicates: [NSPredicate] = []

                if let spaceID {
                    predicates.append(NSPredicate(format: "%K == %@", Key.spaceID, spaceID as NSUUID))
                }

                if !query.isEmpty {
                    predicates.append(
                        NSCompoundPredicate(
                            orPredicateWithSubpredicates: [
                                NSPredicate(format: "%K CONTAINS[cd] %@", Key.title, query),
                                NSPredicate(format: "%K CONTAINS[cd] %@", Key.urlString, query)
                            ]
                        )
                    )
                }

                if predicates.count == 1 {
                    request.predicate = predicates[0]
                } else if !predicates.isEmpty {
                    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                }

                var seenURLs = Set<String>()
                var visits: [HistoryVisit] = []

                for visit in try context.fetch(request).compactMap(Self.historyVisit(from:)) {
                    let key = visit.url.absoluteString
                    guard !seenURLs.contains(key) else { continue }
                    seenURLs.insert(key)
                    visits.append(visit)

                    if visits.count == limit {
                        break
                    }
                }

                return visits
            } catch {
                NSLog("\(Self.appName) failed to load history: \(error.localizedDescription)")
                return []
            }
        }
    }

    func history(
        matching rawQuery: String = "",
        in spaceID: UUID? = nil,
        limit: Int,
        offset: Int = 0
    ) -> [HistoryVisit] {
        guard limit > 0, offset >= 0 else { return [] }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = makeBackgroundContext()

        return context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: Entity.historyVisit)
                request.sortDescriptors = [NSSortDescriptor(key: Key.visitedAt, ascending: false)]
                request.fetchLimit = limit
                request.fetchOffset = offset

                var predicates: [NSPredicate] = []
                if let spaceID {
                    predicates.append(NSPredicate(format: "%K == %@", Key.spaceID, spaceID as NSUUID))
                }
                if !query.isEmpty {
                    predicates.append(
                        NSCompoundPredicate(
                            orPredicateWithSubpredicates: [
                                NSPredicate(format: "%K CONTAINS[cd] %@", Key.title, query),
                                NSPredicate(format: "%K CONTAINS[cd] %@", Key.urlString, query)
                            ]
                        )
                    )
                }
                if predicates.count == 1 {
                    request.predicate = predicates[0]
                } else if !predicates.isEmpty {
                    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                }

                return try context.fetch(request).compactMap(Self.historyVisit(from:))
            } catch {
                NSLog("\(Self.appName) failed to load history: \(error.localizedDescription)")
                return []
            }
        }
    }

    func deleteHistory(withIDs ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try deleteHistory(.ids(ids))
    }

    func deleteHistory(visitedAfter startDate: Date?, in spaceID: UUID? = nil) throws {
        try deleteHistory(.visitedAfter(startDate, spaceID: spaceID))
    }

    /// Retention pruning: drops visits that fell out of the configured
    /// history window, across every Space. Returns how many were removed
    /// so the caller can skip UI refreshes on a no-op pass.
    @discardableResult
    func deleteHistory(visitedBefore cutoff: Date) throws -> Int {
        try deleteHistory(.visitedBefore(cutoff))
    }

    private enum HistoryDeletion: Sendable {
        case ids(Set<UUID>)
        case visitedAfter(Date?, spaceID: UUID?)
        case visitedBefore(Date)
    }

    @discardableResult
    private func deleteHistory(_ deletion: HistoryDeletion) throws -> Int {
        let context = makeBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        return try context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: Entity.historyVisit)
                // Deletion needs identity, not attribute data; skipping the
                // property fault matters for the retention prune, which can
                // sweep a year of visits in one pass.
                request.includesPropertyValues = false
                switch deletion {
                case .ids(let ids):
                    request.predicate = NSPredicate(format: "%K IN %@", Key.id, Array(ids))
                case .visitedAfter(let startDate, let spaceID):
                    var predicates: [NSPredicate] = []
                    if let startDate {
                        predicates.append(NSPredicate(format: "%K >= %@", Key.visitedAt, startDate as NSDate))
                    }
                    if let spaceID {
                        predicates.append(NSPredicate(format: "%K == %@", Key.spaceID, spaceID as NSUUID))
                    }
                    if predicates.count == 1 {
                        request.predicate = predicates[0]
                    } else if !predicates.isEmpty {
                        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                    }
                case .visitedBefore(let cutoff):
                    request.predicate = NSPredicate(format: "%K < %@", Key.visitedAt, cutoff as NSDate)
                }
                let expired = try context.fetch(request)
                for object in expired {
                    context.delete(object)
                }
                if context.hasChanges {
                    try context.save()
                }
                return expired.count
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private func loadCoreDataState() -> BrowserWindowState? {
        let context = container.viewContext
        return Self.loadCoreDataState(in: context)
    }

    private func upsert(_ state: BrowserWindowState, in context: NSManagedObjectContext) throws {
        let session = try fetchSession(in: context)
        session.setValue("main", forKey: Key.id)
        session.setValue(state.activeSpaceID, forKey: Key.activeSpaceID)
        session.setValue(state.activeTabID, forKey: Key.activeTabID)
        session.setValue(Self.encodeUUIDList(state.splitTabIDs), forKey: Key.splitTabIDs)
        session.setValue(Self.encodeDoubleList(state.splitPaneRatios), forKey: Key.splitPaneRatios)
        session.setValue(state.splitLayout, forKey: Key.splitLayout)
        session.setValue(state.isSplitViewEnabled, forKey: Key.isSplitViewEnabled)

        let existingSpaces = try fetchObjects(entityName: Entity.space, in: context)
        var spacesByID = Dictionary(
            uniqueKeysWithValues: existingSpaces.compactMap { object -> (UUID, NSManagedObject)? in
                guard let id = object.uuid(for: Key.id) else { return nil }
                return (id, object)
            }
        )

        for space in state.spaces {
            let object = spacesByID[space.id]
                ?? NSEntityDescription.insertNewObject(forEntityName: Entity.space, into: context)
            object.setValue(space.id, forKey: Key.id)
            object.setValue(space.name, forKey: Key.name)
            object.setValue(space.symbolName, forKey: Key.symbolName)
            object.setValue(space.themeColorHex, forKey: Key.themeColorHex)
            object.setValue(
                space.themeAuxiliaryColorHexes.isEmpty
                    ? nil
                    : space.themeAuxiliaryColorHexes.joined(separator: ","),
                forKey: Key.themeAuxiliaryColorHexes
            )
            object.setValue(space.themeAppearance.rawValue, forKey: Key.themeAppearance)
            object.setValue(space.themeOpacity, forKey: Key.themeOpacity)
            object.setValue(space.themeTexture, forKey: Key.themeTexture)
            object.setValue(space.dataStoreID, forKey: Key.dataStoreID)
            object.setValue(space.createdAt, forKey: Key.createdAt)
            spacesByID[space.id] = nil
        }

        for object in spacesByID.values {
            context.delete(object)
        }

        let existingFolders = try fetchObjects(entityName: Entity.folder, in: context)
        var foldersByID = Dictionary(
            uniqueKeysWithValues: existingFolders.compactMap { object -> (UUID, NSManagedObject)? in
                guard let id = object.uuid(for: Key.id) else { return nil }
                return (id, object)
            }
        )
        let spaceIDs = Set(state.spaces.map(\.id))
        let folderIDs = Set(state.folders.map(\.id))

        for folder in state.folders {
            guard spaceIDs.contains(folder.spaceID) else { continue }
            let object = foldersByID[folder.id]
                ?? NSEntityDescription.insertNewObject(forEntityName: Entity.folder, into: context)
            object.setValue(folder.id, forKey: Key.id)
            object.setValue(folder.name, forKey: Key.name)
            object.setValue(folder.spaceID, forKey: Key.spaceID)
            object.setValue(
                folder.parentFolderID.flatMap { folderIDs.contains($0) ? $0 : nil },
                forKey: Key.parentFolderID
            )
            object.setValue(folder.sortOrder, forKey: Key.sortOrder)
            object.setValue(folder.isExpanded, forKey: Key.isExpanded)
            foldersByID[folder.id] = nil
        }

        for object in foldersByID.values {
            context.delete(object)
        }

        let existingTabs = try fetchObjects(entityName: Entity.tab, in: context)
        var tabsByID = Dictionary(
            uniqueKeysWithValues: existingTabs.compactMap { object -> (UUID, NSManagedObject)? in
                guard let id = object.uuid(for: Key.id) else { return nil }
                return (id, object)
            }
        )
        for tab in state.tabs {
            guard spaceIDs.contains(tab.spaceID) else { continue }
            let object = tabsByID[tab.id]
                ?? NSEntityDescription.insertNewObject(forEntityName: Entity.tab, into: context)
            object.setValue(tab.id, forKey: Key.id)
            object.setValue(tab.title, forKey: Key.title)
            object.setValue(tab.url?.absoluteString, forKey: Key.urlString)
            object.setValue(tab.faviconSymbol, forKey: Key.faviconSymbol)
            object.setValue(tab.faviconData, forKey: Key.faviconData)
            object.setValue(tab.favoriteTitle, forKey: Key.favoriteTitle)
            object.setValue(tab.favoriteURL?.absoluteString, forKey: Key.favoriteURLString)
            object.setValue(tab.favoriteFaviconSymbol, forKey: Key.favoriteFaviconSymbol)
            object.setValue(tab.favoriteFaviconData, forKey: Key.favoriteFaviconData)
            object.setValue(tab.isFavorite, forKey: Key.isFavorite)
            object.setValue(tab.isPinned, forKey: Key.isPinned)
            object.setValue(tab.folderID.flatMap { folderIDs.contains($0) ? $0 : nil }, forKey: Key.folderID)
            object.setValue(tab.spaceID, forKey: Key.spaceID)
            object.setValue(tab.sortOrder, forKey: Key.sortOrder)
            object.setValue(tab.lastAccessedAt, forKey: Key.lastAccessedAt)
            object.setValue(tab.hasBeenActivated, forKey: Key.hasBeenActivated)
            tabsByID[tab.id] = nil
        }

        for object in tabsByID.values {
            context.delete(object)
        }
    }

    private func fetchSession(in context: NSManagedObjectContext) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: Entity.session)
        request.predicate = NSPredicate(format: "%K == %@", Key.id, "main")
        request.fetchLimit = 1

        if let session = try context.fetch(request).first {
            return session
        }

        return NSEntityDescription.insertNewObject(forEntityName: Entity.session, into: context)
    }

    private func fetchObjects(entityName: String, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return try context.fetch(request)
    }

    private static func loadCoreDataState(in context: NSManagedObjectContext) -> BrowserWindowState? {
        context.performAndWait {
            do {
                let sessionRequest = NSFetchRequest<NSManagedObject>(entityName: Entity.session)
                sessionRequest.fetchLimit = 1

                guard let session = try context.fetch(sessionRequest).first else {
                    return nil
                }

                let spaceRequest = NSFetchRequest<NSManagedObject>(entityName: Entity.space)
                spaceRequest.sortDescriptors = [NSSortDescriptor(key: Key.createdAt, ascending: true)]

                let tabRequest = NSFetchRequest<NSManagedObject>(entityName: Entity.tab)
                tabRequest.sortDescriptors = [NSSortDescriptor(key: Key.sortOrder, ascending: true)]

                let folderRequest = NSFetchRequest<NSManagedObject>(entityName: Entity.folder)
                folderRequest.sortDescriptors = [NSSortDescriptor(key: Key.sortOrder, ascending: true)]

                let spaces = try context.fetch(spaceRequest).compactMap(space(from:))
                let folders = try context.fetch(folderRequest).compactMap(folder(from:))
                let tabs = try context.fetch(tabRequest).compactMap(tab(from:))
                guard let activeSpaceID = session.uuid(for: Key.activeSpaceID) ?? spaces.first?.id else {
                    return nil
                }

                return BrowserWindowState(
                    spaces: spaces,
                    folders: folders,
                    tabs: tabs,
                    activeSpaceID: activeSpaceID,
                    activeTabID: session.uuid(for: Key.activeTabID),
                    splitTabIDs: Self.decodeUUIDList(session.string(for: Key.splitTabIDs)),
                    splitPaneRatios: Self.decodeDoubleList(session.string(for: Key.splitPaneRatios)),
                    splitLayout: session.string(for: Key.splitLayout) ?? "horizontal",
                    isSplitViewEnabled: session.bool(for: Key.isSplitViewEnabled)
                )
            } catch {
                NSLog("\(appName) failed to load session: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func loadHistoryVisits(in context: NSManagedObjectContext) -> [HistoryVisit] {
        context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: Entity.historyVisit)
                request.sortDescriptors = [NSSortDescriptor(key: Key.visitedAt, ascending: true)]
                return try context.fetch(request).compactMap(historyVisit(from:))
            } catch {
                NSLog("\(appName) failed to load history: \(error.localizedDescription)")
                return []
            }
        }
    }

    private static func insert(_ visit: HistoryVisit, in context: NSManagedObjectContext) {
        let object = NSEntityDescription.insertNewObject(forEntityName: Entity.historyVisit, into: context)
        object.setValue(visit.id, forKey: Key.id)
        object.setValue(visit.title, forKey: Key.title)
        object.setValue(visit.url.absoluteString, forKey: Key.urlString)
        object.setValue(visit.tabID, forKey: Key.tabID)
        object.setValue(visit.spaceID, forKey: Key.spaceID)
        object.setValue(visit.visitedAt, forKey: Key.visitedAt)
    }

    private static func space(from object: NSManagedObject) -> BrowserSpace? {
        guard let id = object.uuid(for: Key.id) else { return nil }

        return BrowserSpace(
            id: id,
            name: object.string(for: Key.name) ?? String(localized: "Space"),
            symbolName: object.string(for: Key.symbolName) ?? "sparkle",
            themeColorHex: object.string(for: Key.themeColorHex),
            themeAuxiliaryColorHexes: object.string(for: Key.themeAuxiliaryColorHexes)?
                .split(separator: ",")
                .map(String.init) ?? [],
            themeAppearance: object.string(for: Key.themeAppearance)
                .flatMap(SpaceThemeAppearance.init(rawValue:)) ?? .automatic,
            themeOpacity: object.optionalDouble(for: Key.themeOpacity) ?? 0.5,
            themeTexture: object.optionalDouble(for: Key.themeTexture) ?? 0,
            dataStoreID: object.uuid(for: Key.dataStoreID) ?? id,
            createdAt: object.date(for: Key.createdAt) ?? Date()
        )
    }

    private static func folder(from object: NSManagedObject) -> BrowserFolder? {
        guard
            let id = object.uuid(for: Key.id),
            let spaceID = object.uuid(for: Key.spaceID)
        else {
            return nil
        }

        return BrowserFolder(
            id: id,
            name: object.string(for: Key.name) ?? String(localized: "New Folder"),
            spaceID: spaceID,
            parentFolderID: object.uuid(for: Key.parentFolderID),
            sortOrder: object.double(for: Key.sortOrder),
            isExpanded: object.bool(for: Key.isExpanded)
        )
    }

    private static func tab(from object: NSManagedObject) -> BrowserTab? {
        guard
            let id = object.uuid(for: Key.id),
            let spaceID = object.uuid(for: Key.spaceID)
        else {
            return nil
        }

        let url = object.string(for: Key.urlString).flatMap(URL.init(string:))

        return BrowserTab(
            id: id,
            title: object.string(for: Key.title) ?? BrowserDefaults.newTabTitle,
            url: url,
            faviconSymbol: object.string(for: Key.faviconSymbol) ?? "globe",
            faviconData: object.data(for: Key.faviconData),
            favoriteTitle: object.string(for: Key.favoriteTitle),
            favoriteURL: object.string(for: Key.favoriteURLString).flatMap(URL.init(string:)),
            favoriteFaviconSymbol: object.string(for: Key.favoriteFaviconSymbol),
            favoriteFaviconData: object.data(for: Key.favoriteFaviconData),
            isLoading: false,
            loadingProgress: 0,
            isFavorite: object.bool(for: Key.isFavorite),
            isPinned: object.bool(for: Key.isPinned),
            folderID: object.uuid(for: Key.folderID),
            spaceID: spaceID,
            sortOrder: object.double(for: Key.sortOrder),
            lastAccessedAt: object.date(for: Key.lastAccessedAt) ?? Date(),
            hasBeenActivated: object.value(forKey: Key.hasBeenActivated) as? Bool ?? !object.bool(for: Key.isFavorite)
        )
    }

    private static func historyVisit(from object: NSManagedObject) -> HistoryVisit? {
        guard
            let id = object.uuid(for: Key.id),
            let urlString = object.string(for: Key.urlString),
            let url = URL(string: urlString),
            let tabID = object.uuid(for: Key.tabID),
            let spaceID = object.uuid(for: Key.spaceID),
            let visitedAt = object.date(for: Key.visitedAt)
        else {
            return nil
        }

        return HistoryVisit(
            id: id,
            title: object.string(for: Key.title) ?? urlString,
            url: url,
            tabID: tabID,
            spaceID: spaceID,
            visitedAt: visitedAt
        )
    }

    private static func makeModel(configuresStoreConfigurations: Bool = true) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let sessionEntities = [
            makeSessionEntity(),
            makeSpaceEntity(),
            makeFolderEntity(),
            makeTabEntity()
        ]
        let historyEntities = [makeHistoryVisitEntity()]

        model.entities = sessionEntities + historyEntities
        if configuresStoreConfigurations {
            model.setEntities(sessionEntities, forConfigurationName: StoreConfiguration.session)
            model.setEntities(historyEntities, forConfigurationName: StoreConfiguration.history)
        }
        return model
    }

    private static func makeSessionEntity() -> NSEntityDescription {
        makeEntity(
            named: Entity.session,
            properties: [
                attribute(Key.id, .stringAttributeType, optional: false),
                attribute(Key.activeSpaceID, .UUIDAttributeType, optional: false),
                attribute(Key.activeTabID, .UUIDAttributeType),
                attribute(Key.splitTabIDs, .stringAttributeType),
                attribute(Key.splitPaneRatios, .stringAttributeType),
                attribute(Key.splitLayout, .stringAttributeType),
                attribute(Key.isSplitViewEnabled, .booleanAttributeType, optional: false)
            ]
        )
    }

    private static func encodeUUIDList(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    private static func decodeUUIDList(_ value: String?) -> [UUID] {
        value?
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        ?? []
    }

    private static func encodeDoubleList(_ values: [Double]) -> String {
        values.map { String($0) }.joined(separator: ",")
    }

    private static func decodeDoubleList(_ value: String?) -> [Double] {
        value?
            .split(separator: ",")
            .compactMap { Double(String($0)) }
        ?? []
    }

    private static func makeSpaceEntity() -> NSEntityDescription {
        makeEntity(
            named: Entity.space,
            properties: [
                attribute(Key.id, .UUIDAttributeType, optional: false),
                attribute(Key.name, .stringAttributeType, optional: false),
                attribute(Key.symbolName, .stringAttributeType, optional: false),
                attribute(Key.themeColorHex, .stringAttributeType),
                attribute(Key.themeAuxiliaryColorHexes, .stringAttributeType),
                attribute(Key.themeAppearance, .stringAttributeType),
                attribute(Key.themeOpacity, .doubleAttributeType),
                attribute(Key.themeTexture, .doubleAttributeType),
                attribute(Key.dataStoreID, .UUIDAttributeType),
                attribute(Key.createdAt, .dateAttributeType, optional: false)
            ]
        )
    }

    private static func makeFolderEntity() -> NSEntityDescription {
        makeEntity(
            named: Entity.folder,
            properties: [
                attribute(Key.id, .UUIDAttributeType, optional: false),
                attribute(Key.name, .stringAttributeType, optional: false),
                attribute(Key.spaceID, .UUIDAttributeType, optional: false),
                attribute(Key.parentFolderID, .UUIDAttributeType),
                attribute(Key.sortOrder, .doubleAttributeType, optional: false),
                attribute(Key.isExpanded, .booleanAttributeType, optional: false)
            ]
        )
    }

    private static func makeTabEntity() -> NSEntityDescription {
        makeEntity(
            named: Entity.tab,
            properties: [
                attribute(Key.id, .UUIDAttributeType, optional: false),
                attribute(Key.title, .stringAttributeType, optional: false),
                attribute(Key.urlString, .stringAttributeType),
                attribute(Key.faviconSymbol, .stringAttributeType, optional: false),
                attribute(Key.faviconData, .binaryDataAttributeType),
                attribute(Key.favoriteTitle, .stringAttributeType),
                attribute(Key.favoriteURLString, .stringAttributeType),
                attribute(Key.favoriteFaviconSymbol, .stringAttributeType),
                attribute(Key.favoriteFaviconData, .binaryDataAttributeType),
                attribute(Key.isFavorite, .booleanAttributeType, optional: false),
                attribute(Key.isPinned, .booleanAttributeType, optional: false),
                attribute(Key.folderID, .UUIDAttributeType),
                attribute(Key.spaceID, .UUIDAttributeType, optional: false),
                attribute(Key.sortOrder, .doubleAttributeType, optional: false),
                attribute(Key.lastAccessedAt, .dateAttributeType, optional: false),
                attribute(Key.hasBeenActivated, .booleanAttributeType)
            ]
        )
    }

    private static func makeHistoryVisitEntity() -> NSEntityDescription {
        makeEntity(
            named: Entity.historyVisit,
            properties: [
                attribute(Key.id, .UUIDAttributeType, optional: false),
                attribute(Key.title, .stringAttributeType, optional: false),
                attribute(Key.urlString, .stringAttributeType, optional: false),
                attribute(Key.tabID, .UUIDAttributeType, optional: false),
                attribute(Key.spaceID, .UUIDAttributeType, optional: false),
                attribute(Key.visitedAt, .dateAttributeType, optional: false)
            ]
        )
    }

    private static func makeEntity(named name: String, properties: [NSPropertyDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = properties
        return entity
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = true
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        if !optional {
            attribute.defaultValue = defaultValue(for: type)
        }
        return attribute
    }

    private static func defaultValue(for type: NSAttributeType) -> Any? {
        switch type {
        case .stringAttributeType:
            return ""
        case .UUIDAttributeType:
            return UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        case .dateAttributeType:
            return Date(timeIntervalSince1970: 0)
        case .booleanAttributeType:
            return false
        case .doubleAttributeType:
            return 0
        case .binaryDataAttributeType:
            return nil
        default:
            return nil
        }
    }
}

private enum StoreConfiguration {
    static let session = "SessionState"
    static let history = "History"
}

private enum Entity {
    static let session = "PersistedSessionState"
    static let space = "PersistedBrowserSpace"
    static let folder = "PersistedBrowserFolder"
    static let tab = "PersistedBrowserTab"
    static let historyVisit = "PersistedHistoryVisit"
}

private enum Key {
    static let id = "id"
    static let activeSpaceID = "activeSpaceID"
    static let activeTabID = "activeTabID"
    static let splitTabIDs = "splitTabIDs"
    static let splitPaneRatios = "splitPaneRatios"
    static let splitLayout = "splitLayout"
    static let isSplitViewEnabled = "isSplitViewEnabled"
    static let name = "name"
    static let symbolName = "symbolName"
    static let themeColorHex = "themeColorHex"
    static let themeAuxiliaryColorHexes = "themeAuxiliaryColorHexes"
    static let themeAppearance = "themeAppearance"
    static let themeOpacity = "themeOpacity"
    static let themeTexture = "themeTexture"
    static let dataStoreID = "dataStoreID"
    static let createdAt = "createdAt"
    static let title = "title"
    static let urlString = "urlString"
    static let faviconSymbol = "faviconSymbol"
    static let faviconData = "faviconData"
    static let favoriteTitle = "favoriteTitle"
    static let favoriteURLString = "favoriteURLString"
    static let favoriteFaviconSymbol = "favoriteFaviconSymbol"
    static let favoriteFaviconData = "favoriteFaviconData"
    static let isFavorite = "isFavorite"
    static let isPinned = "isPinned"
    static let folderID = "folderID"
    static let parentFolderID = "parentFolderID"
    static let tabID = "tabID"
    static let spaceID = "spaceID"
    static let sortOrder = "sortOrder"
    static let isExpanded = "isExpanded"
    static let lastAccessedAt = "lastAccessedAt"
    static let hasBeenActivated = "hasBeenActivated"
    static let visitedAt = "visitedAt"
}

private extension NSManagedObject {
    func bool(for key: String) -> Bool {
        value(forKey: key) as? Bool ?? false
    }

    func data(for key: String) -> Data? {
        value(forKey: key) as? Data
    }

    func date(for key: String) -> Date? {
        value(forKey: key) as? Date
    }

    func double(for key: String) -> Double {
        value(forKey: key) as? Double ?? 0
    }

    func optionalDouble(for key: String) -> Double? {
        value(forKey: key) as? Double
    }

    func string(for key: String) -> String? {
        value(forKey: key) as? String
    }

    func uuid(for key: String) -> UUID? {
        value(forKey: key) as? UUID
    }
}

private extension JSONEncoder {
    static var candoa: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var candoa: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
