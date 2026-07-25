# juliac entry point: the build-request Lambda `bootstrap` executable.
include(joinpath(@__DIR__, "..", "..", "lite", "src", "juliac-trim-compat.jl"))
include(joinpath(@__DIR__, "BuildRequest.jl"))
using .BuildRequest

function (@main)(args::Vector{String})::Cint
    trim_compat_init()
    BuildRequest.lambda_main()
    return 0
end
