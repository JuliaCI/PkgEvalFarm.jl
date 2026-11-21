# Web submission: a person submits a run from a browser, so that tools without
# farm credentials (AI agents in sandboxes, scripts, a chat message) only need to
# produce a link. Nothing is submitted without that person's explicit confirmation.
#
#   GET  /submit?primary=..&against=..&packages=A,B&assertions=true&fresh_baseline=true&request=ID
#        validates the spec and sends the browser through GitHub sign-in (the farm's
#        OAuth app); a per-flow nonce cookie binds the round trip to this browser
#   GET  /submit/callback?code=..&state=..
#        exchanges the code, checks the submitter requirement with the person's own
#        token (as /creds does), pins JuliaLang/julia refs to commits, revokes the
#        token, and redirects to the review page with a signed, short-lived ticket
#   GET  /submit/review?t=TICKET
#        the review page (safe to reload): what would run, a confirmation box and
#        the submit button
#   POST /submit   (form: ticket, confirm)
#        verifies the ticket and creates run "web-<request>" as that person, under
#        the submitter role
#
# The run id comes from `request` (generated when absent), so the link's author knows
# it in advance and a repeated click cannot submit twice; a request id that another
# link already used is refused rather than reported as this link's run. State and
# tickets are HMAC-signed with a key derived from the OAuth app's client secret, the
# one new secret this needs (an SSM SecureString, or GITHUB_CLIENT_SECRET for local
# runs). Configured by GITHUB_CLIENT_SECRET[_PARAM] and PUBLIC_URL (the broker's
# public origin, for the OAuth redirect); without them these routes answer 503.

include(joinpath(@__DIR__, "..", "..", "lite", "src", "FarmLite.jl"))
import .FarmLite

const JULIA_REPO = "JuliaLang/julia"
const STATE_TTL = 600    # seconds from the link to the GitHub callback
const TICKET_TTL = 900   # seconds the review page may sit before the click
# CloudFront refuses URLs over 8192 bytes, and the spec travels in the link, in the
# GitHub authorize URL and callback (as the doubly encoded state) and in the review
# URL; links whose longest leg would not fit are refused before the GitHub detour
const MAX_URL = 7800
const MAX_PACKAGES = 300
const NONCE_COOKIE = "pkgeval_submit"
# Not just read:org: GitHub keeps at most ten tokens per user, app and scope set and
# revokes the oldest beyond that. A scope set of its own puts these short-lived
# sign-in tokens (revoked right after use) in a bucket of their own, so they can
# never evict a machine's `farm login` token (read:org).
const WEB_SCOPE = "read:org read:user"

github_web() = get(ENV, "GITHUB_WEB", "https://github.com")::String
public_url() = String(rstrip(get(ENV, "PUBLIC_URL", "")::String, '/'))
public_host() = lowercase(String(split(split(public_url(), "://")[end], '/')[1]))
callback_url() = public_url() * "/submit/callback"
review_url(ticket::String) = public_url() * "/submit/review?t=" * urlencode(ticket)
report_page() = get(ENV, "PKGEVAL_REPORT_PAGE", "https://pkgeval-reports.julialang.org/")::String
report_url(run_id::String) = report_page() * "?run=" * urlencode(run_id)

now_s() = floor(Int, time())

function random_hex(nbytes::Int)
    bytes = Vector{UInt8}(undef, nbytes)
    Base.Libc.getrandom!(bytes)
    return bytes2hex(bytes)
end


## secrets

const CLIENT_SECRET = Ref{Union{Nothing,String}}(nothing)
# when the secret was last found missing (a placeholder, or a failed read): an
# unconfigured deployment must not turn every anonymous request into an SSM call
const SECRET_MISS_AT = Ref{Int}(0)
const SECRET_MISS_TTL = 60

"The broker's own credentials as a FarmLite context (for SSM)."
function broker_lite_ctx(creds::FarmLite.AwsCreds)
    FarmLite.LiteCtx(; region=env("FARM_REGION"), creds,
                     queue_url=env("PKGEVAL_QUEUE_URL"),
                     slow_queue_url=get(ENV, "PKGEVAL_SLOW_QUEUE_URL", "")::String,
                     runs_table=env("PKGEVAL_RUNS_TABLE"),
                     jobs_table=env("PKGEVAL_JOBS_TABLE"),
                     bucket=env("PKGEVAL_BUCKET"),
                     endpoint=get(ENV, "FARM_ENDPOINT", nothing))
end

