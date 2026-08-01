# Local full-fidelity farm simulation: moto for the AWS surface, the real
# PkgEval sandbox for evaluation, the real worker processing loop — so protocol
# bugs (holds, donation, derivations, publication, convergence) reproduce in
# minutes locally instead of one EC2 trial run each.
#
# Gated on PKGEVAL_SIM_JULIA: a julia *install directory* (bin/julia inside) to
# evaluate with. Point it at a cache-hook build (e.g. a cache-fetch-hook branch
# checkout's usr/) and expansion's sandboxed detection selects the protocol
# scheme, exercising the full ladder; a plain julia falls back to the depot
# scheme, which is also a valid (smaller) simulation.
#
# Host accommodations (attempted automatically, skipped with a message if
# unavailable):
# - overlayfs upperdirs cannot live on an overlay filesystem, so TMPDIR moves
#   to a directory next to this checkout (assumed to be on a real fs)
# - crun's OCI default device set needs /dev/full, which restricted /dev
#   setups lack; a bind-mount of /dev/zero over a placeholder suffices
# - unprivileged user namespaces must be available

module SimTests

using Test
using Dates
import PkgEval
import HTTP
using PkgEvalFarm
using AWS
using AWS: @service
@service Dynamodb
@service SQS
@service S3

using ..MotoHelpers: MotoHelpers, MotoConfig, start_moto

const PEF = PkgEvalFarm

sim_julia = get(ENV, "PKGEVAL_SIM_JULIA", "")

function ensure_dev_full()
    ispath("/dev/full") && return true
    try
        touch("/dev/full")
        run(`mount --bind /dev/zero /dev/full`)
        return true
    catch
        return false
    end
end

if isempty(sim_julia) || !isfile(joinpath(sim_julia, "bin", "julia"))
    @test_skip "farm simulation (set PKGEVAL_SIM_JULIA to a julia install dir)"
elseif !MotoHelpers.moto_available()
    @test_skip "farm simulation (moto_server not found)"
elseif !ensure_dev_full()
    @test_skip "farm simulation (/dev/full unavailable and cannot be faked)"
elseif !success(`unshare --user --map-root-user true`)
    @test_skip "farm simulation (no unprivileged user namespaces)"
else

# overlay upperdirs need a real filesystem; the checkout's fs qualifies
simtmp = normpath(joinpath(@__DIR__, "..", ".simtmp"))
mkpath(simtmp)
ENV["TMPDIR"] = simtmp

proc, port = start_moto()
aws = MotoConfig("http://127.0.0.1:$port", "us-east-1",
                 AWS.AWSCredentials("testing", "testing"))

