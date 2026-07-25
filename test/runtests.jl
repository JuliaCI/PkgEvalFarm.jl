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
    let c = parse_command("@nanosoldier2 runtests()")
        @test c.packages == String[] && c.vs === nothing && c.error === nothing
    end
    let c = parse_command("@nanosoldier2 runtests([\"Foo\", \"Bar\"])")
        @test c.packages == ["Foo", "Bar"] && c.vs === nothing
    end
    let c = parse_command("please @nanosoldier2 runtests(ALL, vs = \":master\")")
        @test c.packages == String[] && c.vs == ":master"
    end
    let c = parse_command("@nanosoldier2 runtests(vs=\"v1.12.0\")")
        @test c.vs == "v1.12.0"
    end
    @test parse_command("@nanosoldier2 runtests(rm(\"/\"))").error !== nothing
    @test parse_command("@nanosoldier2 runtests(") === nothing

    resolve_vs = PEF.FarmBot.resolve_vs
    @test resolve_vs(":master", "JuliaLang/julia") == "JuliaLang/julia#master"
    @test resolve_vs("@0123abc", "JuliaLang/julia") == "JuliaLang/julia#0123abc"
    @test resolve_vs("v1.12.0", "JuliaLang/julia") == "v1.12.0"
end

@testset "broker unit tests" begin
    include("broker.jl")
end

@testset "moto integration" begin
    include("moto.jl")
end

end
