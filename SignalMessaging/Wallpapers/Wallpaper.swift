//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public enum Wallpaper: String, CaseIterable {
    public static let wallpaperDidChangeNotification = NSNotification.Name("wallpaperDidChangeNotification")

    // Solid
    case blush
    case copper
    case zorba
    case envy
    case sky
    case wildBlueYonder
    case lavender
    case shocking
    case gray
    case eden
    case violet
    case eggplant

    // Gradient
    case starshipGradient
    case woodsmokeGradient
    case coralGradient
    case ceruleanGradient
    case roseGradient
    case aquamarineGradient
    case tropicalGradient
    case blueGradient
    case bisqueGradient

    // Custom
    case photo

    public static var defaultWallpapers: [Wallpaper] { allCases.filter { $0 != .photo } }

    public static func warmCaches() {
        owsAssertDebug(!Thread.isMainThread)

        let photoURLs: [URL]
        do {
            photoURLs = try OWSFileSystem.recursiveFilesInDirectory(wallpaperDirectory.path).map { URL(fileURLWithPath: $0) }
        } catch {
            owsFailDebug("Failed to enumerate wallpaper photos \(error)")
            return
        }

        guard !photoURLs.isEmpty else { return }

        var keysToCache = [String]()
        var orphanedKeys = [String]()

        SDSDatabaseStorage.shared.read { transaction in
            for url in photoURLs {
                guard let key = url.lastPathComponent.removingPercentEncoding else {
                    owsFailDebug("Failed to remove percent encoding in key")
                    continue
                }
                guard case .photo = get(for: key, transaction: transaction) else {
                    orphanedKeys.append(key)
                    continue
                }
                keysToCache.append(key)
            }
        }

        if !orphanedKeys.isEmpty {
            Logger.info("Cleaning up \(orphanedKeys.count) orphaned wallpaper photos")
            for key in orphanedKeys {
                do {
                    try cleanupPhotoIfNecessary(for: key)
                } catch {
                    owsFailDebug("Failed to cleanup orphaned wallpaper photo \(key) \(error)")
                }
            }
        }

        for key in keysToCache {
            do {
                try photo(for: key)
            } catch {
                owsFailDebug("Failed to cache wallpaper photo \(key) \(error)")
            }
        }
    }

    public static func clear(for thread: TSThread? = nil, transaction: SDSAnyWriteTransaction) throws {
        owsAssertDebug(!Thread.isMainThread)

        enumStore.removeValue(forKey: key(for: thread), transaction: transaction)
        dimmingStore.removeValue(forKey: key(for: thread), transaction: transaction)
        try OWSFileSystem.deleteFileIfExists(url: photoURL(for: thread))

        transaction.addAsyncCompletion {
            NotificationCenter.default.post(name: wallpaperDidChangeNotification, object: thread?.uniqueId)
        }
    }

    public static func resetAll(transaction: SDSAnyWriteTransaction) throws {
        owsAssertDebug(!Thread.isMainThread)

        enumStore.removeAll(transaction: transaction)
        dimmingStore.removeAll(transaction: transaction)
        try OWSFileSystem.deleteFileIfExists(url: wallpaperDirectory)

        transaction.addAsyncCompletion {
            NotificationCenter.default.post(name: wallpaperDidChangeNotification, object: nil)
        }
    }

    public static func setBuiltIn(_ wallpaper: Wallpaper, for thread: TSThread? = nil, transaction: SDSAnyWriteTransaction) throws {
        owsAssertDebug(!Thread.isMainThread)

        owsAssertDebug(wallpaper != .photo)

        try set(wallpaper, for: thread, transaction: transaction)
    }

    public static func setPhoto(_ photo: UIImage, for thread: TSThread? = nil, transaction: SDSAnyWriteTransaction) throws {
        owsAssertDebug(Thread.current != .main)

        try set(.photo, photo: photo, for: thread, transaction: transaction)
    }

    public static func exists(for thread: TSThread? = nil, transaction: SDSAnyReadTransaction) -> Bool {
        guard get(for: thread, transaction: transaction) != nil else {
            if thread != nil { return exists(transaction: transaction) }
            return false
        }
        return true
    }

    public static func dimInDarkMode(for thread: TSThread? = nil, transaction: SDSAnyReadTransaction) -> Bool {
        guard let dimInDarkMode = getDimInDarkMode(for: thread, transaction: transaction) else {
            if thread != nil { return self.dimInDarkMode(transaction: transaction) }
            return true
        }
        return dimInDarkMode
    }

    public static func view(for thread: TSThread? = nil,
                            transaction: SDSAnyReadTransaction) -> WallpaperView? {
        AssertIsOnMainThread()

        guard let wallpaper: Wallpaper = {
            if let wallpaper = get(for: thread, transaction: transaction) {
                return wallpaper
            } else if thread != nil, let wallpaper = get(for: nil, transaction: transaction) {
                return wallpaper
            } else {
                return nil
            }
        }() else { return nil }

        let photo: UIImage? = {
            guard case .photo = wallpaper else { return nil }
            if let photo = try? self.photo(for: thread) {
                return photo
            } else if thread != nil, let photo = try? self.photo(for: nil) {
                return photo
            } else {
                return nil
            }
        }()

        if case .photo = wallpaper, photo == nil {
            owsFailDebug("Missing photo for wallpaper \(wallpaper)")
            return nil
        }

        let shouldDim = (Theme.isDarkThemeEnabled &&
                            dimInDarkMode(for: thread, transaction: transaction))

        guard let view = view(for: wallpaper,
                              photo: photo,
                              shouldDim: shouldDim) else {
            return nil
       }

        return view
    }

    public static func shouldDim(thread: TSThread?,
                                 transaction: SDSAnyReadTransaction) -> Bool {
        (Theme.isDarkThemeEnabled &&
            dimInDarkMode(for: thread, transaction: transaction))
    }

    public static func view(for wallpaper: Wallpaper,
                            photo: UIImage? = nil,
                            shouldDim: Bool) -> WallpaperView? {
        AssertIsOnMainThread()

        guard let mode = { () -> WallpaperView.Mode? in
            if case .photo = wallpaper {
                guard let photo = photo else {
                    owsFailDebug("Missing photo for wallpaper \(wallpaper)")
                    return nil
                }
                return .image(image: photo)
            } else if let solidColor = wallpaper.asSolidColor {
                return .solidColor(solidColor: solidColor)
            } else if let swatchView = wallpaper.asSwatchView(mode: .rectangle) {
                return .gradientView(gradientView: swatchView)
            } else {
                owsFailDebug("Unexpected wallpaper type \(wallpaper)")
                return nil
            }
        }() else {
            return nil
        }
        return WallpaperView(mode: mode, shouldDim: shouldDim)
    }
}

