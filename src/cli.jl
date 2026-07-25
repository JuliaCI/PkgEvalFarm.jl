# `bin/farm` command-line interface.

const CLI_HELP = """
    farm — distributed PkgEval orchestration

    usage: farm <command> [options]

    commands:
      login    [--broker URL]                     enroll this machine (GitHub device flow)
      worker   [--broker URL] [--ninstances N] [--once]
                                                  evaluate jobs from the queue
      submit   --primary SPEC [--against SPEC] [--assertions] [PKG...]
                                                  submit a run (all packages if none given)
      status   RUN_ID                             show run progress
      report   RUN_ID                             aggregate, upload and print the report
      bot      [--interval SECS] [--name NAME]    run the @nanosoldier2 bot

    The broker URL can also be set via PKGEVAL_FARM_BROKER. Julia SPECs are release
    names ("nightly", "v1.12.0") or repo specs ("JuliaLang/julia#0123abc").
    """

function main(args::Vector{String}=ARGS)
    isempty(args) && (println(CLI_HELP); return 0)
    command, rest... = args
    rest = collect(String, rest)

    # split --flag [value] options from positional arguments
    options = Dict{String,String}()
    positional = String[]
    flags = Set(["--once", "--assertions"])
    i = 1
    while i <= length(rest)
        arg = rest[i]
        if arg in flags
            options[arg] = "true"
        elseif startswith(arg, "--")
            i == length(rest) && error("missing value for $arg")
            options[arg] = rest[i+1]
            i += 1
        else
            push!(positional, arg)
        end
        i += 1
    end
    broker = get(options, "--broker", nothing)

    if command == "login"
        login(something(broker, broker_url()))
    elseif command == "worker"
        run_worker(; broker,
                   ninstances=parse(Int, get(options, "--ninstances", string(Sys.CPU_THREADS))),
                   once=haskey(options, "--once"))
    elseif command == "submit"
        haskey(options, "--primary") || error("submit requires --primary")
        buildflags = haskey(options, "--assertions") ?
            ["LLVM_ASSERTIONS=1", "FORCE_ASSERTIONS=1"] : String[]
        configs = build_configs(options["--primary"];
                                against=get(options, "--against", nothing), buildflags)
        ctx, user = farm_ctx(; broker, role="submitter")
        run_id = submit_run(ctx; configs, packages=positional, submitter=user)
        println(run_id)
    elseif command == "status"
        length(positional) == 1 || error("status requires exactly one RUN_ID")
        ctx, _ = farm_ctx(; broker, role="submitter")
        status = run_status(ctx, only(positional))
        println("run $(status.run_id): $(status.status), ",
                "$(status.completed)/$(status.total) jobs finished ",
                "(submitted by $(status.submitter) at $(status.created_at))")
    elseif command == "report"
        length(positional) == 1 || error("report requires exactly one RUN_ID")
        provider = lite_ctx_provider(; broker)
        report = FarmBot.generate_report(provider(), only(positional))
        println(report.markdown)
    elseif command == "bot"
        haskey(options, "--name") && (ENV["BOT_NAME"] = options["--name"])
        FarmBot.run_bot(lite_ctx_provider(; broker);
                        interval=parse(Int, get(options, "--interval", "60")))
    elseif command in ("help", "--help", "-h")
        println(CLI_HELP)
    else
        println(stderr, "unknown command: $command\n")
        println(stderr, CLI_HELP)
        return 1
    end
    return 0
end
