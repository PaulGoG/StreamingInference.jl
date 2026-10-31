# Provenance and I/O safety: stage timing, run identity, hardware and
# platform fingerprint, git and manifest snapshots, overwrite-safe writers,
# and the memory pre-flight of a stage.

"""
    TIMER

Package-wide `TimerOutput` accumulating the wall time and allocations of
every pipeline stage (`@timeit TIMER "stage" ...`); [`report_timing`](@ref)
prints its table.
"""
const TIMER = TimerOutput()

"""
    report_timing(io = stdout)

Print the stage-timing table of [`TIMER`](@ref).
"""
function report_timing(io::IO = stdout)
    println(io)
    print_timer(io, TIMER; sortby = :firstexec)
    println(io)
    return nothing
end

"""
    with_file_log(f, path)

Run `f()` with every log record of the global logger also written to the
file at `path` (created or truncated, flushed after each record); the
global logger is restored and the file closed when `f` returns or throws.
Returns the value of `f()`. The directory of `path` must exist.

# Example

```julia
result = with_file_log(joinpath(run_dir, "training.log")) do
    run_stage(config)
end
```
"""
function with_file_log(f, path::AbstractString)
    stream = open(path, "w")
    console = global_logger()
    global_logger(TeeLogger(console, FileLogger(stream; always_flush = true)))
    try
        return f()
    finally
        global_logger(console)
        flush(stream)
        close(stream)
    end
end

"""
    new_run_id() -> String

Eight-character run identifier drawn from a UUID.
"""
new_run_id() = string(uuid4())[1:8]

"""
    machine_id() -> String

Stable anonymous identifier of the host: the first twelve hexadecimal
characters of the SHA-256 digest of its name. Two runs on the same
machine share it and runs on different machines do not; the machine's
name, personal data in a published artifact, is not recoverable from it.
"""
machine_id() = bytes2hex(sha256(gethostname()))[1:12]

"""
    sanitized_versioninfo() -> String

`InteractiveUtils.versioninfo()` output with the user's home directory
replaced by `~`. The `Environment:` block echoes every `JULIA_*`
variable, several of which customarily hold paths under the home
directory and with it the account name.
"""
function sanitized_versioninfo()
    text = sprint(InteractiveUtils.versioninfo)
    home = homedir()
    return isempty(home) ? text : replace(text, home => "~")
end

"""
    hardware_fingerprint() -> Dict{String, Any}

Platform fingerprint recorded in run provenance snapshots: an anonymous
machine identifier ([`machine_id`](@ref)), OS kernel, CPU model and
logical core count, total memory, Julia version with the sanitised
`versioninfo()` output ([`sanitized_versioninfo`](@ref)), and
thread/worker counts (Julia threads, BLAS threads, `Distributed`
workers). The host's name never enters a snapshot. No GPU fields are
recorded.
"""
function hardware_fingerprint()
    cpu = Sys.cpu_info()
    return Dict{String,Any}(
        "machine_id" => machine_id(),
        "kernel" => string(Sys.KERNEL),
        "julia_version" => string(VERSION),
        "versioninfo" => sanitized_versioninfo(),
        "cpu_model" => isempty(cpu) ? "unknown" : first(cpu).model,
        "cpu_threads_logical" => Sys.CPU_THREADS,
        "total_memory_gib" => round(Sys.total_memory() / 2^30; digits = 2),
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "distributed_workers" => Distributed.nworkers(),
    )
end

"""
    root_package_version(root) -> String

Version declared in the `Project.toml` of the pipeline root `root`, or
`"unknown"`.
"""
function root_package_version(root::AbstractString)
    project = joinpath(root, "Project.toml")
    isfile(project) || return "unknown"
    return string(get(TOML.parsefile(project), "version", "unknown"))
end

"""
    git_provenance() -> Dict{String, Any}

Git description of the pipeline root ([`project_root`](@ref),
`DrWatson.gitdescribe`), whether the tree is dirty, the version of the
package at the root (`package_version`, from its `Project.toml`), and the
version of this package (`streaminference_version`); `"unknown"` for the
commit and `true` for the dirty flag when the tree's state cannot be
established (outside a git repository, or without git).
"""
function git_provenance()
    root = project_root()
    commit, dirty = git_state(root)
    return Dict{String,Any}(
        "git_commit" => commit,
        "git_dirty" => dirty,
        "package_version" => root_package_version(root),
        "streaminference_version" => string(pkgversion(@__MODULE__)),
    )
end

