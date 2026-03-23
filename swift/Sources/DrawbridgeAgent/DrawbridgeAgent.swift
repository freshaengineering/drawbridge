import ArgumentParser
import Foundation

// TODO: Uncomment when swift-erlang-actor-system resolves:
// import ErlangActorSystem

@main
struct DrawbridgeAgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drawbridge-agent",
        abstract: "Apple Container lifecycle manager with Erlang distribution interface"
    )

    @Option(name: .long, help: "Erlang node name (e.g. drawbridge_agent@localhost)")
    var nodeName: String = "drawbridge_agent@localhost"

    @Option(name: .long, help: "Erlang cluster cookie")
    var cookie: String = "drawbridge"

    @Option(name: .long, help: "EPMD port")
    var epmdPort: Int = 4369

    func run() async throws {
        print("[DrawbridgeAgent] Starting node=\(nodeName) cookie=\(cookie) epmd=\(epmdPort)")

        let manager = ContainerManager()

        // Reconcile with Apple Container on startup to pick up already-running containers
        await manager.reconcile()

        // TODO: When swift-erlang-actor-system is available, replace the CommandServer
        // fallback below with Erlang distribution:
        //
        //   let actorSystem = try await ErlangActorSystem(
        //       node: nodeName,
        //       cookie: cookie,
        //       epmdPort: epmdPort
        //   )
        //   try await actorSystem.register(manager, name: "container_manager")
        //   print("[DrawbridgeAgent] Registered container_manager, waiting for calls...")
        //   try await actorSystem.terminated  // park here until node shutdown
        //
        // For now, fall back to stdin/stdout JSON protocol so the Elixir Port still works:

        print("[DrawbridgeAgent] Erlang distribution not yet available; using stdin/stdout JSON protocol")
        print("[DrawbridgeAgent] Container manager ready, waiting for connections...")
        fflush(stdout)

        let server = CommandServer(manager: manager)
        try await server.run()
    }
}
