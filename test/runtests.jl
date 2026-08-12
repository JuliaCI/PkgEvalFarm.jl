using Test
using PkgEvalFarm
using AWS
using Dates
using JSON
import PkgEval

const PEF = PkgEvalFarm

# PKGEVAL_TEST_ONLY=<name> runs a single expensive suite (seal, e2e, broker,
# moto, sim) for fast iteration; the cheap inline testsets always run.
const TEST_ONLY = get(ENV, "PKGEVAL_TEST_ONLY", "")
want(name) = isempty(TEST_ONLY) || TEST_ONLY == name

include("motohelpers.jl")

@testset "PkgEvalFarm" begin

@testset "schema" begin
    @testset "run ids" begin
        id = PEF.new_run_id(DateTime(2026, 7, 25, 1, 2, 3))
        @test startswith(id, "20260725-010203-")
        @test PEF.new_run_id() != PEF.new_run_id()
    end

    @testset "job keys" begin
        @test PEF.job_key("primary", "Example") == "primary#Example"
        @test PEF.split_job_key("primary#Example") == ("primary", "Example")
        # package names can't contain '#', but be safe about config names
        @test PEF.split_job_key("primary#Weird#Name") == ("primary", "Weird#Name")
    end

    @testset "DynamoDB marshalling" begin
        item = Dict("s" => "x", "n" => 3, "f" => 1.5, "b" => true, "nul" => nothing,
                    "l" => Any["a", 1], "m" => Dict("k" => "v"))
        @test PEF.ddb_parse(PEF.ddb_item(item)) == item
        @test PEF.ddb_wrap(3)["N"] == "3"
        @test PEF.ddb_unwrap(Dict("N" => "2.5")) === 2.5
    end

    @testset "Configuration round-trip" begin
        cfg = PkgEval.Configuration(; name="primary", julia="JuliaLang/julia#0123abc",
                                    buildflags=["LLVM_ASSERTIONS=1"], time_limit=120.0,
                                    rr=PkgEval.RREnabled, goal=:load)
        d = JSON.parse(JSON.json(PEF.config_to_dict(cfg)))  # through JSON, like DynamoDB
        cfg2 = PEF.config_from_dict(d)
        @test cfg2.name == "primary"
        @test cfg2.julia == "JuliaLang/julia#0123abc"
        @test cfg2.buildflags == ["LLVM_ASSERTIONS=1"]
        @test cfg2.time_limit == 120.0
        @test cfg2.rr == PkgEval.RREnabled
        @test cfg2.goal === :load
        # defaults are not serialized, so they keep tracking PkgEval
        @test !haskey(d, "memory_limit")
        @test !PkgEval.ismodified(cfg2, :memory_limit)
        # unknown settings fail loudly instead of being dropped
        @test_throws ErrorException PEF.config_from_dict(Dict("name" => "x", "frobnicate" => 1))
    end

    @testset "error_line extraction" begin
        el = PEF.error_line
        # first non-generic ERROR: line wins, ANSI/\r stripped
        @test el("Testing...\n\e[91mERROR: MethodError: no method matching f()\e[0m\r\n") ==
              "ERROR: MethodError: no method matching f()"
        # crash-class markers trump an earlier ERROR: line
        @test el("ERROR: whatever\njulia: gc.c:123: Assertion `x' failed\n") ==
              "julia: gc.c:123: Assertion `x' failed"
        @test el("Internal error: during type inference\n") ==
              "Internal error: during type inference"
        # among crash-class markers, the first *line* wins, not the first pattern
        @test el("Internal error: inference\njulia: Assertion `x' failed\n") ==
              "Internal error: inference"
        # generic restatements are skipped in favour of the failure location
        @test el("""
                 Loss: Test Failed at /pkg/test/runtests.jl:87
                 ERROR: LoadError: Some tests did not pass: 3 passed, 1 failed
                 """) == "Loss: Test Failed at /pkg/test/runtests.jl:87"
        @test el("all fine\nTesting X tests passed\n") === nothing
        # long lines are clipped to the 240-char budget
        long = "ERROR: " * "x"^300
        @test length(something(el(long))) == 240
        @test endswith(something(el(long)), "…")

        # candidate lists: log order within a tier, deduplicated by normalized
        # form (the /b variant collapses into the /a one), capped by `limit`
        elc = PEF.error_line_candidates
        @test elc("ERROR: Shared noise\n" *
                  "ERROR: MethodError: no method matching f() at /a/x.jl:1\n" *
                  "ERROR: MethodError: no method matching f() at /b/y.jl:2\n"; limit=4) ==
              ["ERROR: Shared noise",
               "ERROR: MethodError: no method matching f() at /a/x.jl:1"]
        # crash-class markers outrank ERROR: lines in the list, as for error_line
        @test elc("ERROR: x\nInternal error: boom\n"; limit=4) ==
              ["Internal error: boom", "ERROR: x"]
        @test length(elc(join(["ERROR: e$i" for i in 1:10], '\n'); limit=4)) == 4
        # error_line stays the first candidate
        @test el("ERROR: a\nERROR: b\n") == "ERROR: a"

        # pass-side noise hashes: one per distinct error-shaped line, empty for
        # a clean log (=> the attribute is omitted entirely)
        nh = PEF.pass_sig_hashes("ok\nERROR: expected error at /x/y.jl:3\nfine\n")
        @test nh == [PEF.FarmBot.sig_hash(
                        PEF.FarmBot.normalize_error_line("ERROR: expected error at /x/y.jl:3"))]
        @test isempty(PEF.pass_sig_hashes("all good\n"))
    end

    @testset "sig_hash" begin
        # FNV-1a 64: known vectors, since worker and bot must agree across
        # Julia versions (which Base.hash does not guarantee)
        sh = PEF.FarmBot.sig_hash
        @test sh("") == "cbf29ce484222325"     # offset basis
        @test sh("a") == "af63dc4c8601ec8c"
        @test length(sh("any other text")) == 16
    end