"""
    layer_provenance(manifest = active_manifest_path()) -> Vector{Dict{String, Any}}

The packages of the resolved environment that make up the pipeline: this
package and every package whose dependencies reach it, as the Manifest at
`manifest` records them. Each entry holds the `name` and `version` and,
according to how the package is tracked, its `tree_hash` (registered or
tracked by URL), `url` and `revision` (tracked by URL), or its `path` with
the `git_commit` and `git_dirty` state of that directory (tracked by path).
This package comes first, the others follow by name. Empty without a
Manifest on disk.

The git description of the pipeline root ([`git_provenance`](@ref)) covers
one repository; a pipeline assembled from several packages is attributed to
code only by the revision of each.
"""
function layer_provenance(manifest::Union{Nothing,AbstractString} = active_manifest_path())
    (manifest === nothing || !isfile(manifest)) && return Dict{String,Any}[]
    entries = get(TOML.parsefile(manifest), "deps", Dict{String,Any}())
    core = string(nameof(@__MODULE__))
    haskey(entries, core) || return Dict{String,Any}[]
    # `deps` is a list of names, or a table of names to UUIDs where a name is ambiguous
    dependencies(name) =
        let deps = get(first(entries[name]), "deps", String[])
            deps isa AbstractDict ? collect(keys(deps)) : deps
        end
    dependents = Set([core])
    grown = true
    while grown
        grown = false
        for name in keys(entries)
            name in dependents && continue
            if any(in(dependents), dependencies(name))
                push!(dependents, name)
                grown = true
            end
        end
    end
    names = vcat(core, sort!(collect(setdiff(dependents, [core]))))
    return [layer_record(name, first(entries[name]), dirname(manifest)) for name in names]
end

function layer_record(
    name::AbstractString,
    entry::AbstractDict,
    manifest_dir::AbstractString,
)
    record = Dict{String,Any}(
        "name" => String(name),
        "version" => string(get(entry, "version", "unknown")),
    )
    haskey(entry, "git-tree-sha1") && (record["tree_hash"] = entry["git-tree-sha1"])
    haskey(entry, "repo-url") && (record["url"] = entry["repo-url"])
    haskey(entry, "repo-rev") && (record["revision"] = entry["repo-rev"])
    if haskey(entry, "path")
        path = normdir(joinpath(manifest_dir, entry["path"]))
        record["path"] = provenance_path(path)
        commit, dirty = git_state(path)
        record["git_commit"] = commit
        record["git_dirty"] = dirty
    end
    return record
end

"""
    git_state(dir) -> (commit, dirty)

`DrWatson.gitdescribe` of the repository holding `dir` and whether its tree
is dirty; `"unknown"` and `true` when the state cannot be established
(outside a git repository, or without git).
"""
function git_state(dir::AbstractString)
    # DrWatson warns on a dirty tree at every call; the flag is recorded
    # explicitly instead.
    commit = try
        with_logger(NullLogger()) do
            something(DrWatson.gitdescribe(dir), "unknown")
        end
    catch e
        e isa InterruptException && rethrow()
        "unknown"
    end
    # A tree whose state cannot be established is not recorded as clean.
    dirty = commit == "unknown" ? true : try
        DrWatson.isdirty(dir)
    catch e
        e isa InterruptException && rethrow()
        true
    end
    return commit, dirty
end

"""
    active_manifest_path() -> Union{Nothing, String}

Path of the Manifest resolved for the active project, or `nothing` when the
active project has none on disk. Candidates are searched in the directory
of `Base.active_project()` in the order Julia itself applies: the
version-specific `Manifest-v<major>.<minor>.toml`, `JuliaManifest.toml`,
`Manifest.toml`.
"""
function active_manifest_path()
    project = Base.active_project()
    project === nothing && return nothing
    dir = dirname(project)
    candidates = (
        "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
        "JuliaManifest.toml",
        "Manifest.toml",
    )
    for name in candidates
        path = joinpath(dir, name)
        isfile(path) && return path
    end
    return nothing
end

"""
    manifest_sha256() -> String

SHA-256 digest (hexadecimal) of the active Manifest
([`active_manifest_path`](@ref)), or `"unknown"` when there is none. The
digest identifies the resolved dependency state of a run without carrying
the file into every record.
"""
function manifest_sha256()
    path = active_manifest_path()
    return path === nothing ? "unknown" : content_digest(path)
end

"""
    snapshot_manifest(dir) -> Union{Nothing, String}

Copy the active Manifest ([`active_manifest_path`](@ref)) to
`<dir>/manifest_snapshot.toml`, backing up an existing snapshot first
([`backup_existing!`](@ref)), and return the path written; `nothing`, with
a warning, when the active project has no Manifest. Manifests are not
tracked in the repository, so this copy is what pins the resolved
environment of a run.
"""
function snapshot_manifest(dir::AbstractString)
    source = active_manifest_path()
    if source === nothing
        @warn "no Manifest found for the active project; the resolved environment of this run is not recorded." active_project =
            Base.active_project()
        return nothing
    end
    target = joinpath(dir, "manifest_snapshot.toml")
    mkpath(dir)
    backup_existing!(target)
    cp(source, target)
    return String(target)
