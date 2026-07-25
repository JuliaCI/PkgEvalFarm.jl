# juliac entry point: the Lambda `bootstrap` executable.
#
# Besides the entry point, this file carries a handful of `--trim=safe`
# compatibility method overrides for Base / Downloads / Parsers internals that the
# trim verifier rejects. They are compiled into the binary only: the unit tests
# include FarmBroker.jl directly and never load this file.

using FarmBroker
using Downloads
using JSON

# Base.errormonitor (used by Downloads for its curl tasks) prints unhandled task
# failures with the fully dynamic display_error/showerror machinery; keep the
# monitoring but print a plain message instead.
@eval Base begin
    function errormonitor(t::Task)
        t2 = Task() do
            if istaskfailed(t)
                Core.print(Core.stderr,
                    "Unhandled Task ERROR (details unavailable in trimmed binary)\n")
            end
            nothing
        end
        t2.sticky = false
        _wait2(t, t2)
        return t
    end

    # ditto for the error printing in Timer's callback wrapper (used by Downloads
    # for its curl timeouts); everything except the catch block matches Base
    function Timer(cb::Function, timeout; spawn::Union{Nothing,Bool}=nothing, kwargs...)
        sticky = spawn === nothing ? current_task().sticky : !spawn
        timer = Timer(timeout; kwargs...)
        t = @task begin
            unpreserve_handle(timer)
            while _trywait(timer)
                try
                    cb(timer)
                catch
                    Core.print(Core.stderr,
                        "Error in Timer callback (details unavailable in trimmed binary)\n")
                    return
                end
                isopen(timer) || return
            end
        end
        t.sticky = sticky
        preserve_handle(timer)
        @lock timer.cond begin
            if timer.set
                schedule(t)
            else
                _wait2(timer.cond, t)
            end
        end
        return timer
    end
end

# The stock definition calls a `Downloader.easy_hook::Union{Function,Nothing}` via
# `invokelatest`, an unverifiable dynamic call. The broker never installs a hook.
@eval Downloads begin
    function easy_hook(downloader::Downloader, easy::Curl.Easy, info::NamedTuple)
        downloader.easy_hook === nothing ||
            Core.print(Core.stderr, "WARNING: Downloader.easy_hook ignored in trimmed binary\n")
        nothing
    end
end

# `Easy.seeker` is `Union{Function,Nothing}`, so libcurl's seek callback is an
# unverifiable dynamic call; the broker never needs request-body rewinding (no
# redirects or auth retries on the runtime API, GitHub, or STS), so don't register
# the callback at all (libcurl then simply cannot rewind, as if input were a pipe).
@eval Downloads.Curl begin
    set_seeker(seeker::Function, easy::Easy) = nothing
end

# JSON.jl parses float literals via the generic Parsers.jl path, which deliberately
# un-specializes its accumulator with `Base.inferencebarrier` and can therefore
# never pass the trim verifier. For the `String` buffers JSON.jl uses, parse the
# (already syntax-validated) number token with the C strtod via Base.tryparse
# instead — equally correctly rounded.
@eval JSON.Parsers begin
    function xparse2(::Type{Float64}, buf::String, pos::Int, len::Int)
        i = pos
        while i <= len
            b = codeunit(buf, i)
            isnumbyte = (UInt8('0') <= b <= UInt8('9')) | (b == UInt8('-')) |
                        (b == UInt8('+')) | (b == UInt8('.')) |
                        (b == UInt8('e')) | (b == UInt8('E'))
            isnumbyte || break
            i += 1
        end
        tlen = i - pos
        val = tlen == 0 ? nothing : Base.tryparse(Float64, SubString(buf, pos, i - 1))
        val === nothing && return Result{Float64}(INVALID, Int64(max(tlen, 1)))
        code = isfinite(val) ? OK : (OK | SPECIAL_VALUE)
        return Result{Float64}(code, Int64(tlen), val)
    end
end

function (@main)(args::Vector{String})::Cint
    FarmBroker.run_loop()
    return 0
end
