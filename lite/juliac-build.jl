# Shared build logic for the farm's juliac-compiled Lambda bundles (broker, bot):
# compile `<app>/src/main.jl` into a `bootstrap` executable, bundle the Julia
# runtime libraries it needs, and zip everything up for the `provided.al2023`
# Lambda runtime. Use Julia 1.13: 1.12's Downloads stdlib does not pass the
# `--trim=safe` verifier.
#
# Included by `<app>/build/build.jl`, which calls `build_lambda_bundle(app_dir)`.

using Pkg

# The trimmed binary contains no compiler and does no linear algebra, so skip the
# codegen and BLAS/SuiteSparse stacks (and the sysimage: the app image is embedded
# in the executable) -- this is what keeps the bundle within Lambda's size limits.
const SKIPPED_LIBS = r"""^(
    sys\S*\.so            # stock sysimage (ours is embedded in the executable)
    |libLLVM|libjulia-codegen|libccalltest|libllvmcalltest
    |libopenblas|libblastrampoline
    |libamd|libbtf|libcamd|libccolamd|libcholmod|libcolamd|libklu|libldl|librbio
    |libspqr|libsuitesparseconfig|libumfpack
    |libgit2              # LibGit2 stdlib, not in the image (libssh2 stays: libcurl needs it)
    |libgfortran|libquadmath|libgomp
)"""x

function build_lambda_bundle(app_dir::String;
                             trim::String=something(let i = findfirst(a -> startswith(a, "--trim"), ARGS)
                                 i === nothing ? nothing : ARGS[i]
                             end, "--trim=safe"))
    app = basename(app_dir)
    build_dir = joinpath(app_dir, "build")
    stage_dir = joinpath(build_dir, "stage")

    Pkg.activate(app_dir)
    Pkg.instantiate()

    juliac = normpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")
    isfile(juliac) || error("juliac not found at $juliac; use Julia >= 1.13")

    rm(stage_dir; force=true, recursive=true)
    mkpath(stage_dir)
    exe = joinpath(stage_dir, "bootstrap")

    # juliac otherwise compiles for the *build host's* CPU, and Julia refuses to
    # load a code image whose target uses features the runtime host lacks
    # ("Rejecting this target due to use of runtime-disabled features"). Lambda's
    # microVMs mask AVX-512, so a build on e.g. a Zen 4 machine dies during init.
    #
    # `sandybridge` is the ISA floor: old enough for any Lambda host (and any
    # plausible worker), new enough that codegen inlines `floor` & co. instead of
    # calling libm — juliac's link line has no `-lm`, so a `generic` build fails
    # to link. A single target (rather than a multiversioned `a;b;c` string) also
    # keeps `julia -C $target -e ...` legal, which the cache warm-up below needs.
    cpu_target = get(ENV, "JULIA_CPU_TARGET", "sandybridge")

    @info "compiling $app with juliac" trim cpu_target
    env = copy(ENV)
    env["JULIA_PROJECT"] = app_dir
    env["JULIA_CPU_TARGET"] = cpu_target

    # Warm the precompile caches *for the target CPU* first. juliac runs its own
    # `Pkg.precompile()` but without the target flag (juliac.jl:162 uses
    # `julia_cmd`, not `julia_cmd_target`), so the caches it builds are the wrong
    # ones and the build script then tries to precompile mid-compile — which
    # fails with "cannot register new atexit hook; already exiting".
    run(setenv(`$(Base.julia_cmd()[1]) -C $cpu_target --startup-file=no
                -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"`,
               env; dir=app_dir))
    run(setenv(`$(Base.julia_cmd()[1]) $juliac --output-exe $exe --experimental $trim
                --relative-rpath $(joinpath(app_dir, "src", "main.jl"))`,
               env; dir=app_dir))

    # bundle the Julia runtime libraries next to the executable ("julia/" is where
    # --relative-rpath points the executable's RPATH). Everything is laid out flat
    # in that folder; the julia loader additionally expects libjulia's private
    # libraries in a "julia/" subdir next to libjulia itself, which a self-symlink
    # satisfies.
    libdir = normpath(Sys.BINDIR, "..", "lib")
    stage_libdir = joinpath(stage_dir, "julia")
    mkpath(stage_libdir)
    for lib in readdir(joinpath(libdir, "julia"))
        occursin(SKIPPED_LIBS, lib) && continue
        cp(joinpath(libdir, "julia", lib), joinpath(stage_libdir, lib))
    end
    for lib in filter(f -> occursin(r"^libjulia\.so", f), readdir(libdir))
        cp(joinpath(libdir, lib), joinpath(stage_libdir, lib); force=true)
    end
    symlink(".", joinpath(stage_libdir, "julia"))

    # crash forensics: a chained SIGSEGV reporter (see segvreport.c). Compiled
    # into the runtime-lib dir so the executable's RPATH resolves it by name.
    run(`cc -shared -fPIC -O2 -o $(joinpath(stage_libdir, "libsegvreport.so"))
        $(joinpath(@__DIR__, "segvreport.c"))`)

    zip = joinpath(build_dir, "bootstrap.zip")
    rm(zip; force=true)
    if Sys.which("zip") !== nothing
        run(Cmd(`zip -qry $zip bootstrap julia`; dir=stage_dir))
    else
        # Lambda requires the executable bit on bootstrap, so set external_attr
        # explicitly; symlinks (the "julia/julia" self-link) are stored as such
        script = """
            import os, stat, zipfile
            with zipfile.ZipFile("$zip", "w", zipfile.ZIP_DEFLATED) as zf:
                for root, dirs, files in os.walk("."):
                    for name in dirs + files:
                        path = os.path.join(root, name)
                        info = zipfile.ZipInfo(os.path.relpath(path, "."))
                        if os.path.islink(path):
                            info.external_attr = (stat.S_IFLNK | 0o777) << 16
                            zf.writestr(info, os.readlink(path))
                        elif os.path.isfile(path):
                            info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
                            with open(path, "rb") as fh:
                                zf.writestr(info, fh.read())
                    dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
            """
        run(Cmd(`python3 -c $script`; dir=stage_dir))
    end
    @info "built" zip size_mb=round(filesize(zip) / 2^20; digits=1)
    return zip
end
