import Testing
@testable import MatrixNetModel

struct TunneledFlowReconstructorTests {
    private func address(_ string: String) throws -> IPAddress {
        try #require(IPAddress(string))
    }

    @Test func reconstructsAppDomainAndBytesFromTunnelOutbound() throws {
        // 真机: utun 出向 proc=Safari, src 网关 198.19.0.1:52750 -> fake 198.0.0.60:443
        let gateway = try address("198.19.0.1")
        let fake = try address("198.0.0.60")
        let app = Endpoint(address: gateway, port: 52750)
        let dst = Endpoint(address: fake, port: 443)
        let outbound = FiveTuple(proto: .tcp, source: app, destination: dst)
        let inbound = FiveTuple(proto: .tcp, source: dst, destination: app)

        var sut = TunneledFlowReconstructor()
        // ClientHello 出向带 SNI 与真实 app PID
        sut.ingest(.init(
            onTunnel: true,
            pid: 1778,
            outbound: true,
            fiveTuple: outbound,
            payloadLength: 517,
            sni: "www.cloudflare.com"
        ))
        // 入向回包由代理写回,pid 不同;按 flowKey 归同一流并累加
        sut.ingest(.init(
            onTunnel: true,
            pid: 14428,
            outbound: false,
            fiveTuple: inbound,
            payloadLength: 1400,
            sni: nil
        ))

        let flows = sut.flows()
        #expect(flows.count == 1)
        let flow = try #require(flows.first)
        #expect(flow.pid == 1778) // 取出向腿的真实 app PID
        #expect(flow.domain == "www.cloudflare.com") // 取出向 SNI
        #expect(flow.fakeDestination.address == fake)
        #expect(flow.bytesOut == 517)
        #expect(flow.bytesIn == 1400)
    }

    @Test func ignoresNonTunnelPackets() throws {
        // en0 上代理上游腿不归本 reconstructor(由 ConnectionAggregator 单独去重)
        let local = try address("172.30.200.128")
        let upstream = try address("101.226.100.232")
        let tuple = FiveTuple(
            proto: .tcp,
            source: Endpoint(address: local, port: 50002),
            destination: Endpoint(address: upstream, port: 443)
        )
        var sut = TunneledFlowReconstructor()
        sut.ingest(.init(
            onTunnel: false,
            pid: 14428,
            outbound: true,
            fiveTuple: tuple,
            payloadLength: 1200,
            sni: nil
        ))
        #expect(sut.flows().isEmpty)
    }

    @Test func keepsAppPidFromOutboundEvenIfInboundSeenFirst() throws {
        let gateway = try address("198.19.0.1")
        let fake = try address("198.0.0.16")
        let app = Endpoint(address: gateway, port: 49956)
        let dst = Endpoint(address: fake, port: 443)
        let outbound = FiveTuple(proto: .tcp, source: app, destination: dst)
        let inbound = FiveTuple(proto: .tcp, source: dst, destination: app)

        var sut = TunneledFlowReconstructor()
        sut.ingest(.init(
            onTunnel: true,
            pid: 14428,
            outbound: false,
            fiveTuple: inbound,
            payloadLength: 60,
            sni: nil
        ))
        sut.ingest(.init(
            onTunnel: true,
            pid: 24179,
            outbound: true,
            fiveTuple: outbound,
            payloadLength: 200,
            sni: "api.anthropic.com"
        ))

        let flow = try #require(sut.flows().first)
        #expect(flow.pid == 24179) // 出向腿 PID 覆盖入向腿 PID
        #expect(flow.domain == "api.anthropic.com")
    }
}
