import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - 設定定数
private let SAMPLE_FACTOR: Int = 14
private let AA_CHARS = Array(" .._`',;:~-!^=+|\\/><?_[]{}()vxFtTzZpPdbkK49860O#W&@$")
private let RAIN_CHARS = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ*+-<>[]")

// MARK: - デジタル・レイン管理クラス
final class MatrixRain {
    let cols: Int
    let rows: Int
    var drops: [Int]
    var speeds: [Int]
    var grid: [[Character]]
    let tailLen: Int = 60

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.drops = (0..<cols).map { _ in
            Double.random(in: 0...1) < 0.3
                ? Int.random(in: -rows...0)
                : Int.random(in: (-rows * 40)...(-rows))
        }
        self.speeds = (0..<cols).map { _ in Int.random(in: 1...3) }
        self.grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    }

    func update() {
        grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)

        for x in 0..<cols {
            drops[x] += speeds[x]

            if drops[x] >= rows + tailLen {
                drops[x] = Int.random(in: -10...0)
                speeds[x] = Int.random(in: 1...3)
            }

            for i in 0..<tailLen {
                let y = drops[x] - i
                if y >= 0 && y < rows {
                    grid[y][x] = RAIN_CHARS.randomElement() ?? "0"
                }
            }
        }
    }

    func getColor(x: Int, y: Int) -> CGColor? {
        guard grid[y][x] != " " else { return nil }

        let distFromTip = drops[x] - y
        guard distFromTip >= 0 else { return nil }

        // 先端：高輝度の緑
        if distFromTip <= 2 {
            return CGColor(red: 200/255.0, green: 255/255.0, blue: 200/255.0, alpha: 1.0)
        }

        var t = 1.0 - (Double(distFromTip) / Double(tailLen))
        t = max(0.0, min(1.0, t))

        let r = (200.0 * t + 0.0 * (1.0 - t)) / 255.0
        let g = (255.0 * t + 130.0 * (1.0 - t)) / 255.0
        let b = (200.0 * t + 0.0 * (1.0 - t)) / 255.0

        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - 動画変換パイプライン
actor VideoMatrixConverter {
    func convert(inputURL: URL, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "MatrixConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "ビデオトラックが見つかりません。"])
        }

        let originalTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let transformedSize = naturalSize.applying(originalTransform)
        
        // 16の倍数にスナップ（H.264圧縮の安定化）
        let targetWidth = (Int(abs(transformedSize.width)) / 16) * 16
        let targetHeight = (Int(abs(transformedSize.height)) / 16) * 16
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30.0

        // アスキーグリッドのサイズ
        let smallW = targetWidth / SAMPLE_FACTOR
        let smallH = targetHeight / SAMPLE_FACTOR
        let cellW = CGFloat(targetWidth) / CGFloat(smallW)
        let cellH = CGFloat(targetHeight) / CGFloat(smallH)

        let rain = MatrixRain(cols: smallW, rows: smallH)

        // Reader セットアップ
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // 出力先一時ファイル
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Writer セットアップ
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight
            ]
        )

        writer.add(writerInput)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // 描画バッファ
        var pixelBufferPool = adaptor.pixelBufferPool
        let font = CTFontCreateWithName("Courier-Bold" as CFString, min(cellW, cellH) * 1.1, nil)
        let charLen = AA_CHARS.count

        var processedDuration: CMTime = .zero

        while reader.status == .reading {
            if !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            processedDuration = pts

            // ピクセル取得用
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
                CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
                continue
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            let bufW = CVPixelBufferGetWidth(imageBuffer)
            let bufH = CVPixelBufferGetHeight(imageBuffer)

            // フレーム生成
            var outPixelBuffer: CVPixelBuffer?
            if pixelBufferPool == nil {
                pixelBufferPool = adaptor.pixelBufferPool
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool!, &outPixelBuffer)

            if let outBuffer = outPixelBuffer {
                CVPixelBufferLockBaseAddress(outBuffer, [])
                let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
                let outContext = CGContext(
                    data: CVPixelBufferGetBaseAddress(outBuffer),
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(outBuffer),
                    space: rgbColorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                )

                if let ctx = outContext {
                    // 背景を黒でクリア
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
                    ctx.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

                    rain.update()

                    // サンプリング & テキスト描画
                    for y in 0..<smallH {
                        for x in 0..<smallW {
                            let srcX = min(x * SAMPLE_FACTOR, bufW - 1)
                            let srcY = min(y * SAMPLE_FACTOR, bufH - 1)

                            let pixelOffset = srcY * bytesPerRow + srcX * 4
                            let pixelPtr = baseAddress.advanced(by: pixelOffset).assumingMemoryBound(to: UInt8.self)
                            let b = Double(pixelPtr[0])
                            let g = Double(pixelPtr[1])
                            let r = Double(pixelPtr[2])
                            let brightness = (r * 0.299 + g * 0.587 + b * 0.114)

                            // 1. ビデオ文字
                            let charIdx = Int((brightness / 256.0) * Double(charLen))
                            let videoChar = AA_CHARS[min(charIdx, charLen - 1)]

                            // 2. レイン文字
                            let rainChar = (y < rain.rows && x < rain.cols) ? rain.grid[y][x] : " "
                            let rainColor = rain.getColor(x: x, y: y)

                            var charToDraw: Character?
                            var drawColor: CGColor?

                            if videoChar != " " && brightness > 50 {
                                charToDraw = videoChar
                                let intensity = max(100.0, brightness) / 255.0
                                drawColor = CGColor(red: 0, green: intensity, blue: 0, alpha: 1.0)
                            } else if rainChar != " " && rainColor != nil {
                                charToDraw = rainChar
                                drawColor = rainColor
                            }

                            if let char = charToDraw, let color = drawColor {
                                let posX = CGFloat(x) * cellW
                                // CoreGraphicsは原点が左下のためY座標を反転
                                let posY = CGFloat(targetHeight) - (CGFloat(y + 1) * cellH)

                                let attrString = NSAttributedString(
                                    string: String(char),
                                    attributes: [
                                        .font: font,
                                        .foregroundColor: color
                                    ]
                                )
                                let line = CTLineCreateWithAttributedString(attrString)
                                ctx.textPosition = CGPoint(x: posX, y: posY)
                                CTLineDraw(line, ctx)
                            }
                        }
                    }
                }

                CVPixelBufferUnlockBaseAddress(outBuffer, [])
                adaptor.append(outBuffer, withPresentationTime: pts)
            }

            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

            let progress = duration.seconds > 0 ? min(1.0, processedDuration.seconds / duration.seconds) : 0.0
            progressHandler(progress)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        if reader.status == .failed || writer.status == .failed {
            throw writer.error ?? reader.error ?? NSError(domain: "MatrixConverter", code: -2, userInfo: nil)
        }

        return outputURL
    }
}

