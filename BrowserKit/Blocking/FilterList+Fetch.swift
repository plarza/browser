import Foundation

extension FilterList {
    /// The lists that could be fetched, in the order asked for.
    @MainActor
    static func fetch(_ urls: [URL]) async -> [FilterList] {
        let session = Engine.session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        let texts = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200
                    else { return (index, nil) }
                    return (index, String(decoding: data, as: UTF8.self))
                }
            }
            var texts: [Int: String] = [:]
            for await (index, text) in group { texts[index] = text }
            return texts
        }
        return urls.indices.compactMap { index in texts[index].map { FilterList(url: urls[index], text: $0) } }
    }
}