"The OAuth app's client secret, or `nothing` when it is not configured (yet)."
function client_secret()::Union{Nothing,String}
    cached = CLIENT_SECRET[]
    cached === nothing || return cached
    direct = get(ENV, "GITHUB_CLIENT_SECRET", "")::String
    if !isempty(direct)
        CLIENT_SECRET[] = direct
        return direct
    end
    param = get(ENV, "GITHUB_CLIENT_SECRET_PARAM", "")::String
    isempty(param) && return nothing
    now_s() - SECRET_MISS_AT[] < SECRET_MISS_TTL && return nothing
    c = lambda_creds()
    secret = try
        FarmLite.ssm_parameter(broker_lite_ctx(FarmLite.AwsCreds(c.access_key_id,
                                                                 c.secret_key, c.token)),
                               param)
    catch
        SECRET_MISS_AT[] = now_s()
        rethrow()
    end
    # a placeholder left from terraform is not a secret: stay unconfigured; a secret
    # set out of band is picked up within SECRET_MISS_TTL, without a redeploy
    if isempty(secret) || startswith(secret, "placeholder")
        SECRET_MISS_AT[] = now_s()
        return nothing
    end
    CLIENT_SECRET[] = secret
    return secret
end

"The client secret if web submission is fully configured, else `nothing`."
web_secret() = isempty(public_url()) ? nothing : client_secret()

signing_key(secret::String) = hmac_sha256(Vector{UInt8}(secret), "pkgeval web submit v1")
mac(key::Vector{UInt8}, purpose::String, payload::String) =
    bytes2hex(hmac_sha256(key, purpose * "\n" * payload))

function secure_equals(a::String, b::String)
    ncodeunits(a) == ncodeunits(b) || return false
    diff = UInt8(0)
    for (x, y) in zip(codeunits(a), codeunits(b))
        diff |= x ⊻ y
    end
    return diff == 0x00
end

"`payload&s=<mac>`; the signature always comes last."
signed(key::Vector{UInt8}, purpose::String, payload::String) =
    payload * "&s=" * mac(key, purpose, payload)

"The payload of a `signed` string, or `nothing` if the signature does not verify."
function verify_signed(key::Vector{UInt8}, purpose::String, s::String)::Union{Nothing,String}
    i = findlast("&s=", s)
    i === nothing && return nothing
    payload = s[1:prevind(s, first(i))]
    sig = s[nextind(s, last(i)):end]
    secure_equals(mac(key, purpose, payload), String(sig)) || return nothing
    return String(payload)
end


## query strings and forms

function urldecode(s::AbstractString)::String
    cu = codeunits(s)
    out = UInt8[]
    i = 1
    n = length(cu)
    while i <= n
        b = cu[i]
        if b == UInt8('+')
            push!(out, UInt8(' '))
            i += 1
        elseif b == UInt8('%') && i + 2 <= n
            hex = tryparse(UInt8, String(cu[i+1:i+2]); base=16)
            if hex === nothing
                push!(out, b)
                i += 1
            else
                push!(out, something(hex))
                i += 3
            end
        else
            push!(out, b)
            i += 1
        end
    end
    return String(out)
end

const Params = Vector{Pair{String,String}}

function parse_query(q::AbstractString)::Params
    out = Params()
    for part in split(q, '&'; keepempty=false)
        i = findfirst('=', part)
        key, value = i === nothing ? (part, "") :
                     (part[1:prevind(part, i)], part[nextind(part, i):end])
        push!(out, urldecode(key) => urldecode(value))
    end
    return out
end

"""
    param(params, key) -> (value::Union{Nothing,String}, ok::Bool)

The single value of `key`. A repeated key is an error rather than first- or
last-wins, so a link cannot show one value and submit another.
"""
function param(params::Params, key::String)
    value = nothing
    for (k, v) in params
        k == key || continue
        value === nothing || return (nothing, false)
        value = v
    end
    return (value, true)
end

function parse_bool(s::Union{Nothing,String})::Union{Nothing,Bool}
    s === nothing && return false
    v = lowercase(something(s))
    v in ("", "0", "false", "no", "off") && return false
    v in ("1", "true", "yes", "on") && return true
    return nothing
end


## the run spec

struct WebSpec
    primary::String
    against::Union{Nothing,String}
    packages::Vector{String}
    assertions::Bool
    fresh_baseline::Bool
    request::String
end

# ASCII classes and \z: PCRE's `\d` matches any Unicode digit (fullwidth "１" looks
# like "1" but no worker can parse it) and `$` matches before a final newline
const VERSION_RE = r"^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\z"
const REF_RE = r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z"
const SHA_RE = r"^[0-9a-f]{40}\z"
const PKG_RE = r"^[A-Za-z][A-Za-z0-9_]*\z"
const REQUEST_RE = r"^[A-Za-z0-9_-]{8,64}\z"
const SHOWABLE_RE = r"^[A-Za-z0-9._/#+:@-]{1,60}\z"

