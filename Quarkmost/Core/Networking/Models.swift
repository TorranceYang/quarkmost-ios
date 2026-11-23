import Foundation

// Mattermost API v4 models. Decoded with `.convertFromSnakeCase`.
// Only the fields the app uses are declared; unknown fields are ignored.

public struct User: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let firstName: String?
    public let lastName: String?
    public let nickname: String?
    public let isBot: Bool?
    public let lastPictureUpdate: Int64?
    public let deleteAt: Int64?
    public let email: String?
    public let position: String?
    public let roles: String?
    public let props: JSONValue?
    public let notifyProps: JSONValue?
    public let timezone: JSONValue?

    public var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        let full = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? username : full
    }
}

public struct Team: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let displayName: String
}

public enum ChannelType: String, Codable, Sendable {
    case open = "O", privateChannel = "P", direct = "D", group = "G"
}

public struct Channel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let teamId: String
    public let type: ChannelType
    public let name: String
    public let displayName: String
    public let header: String?
    public let purpose: String?
    public let lastPostAt: Int64
    public let totalMsgCount: Int64?
    public let totalMsgCountRoot: Int64?
    public let deleteAt: Int64
    public let creatorId: String?
    public let createAt: Int64?
}

public struct ChannelMember: Codable, Hashable, Sendable {
    public let channelId: String
    public let userId: String
    public let msgCount: Int64
    public let msgCountRoot: Int64?
    public let mentionCount: Int64
    public let mentionCountRoot: Int64?
    public let lastViewedAt: Int64
    public let notifyProps: JSONValue?

    public var isMuted: Bool { notifyProps?["mark_unread"]?.stringValue == "mention" }
}

/// A sidebar section ("Favorites", "Channels", "Direct Messages", or a custom one).
public struct SidebarCategory: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case favorites, channels, directMessages = "direct_messages", custom }
    public enum Sorting: String, Codable, Sendable { case alpha, recent, manual, none = "" }
    public let id: String
    public let userId: String
    public let teamId: String
    public let displayName: String
    public let type: Kind
    public let sorting: Sorting?
    public let channelIds: [String]
    public var collapsed: Bool?
    public let muted: Bool?
}

/// `{"user_id": ..., "status": "online" | "away" | "dnd" | "offline"}`
public struct UserStatus: Codable, Hashable, Sendable {
    public let userId: String
    public let status: String
}

public struct Preference: Codable, Hashable, Sendable {
    public let userId: String
    public let category: String
    public let name: String
    public let value: String
}

public struct SidebarCategoryList: Codable, Sendable {
    public let categories: [SidebarCategory]
    public let order: [String]

    public var ordered: [SidebarCategory] {
        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return order.compactMap { byId[$0] }
    }
}

public struct FileInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let `extension`: String
    public let size: Int64
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public let hasPreviewImage: Bool?
}

public struct PostMetadata: Codable, Hashable, Sendable {
    public var files: [FileInfo]?
    public var reactions: [Reaction]?
    public var embeds: [PostEmbed]?
    public var images: [String: PostImageMeta]?
}

public struct PostEmbed: Codable, Hashable, Sendable {
    public let type: String
    public let url: String?
    public let data: JSONValue?
}

public struct PostImageMeta: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
}

public struct Reaction: Codable, Hashable, Sendable {
    public let userId: String
    public let postId: String
    public let emojiName: String
    public let createAt: Int64?
}

