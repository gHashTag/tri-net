// Token scope regression test for phone/shared/CallIdentity.swift (#415).
// Exercises the real load/save paths and the Authorization header value:
//   swiftc phone/shared/CallIdentity.swift phone/shared/tests/token_scope/main.swift -o token_scope && ./token_scope
import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func freshDefaults() -> UserDefaults {
    let suite = "trinet.token-scope.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// A bundle with only the given Info.plist keys, so a test controls the
/// bundled address and token exactly.
func bundle(_ info: [String: String]) -> Bundle {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("token-scope-\(UUID().uuidString).bundle")
    let contents = root.appendingPathComponent("Contents")
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist = info
    plist["CFBundleIdentifier"] = "test.token-scope.\(UUID().uuidString)"
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: contents.appendingPathComponent("Info.plist"))
    return Bundle(path: root.path)!
}

let serverA = "https://a.example.test"
let serverB = "https://b.example.test"
let tokenA = "token-for-a-1f0c"
let empty = bundle([:])

// 1. Address-only edit in Settings: the form still holds A's token, only the
//    address changes to B. Neither the save nor a reload after restart may
//    send A's token to B, and A keeps its token.
do {
    let defaults = freshDefaults()
    var form = InternetCallConfiguration(apiBaseURL: serverA, liveKitURL: "", accessToken: tokenA, developmentRoomToken: "")
    form.save(defaults: defaults, bundle: empty)
    let atA = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(atA.authorizationHeader == "Bearer \(tokenA)", "A's token is sent to A")

    form = atA
    form.apiBaseURL = serverB
    form.save(defaults: defaults, bundle: empty)
    let atB = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(atB.apiBaseURL == serverB, "address-only edit switches to B")
    check(atB.authorizationHeader == nil, "address-only edit: no Authorization to B")
    check(InternetCallConfiguration.storedAccessTokens(defaults)[serverB] == nil, "address-only edit: nothing stored for B")
    check(InternetCallConfiguration.storedAccessTokens(defaults)[serverA] == tokenA, "address-only edit: A keeps its token")

    // Restart: a new load from the same defaults still sends nothing to B.
    let restarted = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(restarted.authorizationHeader == nil, "after restart: no Authorization to B")

    // Back to A: A's token is used again.
    var back = restarted
    back.apiBaseURL = serverA
    back.save(defaults: defaults, bundle: empty)
    check(InternetCallConfiguration.load(defaults: defaults, bundle: empty).authorizationHeader == "Bearer \(tokenA)",
          "switching back to A sends A's token")
}

