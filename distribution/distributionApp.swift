//
//  distributionApp.swift
//  distribution
//
//  Created by Mackenzie Straight on 12/1/23.
//

import SwiftUI
import SWXMLHash
import Zip

@main
struct distributionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(retroPath: getRetroPath())
        }.defaultSize(width: 400.0, height: 600.0)
    }
    
    private func getRetroPath() -> URL {
        let parentURL = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        
        if (try? parentURL.appending(component: "eXoDOS").checkResourceIsReachable()) ?? false {
            return parentURL
        }
        
        return URL(fileURLWithPath: "/Volumes/Retro")
    }
}

struct ContentView: View {
    var retroPath: URL
    var preview = false
    @State private var searchText = ""
    @State private var items: [Game] = []
    @State private var isRunning = false
    @State private var hasError = false
    @State private var status = "Ready."
    
    private let types: [String] = ["Box - Front", "Box - 3D", "Box - Front - Reconstructed", "Advertisement Flyer - Front", "Screenshot - Game Title"]
    private let regions: [String] = ["United States", "North America"]
    
    var body: some View {
        VStack {
            TextField("Search", text: $searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
            
            let games = filteredItems
            if isRunning || hasError {
                Text(status).italic()
            } else {
                Text("\(games.count) game\(games.count != 1 ? "s" : "").").italic()
            }
            
            List(games) { game in
                HStack {
                    GameImageView(retroPath: retroPath, game: game, types: types, regions: regions)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text(game.title)
                        Text(game.platform).italic().opacity(0.9)
                    }
                    Spacer()
                    Button(action: { handlePlay(for: game) }, label: {
                        Image(systemName: "play.circle.fill")
                    }).disabled(isRunning)
                }
                .tag(game.id)
            }
        }
        .onAppear {
            if !preview {
                loadGames()
            }
        }
    }
    