end

"""
    provenance() -> Dict{String, Any}

`hardware`, `git`, `layers`, and `environment` sections of a provenance
snapshot, plus the wall-clock time of writing. `layers` lists the packages
of the pipeline with their revisions ([`layer_provenance`](@ref));
`environment` names the active project and the digest of its Manifest
([`manifest_sha256`](@ref)).
"""
function provenance()
    return Dict{String,Any}(
        "hardware" => hardware_fingerprint(),
        "git" => git_provenance(),
        "layers" => layer_provenance(),
        "environment" => Dict{String,Any}(
            "active_project" =>
                provenance_path(something(Base.active_project(), "unknown")),
            "manifest_sha256" => manifest_sha256(),
        ),
        "written_at" => string(Dates.now()),
    )
end

"""
    content_digest(path) -> String

SHA-256 (hexadecimal) of the content of the file at `path`: the identity
of an input product whatever its location or modification time.
"""
content_digest(path::AbstractString) = bytes2hex(open(sha256, path))

"""
    parameter_digest(parameters) -> String

SHA-256 (hexadecimal) of the key-sorted TOML rendering of a parameter
dictionary: the identity of the parameters of a product, the same in
every process and on every machine (unlike `Base.hash`, which also differs
between Julia versions). It is as stable as the TOML rendering: a change
of the TOML printer would change it.
"""
function parameter_digest(parameters::AbstractDict)
    io = IOBuffer()
    TOML.print(io, parameters; sorted = true)
    return bytes2hex(sha256(take!(io)))
end

"""
    product_table(kind; channels, parents = Dict{String,Any}(), schema = 1) -> Dict{String,Any}

The `[product]` table of a sidecar: the `kind` of product (`"features"`,
`"labels"`, …), the `channels` it was made from (a channel-set token such
as `"A"`), the `schema` version of its tables, and the content digests
([`content_digest`](@ref)) of its `parents`, so that a product can be
traced to its inputs and refused when they do not match.
"""
function product_table(
    kind::AbstractString;
    channels::AbstractString,
    parents::AbstractDict = Dict{String,Any}(),
    schema::Integer = 1,
)
    schema >= 1 || throw(ArgumentError("schema must be at least 1."))
    return Dict{String,Any}(
        "kind" => String(kind),
        "channels" => String(channels),
        "schema" => Int(schema),
        "parents" => Dict{String,Any}(String(k) => v for (k, v) in parents),
    )
end

"""
    recorded_channels(table_path; default) -> String

The channel set a product was made from, as the sidecar of the table at
`table_path` records it ([`sidecar_path`](@ref)): `channels` of
its `[product]` table ([`product_table`](@ref)), else of `[features]`.
`default` is returned for a table without a sidecar or whose sidecar names
no channel set, as the products made before the channel sets were recorded.
"""
function recorded_channels(table_path::AbstractString; default::AbstractString)
    sidecar = sidecar_path(table_path)
    isfile(sidecar) || return String(default)
    tables = TOML.parsefile(sidecar)
    for name in ("product", "features")
        channels = get(get(tables, name, Dict{String,Any}()), "channels", nothing)
        channels isa AbstractString && return String(channels)
    end
    return String(default)
end

"""
    gapped_product(features_path) -> Bool

Whether a feature table is the product of a record with gaps: its sidecar
([`sidecar_path`](@ref)) lists the stretches between them, and its rows are
not consecutive windows of the record ([`window_indices`](@ref)). `false`
for a table without a sidecar.
"""
function gapped_product(features_path::AbstractString)
    sidecar = sidecar_path(features_path)
    isfile(sidecar) || return false
    return haskey(get(TOML.parsefile(sidecar), "features", Dict{String,Any}()), "stretches")
end

"""
    run_channels(model_dir; default) -> String

The channel set of the features a run was fitted on, from the `channels`
key of the `[features]` table of the configuration snapshot
`<model_dir>/config.toml`; `default` when the run directory has no
snapshot or the snapshot records no channel set, as for the runs made
before the channel sets were recorded ([`recorded_channels`](@ref) reads
the same of a product).
"""
function run_channels(model_dir::AbstractString; default::AbstractString)
    path = joinpath(model_dir, "config.toml")
    isfile(path) || return String(default)
    features = get(TOML.parsefile(path), "features", Dict{String,Any}())
    return String(get(features, "channels", default))
end

"""
    backup_existing!(path) -> Union{Nothing, String}

Move an existing file at `path` to `<stem>_#k<ext>` with the first free
`k ≥ 1` (the `safesave` convention of DrWatson), so that a new write at
`path` never destroys a previous result. Returns the backup path, or
`nothing` when there was nothing to move.
"""
function backup_existing!(path::AbstractString)
    isfile(path) || return nothing
    stem, ext = splitext(path)
    k = 1
    while isfile("$(stem)_#$(k)$(ext)")
        k += 1
    end
    backup = "$(stem)_#$(k)$(ext)"
    mv(path, backup)
    @info "existing file moved to a backup" path = path backup = backup
    return backup