// 2. A token typed for B together with the address is stored for B only.
do {
    let defaults = freshDefaults()
    InternetCallConfiguration(apiBaseURL: serverA, liveKitURL: "", accessToken: tokenA, developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    InternetCallConfiguration(apiBaseURL: serverB, liveKitURL: "", accessToken: "token-for-b-77aa", developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    check(InternetCallConfiguration.load(defaults: defaults, bundle: empty).authorizationHeader == "Bearer token-for-b-77aa",
          "a new token for B is sent to B")
    check(InternetCallConfiguration.storedAccessTokens(defaults)[serverA] == tokenA, "A's token is kept")
}

// 3. Legacy migration: an older build saved one token with address A. The
//    bundle now points at a .local server, which preferredAPIBaseURL may pick
//    over a private saved IPv4 address; the token stays bound to A.
do {
    let defaults = freshDefaults()
    let legacyAddress = "http://192.168.1.20:8080"
    defaults.set(legacyAddress, forKey: "internetAPIBaseURL")
    defaults.set(tokenA, forKey: "serviceAccessToken")
    let bundled = bundle(["TRINET_API_BASE_URL": "http://calls.local:8080"])
    let loaded = InternetCallConfiguration.load(defaults: defaults, bundle: bundled)
    check(loaded.apiBaseURL == "http://calls.local:8080", "legacy: bundled .local address replaces private IPv4")
    check(loaded.authorizationHeader == nil, "legacy: no Authorization to the rewritten address")
    check(InternetCallConfiguration.storedAccessTokens(defaults)["http://192.168.1.20:8080"] == tokenA,
          "legacy: token bound to the address it was saved with")
    check(defaults.string(forKey: "serviceAccessToken") == nil, "legacy keys removed")
}

// 4. Legacy migration with a recorded origin wins over the saved address.
do {
    let defaults = freshDefaults()
    defaults.set(serverB, forKey: "internetAPIBaseURL")
    defaults.set(tokenA, forKey: "serviceAccessToken")
    defaults.set(serverA, forKey: "serviceAccessTokenOrigin")
    let loaded = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(loaded.apiBaseURL == serverB, "legacy origin: address B kept")
    check(loaded.authorizationHeader == nil, "legacy origin: A's token not sent to B")
    check(InternetCallConfiguration.storedAccessTokens(defaults)[serverA] == tokenA, "legacy origin: token bound to A")
}

// 5. Legacy token without any address is never sent anywhere.
do {
    let defaults = freshDefaults()
    defaults.set(tokenA, forKey: "serviceAccessToken")
    let bundled = bundle(["TRINET_API_BASE_URL": serverB])
    let loaded = InternetCallConfiguration.load(defaults: defaults, bundle: bundled)
    check(loaded.authorizationHeader == nil, "legacy without address: not sent to the bundled server")
    check(InternetCallConfiguration.storedAccessTokens(defaults).isEmpty, "legacy without address: not bound")
    check(defaults.string(forKey: "serviceAccessToken") == nil, "legacy without address: deleted")
}

// 5b. The same originless legacy token, then a new address saved in
//     Settings and a restart: the token never reaches the new host.
do {
    let defaults = freshDefaults()
    defaults.set("old-sentinel-3c1d", forKey: "serviceAccessToken")
    let first = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(first.authorizationHeader == nil, "originless legacy: first load sends nothing")
    var form = first
    form.apiBaseURL = serverB
    form.save(defaults: defaults, bundle: empty)
    let reloaded = InternetCallConfiguration.load(defaults: defaults, bundle: empty)
    check(reloaded.apiBaseURL == serverB, "originless legacy: new address saved")
    check(reloaded.authorizationHeader == nil, "originless legacy: no Authorization to the new address")
    check(!InternetCallConfiguration.storedAccessTokens(defaults).values.contains("old-sentinel-3c1d"),
          "originless legacy: token not stored for any origin")
    check(defaults.string(forKey: "serviceAccessToken") == nil, "originless legacy: legacy key deleted")
}

// 5c. Save before any load (the first thing a build does is save): the
//     originless legacy token is still not adopted by the saved address.
do {
    let defaults = freshDefaults()
    defaults.set("old-sentinel-3c1d", forKey: "serviceAccessToken")
    InternetCallConfiguration(apiBaseURL: serverB, liveKitURL: "", accessToken: "", developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    check(InternetCallConfiguration.load(defaults: defaults, bundle: empty).authorizationHeader == nil,
          "originless legacy, save first: no Authorization to the saved address")
}

// 6. A bundled token is sent only to the bundled origin, and an address-only
//    edit with the bundled token in the form does not store it for B.
do {
    let defaults = freshDefaults()
    let bundled = bundle(["TRINET_API_BASE_URL": serverA, "TRINET_SERVICE_ACCESS_TOKEN": "bundled-token-9e"])
    let atA = InternetCallConfiguration.load(defaults: defaults, bundle: bundled)
    check(atA.authorizationHeader == "Bearer bundled-token-9e", "bundled token sent to the bundled origin")
    var form = atA
    form.apiBaseURL = serverB
    form.save(defaults: defaults, bundle: bundled)
    let atB = InternetCallConfiguration.load(defaults: defaults, bundle: bundled)
    check(atB.authorizationHeader == nil, "bundled token not sent to B after an address-only edit")
}

// 7. Clearing the token field while staying on the same server removes
//    only that server's token.
do {
    let defaults = freshDefaults()
    InternetCallConfiguration(apiBaseURL: serverA, liveKitURL: "", accessToken: tokenA, developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    InternetCallConfiguration(apiBaseURL: serverB, liveKitURL: "", accessToken: "token-for-b-77aa", developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    InternetCallConfiguration(apiBaseURL: serverB, liveKitURL: "", accessToken: "", developmentRoomToken: "")
        .save(defaults: defaults, bundle: empty)
    check(InternetCallConfiguration.load(defaults: defaults, bundle: empty).authorizationHeader == nil,
          "cleared token on B is no longer sent")
    check(InternetCallConfiguration.storedAccessTokens(defaults)[serverA] == tokenA, "clearing B keeps A's token")
}

// 8. The header is absent for an empty token.
check(InternetCallConfiguration(apiBaseURL: serverA, liveKitURL: "", accessToken: "", developmentRoomToken: "")
        .authorizationHeader == nil, "empty token: no Authorization")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
