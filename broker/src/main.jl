# juliac entry point: the Lambda `bootstrap` executable.
#
# The shared include carries the `--trim=safe` compatibility method overrides for
# Base / Downloads / Parsers internals that the trim verifier rejects. It is
# compiled into the binary only (the unit tests include FarmBroker.jl directly)
# and must come before `using FarmBroker` so that module `__init__`s and
# precompiled callers resolve to the replacement methods.
include(joinpath(@__DIR__, "..", "..", "lite", "src", "juliac-trim-compat.jl"))

using FarmBroker

function (@main)(args::Vector{String})::Cint
    trim_compat_init()  # eagerly load libcurl and its dependency chain
    FarmBroker.run_loop()
    return 0
end
