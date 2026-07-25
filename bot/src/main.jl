# juliac entry point: the bot Lambda `bootstrap` executable.
#
# The shared include carries the `--trim=safe` compatibility method overrides for
# Base / Downloads / Parsers internals that the trim verifier rejects. It is
# compiled into the binary only (the tests include FarmBot.jl directly) and must
# come before FarmBot is loaded so that module `__init__`s and precompiled
# callers resolve to the replacement methods.
include(joinpath(@__DIR__, "..", "..", "lite", "src", "juliac-trim-compat.jl"))

# Bot-only override: `parse_command` uses Meta.parse, which dispatches through the
# untyped `Core._parse` binding (JuliaSyntax by default) — unverifiable and
# uncompilable under trimming. Route it to the flisp C parser instead (a plain
# ccall), with the surrounding code isa-narrowed. Command syntax is simple enough
# that the two parsers agree.
@eval Base.Meta begin
    function _parse_string(text::AbstractString, filename::AbstractString,
                           lineno::Integer, index::Integer, options)
        if index < 1 || index > ncodeunits(text) + 1
            throw(BoundsError(text, index))
        end
        ret = Base.fl_parse(String(text), String(filename), lineno, index - 1,
                            options)::Core.SimpleVector
        return ret[1], (ret[2]::Int) + 1
    end

    function parse(str::AbstractString, pos::Integer;
                   filename="none", greedy::Bool=true, raise::Bool=true, depwarn::Bool=true)
        ex, pos = _parse_string(str, String(filename), 1, pos, greedy ? :statement : :atom)
        if raise && ex isa Expr && ex.head === :error
            err = ex.args[1]
            throw(err isa String ? ParseError(err) : err)  # String: flisp parser
        end
        return ex, pos
    end

    function parse(str::AbstractString;
                   filename="none", raise::Bool=true, depwarn::Bool=true)
        ex, pos = parse(str, 1; filename, greedy=true, raise, depwarn)
        if ex isa Expr && ex.head === :error
            return ex
        end
        if pos <= ncodeunits(str)
            raise && throw(ParseError("extra token after end of expression"))
            return Expr(:error, "extra token after end of expression")
        end
        return ex
    end
end

include(joinpath(@__DIR__, "FarmBot.jl"))
using .FarmBot

function (@main)(args::Vector{String})::Cint
    trim_compat_init()  # eagerly load libcurl and its dependency chain
    FarmBot.lambda_main()
    return 0
end
