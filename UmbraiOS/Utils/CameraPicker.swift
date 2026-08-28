// 拍照取图：SwiftUI 没有原生相机组件，包一层 UIImagePickerController（只用 .camera 源 ——
// 相册走 PhotosPicker，系统的有限授权流程都在那边，这里不碰 PHPhotoLibrary）。
// 权限文案在 Info.plist 的 NSCameraUsageDescription，早在语音一期就配好了。
//
// 原先是 MoneyAddView.swift 里的 private 组件；提醒附件（2026-08-27）也要拍照，
// 被两个功能用到就按工程约定挪进 Utils/，两处共用这一份。
import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    /// 拍到一张图的回调（取消不回调）。
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
