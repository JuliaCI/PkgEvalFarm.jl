# juliac entry point: the Lambda `bootstrap` executable.
#
# Besides the entry point, this file carries a handful of `--trim=safe`
# compatibility method overrides for Base / Downloads / Parsers internals that the
# trim verifier rejects (or that trimming drops even though the runtime reaches
# them dynamically). They are compiled into the binary only: the unit tests
# include FarmBroker.jl directly and never load this file.

# The Base overrides must be in place *before* Downloads is loaded: module
# `__init__`s and precompiled callers must resolve to the replacement methods.

# ccall() into a LazyLibrary-based jll (LibCURL and its dependencies) resolves the
# library through `dlopen(::LazyLibrary)`. The stock implementation cannot be
# trim-verified (`path` and `on_load_callback` are untyped fields), so replace it
# with a typed equivalent. None of the libraries the broker uses has an
# on_load_callback (only libblastrampoline does, which is not in the image).
@eval Base.Libc.Libdl begin
    function dlopen(ll::LazyLibrary, flags::Integer = ll.flags; kwargs...)
        handle = @atomic :acquire ll.handle
        if handle == C_NULL
            @lock ll.lock begin
                # check to see if another thread has already run this
                if ll.handle == C_NULL
                    for dep in ll.dependencies()
                        dlopen(dep; kwargs...)
                    end
                    # an inlined isa-chain rather than string(ll.path): the field is
                    # untyped, so any dispatch on it is rejected by the verifier
                    path = ll.path
                    pathstr = if path isa String
                        path
                    elseif path isa LazyLibraryPath
                        parts = String[]
                        for p in path.pieces
                            if p isa String
                                push!(parts, p)
                            elseif p isa PrivateShlibdirGetter
                                push!(parts, private_shlibdir())
                            else
                                error("unsupported LazyLibraryPath piece in trimmed binary")
                            end
                        end
                        joinpath(parts)
                    else
                        error("unsupported LazyLibrary path in trimmed binary")
                    end
                    handle = dlopen(pathstr, flags; kwargs...)::Ptr{Cvoid}
                    @atomic :release ll.handle = handle
                    ll.on_load_callback === nothing ||
                        error("LazyLibrary on_load_callback is unsupported in the trimmed binary")
                else
                    handle = @atomic :acquire ll.handle
                end
            end
        end
        return handle
    end
end

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

    # `@sync` (used by Downloads.request to manage its response/upload tasks) waits
    # via sync_end, whose generic `wait(::Any)` branch cannot be trim-verified; in
    # this binary every synced object is a Task, so wait accordingly. Registered as
    # an entrypoint below since precompiled callers reach it dynamically.
    function sync_end(c::Channel{Any})
        local c_ex
        while isready(c)
            r = take!(c)
            if isa(r, Task)
                _wait(r)
                if istaskfailed(r)
                    if !@isdefined(c_ex)
                        c_ex = CompositeException()
                    end
                    push!(c_ex, TaskFailedException(r))
                end
            else
                Core.print(Core.stderr,
                    "WARNING: non-Task object in @sync ignored in trimmed binary\n")
            end
        end
        close(c)
        if @isdefined(c_ex)
            throw(c_ex)
        end
        nothing
    end
end

using FarmBroker
using Downloads
using JSON

# The stock definition calls a `Downloader.easy_hook::Union{Function,Nothing}` via
# `invokelatest`, an unverifiable dynamic call. The broker never installs a hook.
@eval Downloads begin
    function easy_hook(downloader::Downloader, easy::Curl.Easy, info::NamedTuple)
        downloader.easy_hook === nothing ||
            Core.print(Core.stderr, "WARNING: Downloader.easy_hook ignored in trimmed binary\n")
        nothing
    end
end

