import SwiftUI

struct AsyncPreviewImage: View {
    var path: String?
    var revision = ""
    var scope: PreviewScope = .thumbnail
    var fit = false
    var placeholder = "正在读取预览"
    @StateObject private var model = PreviewImageModel()
    private var key: PreviewImageKey? { path.map { .init(path:$0,revision:revision) } }
    var body: some View {
        GeometryReader { geometry in
            if model.key == key,let bitmap = model.bitmap {
                let image = Image(decorative:bitmap.image,scale:2).resizable()
                if fit { image.aspectRatio(contentMode:.fit).frame(width:geometry.size.width,height:geometry.size.height) }
                else { image.scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped() }
            } else {
                VStack(spacing:5) {
                    Image(systemName:model.key == key && model.failure != nil ? "photo.badge.exclamationmark" : "photo")
                    if geometry.size.height >= 60 { Text(model.key == key ? model.failure?.message ?? placeholder : placeholder).font(.system(size:9)).multilineTextAlignment(.center) }
                }.foregroundStyle(.secondary).frame(width:geometry.size.width,height:geometry.size.height)
            }
        }
        .task(id:key) { if let key { model.begin(key,scope:scope) } else { model.cancel() } }
        .onDisappear { model.cancel() }
        .accessibilityLabel(model.key == key && model.failure != nil ? model.failure!.message : "图片预览")
    }
}
