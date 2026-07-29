# Minimal reproducer: juliac --trim binary corrupting FileWatching.FDWatchers.
# The image-resident FDWatchers Vector's runtime-grown backing Memory loses its
# old->young edge in the trimmed image; a GC frees it, and the next
# socket_callback-driven _FDWatcher constructor reads recycled memory.
include("/workspace/PkgEvalFarm.jl/lite/src/juliac-trim-compat.jl")
include("/workspace/PkgEvalFarm.jl/lite/src/FarmLite.jl")
using .FarmLite

function (@main)(args::Vector{String})::Cint
    trim_compat_init()
    for i in 1:60
        try
            # a refused connection still drives curl's socket_callback -> FDWatcher
            FarmLite.http_request("GET", "http://127.0.0.1:1/")
        catch
        end
        GC.gc(i % 3 == 0)   # mix of minor and full collections
        print(Core.stderr, ".")
    end
    println(Core.stderr, "\nsurvived")
    return 0
end
