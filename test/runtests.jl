using Test
using PkgEvalFarm
using AWS
using Dates
using JSON
import PkgEval

const PEF = PkgEvalFarm

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

@testset "broker unit tests" begin
    include("broker.jl")
end

@testset "moto integration" begin
    include("moto.jl")
end

end