"A rejected value, quoted only when it is short and plain (pages never echo prose a link chose)."
shown(s::AbstractString) = occursin(SHOWABLE_RE, s) ? "`" * s * "`" : "the value given"

"""
A Julia spec the farm can run, or an error message. Workers only download builds:
official binaries for `nightly`, `stable` and release versions, and CI-staged
builds for JuliaLang/julia commits (the only ones with an assertions variant, so
with assertions a version means its release tag in JuliaLang/julia). Versions are
spelled `v1.12.0`, the form baseline reuse recognizes.
"""
function normalize_julia(spec::String, assertions::Bool)::Tuple{Union{Nothing,String},String}
    if spec == "nightly" || spec == "stable"
        assertions && return (nothing, "`$spec` has no assertions build; use a JuliaLang/julia commit or branch (e.g. JuliaLang/julia#master)")
        return (spec, "")
    end
    if occursin(VERSION_RE, spec)
        v = "v" * lstrip(spec, 'v')
        return (assertions ? "$JULIA_REPO#" * v : v, "")
    end
    i = findfirst('#', spec)
    i === nothing &&
        return (nothing, shown(spec) * " is not a Julia spec: use nightly, stable, a version like 1.12.0, or JuliaLang/julia#<ref>")
    repo = spec[1:prevind(spec, i)]
    ref = spec[nextind(spec, i):end]
    repo == JULIA_REPO ||
        return (nothing, "only $JULIA_REPO commits can be evaluated (got $(shown(repo)))")
    occursin(REF_RE, ref) || return (nothing, shown(ref) * " is not a valid git ref")
    return ("$JULIA_REPO#$ref", "")
end

"""
    parse_spec(params; generate_request=false) -> (spec, error_message)

Validate a submission. `request` names the run (`web-<request>`); with
`generate_request` a missing one is made up, otherwise it is required.
"""
function parse_spec(params::Params; generate_request::Bool=false)::Tuple{Union{Nothing,WebSpec},String}
    for (k, v) in params
        (isvalid(String, k) && isvalid(String, v)) || return (nothing, "parameters must be UTF-8")
    end
    for (k, _) in params
        k in ("primary", "against", "packages", "assertions", "fresh_baseline", "request") ||
            return (nothing, "unknown parameter " * shown(k))
    end
    primary_raw, ok1 = param(params, "primary")
    against_raw, ok2 = param(params, "against")
    packages_raw, ok3 = param(params, "packages")
    assertions_raw, ok4 = param(params, "assertions")
    fresh_raw, ok5 = param(params, "fresh_baseline")
    request_raw, ok6 = param(params, "request")
    (ok1 && ok2 && ok3 && ok4 && ok5 && ok6) || return (nothing, "each parameter may appear only once")

    assertions = parse_bool(assertions_raw)
    assertions === nothing && return (nothing, "assertions must be true or false")
    fresh = parse_bool(fresh_raw)
    fresh === nothing && return (nothing, "fresh_baseline must be true or false")

    (primary_raw === nothing || isempty(something(primary_raw))) &&
        return (nothing, "`primary` (the Julia to evaluate) is required")
    primary, err = normalize_julia(String(strip(something(primary_raw))), something(assertions))
    primary === nothing && return (nothing, "primary: " * err)
    against = nothing
    if against_raw !== nothing && !isempty(strip(something(against_raw)))
        a, err = normalize_julia(String(strip(something(against_raw))), something(assertions))
        a === nothing && return (nothing, "against: " * err)
        against = a
    end

    packages = String[]
    if packages_raw !== nothing
        for name in split(something(packages_raw), r"[\s,]+"; keepempty=false)
            pkg = String(name)
            endswith(pkg, ".jl") && (pkg = String(chop(pkg; tail=3)))
            occursin(PKG_RE, pkg) || return (nothing, shown(pkg) * " is not a package name")
            pkg in packages || push!(packages, pkg)
        end
        length(packages) <= MAX_PACKAGES ||
            return (nothing, "a web submission can name at most $MAX_PACKAGES packages " *
                             "(leave `packages` out to test all of them, or use `farm submit`)")
    end

    request = if request_raw === nothing || isempty(something(request_raw))
        generate_request || return (nothing, "missing request id")
        random_hex(12)
    else
        something(request_raw)
    end
    occursin(REQUEST_RE, request) ||
        return (nothing, "request must be 8-64 letters, digits, '-' or '_'")

    return (WebSpec(something(primary), against, packages, something(assertions),
                    something(fresh), request), "")
