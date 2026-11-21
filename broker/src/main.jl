# juliac entry point: the Lambda `bootstrap` executable.
#
# The shared include carries the `--trim=safe` compatibility method overrides for
# Base / Downloads / Parsers internals that the trim verifier rejects. It is
# compiled into the binary only (the unit tests include FarmBroker.jl directly)
# and must come before FarmBroker is loaded so that module `__init__`s and
# precompiled callers resolve to the replacement methods.
include(joinpath(@__DIR__, "..", "..", "lite", "src", "juliac-trim-compat.jl"))

# included as a file rather than loaded as a package (like the bot): FarmBroker
# includes the shared lite/src/FarmLite.jl, which lies outside this project, and a
# package precompiles from wherever its source is installed
include(joinpath(@__DIR__, "FarmBroker.jl"))
using .FarmBroker

function (@main)(args::Vector{String})::Cint
    trim_compat_init()  # eagerly load libcurl and its dependency chain
    FarmBroker.run_loop()
    return 0
end