end

@testset "failure signature clustering" begin
    # unit-drive of the bot's report_json over fabricated DynamoDB items
    FB = PEF.FarmBot
    attr = FB.FarmLite.attr
    ctx = FB.FarmLite.LiteCtx(; region="us-east-1",
        creds=FB.FarmLite.AwsCreds("t", "t", nothing),
        queue_url="q", runs_table="r", jobs_table="j", bucket="b")
    run = FB.FarmLite.Item("run_id" => attr("RID"), "submitter" => attr("kc"),
                           "created_at" => attr("2026-07-30T06:00:00Z"),
                           "total_jobs" => attr(6))
    job(cfg, pkg, status; error_line=nothing, error_lines=nothing, pass_sigs=nothing) = begin
        it = FB.FarmLite.Item("config" => attr(cfg), "package" => attr(pkg),
                              "status" => attr(status), "duration" => attr(10.0))
        error_line === nothing || (it["error_line"] = attr(error_line))
        error_lines === nothing || (it["error_lines"] = attr(error_lines))
        pass_sigs === nothing || (it["pass_sigs"] = attr(pass_sigs))
        it
    end
    configs = [FB.ConfigInfo("primary", "JuliaLang/julia#abc", nothing),
               FB.ConfigInfo("against", "v1.12.0", nothing)]
    jobs = [
        # same failure modulo location/LoadError nesting: one cluster of two
        job("primary", "A", "fail";
            error_line="ERROR: LoadError: MethodError: no method matching f() at /a/x.jl:12"),
        job("against", "A", "test"),
        job("primary", "B", "fail";
            error_line="ERROR: MethodError: no method matching f() at /b/y.jl:99"),
        job("against", "B", "test"),
        # differs only in the address: still its own cluster, below the pair
        job("primary", "C", "crash"; error_line="Unreachable reached at 0xdeadbeef"),
        job("against", "C", "load"),
        # fails on both builds: not a new failure, excluded
        job("primary", "D", "fail"; error_line="ERROR: MethodError: no method matching f()"),
        job("against", "D", "fail"; error_line="ERROR: MethodError: no method matching f()"),
        # hard new failure without a recorded line: not in nfsig
        job("primary", "E", "fail"),
        job("against", "E", "test"),
        # the pass log shares the first candidate (its tests print that error
        # even when passing), so the signature comes from the second
        job("primary", "F", "fail";
            error_line="ERROR: Shared error between pass and fail",
            error_lines="ERROR: Shared error between pass and fail\n" *
                        "ERROR: Unique error on the failing side"),
        job("against", "F", "test";
            pass_sigs=FB.sig_hash(FB.normalize_error_line(
                "ERROR: Shared error between pass and fail"))),
        # every candidate shared with the pass: dropped from clustering
        job("primary", "G", "fail";
            error_line="ERROR: Shared error between pass and fail"),
        job("against", "G", "test";
            pass_sigs=FB.sig_hash(FB.normalize_error_line(
                "ERROR: Shared error between pass and fail"))),
    ]
    d = JSON.parse(FB.report_json(ctx, run, jobs, configs, 0.0, false))
    @test length(d["sigs"]) == 3
    @test d["sigs"][1]["n"] == 2  # most common first
    @test occursin("MethodError", d["sigs"][1]["label"])
    @test d["sigs"][2]["n"] == 1
    @test d["sigs"][3]["label"] == "ERROR: Unique error on the failing side"
    @test d["nfsig"] == Dict("A" => 0, "B" => 0, "C" => 1, "F" => 2)
    @test !haskey(d["nfsig"], "D") && !haskey(d["nfsig"], "E") && !haskey(d["nfsig"], "G")
    # no error lines recorded => the fields are omitted entirely
    d0 = JSON.parse(FB.report_json(ctx, run, [job("primary", "A", "fail"),
                                              job("against", "A", "test")],
                                   configs, 0.0, false))
    @test !haskey(d0, "sigs") && !haskey(d0, "nfsig")
