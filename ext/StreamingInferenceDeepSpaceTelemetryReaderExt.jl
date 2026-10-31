# ext/StreamingInferenceDeepSpaceTelemetryReaderExt.jl — a DeepSpaceTelemetry
# run directory as a run of the consumer, through the producer's reference
# run adapter (RunAdapter of DeepSpaceTelemetryReader, the reader package of
# DeepSpaceTelemetry), which is versioned with the run-directory contract,
# so that a change of the contract changes its version. The consumer only
# reads.
module StreamingInferenceDeepSpaceTelemetryReaderExt

using DeepSpaceTelemetryReader: RunAdapter
using TOML: TOML
using StreamingInference:
    AbstractTelemetryRun,
    RunGeometry,
    BatchRecord,
    ArrivalEvent,
    DeclaredHole,
    parse_batch_name,
    batch_rows,
    time_row,
    row_time,
    event_symbol,
    hole_cause
import StreamingInference:
    open_telemetry_run,
    telemetry_run_columns,
    run_geometry,
    list_batches,
    batch_records,
    read_batch,
    arrival_events,
    run_state,
    record_final,
    declared_holes,
    run_descriptor

"""
    DeepSpaceTelemetryRun

A DeepSpaceTelemetry run directory opened read-only: the producer's run
handle, the [`RunGeometry`](@ref) of the consumer, the indices of the
payload columns served and whether they are served as a matrix.
"""
struct DeepSpaceTelemetryRun <: AbstractTelemetryRun
    handle::RunAdapter.RunHandle
    geometry::RunGeometry
    columns::Vector{Int}
    as_matrix::Bool
end

"""
    select_columns(names, columns, run_dir) -> (indices, as_matrix)

The payload columns of a run with the column `names` that `columns`
selects: `nothing` the only one, a name that column as a vector, a vector
of names those columns, in that order, as a matrix.
"""
function select_columns(names::AbstractVector{<:AbstractString}, columns, run_dir)
    if columns === nothing
        length(names) == 1 && return [1], false
        throw(
            ArgumentError(
                "$run_dir carries the payload columns $(join(names, ", ")); name the " *
                "columns to serve (`columns`).",
            ),
        )
    end
    wanted = columns isa AbstractString ? [String(columns)] : String.(collect(columns))
    isempty(wanted) && throw(ArgumentError("no payload column requested of $run_dir."))
    allunique(wanted) || throw(
        ArgumentError("payload columns requested more than once: $(join(wanted, ", "))."),
    )
    indices = map(wanted) do c
        j = findfirst(==(c), names)
        j === nothing && throw(
            ArgumentError(
                "$run_dir carries no payload column $(repr(c)) (columns: $(join(names, ", "))).",
            ),
        )
        j
    end
    return indices, !(columns isa AbstractString)
end

function open_telemetry_run(
    run_dir::AbstractString;
    producer_compat::AbstractString = "2.6",
    columns::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}} = nothing,
)
    isdir(run_dir) || throw(ArgumentError("run directory not found: $run_dir"))
    requested = tryparse(VersionNumber, producer_compat)
    requested === nothing &&
        throw(ArgumentError("producer_compat = $(repr(producer_compat)) is not a version."))
    # The adapter reads the declared-hole feed and the payload-row stamps,
    # which producers before 2.6.0 lack: its own floor binds below it.
    floor = max(requested, RunAdapter.MINIMUM_PRODUCER_VERSION)
    handle = RunAdapter.open_run(String(run_dir); minimum_version = floor)
    g = RunAdapter.run_geometry(handle)
    # Rows are counted from the mission epoch, as the payload export writes
    # them; a producer that anchors payload row 1 elsewhere (an initial
    # downtime) would shift every row against the event tables.
    g.payload_origin == g.start_sim_time || throw(
        ArgumentError(
            "payload row 1 of $run_dir lies at $(g.payload_origin), not at the mission " *
            "epoch $(g.start_sim_time) (initial downtime); the consumer counts payload " *
            "rows from the mission epoch.",
        ),
    )
    indices, as_matrix = select_columns(g.columns, columns, run_dir)
    # The producer zero-pads its stream beyond an external payload; windows
    # beyond its rows are not scored.
    geometry = RunGeometry(
        g.sample_rate,
        g.segment_duration_sec,
        g.batch_size,
        g.start_sim_time,
        isempty(g.package_version) ? "unknown" : g.package_version;
        payload_rows = something(g.payload_rows, 0),
    )
    return DeepSpaceTelemetryRun(handle, geometry, indices, as_matrix)
end