# `Downloads.request`'s precompiled body reaches Base's task-sync machinery
# (`@sync` / `sync_end` / `wait(::Any)`) in ways trimming cannot follow, which
# leaves the compiled binary missing instances and deadlocks the first request.
# Overwrite it with an identical copy whose `@sync` block is expanded into
# explicit, fully-typed Task construction so the whole path is compiled fresh
# under the verifier's eyes. Otherwise a verbatim copy of the stock definition
# (julia 1.13).
@eval Downloads begin
function request(
    url        :: AbstractString;
    input      :: Union{ArgRead, Nothing} = nothing,
    output     :: Union{ArgWrite, Nothing} = nothing,
    method     :: Union{AbstractString, Nothing} = nothing,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    timeout    :: Real = Inf,
    progress   :: Union{Function, Nothing} = nothing,
    verbose    :: Bool = false,
    debug      :: Union{Function, Nothing} = nothing,
    throw      :: Bool = true,
    downloader :: Union{Downloader, Nothing} = nothing,
    interrupt  :: Union{Nothing, Base.Event} = nothing,
) :: Union{Response, RequestError}
    if downloader === nothing
        @lock DOWNLOAD_LOCK begin
            downloader = DOWNLOADER[]
            if downloader === nothing
                downloader = DOWNLOADER[] = Downloader()
            end
        end
    end
    # single assignment to variable used in closure to avoid boxing
    downloader′ = downloader
    have_input = input !== nothing
    have_output = output !== nothing
    input = something(input, devnull)
    output = something(output, devnull)
    _input_size = arg_read_size(input)
    if _input_size === nothing
        # take input_size from content-length header if one is supplied
        _input_size = content_length(headers)
    end
    # single assignment to variable used in closure to avoid boxing
    input_size = _input_size

    progress = p_func(progress, input, output)
    response = Ref{Union{Response, RequestError}}()
    arg_read(input) do input
        arg_write(output) do output
            with_handle(Easy()) do easy
                # setup the request
                set_url(easy, url)
                set_timeout(easy, timeout)
                set_verbose(easy, verbose)
                set_debug(easy, debug)
                add_headers(easy, headers)

                # libcurl does not set the default header reliably so set it
                # explicitly unless user has specified it, xref
                # https://github.com/JuliaLang/Pkg.jl/pull/2357
                if !any(kv -> lowercase(kv[1]) == "user-agent", headers)
                    Curl.add_header(easy, "User-Agent", Curl.USER_AGENT)
                end

                if have_input
                    enable_upload(easy)
                    if input_size !== nothing
                        set_upload_size(easy, input_size)
                    end
                    if applicable(seek, input, 0)
                        set_seeker(easy) do offset
                            seek(input, Int(offset))
                        end
                    end
                else
                    set_body(easy, have_output && method != "HEAD")
                end
                method !== nothing && set_method(easy, method)
                progress !== nothing && enable_progress(easy)
                set_ca_roots(downloader′, easy)
                info = (url = url, method = method, headers = headers)
                easy_hook(downloader′, easy, info)

                # do the request
                add_handle(downloader′.multi, easy)
                interrupted = Threads.Atomic{Bool}(false)
                if interrupt !== nothing
                    interrupt_task = @async begin
                        # wait for the interrupt event
                        wait(interrupt)
                        # cancel the request
                        remove_handle(downloader′.multi, easy)
                        close(easy.output)
                        close(easy.progress)
                        interrupted[] = true
                        close(input)
                        notify(easy.ready)
                    end
                else
                    interrupt_task = nothing
                end
                try # ensure handle is removed
                    sync_ch = Channel(Inf)
                    drain_task = Task(() -> (for buf in easy.output; write(output, buf); end))
                    put!(sync_ch, drain_task)
                    schedule(drain_task)
                    if progress !== nothing
                        t2 = Task(() -> (for prog in easy.progress; progress(prog...); end))
                        put!(sync_ch, t2); schedule(t2)
                    end
                    if have_input
                        t3 = Task(() -> upload_data(easy, input))
                        put!(sync_ch, t3); schedule(t3)
                    end
                    Base.sync_end(sync_ch)
                finally
                    if !(interrupted[])
                        if interrupt_task !== nothing
                            # trigger interrupt
                            notify(interrupt)
                            wait(interrupt_task)
                        else
                            remove_handle(downloader′.multi, easy)
                        end
                    end
                end

                # return the response or throw an error
                response[] = Response(get_response_info(easy)...)
                easy.code == Curl.CURLE_OK && return
                message = get_curl_errstr(easy)
                if easy.code == typemax(Curl.CURLcode)
                    # uninitialized code, likely a protocol error
                    code = Int(0)
                else
                    code = Int(easy.code)
                end
                response[] = RequestError(url, code, message, response[])
                throw && Base.throw(response[])
            end
        end
    end
    return response[]
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

# Some of the replacement methods above are reached *dynamically* from precompiled
# stdlib code (the ccall machinery invokes `dlopen(::LazyLibrary)` through a
# function pointer; `Downloads.request`'s precompiled body reaches `sync_end`), so
# trimming cannot see those uses; register them as entrypoints to keep standalone
# compiled instances in the image.
Base.Experimental.entrypoint(Base.Libc.Libdl.dlopen, (Base.Libc.Libdl.LazyLibrary,))
Base.Experimental.entrypoint(Base.Libc.Libdl.dlopen, (Base.Libc.Libdl.LazyLibrary, UInt32))
Base.Experimental.entrypoint(Base.sync_end, (Channel{Any},))

function (@main)(args::Vector{String})::Cint
    # load libcurl and its dependency chain eagerly up front (also keeps the
    # LazyLibrary dlopen method statically reachable)
    Downloads.Curl.LibCURL.LibCURL_jll.eager_mode()
    FarmBroker.run_loop()
    return 0
end
