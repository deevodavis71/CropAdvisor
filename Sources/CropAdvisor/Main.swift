import Foundation

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            Snapshot.run(CommandLine.arguments)
        }
        if CommandLine.arguments.contains("--analyze") {
            exit(CLI.run(CommandLine.arguments))
        }
        CropAdvisorApp.main()
    }
}
