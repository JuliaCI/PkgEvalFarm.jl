# Build the buildreq Lambda bundle: a juliac-compiled `bootstrap` executable plus the
# Julia runtime libraries it needs, zipped up for the `provided.al2023` runtime.
#
#   julia +1.13 --project=buildreq buildreq/build/build.jl [--trim=safe]
#
# produces buildreq/build/bootstrap.zip, which terraform deploys. Use Julia 1.13:
# 1.12's Downloads stdlib does not pass the `--trim=safe` verifier.

include(joinpath(dirname(@__DIR__), "..", "lite", "juliac-build.jl"))
build_lambda_bundle(dirname(@__DIR__))
