import Photos

func askPhotosDirectly() {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
}
