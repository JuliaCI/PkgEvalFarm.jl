# juliac entry point: the Lambda `bootstrap` executable.
using FarmBroker

function (@main)(args::Vector{String})::Cint
    FarmBroker.run_loop()
    return 0
end