    var filteredItems: [Game] {
        if searchText.isEmpty {
            return items
        } else {
            return items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    func loadCollection(_ leGames: inout [Game], _ collection: String, _ xmlPath: String) {
        let path = retroPath.appending(components: collection, "xml", xmlPath)
        guard let data = try? Data(contentsOf: path) else {
            return
        }
        let xml = XMLHash.parse(data)
        for el in xml["LaunchBox"]["Game"].all {
            let title = el["Title"].element!.text
            var item = Game(
                collection: collection,
                platform: el["Platform"].element!.text,
                title: title, path: el["ApplicationPath"].element!.text)
            
            item.id = UUID(uuidString:el["ID"].element!.text)!
            leGames.append(item)
        }
    }
    
    func loadGames() {
        DispatchQueue.global(qos: .background).async {
            let jsonPath = retroPath.appending(component: ".distribution.json")
            if (try? jsonPath.checkResourceIsReachable()) ?? false {
                do {
                    let decoder = JSONDecoder()
                    let games = try decoder.decode([Game].self, from: Data(contentsOf: jsonPath))
                    
                    DispatchQueue.main.async {
                        self.items = games
                    }
                    return
                } catch {
                    print("Failed to load cache, falling back to XML")
                }
            }
            
            var games: [Game] = []
            loadCollection(&games, "eXoDOS", "all/MS-DOS.xml")
            loadCollection(&games, "eXoWin3x", "Windows 3x.xml")
            games = games.sorted(by: { $0.title < $1.title })
            let encoder = JSONEncoder()
            let data = try? encoder.encode(games)
            try? data?.write(to: jsonPath)
            
            DispatchQueue.main.async {
                self.items = games
            }
        }
    }
    
    private func setStatusAsync(_ status: String) {
        DispatchQueue.main.async {
            self.status = status
        }
    }
    
    private func setErrorAsync(_ status: String) {
        DispatchQueue.main.async {
            self.status = status
            hasError = true
            isRunning = false
        }
    }
    
    private func handlePlay(for item: Game) {
        isRunning = true
        status = "Checking game data..."
        DispatchQueue.global(qos: .background).async {
            playExo(item)
        }
    }
    
    private func playExo(_ item: Game) {
        let pathComponents = item.path.split(separator: "\\")
        let batchFileName = pathComponents.last!
        let gameDirName = String(pathComponents[pathComponents.count - 2])
        let zipName = batchFileName.replacingOccurrences(of: ".bat", with: ".zip")
        let exoRoot = self.retroPath.appending(components: item.collection, "eXo", item.collection)
        let zipPath = exoRoot.appending(component: zipName)
        let gamePath = exoRoot.appending(component: gameDirName)
        let zipExists = (try? zipPath.checkResourceIsReachable()) ?? false
        let gameExists = (try? gamePath.checkResourceIsReachable()) ?? false
        
        if !gameExists && !zipExists {
            setStatusAsync("Game .zip is missing.")
            return
        }
        
        if !gameExists {
            setStatusAsync("Extracting game...")
            do {
                try Zip.unzipFile(zipPath, destination: exoRoot, overwrite: true, password: nil)
            } catch {
                setErrorAsync("Failed to extract game!")
                return
            }
        }
        
        setStatusAsync("Launching game...")
        
        let kid = Process()
        kid.executableURL = retroPath.appending(components: "DOSBox Staging.app", "Contents", "MacOS", "dosbox")
        var dosboxConfPath = self.retroPath
        dosboxConfPath.append(component: item.collection)
        for component in pathComponents[0..<pathComponents.count - 1] {
            dosboxConfPath.append(component: component)
        }
        dosboxConfPath.append(component: "dosbox.conf")
        kid.arguments = ["-conf", dosboxConfPath.path]
        kid.currentDirectoryURL = exoRoot.deletingLastPathComponent()
        print(String(describing:kid.arguments))
        do {
            try kid.run()
        } catch {
            setErrorAsync("Failed to launch game.")
            return
        }
        setStatusAsync("Waiting for game...")
        kid.waitUntilExit()
        
        DispatchQueue.main.async {
            isRunning = false
        }
    }
}

func titleToPath(_ input: String) -> String {
    let replacedString = input
        .replacingOccurrences(of: ":", with: "_")
        .replacingOccurrences(of: "'", with: "_")
    return replacedString
}

func makeImageCache() -> NSCache<NSUUID, NSImage> {
    let result = NSCache<NSUUID, NSImage>()
    
    result.countLimit = 100
    return result
}

class GameImageCache {
    static let shared = makeImageCache()
    
    static func getImage(forKey key: UUID) -> NSImage? {
        return shared.object(forKey: key as NSUUID)
    }
    
    static func setImage(_ image: NSImage, forKey key: UUID) {
        shared.setObject(image, forKey: key as NSUUID)
    }
}

class GameImageLoader: ObservableObject {
    @Published var image: Image?
    private var retroPath: URL
    private var game: Game
    private var types: [String]
    private var regions: [String]
    
    init(retroPath: URL, game: Game, types: [String], regions: [String]) {
        self.retroPath = retroPath
        self.game = game
        self.types = types
        self.regions = regions
    }
    
    private func tryLoadImage(source: URL) -> Bool {
        guard let data = try? Data(contentsOf: source),
              let nsImage = NSImage(data: data) else {
            return false
        }
        DispatchQueue.main.async {
            self.image = Image(nsImage: nsImage)
            GameImageCache.setImage(nsImage, forKey: self.game.id)
        }
        return true
    }
    
    func load() {
        if let nsImage = GameImageCache.getImage(forKey: game.id) {
            self.image = Image(nsImage: nsImage)
        } else {
            loadImage()
        }
    }
    
    func unload() {
        self.image = nil
    }
    
    private func loadImage() {
        DispatchQueue.global(qos: .background).async {
            for ext in ["jpg", "png"] {
                let fileName = "\(titleToPath(self.game.title))-01.\(ext)"
                
                for type in self.types {
                    let imageBase = self.retroPath.appending(components: self.game.collection, "Images", self.game.platform, type)
                    for region in self.regions {
                        let regionBase = imageBase.appending(component: region)
                        let path = regionBase.appending(component: fileName)
                        
                        if self.tryLoadImage(source: path) {
                            return
                        }
                    }
                    
                    if self.tryLoadImage(source: imageBase.appending(component: fileName)) {
                        return
                    }
                }
            }
        }
    }
}

struct GameImageView: View {
    @StateObject private var loader: GameImageLoader
    
    init(retroPath: URL, game: Game, types: [String], regions: [String]) {
        _loader = StateObject(wrappedValue: GameImageLoader(retroPath: retroPath, game: game, types: types, regions: regions))
    }
    
    var body: some View {
        Group {
            if let image = loader.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onDisappear { loader.unload() }
            } else {
                Rectangle().fill(Color.gray)
                    .onAppear { loader.load() }
            }
        }
    }
}

struct Game: Identifiable, Codable {
    var id = UUID()
    var collection: String
    var platform: String
    var title: String
    var path: String
}

#Preview {
    ContentView(retroPath: URL(fileURLWithPath: "/Volumes/Retro"), preview: true)
}
