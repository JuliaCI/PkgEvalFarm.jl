module PkgEvalFarm

using AWS
using Dates
using HTTP
using JSON
using Logging
using Random
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

end # module