end

@testset "bot command parsing" begin
    parse_command = PEF.FarmBot.parse_command
    @test parse_command("hello world") === nothing
    let c = parse_command("@pkgeval `runtests([\"Example\"])`")
        @test c.packages == ["Example"]
        @test c.vs === nothing && c.error === nothing
    end
    @testset "duration cutoff" begin
        # plenty of short work: cutoff lands just above the mass needed to
        # backfill behind the longest job
        ests = [fill(60.0, 1000); fill(600.0, 50); [3000.0, 2700.0]]
        cutoff = PkgEvalFarm.duration_cutoff(ests; slots=4, margin=2.0)
        @test cutoff == 60.0                     # the mass condition crosses within
                                                 # the short jobs, so only they are fast
        @test sum(e for e in ests if e <= cutoff) >= 2.0 * 3000.0 * 4
        @test count(>(cutoff), ests) == 52       # 600s jobs and both stragglers: slow

        # a run too small to backfill anything degrades to a single class
        @test PkgEvalFarm.duration_cutoff([300.0, 600.0]; slots=128) == Inf
        @test PkgEvalFarm.duration_cutoff(Float64[]) == Inf

        # uniform durations (e.g. a first run with no history): single class
        @test PkgEvalFarm.duration_cutoff(fill(2700.0, 500); slots=128) == Inf ||
              count(>(PkgEvalFarm.duration_cutoff(fill(2700.0, 500); slots=128)), fill(2700.0, 500)) == 0
    end

    let c = parse_command("@pkgeval runtests(fresh_baseline = true)")
        @test c.fresh_baseline && c.error === nothing && isempty(c.packages)
    end
    let c = parse_command("@pkgeval `runtests([\"Foo\"], fresh_baseline = true)`")
        @test c.fresh_baseline && c.packages == ["Foo"]
    end
    let c = parse_command("@pkgeval runtests()")
        @test c.packages == String[] && c.vs === nothing && c.error === nothing
    end
    let c = parse_command("@pkgeval runtests([\"Foo\", \"Bar\"])")
        @test c.packages == ["Foo", "Bar"] && c.vs === nothing
    end
    let c = parse_command("please @pkgeval runtests(ALL, vs = \":master\")")
        @test c.packages == String[] && c.vs == ":master"
    end
    let c = parse_command("@pkgeval runtests(vs=\"v1.12.0\")")
        @test c.vs == "v1.12.0"
    end
    @test parse_command("@pkgeval runtests(rm(\"/\"))").error !== nothing
    @test parse_command("@pkgeval runtests(") === nothing

    resolve_vs = PEF.FarmBot.resolve_vs
    @test resolve_vs(":master", "JuliaLang/julia") == "JuliaLang/julia#master"
    @test resolve_vs("@0123abc", "JuliaLang/julia") == "JuliaLang/julia#0123abc"
    # version specs anchor to the repo: the farm always builds with assertions,
    # so "official release" download specs would dead-end on the workers
    @test resolve_vs("v1.12.0", "JuliaLang/julia") == "JuliaLang/julia#v1.12.0"
    @test resolve_vs("#1.12.6", "JuliaLang/julia") == "JuliaLang/julia#1.12.6"
