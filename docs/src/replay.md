# Streaming replay

## Terms

The replay uses the vocabulary of a telemetry downlink. A *producer*
generates a record and delivers it to the ground; one execution of it is a
*run*. The record is a sampled series, one column per channel, whose
samples are the *payload rows*, numbered from 1. The producer cuts the
record into *segments* of `segment_duration_sec` and groups `batch_size`
consecutive segments into a *batch*, the unit of transfer; every batch
covers a contiguous range of payload rows ([`BatchRecord`](@ref)). Times
are *mission times*: payload row ``r`` lies at ``t_0 + (r - 1)/f_s``, where
the *epoch* ``t_0`` is `start_sim_time` of the [`RunGeometry`](@ref) and
``f_s`` the sampling rate ([`row_time`](@ref)).

A batch is *delivered*, or on the ground, from its `:ingested` arrival
event on ([`ArrivalEvent`](@ref)). A *lost* batch will never be
delivered; a *pruned* batch was delivered and its payload later removed. A
*declared hole* is a range of rows that the producer announces will never
be delivered ([`DeclaredHole`](@ref)). Its cause ([`HOLE_CAUSES`](@ref))
is a batch lost in transfer (`:lost`) or pruned after delivery
(`:pruned`); rows never produced, because a gap was scheduled
(`:scheduled`), the on-board recorder was full (`:recorder`) or the
producer's stream restarted (`:stream`); or, once the record has ended,
rows produced but not delivered (`:undelivered`) or never reached
(`:not_generated`). The cause `:other` stands for one this version does
not know.

The DeepSpaceTelemetry producer names a batch `LIVE_batch_<k>` when it was
generated during a contact with a ground station, and `ARCH_batch_<k>`
when it was generated outside one and held on board until a later
contact; `k` is the global batch index. The replay treats both alike.

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

[`ScheduledRecordRun`](@ref) applies the delivery of one run to the
content of a local record. Its batches, arrival events and holes are those
of the run, and every delivered batch is served from the rows it holds of
the record, a vector or a matrix with one column per channel. A producer
that carried one payload column thus supplies the arrival process of a
replay on several channels, on the assumption that the delivery of a batch
is common to the synchronous channels of its rows. With `check = true`,
the default, every batch served is compared with the batch the run
delivered: the first column of the record must hold the same samples in
single precision, or the batch is refused.

## DeepSpaceTelemetry runs

