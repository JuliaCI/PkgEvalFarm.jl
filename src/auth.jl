# Worker/submitter authentication.
#
# Machines are enrolled by a human logging in with the GitHub OAuth *device flow*
# (RFC 8628; only needs the public client id). The resulting GitHub token is then
# exchanged at the credential broker — which checks team membership — for short-lived,
# least-privilege STS credentials plus the farm's resource locations. Credentials
# auto-refresh through the broker for as long as the GitHub token stays valid.

const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code"
const GITHUB_TOKEN_URL = "https://github.com/login/oauth/access_token"
const JSON_ACCEPT = ["Accept" => "application/json",
                     "Content-Type" => "application/x-www-form-urlencoded"]

config_dir() = joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")),
                        "PkgEvalFarm")
token_path() = joinpath(config_dir(), "github-token.json")

broker_url() = get(ENV, "PKGEVAL_FARM_BROKER") do
    error("no broker configured; pass --broker or set PKGEVAL_FARM_BROKER")
end

"Query the broker for its public configuration (OAuth client id, org/team names)."
function broker_info(broker::AbstractString)
    resp = HTTP.get(joinpath_url(broker, "info"))
    return JSON.parse(String(resp.body))
end

joinpath_url(base, path) = string(rstrip(base, '/'), "/", path)

"""
    device_flow_login(client_id; scope="read:org") -> token

Interactive GitHub device-flow login: prints a one-time code for the user to enter at
github.com/login/device, polls until approved, and returns the OAuth access token.
"""
function device_flow_login(client_id::AbstractString; scope::AbstractString="read:org",
                           io::IO=stderr)
    resp = HTTP.post(GITHUB_DEVICE_CODE_URL, JSON_ACCEPT,
                     HTTP.URIs.escapeuri(["client_id" => client_id, "scope" => scope]))
    flow = JSON.parse(String(resp.body))
    haskey(flow, "device_code") || error("GitHub device flow failed: $flow")

    println(io)
    println(io, "  To authorize this machine, visit:  ", flow["verification_uri"])
    println(io, "  and enter the code:                ", flow["user_code"])
    println(io)

    interval = get(flow, "interval", 5)
    deadline = time() + get(flow, "expires_in", 900)
    while time() < deadline
        sleep(interval)
        resp = HTTP.post(GITHUB_TOKEN_URL, JSON_ACCEPT,
                         HTTP.URIs.escapeuri([
                             "client_id" => client_id,
                             "device_code" => flow["device_code"],
                             "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"]))
        result = JSON.parse(String(resp.body))
        if haskey(result, "access_token")
            return result["access_token"]
        elseif result["error"] == "authorization_pending"
            continue
        elseif result["error"] == "slow_down"
            interval = get(result, "interval", interval + 5)
        else
            error("GitHub device flow failed: $(result["error"])")
        end
    end
    error("GitHub device flow timed out; run login again")
end

"Log in via the device flow and store the GitHub token for later use."
function login(broker::AbstractString=broker_url())
    info = broker_info(broker)
    token = device_flow_login(info["client_id"])
    user = github_user(token)
    mkpath(config_dir())
    path = token_path()
    write(path, JSON.json(Dict("token" => token, "user" => user, "broker" => broker,
                               "created_at" => isodate())))
    chmod(path, 0o600)
    @info "logged in to PkgEval farm" user broker
    return user
end

function github_user(token::AbstractString)
    resp = HTTP.get("https://api.github.com/user",
                    ["Authorization" => "Bearer $token",
                     "Accept" => "application/vnd.github+json"])
    return JSON.parse(String(resp.body))["login"]
end

"The stored (or environment-provided) GitHub token."
function github_token()
    token = get(ENV, "PKGEVAL_FARM_GITHUB_TOKEN", "")
    isempty(token) || return token
    path = token_path()
    isfile(path) || error("not logged in; run `farm login` first")
    return JSON.parse(read(path, String))["token"]
end


## broker client

struct BrokerError <: Exception
    status::Int
    message::String
end
Base.showerror(io::IO, err::BrokerError) =
    print(io, "credential broker refused the request (HTTP $(err.status)): $(err.message)")

function fetch_broker_creds(broker::AbstractString, role::AbstractString,
                            token::AbstractString)
    resp = HTTP.post(joinpath_url(broker, "creds"),
                     ["Authorization" => "Bearer $token",
                      "Content-Type" => "application/json"],
                     JSON.json(Dict("role" => role));
                     status_exception=false)
    body = String(resp.body)
    if resp.status != 200
        message = try
            JSON.parse(body)["error"]
        catch
            body
        end
        throw(BrokerError(resp.status, message))
    end
    return JSON.parse(body)
