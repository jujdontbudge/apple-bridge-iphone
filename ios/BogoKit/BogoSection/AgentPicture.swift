import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PictureLoad: Sendable {
    case loading
    case shown(UIImage)
    case unavailable(String)
}

@MainActor
@Observable
final class Pictures {
    static let shared = Pictures()
    private static let kept = 24

    private(set) var loads: [String: PictureLoad] = [:]
    private var order: [String] = []

    func load(_ link: String) {
        guard loads[link] == nil else { return }
        loads[link] = .loading
        order.append(link)
        while order.count > Self.kept { loads[order.removeFirst()] = nil }
        Task {
            let result = await PictureFetch.picture(link)
            if loads[link] != nil { loads[link] = result }
        }
    }
}

enum PictureFetch {
    static let byteLimit = 5_000_000
    static let pixelLimit = 30_000_000
    static let shownPixels = 1400
    static let formats: [UTType] = [.jpeg, .png, .heic, .heif, .gif, .webP]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = ["Accept": "image/jpeg, image/png, image/heic, image/gif, image/webp", "Accept-Language": "en"]
        return URLSession(configuration: configuration, delegate: PictureGuard(), delegateQueue: nil)
    }()

    static func picture(_ link: String) async -> PictureLoad {
        guard let url = URL(string: link, encodingInvalidCharacters: false), url.host()?.isEmpty == false,
              url.user() == nil, url.password() == nil else { return .unavailable("not a valid link") }
        guard url.scheme?.lowercased() == "https" else { return .unavailable("not https") }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return .unavailable("couldn’t load") }
            guard http.statusCode == 200 else {
                return .unavailable((300..<400).contains(http.statusCode) ? "redirected off https" : "error \(http.statusCode)")
            }
            let type = http.mimeType?.lowercased() ?? ""
            guard type.hasPrefix("image/") else { return .unavailable("not an image") }
            guard type != "image/svg+xml" else { return .unavailable("SVG isn’t supported") }
            guard http.expectedContentLength <= byteLimit else { return .unavailable("over 5 MB") }
            var data = Data()
            data.reserveCapacity(max(0, Int(http.expectedContentLength)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return .unavailable("over 5 MB") }
            }
            return decode(data)
        } catch let error as URLError where error.code == .timedOut {
            return .unavailable("too slow")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .unavailable("offline")
        } catch {
            return .unavailable("couldn’t load")
        }
    }

    static func decode(_ data: Data) -> PictureLoad {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              formats.contains(where: { type.conforms(to: $0) }) else { return .unavailable("unsupported format") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return .unavailable("unsupported format") }
        guard width <= pixelLimit / height else { return .unavailable("too many pixels") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: shownPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .unavailable("couldn’t read it") }
        return .shown(UIImage(cgImage: image))
    }
}

final class PictureGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }
}

struct AgentPicture: View {
    let link: String
    var side: CGFloat?
    @State private var pictures = Pictures.shared

    var body: some View {
        content.onAppear { pictures.load(link) }
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        switch pictures.loads[link] ?? .loading {
        case .shown(let image) where side != nil:
            let side = side ?? 0
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(image.hasAlpha ? side / 10 : 0)
                .frame(width: side, height: side)
                .background(Color(.tertiarySystemFill))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
                .accessibilityLabel("Agent’s picture")
        case .shown(let image):
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: image.hasAlpha ? 236 : 260)
                    .padding(image.hasAlpha ? 12 : 0)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Agent’s picture")
                Text("Agent’s picture (unverified)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading where side != nil:
            tile(shape) { ProgressView().controlSize(.small) }
        case .unavailable(let why) where side != nil:
            tile(shape) { Image(systemName: "photo").foregroundStyle(.tertiary) }
                .accessibilityLabel("Can’t preview · \(why)")
        case .loading:
            note(shape) {
                ProgressView().controlSize(.small)
                Text("Loading picture").foregroundStyle(.secondary)
            }
        case .unavailable(let why):
            note(shape) {
                Image(systemName: "photo").foregroundStyle(.tertiary)
                Text("Can’t preview · \(why)").foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ shape: RoundedRectangle, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: side, height: side)
            .background(Color(.tertiarySystemFill), in: shape)
    }

    private func note(_ shape: RoundedRectangle, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: shape)
            .accessibilityElement(children: .combine)
    }
}

private extension UIImage {
    var hasAlpha: Bool {
        switch cgImage?.alphaInfo {
        case .first?, .last?, .premultipliedFirst?, .premultipliedLast?: return true
        default: return false
        }
    }
}