// MARK: -

fileprivate extension Wallpaper {
    static func key(for thread: TSThread?) -> String {
        return thread?.uniqueId ?? "global"
    }
}

// MARK: -

extension Wallpaper {
    private static let enumStore = SDSKeyValueStore(collection: "Wallpaper+Enum")

    fileprivate static func set(_ wallpaper: Wallpaper?, photo: UIImage? = nil, for thread: TSThread?, transaction: SDSAnyWriteTransaction) throws {
        owsAssertDebug(photo == nil || wallpaper == .photo)

        try cleanupPhotoIfNecessary(for: thread)

        if let photo = photo { try setPhoto(photo, for: thread) }

        enumStore.setString(wallpaper?.rawValue, key: key(for: thread), transaction: transaction)

        transaction.addAsyncCompletion {
            NotificationCenter.default.post(name: wallpaperDidChangeNotification, object: thread?.uniqueId)
        }
    }

    public static func get(for thread: TSThread?, transaction: SDSAnyReadTransaction) -> Wallpaper? {
        return get(for: key(for: thread), transaction: transaction)
    }

    fileprivate static func get(for key: String, transaction: SDSAnyReadTransaction) -> Wallpaper? {
        guard let rawValue = enumStore.getString(key, transaction: transaction) else {
            return nil
        }
        guard let wallpaper = Wallpaper(rawValue: rawValue) else {
            owsFailDebug("Unexpectedly wallpaper \(rawValue)")
            return nil
        }
        return wallpaper
    }
}

// MARK: -

extension Wallpaper {
    private static let dimmingStore = SDSKeyValueStore(collection: "Wallpaper+Dimming")