end

@testset "webhook signatures" begin
    valid = PEF.FarmLite.valid_signature
    secret, body = "s3cret", "{\"zen\":\"Design for failure.\"}"
    sig = "sha256=" * bytes2hex(PEF.FarmLite.hmac(Vector{UInt8}(secret), body))
    @test valid(secret, body, sig)
    @test !valid(secret, body * " ", sig)          # tampered body
    @test !valid("wrong", body, sig)               # wrong secret
    @test !valid(secret, body, nothing)            # missing header
    @test !valid(secret, body, "sha256=abcd")      # wrong length
    @test !valid("", body, sig)                    # webhook disabled

    @test String(PEF.FarmLite.base64decode_lite("eyJ4Ijoi8J+SqSJ9")) == "{\"x\":\"💩\"}"
end

@testset "IMDS proxy credentials" begin
    import HTTP as TestHTTP
    served = Ref(0)
    router = TestHTTP.Router()
    TestHTTP.register!(router, "GET", "/credentials", req -> begin
        auth = TestHTTP.header(req, "Authorization", "")
        auth == "Bearer sekrit" || return TestHTTP.Response(401)
        served[] += 1
        TestHTTP.Response(200, JSON.json(Dict(
            "AccessKeyId" => "ASIATEST$(served[])", "SecretAccessKey" => "s",
            "Token" => "tok", "Expiration" => "2099-01-01T00:00:00Z")))
    end)
    port = rand(40001:50000)
    server = TestHTTP.serve!(router, "127.0.0.1", port)
    try
        url = "http://127.0.0.1:$port/credentials"
        creds = PEF.proxy_credentials(url, "sekrit")
        @test creds.access_key_id == "ASIATEST1"
        @test creds.token == "tok"
        @test creds.expiry == DateTime(2099, 1, 1)
        # renew fetches fresh credentials
        @test creds.renew().access_key_id == "ASIATEST2"
        # without the bearer token (what sandboxed code could attempt): rejected
        @test_throws TestHTTP.StatusError PEF.proxy_credentials(url, "wrong")
    finally
        close(server)
    end
end

want("seal") && @testset "seal unit tests" begin
    include("seal.jl")
end

want("e2e") && @testset "cache-protocol e2e" begin
    include("protocol_e2e.jl")
end

# moto.jl reuses BrokerTests fixtures, so broker comes along with it
(want("broker") || want("moto")) && @testset "broker unit tests" begin
    include("broker.jl")
end

want("moto") && @testset "moto integration" begin
    include("moto.jl")
end

want("sim") && @testset "farm simulation" begin
    include("sim.jl")
end

end
