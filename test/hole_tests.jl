# Holes the producer declares (`DeclaredHole`) in replays of in-memory runs;
# included by runtests.jl after telemetry_tests.jl, whose reference scorers
# it uses.

@testset "Declared holes" begin
    fs = 0.2
    epoch = Dates.DateTime(2035, 1, 1)
    geometry = RunGeometry(fs, 50.0, 10, epoch, "test")
    n_batches = 80
    payload =
        synthesize_noise(StableRNG(73), n_batches * 100, fs; f_min = 1e-5, psd = noise_psd)
    conditioning = (
        sample_rate = fs,
        window_size = 1000,
        step_size = 100,
        psd = noise_psd,
        context_windows = 1,
    )
    t(k) = epoch + Dates.Second(600 * k)
    # A scheduled generation gap: batches 31–35 are never produced, so no
    # batch and no arrival exists for their rows 3001–3500, which the
    # producer declares when the gap ends
    gap = 31:35
    gap_rows = first(batch_rows(first(gap), 100)):last(batch_rows(last(gap), 100))
    events = [
        ArrivalEvent(t(k), "LIVE_batch_$k", :ingested, 0) for
        k in 1:n_batches if !(k in gap)
    ]
    hole = DeclaredHole(:scheduled, nothing, gap_rows, t(last(gap)))
    plain = MemoryTelemetryRun(geometry, payload, events)
    declared = MemoryTelemetryRun(geometry, payload, events; holes = [hole])

    @test declared_holes(declared) == [hole] && isempty(declared_holes(declared; after = 1))
    @test isempty(declared_holes(plain)) && record_final(plain)
    @test isempty(run_descriptor(plain))
    @test only(batch_records(plain, ["LIVE_batch_3", "LIVE_batch_999"])).rows ==
          batch_rows(3, 100)
    @test declared_holes(ScheduledRecordRun(declared, payload)) == [hole]
    @test hole_cause("Scheduled") == :scheduled && hole_cause(:recorder) == :recorder
    @test hole_cause("a cause of a later producer") == :other
    @test_throws ArgumentError DeclaredHole(:unknown, nothing, 1:10, epoch)
    @test_throws ArgumentError DeclaredHole(:lost, "LIVE_batch_1", 0:10, epoch)
    @test_throws ArgumentError GapEvent(1, 2, :pruned, epoch)

    stateless() = StreamingDetector(RMSScorer(), 1.0; conditioning...)
    base = replay_run(plain, stateless())
    # The windows whose conditioning stretch meets the gap are never
    # evaluable, declared or not: 12–45
    @test setdiff(1:maximum(base.window), base.window) == 12:45
    with_hole = replay_run(declared, stateless())
    @test with_hole.window == base.window && with_hole.score == base.score
    # An erosion of 100 s (20 rows) on each side of the declared rows removes
    # window 46, whose stretch begins on the first row after the gap; window
    # 11, whose stretch ends on the last row before it, was scored before the
    # gap was declared
    eroded = replay_run(declared, stateless(); tdi_gap_dilation_sec = 100.0)
    @test setdiff(base.window, eroded.window) == [46]
    @test 11 in eroded.window
    @test replay_run(plain, stateless(); tdi_gap_dilation_sec = 100.0).window == base.window

    # A stateful scorer is told of the gap with the producer's cause when the
    # producer declares it, not at the end of the record, so the windows
    # after it are released as they complete
    scorer = SequenceRMS()
    state = replay_state(declared, StreamingDetector(scorer, 1.0; conditioning...))
    gaps = gaps_table(state)
    @test gaps.cause == ["scheduled"]
    @test (gaps.first_window, gaps.last_window) == ([12], [45])
    @test gaps.declared_at == [t(last(gap))]
    @test scorer.gaps == [GapEvent(12, 45, :scheduled, t(last(gap)))]
    released = windows_table(state)
    @test released.window == base.window
    @test released.release_at == released.complete_at
    @test state.holes_consumed == 1
    undeclared = replay_state(plain, StreamingDetector(SequenceRMS(), 1.0; conditioning...))
    @test gaps_table(undeclared).cause == ["undelivered"]
    @test gaps_table(undeclared).declared_at == [last(events).sim_time]

    # The declaration of a lost or pruned batch is only counted: its arrival
    # event excludes it
    lost = DeclaredHole(:lost, "LIVE_batch_50", batch_rows(50, 100), t(50))
    probe = ReplayState(plain, stateless())
    @test isempty(process_hole!(probe, lost))
    @test probe.holes_consumed == 1 && isempty(probe.excluded)

    # Declarations out of time order are applied in time order
    later = DeclaredHole(:recorder, nothing, 6001:6200, t(70))
    unordered = MemoryTelemetryRun(geometry, payload, events; holes = [later, hole])
    state_unordered =
        replay_state(unordered, StreamingDetector(SequenceRMS(), 1.0; conditioning...))
    @test gaps_table(state_unordered).cause == ["scheduled", "recorder"]
    @test issorted(gaps_table(state_unordered).declared_at)

    # Live mode reaches the same windows and gaps as the replay
    follow_scorer = SequenceRMS()
    followed = follow_run(
        declared,
        StreamingDetector(follow_scorer, 1.0; conditioning...);
        poll_interval_sec = 0.01,
    )
    @test followed.window == released.window && followed.score == released.score
    @test follow_scorer.gaps == scorer.gaps
end