end

parse_expiration(s::AbstractString) =
    DateTime(replace(s, r"(\.\d+)?Z$" => ""), dateformat"yyyy-mm-dd\THH:MM:SS")

function aws_credentials(broker, role, token, payload=fetch_broker_creds(broker, role, token))
    c = payload["credentials"]
    AWS.AWSCredentials(c["access_key_id"], c["secret_access_key"], c["session_token"];
                       expiry=parse_expiration(c["expiration"]),
                       renew=() -> aws_credentials(broker, role, token))
end

"""
Renewing credentials from a local metadata-style proxy (EC2 workers): sandboxed
package code shares the host network, so IMDS itself is firewalled to root and a
root-owned proxy re-serves the credentials gated on a bearer token that only the
worker's environment holds (the PkgEval sandbox inherits neither environment nor
host files, so the token is out of its reach).
"""
function proxy_credentials(url::AbstractString, token::AbstractString)
    resp = HTTP.get(url, ["Authorization" => "Bearer $token"])
    c = JSON.parse(String(resp.body))
    # IMDS credential document shape
    AWS.AWSCredentials(c["AccessKeyId"], c["SecretAccessKey"], c["Token"];
                       expiry=parse_expiration(c["Expiration"]),
                       renew=() -> proxy_credentials(url, token))
end

"""
    farm_ctx(; broker=broker_url(), role="worker") -> (ctx::FarmCtx, user)

Build a `FarmCtx` with auto-refreshing broker-vended credentials.

The broker is bypassed when `PKGEVAL_CREDS_URL` is set (EC2 workers: bearer-gated
local credential proxy, see `proxy_credentials`) or when `PKGEVAL_QUEUE_URL` alone is
set (ambient AWS credential chain — admins and tests).
"""
function farm_ctx(; broker::Union{AbstractString,Nothing}=nothing, role::AbstractString="worker")
    if broker === nothing && haskey(ENV, "PKGEVAL_CREDS_URL")
        cfg = farm_config_from_env()
        creds = proxy_credentials(ENV["PKGEVAL_CREDS_URL"], ENV["PKGEVAL_CREDS_TOKEN"])
        return FarmCtx(cfg, AWS.AWSConfig(; creds, region=cfg.region)), worker_identity()
    end
    if broker === nothing && haskey(ENV, "PKGEVAL_QUEUE_URL")
        cfg = farm_config_from_env()
        return FarmCtx(cfg, AWS.global_aws_config(; region=cfg.region)), worker_identity()
    end
    broker = something(broker, broker_url())
    token = github_token()
    payload = fetch_broker_creds(broker, role, token)
    creds = aws_credentials(broker, role, token, payload)
    cfg = FarmConfig(payload["config"])
    ctx = FarmCtx(cfg, AWS.AWSConfig(; creds, region=cfg.region))
    return ctx, payload["user"]
end

"""
    lite_ctx_provider(; broker=nothing, role="submitter") -> () -> FarmLite.LiteCtx

A `FarmLite.LiteCtx` factory for the FarmBot code paths (`farm bot`, `farm report`),
re-fetching broker credentials shortly before they expire. Bypasses the broker when
`PKGEVAL_QUEUE_URL` is set (ambient env credentials, like `farm_ctx`).
"""
function lite_ctx_provider(; broker::Union{AbstractString,Nothing}=nothing,
                           role::AbstractString="submitter")
    if broker === nothing && haskey(ENV, "PKGEVAL_QUEUE_URL")
        return FarmLite.ctx_from_env
    end
    broker = something(broker, broker_url())
    token = github_token()
    cached_ctx = Ref{Union{Nothing,FarmLite.LiteCtx}}(nothing)
    expires = Ref(DateTime(0))
    return function ()
        if cached_ctx[] === nothing || expires[] <= Dates.now(UTC) + Dates.Minute(5)
            payload = fetch_broker_creds(broker, role, token)
            c, cfg = payload["credentials"], payload["config"]
            cached_ctx[] = FarmLite.LiteCtx(;
                region=cfg["region"],
                creds=FarmLite.AwsCreds(c["access_key_id"], c["secret_access_key"],
                                        c["session_token"]),
                queue_url=cfg["queue_url"], runs_table=cfg["runs_table"],
                jobs_table=cfg["jobs_table"], bucket=cfg["bucket"])
            expires[] = parse_expiration(c["expiration"])
        end
        return something(cached_ctx[])
    end
end