end

"The canonical query string of a spec (what is signed, and the link format)."
function spec_query(s::WebSpec)::String
    parts = String["primary=" * urlencode(s.primary)]
    s.against === nothing || push!(parts, "against=" * urlencode(something(s.against)))
    isempty(s.packages) || push!(parts, "packages=" * urlencode(join(s.packages, ",")))
    s.assertions && push!(parts, "assertions=true")
    s.fresh_baseline && push!(parts, "fresh_baseline=true")
    push!(parts, "request=" * urlencode(s.request))
    return join(parts, "&")
end

run_id(s::WebSpec) = "web-" * s.request

"Which link a run came from: two links reusing a request id must not be confused."
link_digest(s::WebSpec) = hexdigest(spec_query(s))

function configs_json(s::WebSpec)::String
    primary = FarmLite.config_json("primary", s.primary; assertions=s.assertions)
    against = s.against
    against === nothing && return "[" * primary * "]"
    return "[" * primary * "," *
           FarmLite.config_json("against", something(against); assertions=s.assertions) * "]"
end

"Pin JuliaLang/julia refs to commits (as the bot does); an unresolvable ref is an error."
function pin_spec(gh::FarmLite.GitHubCtx, s::WebSpec)::Tuple{Union{Nothing,WebSpec},String}
    pinned = String[]
    for spec in (s.primary, s.against)
        spec === nothing && continue
        julia = something(spec)
        if startswith(julia, JULIA_REPO * "#")
            julia = FarmLite.pin_commit(gh, julia)
            occursin(SHA_RE, julia[ncodeunits(JULIA_REPO)+2:end]) ||
                return (nothing, "`$(something(spec))` names no commit in $JULIA_REPO")
        end
        push!(pinned, julia)
    end
    against = s.against === nothing ? nothing : pinned[2]
    return (WebSpec(pinned[1], against, s.packages, s.assertions, s.fresh_baseline,
                    s.request), "")
end


## GitHub OAuth web flow

struct OAuthTokenResponse
    access_token::Union{Nothing,String}
    error::Union{Nothing,String}
end

function json_make(::Type{OAuthTokenResponse}, x::LazyVal)
    token = Ref{Union{Nothing,String}}(nothing)
    err = Ref{Union{Nothing,String}}(nothing)
    pos = JSON.applyobject(x) do k, v
        isnullval(v) && return nothing
        if k == "access_token"
            s, p = json_string(v); token[] = s; return p
        elseif k == "error"
            s, p = json_string(v); err[] = s; return p
        end
        return nothing
    end
    return OAuthTokenResponse(token[], err[]), pos::Int
end

form_encode(pairs::Vector{Pair{String,String}}) =
    join([urlencode(k) * "=" * urlencode(v) for (k, v) in pairs], "&")

"What to tell a person about an OAuth error code (fixed texts; a link cannot choose them)."
function oauth_error_text(code::String)::String
    code == "access_denied" && return "the authorization was declined on GitHub"
    code == "redirect_uri_mismatch" &&
        return "the farm's OAuth app has another callback URL configured (redirect_uri_mismatch)"
    code == "application_suspended" && return "the farm's OAuth app is suspended"
    code == "bad_verification_code" &&
        return "the sign-in code was already used or expired; open the submission link again"
    code == "incorrect_client_credentials" &&
        return "the farm's OAuth client secret is wrong (incorrect_client_credentials)"
    return "GitHub sign-in did not complete" *
           (occursin(r"^[a-z_]{1,40}\z", code) ? " (" * code * ")" : "")
end

function exchange_code(secret::String, code::String)::Tuple{Union{Nothing,String},String}
    body = form_encode(["client_id" => env("GITHUB_CLIENT_ID"), "client_secret" => secret,
                        "code" => code, "redirect_uri" => callback_url()])
    resp = http_request("POST", github_web() * "/login/oauth/access_token";
                        headers=["Accept" => "application/json",
                                 "Content-Type" => "application/x-www-form-urlencoded",
                                 "User-Agent" => "PkgEvalFarm-broker"],
                        body)
    resp.status == 200 || return (nothing, "GitHub answered HTTP $(resp.status)")
    r = parse_json(resp.body, OAuthTokenResponse)
    r.access_token === nothing || return (something(r.access_token), "")
    return (nothing, oauth_error_text(something(r.error, "")))