end

"""
    write_toml(path, data; safe = true, tag = true)

Write the dictionary `data` as TOML at `path`, backing up an existing file
first ([`backup_existing!`](@ref)) when `safe`, and merging the
[`provenance`](@ref) sections when `tag`. With `tag`, a key of `data` that
names one of those sections (`hardware`, `git`, `layers`, `environment`,
`written_at`) is refused with an `ArgumentError`. Returns `path`.
"""
function write_toml(
    path::AbstractString,
    data::AbstractDict;
    safe::Bool = true,
    tag::Bool = true,
)
    payload = Dict{String,Any}(data)
    if tag
        sections = provenance()
        for key in keys(sections)
            haskey(payload, key) && throw(
                ArgumentError(
                    "write_toml: the key `$key` of the data names a provenance section; " *
                    "rename it or write with tag = false.",
                ),
            )
        end
        merge!(payload, sections)
    end
    safe && backup_existing!(path)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, payload)
    end
    return String(path)
end

"""
    TIMESTAMP_FORMAT

The text form of a `DateTime` column in every CSV product,
`yyyy-mm-ddTHH:MM:SS.s` (the seconds with one to three decimals, as in
`2035-03-19T16:27:30.0` and `2035-03-18T17:40:33.6`). CSV.jl 0.10 writes
this form by default and CSV.jl 1.x omits the decimal; stating it makes a
product written under either version identical byte for byte.
"""
const TIMESTAMP_FORMAT = Dates.dateformat"yyyy-mm-dd\THH:MM:SS.s"

"""
    write_csv(path, table; safe = true)

Write `table` with `CSV.write` at `path`, backing up an existing file first
when `safe`; `DateTime` columns are written in [`TIMESTAMP_FORMAT`](@ref).
Returns `path`.
"""
function write_csv(path::AbstractString, table; safe::Bool = true)
    safe && backup_existing!(path)
    mkpath(dirname(path))
    CSV.write(path, table; dateformat = TIMESTAMP_FORMAT)
    return String(path)
end

"""
    resource_settings(config) -> NamedTuple

Memory-safety thresholds of the `[resources]` section in GiB:
`max_memory_gib` (a stage whose estimate exceeds it refuses to start;
default half of the machine's memory) and `warn_memory_gib` (a warning;
default a quarter).
"""
function resource_settings(config::AbstractDict)
    r = section(config, "resources")
    total = Sys.total_memory() / 2^30
    max_gib = cfgget(
        r,
        "max_memory_gib",
        round(total / 2; digits = 2);
        type = Float64,
        min = 1e-3,
    )
    warn_gib = cfgget(
        r,
        "warn_memory_gib",
        round(total / 4; digits = 2);
        type = Float64,
        min = 0.0,
    )
    warn_gib <= max_gib || throw(
        ArgumentError("warn_memory_gib = $warn_gib exceeds max_memory_gib = $max_gib."),
    )
    return (max_memory_gib = max_gib, warn_memory_gib = warn_gib, total_memory_gib = total)
end

"""
    record_memory_estimate_gib(n_samples; copies = 6) -> Float64

Pre-flight estimate of the memory of processing a record of `n_samples`
double-precision samples through the high-pass, whitening, and windowing
chain, which holds about `copies` record-length arrays (time series, its
transform, and intermediates).
"""
function record_memory_estimate_gib(n_samples::Integer; copies::Integer = 6)
    n_samples >= 0 || throw(ArgumentError("n_samples must be non-negative."))
    return copies * n_samples * 8 / 2^30
end

"""
    check_memory(estimate_gib, resources; stage)

Enforce the `[resources]` thresholds on a pre-flight estimate: throw an
`ArgumentError` naming `stage` above `max_memory_gib`, warn above
`warn_memory_gib`, otherwise log the estimate. Returns `estimate_gib`.
"""
function check_memory(estimate_gib::Real, resources::NamedTuple; stage::AbstractString)
    if estimate_gib > resources.max_memory_gib
        throw(
            ArgumentError(
                "$stage needs an estimated $(round(estimate_gib; digits = 2)) GiB, above " *
                "[resources] max_memory_gib = $(resources.max_memory_gib) GiB; reduce the " *
                "configuration or raise the threshold.",
            ),
        )
    elseif estimate_gib > resources.warn_memory_gib
        @warn "$stage memory estimate above the warning threshold" estimate_gib =
            round(estimate_gib; digits = 2) warn_memory_gib = resources.warn_memory_gib
    else
        @info "$stage memory estimate" estimate_gib = round(estimate_gib; digits = 3)
    end
    return estimate_gib
end