# The names only: no version floor, since nothing of the run is served
function telemetry_run_columns(run_dir::AbstractString)
    isdir(run_dir) || throw(ArgumentError("run directory not found: $run_dir"))
    handle = RunAdapter.open_run(String(run_dir); minimum_version = v"0.0.0-")
    return copy(RunAdapter.run_geometry(handle).columns)
end

run_geometry(run::DeepSpaceTelemetryRun) = run.geometry
run_state(run::DeepSpaceTelemetryRun) = RunAdapter.run_state(run.handle)
record_final(run::DeepSpaceTelemetryRun) = RunAdapter.record_final(run.handle)

"""
    consumer_record(run, record::RunAdapter.BatchRecord) -> BatchRecord

The consumer's record of a batch: the payload rows the producer stamps on
it, which must agree with its content epoch.
"""
function consumer_record(run::DeepSpaceTelemetryRun, r::RunAdapter.BatchRecord)
    g = run.geometry
    rows = r.rows
    first(rows) >= 1 ||
        throw(ArgumentError("batch $(r.name) carries payload_row $(first(rows))."))
    epoch = ismissing(r.content_epoch) ? nothing : r.content_epoch
    epoch === nothing ||
        time_row(g, epoch) == first(rows) ||
        throw(
            ArgumentError(
                "batch $(r.name) carries payload_row $(first(rows)) but content " *
                "epoch $epoch, which is row $(time_row(g, epoch)).",
            ),
        )
    return BatchRecord(
        r.name,
        r.index,
        r.live,
        rows,
        something(epoch, row_time(g, first(rows))),
        r.state,
    )
end

function list_batches(run::DeepSpaceTelemetryRun)
    records = [consumer_record(run, r) for r in RunAdapter.list_batches(run.handle)]
    # A stored index that has fallen behind the content means the producer
    # discarded production: the record then has permanent gaps that no
    # arrival will fill, which the coverage handles; the drift is reported.
    P = run.geometry.points_per_batch
    drifted = count(r -> first(r.rows) != first(batch_rows(r.index, P)), records)
    drifted == 0 || @warn "the producer discarded production: the stored batch index " *
          "no longer tracks the payload rows, so the record carries permanent gaps." batches_affected =
        drifted total_batches = length(records)
    return records
end

# A live consumer resolves the batches its fresh arrivals name, one metadata
# read each.
function batch_records(run::DeepSpaceTelemetryRun, names)
    records = BatchRecord[]
    for name in unique(String.(collect(names)))
        parsed = try
            parse_batch_name(name)
        catch e
            e isa ArgumentError || rethrow()
            continue      # not a batch of the producer
        end
        k, live = parsed
        ground = joinpath(run.handle.run_dir, "ground", name)
        lost = joinpath(run.handle.run_dir, "lost", name)
        stage, state =
            isdir(ground) ?
            ("ground", isfile(joinpath(ground, "PRUNED")) ? :pruned : :ground) :
            isdir(lost) ? ("lost", :lost) : (nothing, :lost)
        stage === nothing && continue
        rows = RunAdapter.batch_rows(run.handle, stage, name)
        push!(
            records,
            BatchRecord(name, k, live, rows, row_time(run.geometry, first(rows)), state),
        )
    end
    return records
end

function read_batch(run::DeepSpaceTelemetryRun, name::AbstractString)
    isdir(joinpath(run.handle.run_dir, "ground", name)) ||
        throw(ArgumentError("batch $name is not on the ground of $(run.handle.run_dir)."))
    data = RunAdapter.read_batch_matrix(run.handle, String(name))
    return run.as_matrix ? data[:, run.columns] : data[:, only(run.columns)]
end

function arrival_events(run::DeepSpaceTelemetryRun)
    events = [
        ArrivalEvent(e.sim_time, e.batch, event_symbol(String(e.event)), e.attempt) for
        e in RunAdapter.arrival_events(run.handle)
    ]
    sort!(events; by = e -> e.sim_time, alg = Base.Sort.MergeSort)   # stable
    return events
end

# The producer's declared-hole feed, each hole known from the instant it
# was declared
function declared_holes(run::DeepSpaceTelemetryRun; after::Integer = 0)
    return [
        DeclaredHole(
            hole_cause(h.cause),
            ismissing(h.batch) ? nothing : h.batch,
            h.rows,
            coalesce(h.declared_at, h.content_end),
        ) for h in RunAdapter.declared_holes(run.handle; after = after)
    ]
end

function run_descriptor(run::DeepSpaceTelemetryRun)
    path = joinpath(run.handle.run_dir, "descriptor.toml")
    return isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
end

end # module