end

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64encode_compat(data::AbstractString)
    bytes = codeunits(data)
    io = IOBuffer()
    for i in 1:3:length(bytes)
        n = min(3, length(bytes) - i + 1)
        v = UInt32(bytes[i]) << 16
        n > 1 && (v |= UInt32(bytes[i+1]) << 8)
        n > 2 && (v |= UInt32(bytes[i+2]))
        for j in 0:3
            print(io, j <= n ? B64[Int((v >> (18 - 6j)) & 0x3f) + 1] : '=')
        end
    end
    return String(take!(io))
end

"Revoke a token we are done with, so web sign-ins never pile up tokens (best effort)."
function revoke_token(secret::String, token::String)
    try
        cid = env("GITHUB_CLIENT_ID")
        resp = http_request("DELETE", github_api() * "/applications/$cid/token";
                            headers=["Authorization" => "Basic " * base64encode_compat(cid * ":" * secret),
                                     "Accept" => "application/vnd.github+json",
                                     "Content-Type" => "application/json",
                                     "User-Agent" => "PkgEvalFarm-broker"],
                            body="{\"access_token\":" * JSON.json(token) * "}")
        resp.status == 204 || println(Core.stderr, "token revocation answered HTTP ", resp.status)
    catch err
        println(Core.stderr, "token revocation failed: ", @trim_errmsg(err)::String)
    end
    return nothing
end


## responses

function html_escape(s::AbstractString)::String
    io = IOBuffer()
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == '\''
            print(io, "&#39;")
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

const PAGE_STYLE = """
    body{font:16px/1.5 system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;color:#1b1f24;background:#fff}
    h1{font-size:1.4rem} code{font-size:.9em;background:#f1f3f5;padding:.1em .3em;border-radius:3px;word-break:break-all}
    table{border-collapse:collapse;width:100%;margin:1rem 0} th,td{text-align:left;padding:.4rem .5rem;border-bottom:1px solid #e3e6ea;vertical-align:top}
    th{width:9rem;font-weight:600} .note{color:#57606a;font-size:.9rem}
    .confirm{display:block;margin:1.5rem 0 3rem}
    button{font:inherit;font-weight:600;padding:.6rem 1.2rem;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}
    .err{border-left:4px solid #cf222e;padding-left:.8rem}
    @media (prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3} code{background:#21262d} th,td{border-color:#30363d} .note{color:#8b949e}}
    """