// MARK: - メイン画面
struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var isProcessing = false
    @State private var progress: Double = 0.0
    @State private var statusMessage: String = "動画を選択してください"

    var body: some View {
        VStack(spacing: 28) {
            Text("Matrix Video Converter")
                .font(.title2.bold())
                .foregroundColor(.green)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .frame(height: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.4), lineWidth: 1)
                    )

                if isProcessing {
                    VStack(spacing: 16) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.green)
                            .padding(.horizontal, 40)

                        Text("\(Int(progress * 100))% 変換中...")
                            .foregroundColor(.green)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    Text(statusMessage)
                        .foregroundColor(.green.opacity(0.8))
                        .font(.system(.subheadline, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }

            PhotosPicker(
                selection: $selectedItem,
                matching: .videos
            ) {
                Label("動画を選択する", systemImage: "video.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isProcessing ? Color.gray : Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(10)
            }
            .disabled(isProcessing)
        }
        .padding(24)
        .background(Color(white: 0.05).ignoresSafeArea())
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await processVideo(item: newItem)
            }
        }
    }

    private func processVideo(item: PhotosPickerItem) async {
        isProcessing = true
        progress = 0.0
        statusMessage = "動画を読み込み中..."

        do {
            guard let movie = try await item.loadTransferable(type: MovieTransferable.self) else {
                throw NSError(domain: "App", code: -1, userInfo: [NSLocalizedDescriptionKey: "動画ファイルの読み込みに失敗しました。"])
            }

            statusMessage = "マトリックス変換処理を実行中..."
            let converter = VideoMatrixConverter()
            let outputURL = try await converter.convert(inputURL: movie.url) { currentProgress in
                Task { @MainActor in
                    self.progress = currentProgress
                }
            }

            statusMessage = "写真アプリへ保存中..."
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            }

            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: movie.url)

            statusMessage = "完了！写真アプリに保存しました。"
        } catch {
            statusMessage = "エラー: \(error.localizedDescription)"
        }

        isProcessing = false
        selectedItem = nil
    }
}

// MARK: - PhotosPicker用 Transferable構造体
struct MovieTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let targetURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: targetURL)
            return MovieTransferable(url: targetURL)
        }
    }
}
