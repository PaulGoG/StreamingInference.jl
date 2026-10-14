# Streaming replay

## Run interface

A run is anything that implements the interface of
[`AbstractTelemetryRun`](@ref): its geometry ([`run_geometry`](@ref):
sampling rate, segment length, segments per batch, samples per batch,
epoch, producer version), its batches ([`list_batches`](@ref): delivered,
lost or pruned, each with the payload rows it covers), the samples of a
delivered batch ([`read_batch`](@ref)), the arrival feed in time order
([`arrival_events`](@ref)), and the lifecycle state ([`run_state`](@ref)).
A producer that says more implements four further functions, whose
defaults serve one that does not: whether the record is final while the
run still writes derived products ([`record_final`](@ref)), the holes of
the record it declares with their causes ([`declared_holes`](@ref),
[`DeclaredHole`](@ref)), the records of named batches without a full
listing ([`batch_records`](@ref)), and its own identity of the run
([`run_descriptor`](@ref)). [`MemoryTelemetryRun`](@ref) holds a whole
record in memory; an adapter over a producer's run directory implements
the same functions.

## DeepSpaceTelemetry runs

With [DeepSpaceTelemetry](https://github.com/PaulGoG/DeepSpaceTelemetry.jl)
2.6 or later loaded, [`open_telemetry_run`](@ref) opens one of its run
directories through the producer's reference run adapter, which is
versioned with its run-directory contract. The opening refuses a producer
older than `producer_compat`, an external-payload run of a producer up to
2.0.1 that holds a generation gap or an emitter restart (those producers
misplace the payload after it), and a run whose payload row 1 does not lie
at the mission epoch. A run carries one or several named payload columns
under one link accounting; `columns` selects them: the only column by
default, one column by name as a vector, or several names as the channels
of a matrix, in the order given; [`telemetry_run_columns`](@ref) names
the columns a run carries. The holes are those of the producer's
declared-hole feed from 2.6.0 on, and before it the generation gaps its
event logs declare, each known from the end of the gap; the run
descriptor is its `descriptor.toml`.

## Scheduling and conditioning

Replaying the feed ([`replay_run`](@ref)) maintains the delivered rows as
a set of disjoint intervals ([`Coverage`](@ref)), so the order of arrivals
does not matter. A lost or pruned batch is a permanent hole, which later
arrivals never fill, and so is every hole the producer declares — rows it
never produced or never delivered — from the instant of its declaration
([`process_hole!`](@ref)); arrivals and declarations are consumed in
mission-time order. Each permanent hole is widened on both sides by
`tdi_gap_dilation_sec`. A window whose stretch reaches into that margin is
not scored once the hole is known; one that completed before it was
declared has been scored already.

A window is scored once, at the time of the arrival that completes its
conditioning stretch: its own rows widened by `context_windows` window
lengths on each side and cut to the record. The stretch must be delivered
to at least `min_coverage`, and the window's own rows entirely, so a hole
inside a window is never scored across ([`WindowScheduler`](@ref),
[`conditioning_rows`](@ref)). The delivered stretch is high-passed and,
when the detector has a PSD, whitened as a whole, and the window is cut
from it ([`condition_window`](@ref)). The first windows of a record, and
any isolated window, are scored on shorter context and are affected by
the record edges.

## Estimators and ordered release

The detector owns the conditioning; the method applied to each
conditioned window is an estimator ([`AbstractWindowEstimator`](@ref)). A
detector needs a scalar one ([`AbstractWindowScorer`](@ref), implementing
[`window_score`](@ref)).

An estimator declares its memory ([`estimator_memory`](@ref)). A
[`Stateless`](@ref) one is scored as each window completes, in arrival
order, which after an outage or a retransmission is not content order. A
[`Stateful`](@ref) one (a reservoir, a sequential posterior) must see the
windows in content order, each once, with every hole declared. For it the
replay conditions each window when it completes, holds it, and releases
the held windows by increasing index ([`OrderedCommit`](@ref)). A run of
windows that can never be scored, because a lost batch or a declared hole
lies in its own rows or in more of its stretch than `min_coverage` admits,
is declared by one [`GapEvent`](@ref) (cause `:lost`, or the producer's
cause of the hole: `:scheduled`, `:recorder`, `:stream`, `:undelivered`,
`:not_generated`) passed to the estimator ([`estimator_gap!`](@ref))
before the window after it. A missing window
holds back every later one; at the end of the feed the missing windows
are declared `:undelivered`, and an `order_horizon` bounds the wait
during a replay (`:horizon`), after which a window that completes is late
and is skipped and counted, or refused (`late_policy`). Every scored row
then records `release_at` beside `complete_at`, and alerts are timed by
it ([`scored_at`](@ref)). [`replay_state`](@ref) returns the finalised
replay, from which [`windows_table`](@ref) and [`gaps_table`](@ref) are
read.

In live mode ([`follow_run`](@ref)) the consumer polls the arrival feed
and the declared holes, resolves only the batches that fresh arrivals
name, and stops once the producer reports the record final and both
feeds are drained; the windows and gaps are those of the replay of the
finished run.

## Causal whitening

With `trailing_psd` set to a [`TrailingWelch`](@ref), every window is
whitened by a Welch estimate of the delivered record behind it instead of
a fixed PSD: nothing that has not reached the ground enters the estimate.
The segments of all delivered runs in the trailing span are pooled, so no
segment crosses a hole, and the estimate is refreshed as the record grows.

## Thresholds and alerts

[`select_threshold`](@ref) fixes the decision threshold on a calibration
block, by a target rate of false-alarm episodes (`"far"`), a window
false-positive rate (`"fpr"`) or Youden's index (`"youden"`), and
[`threshold_sweep`](@ref) tabulates the operating characteristic.
[`alert_latency_table`](@ref) turns the windows of a replay into alerts:
an alert is a run of `persistence` consecutive alarmed windows, raised by
the arrival that completes it; it is credited to an event when it
overlaps the event's credited span, and every other alert counts as a
false-alarm episode.

## Pipeline root and provenance

Relative paths of a configuration resolve against the pipeline root
([`project_root`](@ref)): the root set by [`with_pipeline_root`](@ref), the
environment variable `STREAMINGINFERENCE_ROOT`, or the nearest directory
above the active environment whose `Project.toml` declares a package.
[`config_root`](@ref) derives the root from the location of a configuration
file. Run provenance records the git state of that root, the packages of
the pipeline with their revisions ([`layer_provenance`](@ref)), the hardware
and the resolved environment ([`provenance`](@ref)); data products are
identified by SHA-256 digests of their parameters and inputs
([`parameter_digest`](@ref), [`content_digest`](@ref),
[`product_table`](@ref)).