    public static func setDimInDarkMode(_ dimInDarkMode: Bool, for thread: TSThread?, transaction: SDSAnyWriteTransaction) throws {
        dimmingStore.setBool(dimInDarkMode, key: key(for: thread), transaction: transaction)

        transaction.addAsyncCompletion {
            NotificationCenter.default.post(name: wallpaperDidChangeNotification, object: thread?.uniqueId)
        }
    }

    fileprivate static func getDimInDarkMode(for thread: TSThread?, transaction: SDSAnyReadTransaction) -> Bool? {
        return dimmingStore.getBool(key(for: thread), transaction: transaction)
    }
}

// MARK: - Photo management

fileprivate extension Wallpaper {
    static let appSharedDataDirectory = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath())
    static let wallpaperDirectory = URL(fileURLWithPath: "Wallpapers", isDirectory: true, relativeTo: appSharedDataDirectory)
    static let cache = NSCache<NSString, UIImage>()

    static func ensureWallpaperDirectory() throws {
        guard OWSFileSystem.ensureDirectoryExists(wallpaperDirectory.path) else {
            throw OWSAssertionError("Failed to create ensure wallpaper directory")
        }
    }

    static func setPhoto(_ photo: UIImage, for thread: TSThread?) throws {
        owsAssertDebug(!Thread.isMainThread)

        cache.setObject(photo, forKey: key(for: thread) as NSString)

        guard let data = photo.jpegData(compressionQuality: 0.8) else {
            throw OWSAssertionError("Failed to get jpg data for wallpaper photo")
        }
        guard !OWSFileSystem.fileOrFolderExists(url: try photoURL(for: thread)) else { return }
        try ensureWallpaperDirectory()
        try data.write(to: try photoURL(for: thread), options: .atomic)
    }

    static func photo(for thread: TSThread?) throws -> UIImage? {
        return try photo(for: key(for: thread))
    }

    @discardableResult
    static func photo(for key: String) throws -> UIImage? {
        if let photo = cache.object(forKey: key as NSString) { return photo }

        guard OWSFileSystem.fileOrFolderExists(url: try photoURL(for: key)) else { return nil }

        let data = try Data(contentsOf: try photoURL(for: key))

        guard let photo = UIImage(data: data) else {
            owsFailDebug("Failed to initialize wallpaper photo from data")
            try cleanupPhotoIfNecessary(for: key)
            return nil
        }

        cache.setObject(photo, forKey: key as NSString)

        return photo
    }

    static func cleanupPhotoIfNecessary(for thread: TSThread?) throws {
        try cleanupPhotoIfNecessary(for: key(for: thread))
    }

    static func cleanupPhotoIfNecessary(for key: String) throws {
        owsAssertDebug(!Thread.isMainThread)

        cache.removeObject(forKey: key as NSString)
        try OWSFileSystem.deleteFileIfExists(url: try photoURL(for: key))
    }

    static func photoURL(for thread: TSThread?) throws -> URL {
        return try photoURL(for: key(for: thread))
    }

    static func photoURL(for key: String) throws -> URL {
        guard let filename = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw OWSAssertionError("Failed to percent encode filename")
        }
        return URL(fileURLWithPath: filename, relativeTo: wallpaperDirectory)
    }
}

// MARK: -

public class WallpaperView {
    fileprivate enum Mode {
        case solidColor(solidColor: UIColor)
        case gradientView(gradientView: UIView)
        case image(image: UIImage)
    }

    public private(set) var contentView: UIView?

    public private(set) var dimmingView: UIView?

    public private(set) var blurProvider: WallpaperBlurProvider?

    private let mode: Mode

    fileprivate init(mode: Mode, shouldDim: Bool) {
        self.mode = mode

        configure(shouldDim: shouldDim)
    }

    @available(swift, obsoleted: 1.0)
    required init(name: String) {
        owsFail("Do not use this initializer.")
    }

    public func asPreviewView() -> UIView {
        let previewView = UIView.container()
        if let contentView = self.contentView {
            previewView.addSubview(contentView)
            contentView.autoPinEdgesToSuperviewEdges()
        }
        if let dimmingView = self.dimmingView {
            previewView.addSubview(dimmingView)
            dimmingView.autoPinEdgesToSuperviewEdges()
        }
        return previewView
    }

