# juliac entry point: the bot Lambda `bootstrap` executable.
include(joinpath(@__DIR__, "FarmBot.jl"))
using .FarmBot

function (@main)(args::Vector{String})::Cint
    FarmBot.lambda_main()
    return 0
end