public struct Post: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createAt: Int64
    public let updateAt: Int64
    public var editAt: Int64
    public let deleteAt: Int64
    public let userId: String
    public let channelId: String
    public let rootId: String
    public var message: String
    public let type: String
    public let props: JSONValue?
    public let fileIds: [String]?
    public var metadata: PostMetadata?
    public let pendingPostId: String?
    public var replyCount: Int?
    public var isPinned: Bool?
    public var isFollowing: Bool?

    public var isSystemMessage: Bool { type.hasPrefix("system_") }
    public var isEdited: Bool { editAt > 0 }
    public var isReply: Bool { !rootId.isEmpty }
    public var fromWebhook: Bool { props?["from_webhook"]?.stringValue == "true" }
    public var fromBot: Bool { props?["from_bot"]?.stringValue == "true" }
    public var overrideUsername: String? { props?["override_username"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    public var overrideIconURL: String? { props?["override_icon_url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    /// Rich message attachments that bots and webhooks send in `props.attachments`.
    public var attachments: [MessageAttachment] {
        guard case .array(let items)? = props?["attachments"] else { return [] }
        return items.compactMap(MessageAttachment.init(json:))
    }

    /// A locally created post shown immediately while it's being sent.
    public static func pending(id: String, channelId: String, userId: String, message: String, rootId: String?) -> Post {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Post(id: id, createAt: now, updateAt: now, editAt: 0, deleteAt: 0, userId: userId, channelId: channelId,
                    rootId: rootId ?? "", message: message, type: "", props: nil, fileIds: nil, metadata: nil,
                    pendingPostId: id, replyCount: 0, isPinned: false, isFollowing: true)
    }
}

public struct MessageAttachment: Hashable, Sendable {
    public struct Field: Hashable, Sendable { public let title: String; public let value: String; public let short: Bool }
    public let color: String?
    public let pretext: String?
    public let authorName: String?
    public let title: String?
    public let titleLink: String?
    public let text: String?
    public let fields: [Field]
    public let footer: String?
    public let imageURL: String?
    public let thumbURL: String?

    init?(json: JSONValue) {
        guard case .object(let o) = json else { return nil }
        func str(_ k: String) -> String? { o[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        color = str("color"); pretext = str("pretext"); authorName = str("author_name")
        title = str("title"); titleLink = str("title_link"); text = str("text"); footer = str("footer")
        imageURL = str("image_url"); thumbURL = str("thumb_url")
        if case .array(let fs)? = o["fields"] {
            fields = fs.compactMap { f in
                guard case .object(let fo) = f else { return nil }
                let value: String = switch fo["value"] {
                case .string(let v)?: v
                case .number(let n)?: n.rounded() == n ? String(Int(n)) : String(n)
                case .bool(let b)?: String(b)
                default: ""
                }
                var short = false
                if case .bool(let b)? = fo["short"] { short = b }
                return Field(title: fo["title"]?.stringValue ?? "", value: value, short: short)
            }
        } else {
            fields = []
        }
    }
}

/// `GET /channels/{id}/posts` returns posts keyed by ID plus an ordering array.
public struct PostList: Codable, Sendable {
    public let order: [String]
    public let posts: [String: Post]
    public let nextPostId: String?
    public let prevPostId: String?

    /// Posts newest-first, as the server orders them.
    public var orderedPosts: [Post] { order.compactMap { posts[$0] } }
}

public struct LoginRequest: Encodable, Sendable {
    public let loginId: String
    public let password: String
    public let token: String?   // MFA code
    public let deviceId: String?
}

/// Arbitrary JSON, for `props` and WebSocket event payloads.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}


public extension User {
    /// `props.customStatus` is a JSON string: {"emoji":"calendar","text":"In a meeting","expires_at":"..."}.
    var customStatus: (emoji: String, text: String)? {
        guard let raw = props?["customStatus"]?.stringValue, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let emoji = obj["emoji"] as? String ?? "", text = obj["text"] as? String ?? ""
        if emoji.isEmpty && text.isEmpty { return nil }
        if let expires = obj["expires_at"] as? String, let date = ISO8601DateFormatter.flexible.date(from: expires),
           date.timeIntervalSince1970 > 0, date < Date() { return nil }
        return (emoji, text)
    }
    var fullName: String { [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    var isSystemAdmin: Bool { roles?.contains("system_admin") ?? false }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public struct UserThread: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var replyCount: Int
    public var lastReplyAt: Int64
    public var lastViewedAt: Int64
    public let participants: [ThreadParticipant]?
    public let post: Post
    public var unreadReplies: Int
    public var unreadMentions: Int
}

public struct ThreadParticipant: Codable, Hashable, Sendable { public let id: String }

public struct ThreadList: Codable, Sendable {
    public let total: Int?
    public let totalUnreadThreads: Int?
    public let totalUnreadMentions: Int?
    public let threads: [UserThread]?
}

public struct Draft: Codable, Hashable, Sendable {
    public let channelId: String
    public let rootId: String?
    public let message: String
    public let updateAt: Int64?
    public let deleteAt: Int64?
}

public struct ChannelStats: Codable, Sendable {
    public let memberCount: Int
    public let pinnedpostCount: Int?
    public let filesCount: Int?
}

public struct FullChannelMember: Codable, Hashable, Sendable {
    public let channelId: String
    public let userId: String
    public let roles: String?
    public let schemeAdmin: Bool?
    public let notifyProps: JSONValue?
}

public struct SlashCommand: Codable, Hashable, Sendable {
    public let trigger: String
    public let autoCompleteDesc: String?
    public let autoCompleteHint: String?
    public let displayName: String?
    public let autoComplete: Bool?
}

public struct UserAutocomplete: Codable, Sendable {
    public let users: [User]?
    public let outOfChannel: [User]?
}

public struct FileUploadResponse: Codable, Sendable { public let fileInfos: [FileInfo] }

public struct FileSearchResults: Codable, Sendable {
    public let order: [String]?
    public let fileInfos: [String: FileInfo]?
    public var ordered: [FileInfo] { (order ?? []).compactMap { fileInfos?[$0] } }
}

public struct CommandResponse: Codable, Sendable {
    public let text: String?
    public let gotoLocation: String?
    public let responseType: String?
}

extension JSONValue: ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { a, _ in a })) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}
