# Shared moto plumbing for the integration tests (moto.jl) and the local farm
# simulation (sim.jl): an AWS config pointing every service at a local moto
# server, and the server lifecycle.

module MotoHelpers

using AWS
using Sockets

# AWS config pointing every service at the moto endpoint
struct MotoConfig <: AWS.AbstractAWSConfig
    endpoint::String
    region::String
    creds::AWS.AWSCredentials
end
AWS.region(c::MotoConfig) = c.region
AWS.credentials(c::MotoConfig) = c.creds
AWS.generate_service_url(c::MotoConfig, service::String, resource::String) =
    string(c.endpoint, resource)

function start_moto()
    port = rand(20000:30000)
    proc = run(pipeline(`moto_server -p $port`; stdout=devnull, stderr=devnull); wait=false)
    for _ in 1:100
        try
            close(Sockets.connect("127.0.0.1", port))
            return proc, port
        catch
            sleep(0.1)
        end
        process_exited(proc) && break
    end
    error("moto_server did not come up (is 'moto[server]' installed?)")
end

moto_available() = Sys.which("moto_server") !== nothing

end # module
