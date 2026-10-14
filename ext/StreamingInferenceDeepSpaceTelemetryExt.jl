# ext/StreamingInferenceDeepSpaceTelemetryExt.jl — a DeepSpaceTelemetry run
# directory as a run of the consumer, through the producer's reference run
# adapter (RunAdapter), which is versioned with the run-directory contract,
# so that a change of the contract surfaces as a version bump rather than as
# silent format drift. The consumer only reads.
module StreamingInferenceDeepSpaceTelemetryExt

using DeepSpaceTelemetry: DeepSpaceTelemetry
using DeepSpaceTelemetry.RunAdapter: RunAdapter
using CSV: CSV
using DataFrames: DataFrame
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
payload columns served and whether they are served as a matrix, whether
the producer stamps the payload row of each batch (2.1.0 and later), and
whether it writes the declared-hole feed (2.6.0 and later).
"""
struct DeepSpaceTelemetryRun <: AbstractTelemetryRun
    handle::RunAdapter.RunHandle
    geometry::RunGeometry
    columns::Vector{Int}
    as_matrix::Bool
    stamped::Bool
    hole_feed::Bool
end

"""
    producer_at_least(version, floor) -> Bool

Whether the recorded producer `version` is `floor` or later; false for a
run that records no version or an unparsable one.
"""
function producer_at_least(version::AbstractString, floor::VersionNumber)
    v = tryparse(VersionNumber, version)
    return v !== nothing && v >= floor
end

"""
    check_payload_alignment(run_dir, config, version)

Refuses an external-payload run of DeepSpaceTelemetry 2.0.1 or earlier
that holds a scheduled generation gap or an emitter restart. Those
producers read the payload sequentially: after a `SCHEDULED` gap the
content epoch jumps to the gap end while the payload resumes where it
stopped, and a restarted emitter reads it again from row 1, so every later
batch carries rows other than those of its content epoch. Fixed in
DeepSpaceTelemetry 2.1.0; a run of unknown version is treated as affected.
"""
function check_payload_alignment(run_dir::AbstractString, config::AbstractDict, version)
    physics = get(config, "physics", Dict{String,Any}())
    get(physics, "data_source", "synthetic") == "external" || return nothing
    producer_at_least(version, v"2.1.0") && return nothing
    first_affected = nothing
    tx = joinpath(run_dir, "events_tx.csv")
    if isfile(tx)
        table = CSV.read(tx, DataFrame; types = String)
        for row in eachrow(table)
            row.Batch in ("SCHEDULED", "STREAM") && row.Event == "gap_start" || continue
            first_affected = something(first_affected, row.SimTime)
            break
        end
    end
    components = joinpath(run_dir, "component_events.csv")
    if isfile(components)
        table = CSV.read(components, DataFrame; types = String)
        for row in eachrow(table)
            row.Component == "emitter" && row.Event == "restart" || continue
            first_affected =
                first_affected === nothing ? row.SimTime : min(first_affected, row.SimTime)
            break
        end
    end
    first_affected === nothing && return nothing
    throw(
        ArgumentError(
            "$run_dir is an external-payload run of DeepSpaceTelemetry $version with a " *
            "generation gap or an emitter restart (first at $first_affected); producers " *
            "up to 2.0.1 misplace the payload from that instant on. Regenerate the run " *
            "with DeepSpaceTelemetry 2.1.0 or later.",
        ),
    )
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
    producer_compat::AbstractString = "1.0",
    columns::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}} = nothing,
)
    isdir(run_dir) || throw(ArgumentError("run directory not found: $run_dir"))
    floor = tryparse(VersionNumber, producer_compat)
    floor === nothing &&
        throw(ArgumentError("producer_compat = $(repr(producer_compat)) is not a version."))
    handle = RunAdapter.open_run(String(run_dir); minimum_version = floor)
    g = RunAdapter.run_geometry(handle)
    version = g.package_version
    check_payload_alignment(handle.run_dir, handle.config, version)
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
        isempty(version) ? "unknown" : version;
        payload_rows = something(g.payload_rows, 0),
    )
    return DeepSpaceTelemetryRun(
        handle,
        geometry,
        indices,
        as_matrix,
        producer_at_least(version, v"2.1.0"),
        producer_at_least(version, v"2.6.0"),
    )
end

run_geometry(run::DeepSpaceTelemetryRun) = run.geometry
run_state(run::DeepSpaceTelemetryRun) = RunAdapter.run_state(run.handle)
record_final(run::DeepSpaceTelemetryRun) = RunAdapter.record_final(run.handle)

"""
    consumer_record(run, record::RunAdapter.BatchRecord) -> BatchRecord

The consumer's record of a batch. A producer from 2.1.0 stamps the payload
row of every batch, which must agree with its content epoch. Before, the
rows follow the content epoch: reconstructing them from the index is only
correct while the producer stores every batch it produces, and when its
recorder overflowed it discarded production and kept numbering what it
stored, so the index drifts behind the content.
"""
function consumer_record(run::DeepSpaceTelemetryRun, r::RunAdapter.BatchRecord)
    g = run.geometry
    P = g.points_per_batch
    epoch = ismissing(r.content_epoch) ? nothing : r.content_epoch
    rows = r.rows
    if run.stamped
        first(rows) >= 1 ||
            throw(ArgumentError("batch $(r.name) carries payload_row $(first(rows))."))
        epoch === nothing ||
            time_row(g, epoch) == first(rows) ||
            throw(
                ArgumentError(
                    "batch $(r.name) carries payload_row $(first(rows)) but content " *
                    "epoch $epoch, which is row $(time_row(g, epoch)).",
                ),
            )
    elseif epoch !== nothing
        row0 = time_row(g, epoch)
        if row0 >= 1
            rows = row0:(row0+P-1)
        else
            @warn "a batch is stamped before the mission epoch; falling back to its " *
                  "index for the payload rows." batch = r.name content_epoch = epoch
            rows = batch_rows(r.index, P)
        end
    end
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

# A live consumer resolves the batches its fresh arrivals name: one metadata
# read each where the producer stamps the payload row, a listing otherwise.
function batch_records(run::DeepSpaceTelemetryRun, names)
    wanted = unique(String.(collect(names)))
    run.stamped || return filter(b -> b.name in Set(wanted), list_batches(run))
    records = BatchRecord[]
    for name in wanted
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

# From 2.6.0 the producer's declared-hole feed; before, the holes its event
# logs declare (the generation gaps; the arrival feed carries the lost and
# pruned batches), each known from the end of the gap.
function declared_holes(run::DeepSpaceTelemetryRun; after::Integer = 0)
    holes = if run.hole_feed
        RunAdapter.declared_holes(run.handle; after = after)
    else
        tracked = filter(
            h -> !(h.cause in (:lost, :pruned)),
            RunAdapter.declare!(RunAdapter.GapTracker(run.handle)),
        )
        tracked[(max(after, 0)+1):end]
    end
    return [
        DeclaredHole(
            hole_cause(h.cause),
            ismissing(h.batch) ? nothing : h.batch,
            h.rows,
            coalesce(h.declared_at, h.content_end),
        ) for h in holes
    ]
end

function run_descriptor(run::DeepSpaceTelemetryRun)
    path = joinpath(run.handle.run_dir, "descriptor.toml")
    return isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
end

end # module