function page(title::String, body_html::String)
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>$(html_escape(title))</title><style>$PAGE_STYLE</style></head>
    <body><h1>$(html_escape(title))</h1>$body_html</body></html>
    """
end

const HTML_HEADERS = Dict(
    "Content-Type" => "text/html; charset=utf-8",
    "Cache-Control" => "no-store",
    "X-Frame-Options" => "DENY",
    "Referrer-Policy" => "no-referrer",
    "X-Content-Type-Options" => "nosniff",
    "Content-Security-Policy" =>
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; " *
        "frame-ancestors 'none'; base-uri 'none'")

html_response(status::Int, title::String, body_html::String;
              cookies::Vector{String}=String[]) =
    FunctionUrlResponse(status, copy(HTML_HEADERS), page(title, body_html), cookies)

error_page(status::Int, title::String, message::String; cookies::Vector{String}=String[]) =
    html_response(status, title, "<p class=\"err\">" * html_escape(message) * "</p>"; cookies)

redirect_response(location::String; cookies::Vector{String}=String[]) =
    FunctionUrlResponse(302, Dict("Location" => location, "Cache-Control" => "no-store",
                                  "Referrer-Policy" => "no-referrer"), "", cookies)

# one cookie per sign-in, named after its nonce, so several links open at once in
# one browser never overwrite each other's binding
nonce_cookie(nonce::String, max_age::Int) =
    "$(NONCE_COOKIE)_$nonce=1; Path=/submit; Max-Age=$max_age; Secure; HttpOnly; SameSite=Lax"

function cookie_value(event, name::String)::Union{Nothing,String}
    for header in event_cookies(event)
        for part in split(header, ';')
            kv = strip(part)
            i = findfirst('=', kv)
            i === nothing && continue
            kv[1:prevind(kv, i)] == name && return String(kv[nextind(kv, i):end])
        end
    end
    return nothing
end

function not_configured()
    error_page(503, "Web submission is not available",
               "This farm deployment has no OAuth client secret or public URL configured. " *
               "Use `farm submit` with a farm login instead.")
end

function julia_cell(spec::String, orig::Union{Nothing,String})
    cell = "<code>" * html_escape(spec) * "</code>"
    (orig !== nothing && something(orig) != spec) &&
        (cell *= " <span class=\"note\">(" * html_escape(something(orig)) * ")</span>")
    return cell
end

"The table of what a run does; `was_*` are the refs as the link named them, before pinning."
function spec_rows(s::WebSpec, was_primary::Union{Nothing,String}=nothing,
                   was_against::Union{Nothing,String}=nothing)
    io = IOBuffer()
    print(io, "<table>")
    print(io, "<tr><th>Julia</th><td>", julia_cell(s.primary, was_primary), "</td></tr>")
    against = s.against
    if against === nothing
        print(io, "<tr><th>Compared with</th><td>nothing (a single-configuration run)</td></tr>")
    else
        print(io, "<tr><th>Compared with</th><td>", julia_cell(something(against), was_against),
              "</td></tr>")
    end
    if isempty(s.packages)
        print(io, "<tr><th>Packages</th><td><strong>all</strong> registered packages compatible with this Julia</td></tr>")
    else
        names = join([html_escape(p) for p in s.packages], ", ")
        print(io, "<tr><th>Packages</th><td>", string(length(s.packages)), ": ", names, "</td></tr>")
    end
    print(io, "<tr><th>Build</th><td>", s.assertions ? "with assertions" : "release build", "</td></tr>")
    s.against === nothing ||
        print(io, "<tr><th>Baseline</th><td>",
              s.fresh_baseline ? "evaluated afresh" : "reuses an earlier run's results when one matches",
              "</td></tr>")
    print(io, "<tr><th>Run</th><td><code>", html_escape(run_id(s)), "</code></td></tr>")
    print(io, "</table>")
    return String(take!(io))
end


## handlers

"GET /submit: validate, then sign in with GitHub."
function web_submit_start(event)
    secret = web_secret()
    secret === nothing && return not_configured()
    # the nonce cookie belongs to the host that sets it and GitHub always returns to
    # PUBLIC_URL, so a link on another host (the raw Function URL) moves there first;
    # CloudFront marks what it forwards, and from it Host is the Function URL's own
    host = event_header(event, "host")
    if event_header(event, "x-amz-cf-id") === nothing && host !== nothing &&
       lowercase(something(host)) != public_host()
        q = event_query(event)
        return redirect_response(public_url() * "/submit" * (isempty(q) ? "" : "?" * q))
    end
    spec, err = parse_spec(parse_query(event_query(event)); generate_request=true)
    spec === nothing && return error_page(400, "This submission link is not valid", err)
    s = something(spec)
    key = signing_key(something(secret))
    nonce = random_hex(16)
    state = signed(key, "state", spec_query(s) * "&n=" * nonce * "&e=" * string(now_s() + STATE_TTL))
    location = github_web() * "/login/oauth/authorize" *
               "?client_id=" * urlencode(env("GITHUB_CLIENT_ID")) *
               "&redirect_uri=" * urlencode(callback_url()) *
               "&scope=" * urlencode(WEB_SCOPE) * "&allow_signup=false" *
               "&state=" * urlencode(state)
    callback_len = ncodeunits(callback_url()) + 6 + 40 + 7 + ncodeunits(urlencode(state))
    review_len = ncodeunits(review_url(state)) + 400  # the ticket adds login, refs, digest
    max(ncodeunits(location), callback_len, review_len) > MAX_URL &&
        return error_page(414, "This submission link is too long",
                          "the run does not fit in a web submission (at most about " *
                          string(MAX_PACKAGES) * " packages with short names); leave `packages` " *
                          "out to test all of them, or use `farm submit` with a farm login")
    return redirect_response(location; cookies=[nonce_cookie(nonce, STATE_TTL)])
end

"""
Check a signed state or ticket: signature, expiry, and that it was issued to this
browser (its nonce cookie). Returns its parameters, or an error message.
"""
function open_signed(event, key::Vector{UInt8}, purpose::String,
                     value::Union{Nothing,String})::Tuple{Union{Nothing,Params},String}
    value === nothing && return (nothing, "the link is incomplete")
    payload = verify_signed(key, purpose, something(value))
    payload === nothing && return (nothing, "the request was altered or is not from this farm")
    params = parse_query(something(payload))
    nonce, ok_n = param(params, "n")
    expiry, ok_e = param(params, "e")
    (ok_n && ok_e && nonce !== nothing && expiry !== nothing) ||
        return (nothing, "the request is malformed")
    deadline = tryparse(Int, something(expiry))
    (deadline === nothing || something(deadline) < now_s()) &&
        return (nothing, "this page expired; open the submission link again")
    cookie_value(event, NONCE_COOKIE * "_" * something(nonce)) == "1" ||
        return (nothing, "this sign-in was started in another browser or on another host " *
                         "(or cookies are blocked); open the submission link again here")
    return (params, "")
end

const TICKET_KEYS = ("n", "e", "login", "link", "was_primary", "was_against")

"The spec part of a state or ticket."
spec_params(params::Params) = filter(p -> !(first(p) in TICKET_KEYS), params)

"GET /submit/callback: who signed in, may they submit, and what exactly would run."
function web_submit_callback(event)
    secret = web_secret()
    secret === nothing && return not_configured()
    key = signing_key(something(secret))
    query = parse_query(event_query(event))
    gh_error, _ = param(query, "error")
    gh_error === nothing ||
        return error_page(403, "GitHub sign-in did not complete",
                          oauth_error_text(something(gh_error)) * ". Nothing was submitted.")
    state, _ = param(query, "state")
    code, _ = param(query, "code")
    params, err = open_signed(event, key, "state", state)
    params === nothing && return error_page(400, "Sign-in could not be verified", err)
    nonce = something(first(param(something(params), "n")))
    spec, err = parse_spec(spec_params(something(params)))
    spec === nothing && return error_page(400, "This submission link is not valid", err)
    code === nothing && return error_page(400, "Sign-in could not be verified", "GitHub sent no code")
    s = something(spec)

    token, err = exchange_code(something(secret), something(code))
    token === nothing && return error_page(403, "GitHub sign-in failed", err)
    login = nothing
    pinned = nothing
    status = 200
    message = ""
    try
        login, status, message = check_role(something(token), "submitter")
        if login !== nothing
            pinned, message = pin_spec(FarmLite.GitHubCtx(something(token), github_api()), s)
            pinned === nothing && (status = 400)
        end
    finally
        revoke_token(something(secret), something(token))
    end
    login === nothing && return error_page(status, "You cannot submit PkgEval runs", message)
    pinned === nothing && return error_page(status, "This submission cannot run", message)
    p = something(pinned)

    extra = "&link=" * link_digest(s) * "&was_primary=" * urlencode(s.primary)
    against = s.against
    against === nothing || (extra *= "&was_against=" * urlencode(something(against)))
    ticket = signed(key, "ticket", "login=" * urlencode(something(login)) * "&" * spec_query(p) *
                                   extra * "&n=" * nonce * "&e=" * string(now_s() + TICKET_TTL))
    # Post/Redirect/Get: the review page can be reloaded or restored without
    # replaying the (single-use) OAuth code; the cookie must outlive the ticket
    return redirect_response(review_url(ticket); cookies=[nonce_cookie(nonce, TICKET_TTL)])
end

const OpenedTicket = Tuple{Union{Nothing,String},Union{Nothing,WebSpec},String,
                           Union{Nothing,String},Union{Nothing,String},String}

"A verified ticket: (login, spec, link digest, refs as linked, error message)."
function open_ticket(event, key::Vector{UInt8}, ticket::Union{Nothing,String})::OpenedTicket
    params, err = open_signed(event, key, "ticket", ticket)
    params === nothing && return (nothing, nothing, "", nothing, nothing, err)
    ps = something(params)
    login, ok1 = param(ps, "login")
    link, ok2 = param(ps, "link")
    was_primary, ok3 = param(ps, "was_primary")
    was_against, ok4 = param(ps, "was_against")
    (ok1 && ok2 && ok3 && ok4 && login !== nothing && link !== nothing) ||
        return (nothing, nothing, "", nothing, nothing, "the ticket is malformed")
    spec, err = parse_spec(spec_params(ps))
    spec === nothing && return (nothing, nothing, "", nothing, nothing, err)
    return (login, spec, something(link), was_primary, was_against, "")
end

"GET /submit/review: what would run, and the confirmation (nothing happens here)."
function web_submit_review(event)
    secret = web_secret()
    secret === nothing && return not_configured()
    key = signing_key(something(secret))
    t, ok = param(parse_query(event_query(event)), "t")
    ok || return error_page(400, "This review page is not valid", "the link is malformed")
    login, spec, _, was_primary, was_against, err = open_ticket(event, key, t)
    (login === nothing || spec === nothing) &&
        return error_page(400, "This review page is not valid", err)
    s = something(spec)
    # every interpolation a String: a long `string(...)` with mixed argument types
    # becomes a Vararg{Any} call, which `juliac --trim` rejects
    who = html_escape(something(login))
    minutes = string(TICKET_TTL ÷ 60)
    rows = spec_rows(s, was_primary, was_against)
    ticket = html_escape(something(t))
    body = """
        <p>Signed in as <strong>@$who</strong>. Review the run; nothing happens until
        you confirm and submit it.</p>
        $rows
        <form method="post" action="/submit">
        <input type="hidden" name="ticket" value="$ticket">
        <label class="confirm"><input type="checkbox" name="confirm" value="yes" required>
        I opened this submission link myself and want this run.</label>
        <button type="submit">Submit this run as @$who</button>
        </form>
        <p class="note">If you did not just open a PkgEval submission link, close this
        page. PkgEval runs on shared JuliaLang compute; a run over all packages takes
        hours. This page stays valid for $minutes minutes.</p>
        """
    return html_response(200, "Submit a PkgEval run?", body)
end

"Credentials of the submitter role, in the person's name (CloudTrail shows who)."
function submitter_ctx(login::String)
    c = assume_role(role_arn("submitter"), login * "-web";
                    duration=parse(Int, get(ENV, "CRED_DURATION", "3600")))
    return broker_lite_ctx(FarmLite.AwsCreds(c.access_key_id, c.secret_access_key,
                                             c.session_token))
end

const LINK_RE = r"\"link\":\"([0-9a-f]{64})\""

"POST /submit: the confirmed click."
function web_submit_confirm(event)
    secret = web_secret()
    secret === nothing && return not_configured()
    key = signing_key(something(secret))
    body = event_body(event)
    event_isbase64(event) && (body = String(base64decode_compat(body)))
    form = parse_query(body)
    ticket, ok = param(form, "ticket")
    confirm, ok2 = param(form, "confirm")
    (ok && ok2) || return error_page(400, "Not submitted", "the form is malformed")
    login_raw, spec, link, _, _, err = open_ticket(event, key, ticket)
    (login_raw === nothing || spec === nothing) && return error_page(400, "Not submitted", err)
    confirm == "yes" ||
        return error_page(400, "Not submitted",
                          "tick the confirmation box on the review page to submit the run")
    login = something(login_raw)
    s = something(spec)

    id = run_id(s)
    ctx = submitter_ctx(login)
    created = FarmLite.create_run(ctx; run_id=id, configs_json=configs_json(s),
                                  packages=s.packages,
                                  context_json="{\"via\":\"web\",\"link\":\"" * link * "\"}",
                                  submitter=login, reuse=!s.fresh_baseline)
    report = "<p>Progress and the report: <a href=\"" * html_escape(report_url(id)) * "\">" *
             html_escape(report_url(id)) * "</a></p>"
    # the nonce cookie is left to expire, so a resubmission says "already submitted"
    created && return html_response(200, "Run submitted",
        "<p>Run <code>$(html_escape(id))</code> is queued as @$(html_escape(login)).</p>" *
        spec_rows(s) * report)
    existing = FarmLite.get_run(ctx, id)
    by = FarmLite.str(existing, "submitter", "someone")
    at = FarmLite.str(existing, "created_at", "earlier")
    m = match(LINK_RE, FarmLite.str(existing, "context", ""))
    if m === nothing || something(m.captures[1]) != link
        return error_page(409, "Not submitted",
            "Run " * id * " already exists, from a different submission (by @" * by *
            " at " * at * "). Ask for a link with a fresh request id.")
    end
    return html_response(200, "Already submitted",
        "<p>Run <code>$(html_escape(id))</code> was already submitted by " *
        "@$(html_escape(by)) at $(html_escape(at)); nothing new was queued.</p>" * report)
end

"Route a web-submission request, rendering failures as a page rather than a 502."
function handle_web(method::String, path::String, event)::FunctionUrlResponse
    try
        if path == "/submit" && method == "GET"
            return web_submit_start(event)
        elseif path == "/submit" && method == "POST"
            return web_submit_confirm(event)
        elseif path == "/submit/callback" && method == "GET"
            return web_submit_callback(event)
        elseif path == "/submit/review" && method == "GET"
            return web_submit_review(event)
        end
        return error_page(405, "Not allowed", "unsupported method")
    catch err
        msg = (@trim_errmsg err)::String
        println(Core.stderr, "web submission failed: ", msg)
        outcome = path == "/submit" && method == "POST" ?
            "The run may or may not have been queued. Submitting the review page again is " *
            "safe: the run id is fixed, so it cannot start twice, and a run recorded but " *
            "not yet started gets started." :
            "Nothing was submitted."
        return error_page(500, "Something went wrong", outcome * " (" * msg * ")")
    end
end
