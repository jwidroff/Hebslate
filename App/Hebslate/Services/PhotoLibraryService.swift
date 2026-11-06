import Photos

/// Deletes the original screen recording from Photos once it's been
/// translated, so the user doesn't have to go find and delete it by hand.
enum PhotoLibraryService {
    enum DeleteError: LocalizedError {
        case notFound
        case denied

        var errorDescription: String? {
            switch self {
            case .notFound: "Couldn't find that recording in Photos — it may already be deleted."
            case .denied: "Hebslate needs permission to manage Photos to delete the recording. Check Settings › Hebslate › Photos."
            }
        }
    }

    /// Deletes the Photos asset with the given local identifier. iOS still
    /// shows its own confirmation before the asset is actually removed.
    static func deleteRecording(identifier: String) async throws {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else { throw DeleteError.denied }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw DeleteError.notFound
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    private static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