    private func configure(shouldDim: Bool) {
        func addDimmingViewIfNecessary() {
            if shouldDim {
                let dimmingView = UIView()
                dimmingView.backgroundColor = .ows_blackAlpha20
                self.dimmingView = dimmingView
            }
        }

        let contentView: UIView = {
            switch mode {
            case .solidColor(let solidColor):
                // Bake the dimming into the color.
                let color = (shouldDim
                                ? solidColor.blended(with: .ows_black, alpha: 0.2)
                                : solidColor)

                let contentView = UIView()
                contentView.backgroundColor = color
                return contentView
            case .gradientView(let gradientView):

                addDimmingViewIfNecessary()

                return gradientView
            case .image(let image):
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true

                // TODO: Bake dimming into the image.
                addDimmingViewIfNecessary()

                return imageView
            }
        }()
        self.contentView = contentView

        addBlurProvider(contentView: contentView)
    }

    private func addBlurProvider(contentView: UIView) {
        self.blurProvider = WallpaperBlurProviderImpl(contentView: contentView)
    }
}

// MARK: -

private struct WallpaperBlurToken: Equatable {
    let contentSize: CGSize
    let isDarkThemeEnabled: Bool
}

// MARK: -

@objc
public class WallpaperBlurState: NSObject {
    public let image: UIImage
    public let referenceView: UIView
    fileprivate let token: WallpaperBlurToken

    private static let idCounter = AtomicUInt(0)
    public let id: UInt = WallpaperBlurState.idCounter.increment()

    fileprivate init(image: UIImage,
                     referenceView: UIView,
                     token: WallpaperBlurToken) {
        self.image = image
        self.referenceView = referenceView
        self.token = token
    }
}

// MARK: -

@objc
public protocol WallpaperBlurProvider: AnyObject {
    var wallpaperBlurState: WallpaperBlurState? { get }
}

// MARK: -

public class WallpaperBlurProviderImpl: NSObject, WallpaperBlurProvider {
    private let contentView: UIView

    private var cachedState: WallpaperBlurState?

    init(contentView: UIView) {
        self.contentView = contentView
    }

    @available(swift, obsoleted: 1.0)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public static let contentDownscalingFactor: CGFloat = 8

    public var wallpaperBlurState: WallpaperBlurState? {
        AssertIsOnMainThread()

        // De-bounce.
        let bounds = contentView.bounds
        let isDarkThemeEnabled = Theme.isDarkThemeEnabled
        let newToken = WallpaperBlurToken(contentSize: bounds.size,
                                          isDarkThemeEnabled: isDarkThemeEnabled)
        if let cachedState = self.cachedState,
           cachedState.token == newToken {
            return cachedState
        }

        self.cachedState = nil

        do {
            guard bounds.width > 0, bounds.height > 0 else {
                return nil
            }
            guard let contentImage = contentView.renderAsImage() else {
                owsFailDebug("Could not render contentView.")
                return nil
            }
            // We approximate the behavior of UIVisualEffectView(effect: UIBlurEffect(style: .regular)).
            let tintColor: UIColor = (isDarkThemeEnabled
                                        ? UIColor.ows_black.withAlphaComponent(0.9)
                                        : UIColor.white.withAlphaComponent(0.6))
            let resizeDimension = contentImage.size.largerAxis / Self.contentDownscalingFactor
            guard let scaledImage = contentImage.resized(withMaxDimensionPoints: resizeDimension) else {
                owsFailDebug("Could not resize contentImage.")
                return nil
            }
            let blurRadius: CGFloat = 32 / Self.contentDownscalingFactor
            let blurredImage = try scaledImage.withGausianBlur(radius: blurRadius,
                                                               tintColor: tintColor)
            let state = WallpaperBlurState(image: blurredImage,
                                           referenceView: contentView,
                                           token: newToken)
            self.cachedState = state
            return state
        } catch {
            owsFailDebug("Error: \(error).")
            return nil
        }
    }
}

// MARK: -

extension CACornerMask {
    var asUIRectCorner: UIRectCorner {
        var corners = UIRectCorner()
        if self.contains(.layerMinXMinYCorner) {
            corners.formUnion(.topLeft)
        }
        if self.contains(.layerMaxXMinYCorner) {
            corners.formUnion(.topRight)
        }
        if self.contains(.layerMinXMaxYCorner) {
            corners.formUnion(.bottomLeft)
        }
        if self.contains(.layerMaxXMaxYCorner) {
            corners.formUnion(.bottomRight)
        }
        return corners
    }
}
