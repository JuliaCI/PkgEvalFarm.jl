# Build the broker Lambda bundle: a juliac-compiled `bootstrap` executable plus the
# Julia runtime libraries it needs, zipped up for the `provided.al2023` runtime.
#
#   julia +1.13 --project=broker broker/build/build.jl [--trim=safe]
#
# produces broker/build/bootstrap.zip, which terraform deploys. Use Julia 1.13:
# 1.12's Downloads stdlib does not pass the `--trim=safe` verifier.

using Pkg

const BROKER_DIR = dirname(@__DIR__)
const BUILD_DIR = @__DIR__
const STAGE_DIR = joinpath(BUILD_DIR, "stage")

trim = something(findfirst(a -> startswith(a, "--trim"), ARGS), "--trim=safe")
trim isa Int && (trim = ARGS[trim])

Pkg.activate(BROKER_DIR)
Pkg.instantiate()

juliac = normpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")
isfile(juliac) || error("juliac not found at $juliac; use Julia >= 1.12")

rm(STAGE_DIR; force=true, recursive=true)
mkpath(STAGE_DIR)
exe = joinpath(STAGE_DIR, "bootstrap")

@info "compiling broker with juliac" trim
env = copy(ENV)
env["JULIA_PROJECT"] = BROKER_DIR
run(setenv(`$(Base.julia_cmd()[1]) $juliac --output-exe $exe --experimental $trim
            --relative-rpath $(joinpath(BROKER_DIR, "src", "main.jl"))`,
           env; dir=BROKER_DIR))

# bundle the Julia runtime libraries next to the executable ("julia/" is where
# --relative-rpath points the executable's RPATH). Everything is laid out flat in
# that folder; the julia loader additionally expects libjulia's private libraries
# in a "julia/" subdir next to libjulia itself, which a self-symlink satisfies.
#
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
libdir = normpath(Sys.BINDIR, "..", "lib")
stage_libdir = joinpath(STAGE_DIR, "julia")
mkpath(stage_libdir)
for lib in readdir(joinpath(libdir, "julia"))
    occursin(SKIPPED_LIBS, lib) && continue
    cp(joinpath(libdir, "julia", lib), joinpath(stage_libdir, lib))
end
for lib in filter(f -> occursin(r"^libjulia\.so", f), readdir(libdir))
    cp(joinpath(libdir, lib), joinpath(stage_libdir, lib); force=true)
end
symlink(".", joinpath(stage_libdir, "julia"))

zip = joinpath(BUILD_DIR, "bootstrap.zip")
rm(zip; force=true)
if Sys.which("zip") !== nothing
    run(Cmd(`zip -qry $zip bootstrap julia`; dir=STAGE_DIR))
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
    run(Cmd(`python3 -c $script`; dir=STAGE_DIR))
end
@info "built" zip size_mb=round(filesize(zip) / 2^20; digits=1)
