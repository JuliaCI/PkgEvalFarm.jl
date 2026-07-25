# Build the broker Lambda bundle: a juliac-compiled `bootstrap` executable plus the
# Julia runtime libraries it needs, zipped up for the `provided.al2023` runtime.
#
#   julia --project=broker broker/build/build.jl [--trim=safe]
#
# produces broker/build/bootstrap.zip, which terraform deploys.

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
# --relative-rpath points the RPATH)
libdir = normpath(Sys.BINDIR, "..", "lib")
stage_libdir = joinpath(STAGE_DIR, "julia")
mkpath(stage_libdir)
cp(joinpath(libdir, "julia"), stage_libdir; force=true)
for lib in filter(f -> occursin(r"^libjulia\.so", f), readdir(libdir))
    cp(joinpath(libdir, lib), joinpath(stage_libdir, lib); force=true)
end

zip = joinpath(BUILD_DIR, "bootstrap.zip")
rm(zip; force=true)
if Sys.which("zip") !== nothing
    run(Cmd(`zip -qry $zip bootstrap julia`; dir=STAGE_DIR))
else
    # Lambda requires the executable bit on bootstrap, so set external_attr explicitly
    script = """
        import os, stat, zipfile
        with zipfile.ZipFile("$zip", "w", zipfile.ZIP_DEFLATED) as zf:
            for root, dirs, files in os.walk("."):
                for f in files:
                    path = os.path.join(root, f)
                    info = zipfile.ZipInfo(os.path.relpath(path, "."))
                    info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
                    with open(path, "rb") as fh:
                        zf.writestr(info, fh.read())
        """
    run(Cmd(`python3 -c $script`; dir=STAGE_DIR))
end
@info "built" zip size_mb=round(filesize(zip) / 2^20; digits=1)