@testset "farm simulation" begin
    for (table, keys) in ["pkgeval-runs" => [("run_id", "HASH")],
                          "pkgeval-jobs" => [("run_id", "HASH"), ("job_key", "RANGE")]]
        Dynamodb.create_table(
            [Dict("AttributeName" => k, "AttributeType" => "S") for (k, _) in keys],
            [Dict("AttributeName" => k, "KeyType" => t) for (k, t) in keys],
            table, Dict("BillingMode" => "PAY_PER_REQUEST"); aws_config=aws)
    end
    S3.create_bucket("pkgeval-results"; aws_config=aws)
    qurls = Dict(q => SQS.create_queue(q; aws_config=aws)["QueueUrl"]
                 for q in ("sim-jobs", "sim-jobs-slow", "sim-jobs-seal"))
    cfg = FarmConfig(; region="us-east-1", queue_url=qurls["sim-jobs"],
                     slow_queue_url=qurls["sim-jobs-slow"],
                     seal_queue_url=qurls["sim-jobs-seal"],
                     runs_table="pkgeval-runs", jobs_table="pkgeval-jobs",
                     bucket="pkgeval-results")
    ctx = PEF.FarmCtx(cfg, aws)

    seal_cache = mktempdir()
    withenv("PKGEVAL_SEAL_CACHE" => seal_cache) do
        configs = [PkgEval.Configuration(; name="primary", julia=sim_julia,
                                         # keep the sim lean and deterministic
                                         rr=PkgEval.RRDisabled)]
        packages = ["Example"]
        run_id = PEF.create_run(ctx, PEF.RunSpec(configs, packages, Dict{String,Any}());
                                submitter="sim", reuse=false)
        @info "sim run created" run_id

        # the real worker wiring, minus the daemon scaffolding: a proxy, the
        # donor closure, and a few claim/process slots
        PEF.start_seal_proxy!(ctx)
        run_cache = Dict{String,Dict{String,Any}}()
        run_cache_lock = ReentrantLock()
        done = Ref(false)
        donors = Threads.Atomic{Int}(0)
        donations = Threads.Atomic{Int}(0)
        PEF.SEAL_DONOR[] = function ()
            donors[] >= 8 && return
            Threads.atomic_add!(donors, 1)
            Threads.atomic_add!(donations, 1)
            errormonitor(@async try
                donated = PEF.claim_seal_job(ctx)
                donated isa PEF.ClaimedJob &&
                    PEF.process_job(ctx, donated, 0, run_cache, run_cache_lock)
            catch err
                @warn "sim donor failed" err
            finally
                Threads.atomic_sub!(donors, 1)
            end)
            return
        end
        slots = map(1:4) do i
            errormonitor(@async while !done[]
                claimed = PEF.claim_seal_job(ctx)
                claimed === nothing && (claimed = PEF.claim_job(ctx; wait=1))
                try
                    if claimed isa PEF.ClaimedExpand
                        PEF.process_expand(ctx, claimed)
                    elseif claimed isa PEF.ClaimedJob
                        PEF.process_job(ctx, claimed, i - 1, run_cache, run_cache_lock)
                    else
                        sleep(0.2)
                    end
                catch err
                    done[] || @warn "sim slot failed" err
                end
            end)
        end

        # first runs download rootfs/registry/packages; generous but bounded
        deadline = time() + parse(Float64, get(ENV, "PKGEVAL_SIM_BUDGET", "1800"))
        final = nothing
        try
            while time() < deadline
                run = PEF.get_run(ctx, run_id)
                if run !== nothing && get(run, "status", "") == "done"
                    final = run
                    break
                end
                sleep(5)
            end
        finally
            done[] = true
            PEF.SEAL_DONOR[] = nothing
        end
        if final === nothing
            # dump state before failing: this is the sim's whole point
            @error "sim run did not complete" run=PEF.get_run(ctx, run_id)
            for j in PEF.run_jobs(ctx, run_id)
                @error "job state" job=j
            end
        end
        @test final !== nothing

        if final !== nothing
            jobs = Dict(j["package"] => j for j in PEF.run_jobs(ctx, run_id))
            @test jobs["Example"]["status"] == "test"

            seal_runs = get(final, "seal_runs", Dict())
            @test haskey(seal_runs, "primary")
            sr = seal_runs["primary"]
            scheme = PEF.seal_run_scheme(PEF.get_run(ctx, sr))
            @info "sim results" scheme donations=donations[]
            seal_jobs = Dict(j["package"] => j for j in PEF.run_jobs(ctx, sr))
            @test seal_jobs["Example"]["status"] == "sealed"

            if scheme == "protocol"
                # the julia carries the hook: the consumer must actually hit
                log = String(PEF.S3.get_object(cfg.bucket,
                    "runs/$run_id/logs/primary/Example.log"; aws_config=aws))
                m = match(r"\[cache_client\] hits=(\d+) misses=(\d+)", log)
                @test m !== nothing
                if m !== nothing
                    @info "consumer cache traffic" hits=m[1] misses=m[2]
                    @test parse(Int, m[1]) > 0
                end
            end
        end
    end
end

kill(proc)

end # gated
end # module
