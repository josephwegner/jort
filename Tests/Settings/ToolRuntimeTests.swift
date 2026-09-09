import XCTest
@testable import JortSettings

final class ToolRuntimeTests: XCTestCase {
    private func package(_ source: String) -> ToolPackage {
        ToolPackage(manifest: .init(id: "dev.jort.test", name: "Test", command: "/test"), source: source)
    }
    func testAsyncContentAndFrozenCapturedFacilities() async {
        let p = package("export default async function(input) { return {output: [input.content, input.clock, input.uuid, Object.isFrozen(input)].join('|')}; }")
        let result = await ToolRuntime.execute(p, input: .init(content: "🌲", date: Date(timeIntervalSince1970: 0), uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        XCTAssertEqual(result.output, "🌲|1970-01-01T00:00:00Z|00000000-0000-0000-0000-000000000001|true")
    }
    func testSyntaxValidationDoesNotExecute() {
        XCTAssertNoThrow(try ToolRuntime.validate(package("throw new Error('never executed'); export default async function() {}")))
        XCTAssertThrowsError(try ToolRuntime.validate(package("export default async function( {")))
    }
    func testDynamicEvaluationDeniedThroughConstructorPaths() async {
        for expression in ["eval('1')", "(0, eval)('1')", "Function('return 1')()", "(()=>{}).constructor('return 1')()", "(async()=>{}).constructor('return 1')()", "(function*(){}).constructor('return 1')()"] {
            let result = await ToolRuntime.execute(package("export default async function() { return {output: String(\(expression))}; }"), input: .init(content: ""))
            XCTAssertNil(result.output, expression); XCTAssertNotNil(result.error, expression)
        }
    }
    func testNoAmbientAuthorityOrImports() async {
        let result = await ToolRuntime.execute(package("export default async function() { return {output: [typeof fetch, typeof process, typeof require, typeof std, typeof os, typeof Date, typeof Math.random].join(',')}; }"), input: .init(content: ""))
        XCTAssertEqual(result.output, Array(repeating: "undefined", count: 7).joined(separator: ","))
        let imported = await ToolRuntime.execute(package("export default async function() { return await import('std'); }"), input: .init(content: ""))
        XCTAssertNotNil(imported.error)
    }
    func testTimeoutMemoryAndResultLimitsAreLocal() async {
        for source in ["while(true) {}", "const a = []; while(true) a.push('x'.repeat(100000));"] {
            let result = await ToolRuntime.execute(package("export default async function() { \(source) }"), input: .init(content: ""), timeout: 0.05)
            XCTAssertNotNil(result.error)
        }
        var p = package("export default async function() { return {output: '12345'}; }")
        p.manifest.maximumOutputBytes = 4
        let result = await ToolRuntime.execute(p, input: .init(content: ""))
        XCTAssertNotNil(result.error)
        let healthy = await ToolRuntime.execute(package("export default async function() { return {output: 'ok'}; }"), input: .init(content: ""))
        XCTAssertEqual(healthy.output, "ok")
    }
    func testCancellationInterruptsLoop() async {
        let p = package("export default async function() { while(true) {} }")
        let task = Task { await ToolRuntime.execute(p, input: .init(content: "")) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.error, "Cancelled.")
    }
    func testDuplicateResolutionAndExceptionsHaveOneBoundedResult() async {
        let p = package("export default async function() { return new Promise(resolve => { resolve({output:'first'}); resolve({output:'second'}); throw Error('late'); }); }")
        let result = await ToolRuntime.execute(p, input: .init(content: ""))
        XCTAssertEqual(result.output, "first")
        let thrown = await ToolRuntime.execute(package("export default async function() { throw {toString(){while(true){}}}; }"), input: .init(content: ""))
        XCTAssertNotNil(thrown.error)
        let frozen = await ToolRuntime.execute(package("export default async function(input) { input.content = 'mutated'; return {output:input.content}; }"), input: .init(content: "original"))
        XCTAssertNotNil(frozen.error)
    }
    func testConcurrentCancellationRacesRemainIsolated() async {
        let p = package("export default async function() { await Promise.resolve(); return {output:'ok'}; }")
        var jobs: [Task<ToolExecutionResult, Never>] = []
        for index in 0..<16 {
            let job = Task { await ToolRuntime.execute(p, input: .init(content: "")) }
            if index.isMultiple(of: 2) { job.cancel() }
            jobs.append(job)
        }
        for job in jobs {
            let result = await job.value
            XCTAssertTrue(result.output == "ok" || result.error == "Cancelled.")
        }
    }
}
