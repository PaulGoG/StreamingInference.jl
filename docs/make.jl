include(joinpath(@__DIR__, "activate.jl"))

using Documenter
using StreamingInference

makedocs(
    sitename = "StreamingInference.jl",
    authors = "Paul-Adrian Gogîță",
    repo = Remotes.GitHub("PaulGoG", "StreamingInference.jl"),
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://PaulGoG.github.io/StreamingInference.jl",
        size_threshold_ignore = ["api.md"],
    ),
    modules = [StreamingInference],
    pages = [
        "Home" => "index.md",
        "Streaming replay" => "replay.md",
        "API reference" => "api.md",
    ],
)

# Deployment to the gh-pages branch: `main` under dev/, release tags under
# their version and stable/. Outside GitHub Actions this is a no-op.
deploydocs(
    repo = "github.com/PaulGoG/StreamingInference.jl.git",
    devbranch = "main",
    push_preview = false,
)