[DeepSpaceTelemetry.jl](https://github.com/PaulGoG/DeepSpaceTelemetry.jl)
simulates the telemetry downlink of a spacecraft: ground-station passes,
packet loss and retransmission, and an on-board recorder. It is not
registered and is added by URL,
`Pkg.add(url = "https://github.com/PaulGoG/DeepSpaceTelemetry.jl")`. With
DeepSpaceTelemetry 2.6 or later loaded, [`open_telemetry_run`](@ref) opens
one of its run directories read-only through the producer's reference run
adapter, which is versioned with its run-directory contract.

A run carries one or several named payload columns under one link
accounting: a batch is transferred, and lost, with all its columns.
[`telemetry_run_columns`](@ref) names the columns of a run, and the
keyword `columns` of `open_telemetry_run` selects those it serves. By
default it serves the only column; a name serves that column as a vector;
a vector of names serves those columns, in the order given, as the
channels of a matrix.

`open_telemetry_run` refuses

- a run directory that does not exist, or a `producer_compat` that is not
  a version number;
- a run written by a producer older than `producer_compat` (default
  `"1.0"`);
- an external-payload run of a producer up to 2.0.1 that holds a scheduled
  generation gap or an emitter restart, since those producers misplace the
  payload from that instant on;
- a run whose payload row 1 does not lie at the mission epoch (an initial
  downtime), since the consumer counts payload rows from the epoch;
- a column selection that is empty, names a column twice or names a column
  the run does not carry, and the default selection on a run that carries
  several columns.

The holes of a run are those of the producer's declared-hole feed from
version 2.6.0 on, and before it the generation gaps its event logs
declare, each known from the end of the gap; the run descriptor is its
`descriptor.toml`.

## Scheduling and conditioning

Replaying the feed ([`replay_run`](@ref)) maintains the delivered rows as
a set of disjoint intervals ([`Coverage`](@ref)), so the order of arrivals
does not matter. A lost or pruned batch is a permanent hole, which later
arrivals never fill, and so is every hole the producer declares — rows it
never produced or never delivered — from the instant of its declaration
([`process_hole!`](@ref)); arrivals and declarations are consumed in
mission-time order.

Each permanent hole is widened on both sides by `tdi_gap_dilation_sec`.
The widening is meant for a derived series in which one sample depends on
input samples up to that interval away, so that the samples next to a
hole are corrupted by it too: for LISA, the combinations of time-delay
interferometry (TDI), formed from measurements delayed by several light
travel times along the arms. The default 0 suits a series without such
memory. A window whose stretch reaches into that margin is not scored
once the hole is known; one that completed before it was declared has
been scored already.

A window is scored once, at the time of the arrival that completes its
conditioning stretch: its own rows widened by `context_windows` window
lengths on each side and cut to the record. The stretch must be delivered
to at least `min_coverage`, and the window's own rows entirely, so a hole
inside a window is never scored across ([`WindowScheduler`](@ref),
[`conditioning_rows`](@ref)). The delivered stretch is high-passed and,
when the detector has a noise power spectral density (PSD), whitened as a
whole, and the window is cut from it ([`condition_window`](@ref)). A
stretch of several channels is conditioned channel by channel, each
whitened by its own PSD, and the window is a matrix with one column per
channel. The first windows of a record, and any isolated window, are
scored on shorter context and are affected by the record edges.

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
the held windows by increasing index ([`OrderedCommit`](@ref)).

A run of windows that can never be scored, because a lost batch or a
declared hole lies in its own rows or in more of its stretch than
`min_coverage` admits, is declared by one [`GapEvent`](@ref), which is
passed to the estimator ([`estimator_gap!`](@ref)) before the window after
it. Its cause is `:lost` for a lost or pruned batch, and the producer's
cause for a declared hole (`:scheduled`, `:recorder`, `:stream`,
`:undelivered`, `:not_generated`).

A missing window holds back every later one. At the end of the feed the
windows still missing are declared `:undelivered`. During a replay,
`order_horizon`, a time period, bounds the wait: once a later window has
been held for longer than it, the windows missing before it are declared
`:horizon`. A window that becomes evaluable after its gap was declared is
late; `late_policy` decides what happens to it: `:skip`, the default,
skips it and counts it, and `:error` refuses it with an `ArgumentError`.

Every scored row then records `release_at` beside `complete_at`, and
alerts are timed by it ([`scored_at`](@ref)). [`replay_state`](@ref)
returns the finalised replay, from which [`windows_table`](@ref) and
[`gaps_table`](@ref) are read.

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

[`alert_latency_table`](@ref) turns the windows of a replay into alerts,
one row per event of an event table. The table gives the event time in
the column `merger_time_s` (or `t_c_sec`), in seconds after the mission
epoch; its label spans in the payload rows `label_start_index` and
`label_end_index`; the signal onset `signal_start_index`, required with
label spans under `crediting = :signal`; and the names of the events in a
column `label` or `event`. The *credited span* of an event runs from
`signal_start_index` to `label_end_index` under `crediting = :signal`,
the default, and over the whole label span under `crediting = :label`. A
table without label spans credits the windows that contain the event
time.

An alert is a run of ``p`` consecutive alarmed windows, where ``p`` is the
persistence (`persistence`); the windows are consecutive in window index,
whatever order they reached the ground in. The alert is raised by the
arrival that completes the run, and it is credited to an event when one
of its windows overlaps the event's credited span. A run of at least
``p`` alarmed windows outside every credited span counts as one
false-alarm episode.

Windows of ``W`` samples advanced by ``S`` overlap: every sample lies in
``κ = \lfloor W/S \rfloor`` consecutive windows ([`window_overlap`](@ref)),
so a transient shorter than a step can alarm ``κ`` consecutive windows and
raise an alert at any persistence up to ``κ``. A persistence ``p`` delays
the alert by ``p - 1`` steps after the first alarmed window, that is by
``(p - 1) S / f_s`` of data at the sampling rate ``f_s``, and a
persistence above ``κ`` requires alarms on windows that share no sample.
The table therefore offers a second tier: with `confirmation_persistence`
above both ``κ`` and ``p``, an alert is confirmed by the arrival that
completes that many consecutive alarmed windows touching the span, and
confirmations are counted and timed beside the alerts (`confirmed`,
`t_confirmation`, `confirmation_latency_data_h`,
`false_confirmations_per_30d`). The preliminary alert keeps its latency;
the confirmation rests on the duration of the excess.

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
