# Compile a Lambda app's `src/main.jl` into a trimmed `bootstrap` executable.
#
#   julia --project=lite/juliac lite/juliac/compile.jl <app_dir> <exe> <trim> <cpu_target>
#
# Runs in its own environment so JuliaC's dependencies never mix with the app's.

using JuliaC

app_dir, exe, trim, cpu_target = ARGS
trim_mode = something(match(r"^--trim(?:=(.*))?$", trim))[1]

img = ImageRecipe(;
    output_type = "--output-exe",
    file = joinpath(app_dir, "src", "main.jl"),
    project = app_dir,
    trim_mode = something(trim_mode, "safe"),
    cpu_target,
)
compile_products(img)
# runtime libraries are bundled into an adjacent "julia/" folder
link_products(LinkRecipe(; image_recipe = img, outname = exe, rpath = "julia"))
