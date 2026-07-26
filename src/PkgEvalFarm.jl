module PkgEvalFarm

using AWS
using Dates
using HTTP
using JSON
using Logging
using Random
import SHA
using TOML

using AWS: @service
@service Dynamodb
@service SQS
@service S3
@service STS

import PkgEval

# the bot/report logic is shared with the compiled bot Lambda, so it lives in a
# stdlib-only module tree (which also brings in FarmLite, the lite AWS client)
include(joinpath(@__DIR__, "..", "bot", "src", "FarmBot.jl"))
using .FarmBot: FarmBot, FarmLite

include("schema.jl")
include("auth.jl")
include("queue.jl")
include("worker.jl")
include("submit.jl")
include("cli.jl")

function __init__()
    # AWS.jl/HTTP.jl default to *no* read timeout, so a request that never
    # answers (or that waits forever for a connection from HTTP.jl's global,
    # per-socket-type pool) hangs the caller with no error and no way out. Every
    # farm call is small and fast; the only slow one is the SQS long poll, hence
    # a read timeout comfortably above it.
    AWS.DEFAULT_BACKEND[] = AWS.HTTPBackend(Dict{Symbol,Any}(
        :connect_timeout => 15,
        :readtimeout => 120,
    ))
end

"""
Entry point for `julia -m PkgEvalFarm ...` and for the `farm` app installed via
`Pkg.Apps` (see `[apps]` in Project.toml).
"""
function (@main)(args::Vector{String})::Cint
    return cli_main(args)
end

end # module
