# Build a sysimage containing the worker and its dependencies.
#
#   julia --project=. sysimage/build.jl [output.so]
#
# Workers otherwise spend ~75s of every boot precompiling AWS.jl, PkgEval and
# their dependency trees (137s for a cold depot, against 62s to fetch the same
# packages and artifacts without compiling them). That is paid on *every*
# launch — spot replacement, queue-driven scale-out, scale-to-zero — so it is
# worth removing even now that Julia itself comes prebuilt from CI.
#
# Two things must match the machine that loads the image or Julia refuses it
# (which is why the loader has a fallback, see terraform/ec2_worker_userdata.sh.tpl):
#
#   * the Julia version — hence the version in the filename;
#   * the CPU target — the trap that broke the Lambdas. Sysimages *can* be
#     multiversioned (juliac's could not), so use the same target string the
#     official Julia binaries ship with: portable down to a generic baseline,
#     fast on the m5a/m6a/m7a mix the ASG launches.

# PackageCompiler lives in its own environment (sysimage/Project.toml) so that
# the *active* project stays the farm itself -- create_sysimage bakes the active
# project's manifest, and that manifest must be the one workers instantiate.
pushfirst!(LOAD_PATH, @__DIR__)
using PackageCompiler
popfirst!(LOAD_PATH)

const CPU_TARGET = get(ENV, "JULIA_CPU_TARGET",
                       "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)")

sysimage_filename() = "pkgevalfarm-julia-$(VERSION)-$(Sys.ARCH).so"

out = get(ARGS, 1, joinpath(@__DIR__, "build", sysimage_filename()))
mkpath(dirname(out))

@info "building sysimage" out julia = VERSION cpu_target = CPU_TARGET

create_sysimage(
    [:PkgEvalFarm];
    sysimage_path=out,
    # exercise the paths a worker runs through before it can claim its first
    # job, so they are compiled in rather than JIT-ed on every boot
    precompile_execution_file=joinpath(@__DIR__, "warmup.jl"),
    cpu_target=CPU_TARGET,
)

@info "built" out size_mb = round(filesize(out) / 2^20; digits=1)
