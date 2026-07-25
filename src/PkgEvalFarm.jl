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

include("schema.jl")
include("auth.jl")
include("queue.jl")
include("worker.jl")
include("submit.jl")
include("report.jl")
include("bot.jl")
include("cli.jl")

end # module
