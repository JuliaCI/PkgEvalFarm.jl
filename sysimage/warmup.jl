# Run while building the sysimage, purely to force compilation. Nothing here
# talks to AWS; anything that throws is fine as long as it compiled on the way.
using PkgEvalFarm
using PkgEvalFarm: JobRef, JobResult, FarmConfig, RunSpec,
                   config_to_dict, config_from_dict, json_message, job_key, split_job_key,
                   ddb_item, ddb_unwrap, new_run_id, log_key, report_key, cli_main,
                   error_line
import PkgEval
import JSON

cfg = PkgEval.Configuration(; name="primary", julia="v1.12.0")
roundtripped = config_from_dict(config_to_dict(cfg))
RunSpec([roundtripped], ["Example"], Dict{String,Any}("source" => "warmup"))

job = JobRef(new_run_id(), "primary", "Example")
JSON.parse(json_message(job))
JobRef(Dict("run_id" => job.run_id, "config" => job.config, "package" => job.package))
split_job_key(job_key(job))
log_key(job.run_id, job.config, job.package)
report_key(job.run_id, "index.html")
JobResult(; status="test", duration=1.0)
error_line("\e[31mERROR: MethodError: no method matching f()\e[0m\n")

for (k, v) in ddb_item(Dict("s" => "x", "n" => 3, "f" => 1.5, "b" => true,
                            "l" => ["a"], "m" => Dict("k" => "v"), "nul" => nothing))
    ddb_unwrap(v)
end

FarmConfig(Dict("region" => "us-east-1", "queue_url" => "q", "runs_table" => "r",
                "jobs_table" => "j", "bucket" => "b"))

cli_main(String[])   # prints usage; compiles the argument parser
