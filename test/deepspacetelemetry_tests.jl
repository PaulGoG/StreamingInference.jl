# The DeepSpaceTelemetry extension: missions of the producer on its tick
# clock over a synthetic external payload, replayed and followed through the
# reference run adapter, and run directories derived from a real
# configuration snapshot for the producer versions and geometries the
# extension must refuse or serve. Included by runtests.jl after
# telemetry_tests.jl, whose reference scorers it uses.

const TelemetryCore = DeepSpaceTelemetry.TelemetryCore

"""
A mission of `days` on the tick clock over the external payload at
`payload_path`, run under `dir`; returns the run directory.
"""
function tick_mission(
    dir,
    run_id,
    payload_path;
    epoch,
    fs = 0.2,
    days = 1.0,
    columns = nothing,
    disruption = nothing,
)
    physics = Dict{String,Any}(
        "data_source" => "external",
        "external_data_path" => payload_path,
        "sample_rate" => fs,
        "segment_duration_sec" => 50.0,
        "batch_size" => 10,
    )
    columns === nothing || (physics["external_data_columns"] = columns)
    scenario = Dict{String,Any}(
        "simulation" => Dict{String,Any}(
            "speed_up" => 3600.0,
            "start_sim_time" => Dates.format(epoch, "yyyy-mm-ddTHH:MM:SS"),
            "mission_wall_seconds" => days * 86400 / 3600,
            "initial_downtime_days" => 0.0,
            "rng_seed" => 7,
        ),
        "storage" => Dict{String,Any}("max_storage_gb" => 2.0),
        "supervision" => Dict{String,Any}("on_component_failure" => "abort"),
        "telemetry" => Dict{String,Any}(
            "session_start" => "00:00:00",
            "session_duration_hours" => 24.0,
            "bandwidth_profile" => "flat",
            "max_batches_per_hour" => 200.0,
        ),
        "physics" => physics,
        "packet_loss" => Dict{String,Any}("enabled" => false),
        "dashboard" => Dict{String,Any}(
            "open_live_viewer" => false,
            "open_receiver_log" => false,
            "open_emitter_log" => false,
        ),
        "post_processing" => Dict{String,Any}(
            "generate_mask_timeline" => false,
            "expand_to_pointwise_masks" => false,
            "alert_latency" => false,
            "delivery_delay" => false,
            "hdf5_export" => false,
        ),
    )
    disruption === nothing || (scenario["disruption"] = disruption)
    path = joinpath(dir, "$run_id.toml")
    open(io -> TOML.print(io, scenario), path, "w")
    cfg = TelemetryCore.tick_configuration(TelemetryCore.load_config(path))
    previous = TelemetryCore.DATA_ROOT[]
    TelemetryCore.DATA_ROOT[] = joinpath(dir, "producer")
    try
        return DeepSpaceTelemetry.Supervisor.run_mission(
            cfg;
            run_id = run_id,
            orig_stdout = devnull,
        )
    finally
        TelemetryCore.DATA_ROOT[] = previous
    end
end

@testset "DeepSpaceTelemetry runs" begin
    fs = 0.2
    n_rows = 17_280                       # one mission day at 0.2 Hz
    epoch = Dates.DateTime(2035, 1, 1, 6)
    payload = synthesize_noise(StableRNG(41), n_rows, fs; f_min = 1e-5, psd = noise_psd)
    burst = 9001:10000
    payload[burst] .+= 3e-19 .* sin.(2π * 5e-3 .* (0:999) ./ fs)
    second = synthesize_noise(StableRNG(42), n_rows, fs; f_min = 1e-5, psd = noise_psd)
    conditioning = (
        sample_rate = fs,
        window_size = 1000,
        step_size = 100,
        psd = noise_psd,
        context_windows = 2,
    )
    mktempdir() do dir
        payload_path = joinpath(dir, "payload.csv")
        CSV.write(payload_path, DataFrame(Amplitude = Float32.(payload)))
        run_dir = tick_mission(dir, "coupling", payload_path; epoch = epoch)
        @test isfile(joinpath(run_dir, "RUN_COMPLETE"))

        run = open_telemetry_run(run_dir; producer_compat = "2.6")
        geometry = run_geometry(run)
        @test geometry.sample_rate == fs && geometry.points_per_batch == 100
        @test geometry.start_sim_time == epoch && geometry.payload_rows == n_rows
        @test VersionNumber(geometry.package_version) >= v"2.6.0"
        @test run_state(run) == :complete && record_final(run)
        descriptor = run_descriptor(run)
        @test descriptor["schema"] == "deepspacetelemetry-run/1"
        @test descriptor["mode"] == "tick" && descriptor["run_id"] == "coupling"
        # The identity of the producer's code (2.6.1 and later), recorded also
        # for a copy installed by commit, as this environment pins it
        @test occursin(r"^[0-9a-f]{40}$", descriptor["git_commit"])
        @test occursin(r"^[0-9a-f]{40}$", descriptor["git_tree_sha1"])
        @test descriptor["git_dirty"] == false
        batches = list_batches(run)
        @test !isempty(batches) && issorted([b.index for b in batches])
        delivered = filter(b -> b.state == :ground, batches)
        first_batch = delivered[1]
        @test read_batch(run, first_batch.name) == Float32.(payload[first_batch.rows])
        @test batch_records(run, [first_batch.name, "LIVE_batch_999999"]) == [first_batch]
        events = arrival_events(run)
        @test !isempty(events) && issorted([e.sim_time for e in events])
        @test count(e -> e.event == :ingested, events) == length(delivered)
        @test all(h -> h.cause in HOLE_CAUSES, declared_holes(run))
        @test_throws ArgumentError open_telemetry_run(run_dir; producer_compat = "99.0")
        @test_throws ArgumentError open_telemetry_run(run_dir; producer_compat = "two")
        @test_throws ArgumentError open_telemetry_run(joinpath(dir, "absent"))
        # The single column by name serves the same payload; another name is
        # refused
        @test read_batch(
            open_telemetry_run(run_dir; columns = "Amplitude"),
            first_batch.name,
        ) == read_batch(run, first_batch.name)
        @test_throws ArgumentError open_telemetry_run(run_dir; columns = "A")

        detector = StreamingDetector(RMSScorer(), 1.0; conditioning...)
        windows = replay_run(run, detector)
        @test nrow(windows) >= 1 && all(windows.coverage .== 1.0)
        @test all(windows.complete_at .>= windows.content_end) &&
              issorted(windows.complete_at)
        # The score of a window equals a direct evaluation on the stretch that
        # was on the ground when it completed
        w = windows[1, :]
        arrived = Coverage()
        for e in events
            e.event == :ingested && e.sim_time <= w.complete_at || continue
            add!(arrived, only(b.rows for b in batches if b.name == e.batch))
        end
        span = covered_stretch(arrived, w.row_start:w.row_end)
        lo = max(first(span), w.row_start - 2000)
        hi = min(last(span), w.row_end + 2000)
        @test isapprox(
            windows.score[1],
            score_window(detector, Float32.(payload[lo:hi]), w.row_start - lo + 1);
            atol = 1e-6,
        )
        # Followed after the end of the run, the record is final at once and
        # the live consumer reaches the windows of the replay
        followed = follow_run(run, detector; poll_interval_sec = 0.01)
        @test followed.window == windows.window && followed.score == windows.score

        # The delivery of this one-column mission applied to a record of two
        # channels whose first is the payload it carried
        pair_detector = StreamingDetector(
            ColumnRMS(1),
            1.0;
            conditioning...,
            psd = (noise_psd, noise_psd),
        )
        scheduled = ScheduledRecordRun(run, hcat(payload, second))
        @test replay_run(scheduled, pair_detector).score == windows.score
        @test_throws ArgumentError read_batch(
            ScheduledRecordRun(run, hcat(second, payload)),
            first_batch.name,
        )

        # The same mission with both channels as payload columns of the
        # producer: one batch, one transfer for the pair
        pair_path = joinpath(dir, "pair.csv")
        CSV.write(pair_path, DataFrame(A = Float32.(payload), E = Float32.(second)))
        pair_dir = tick_mission(dir, "pair", pair_path; epoch = epoch, columns = ["A", "E"])
        @test_throws ArgumentError open_telemetry_run(pair_dir)
        @test telemetry_run_columns(pair_dir) == ["A", "E"]
        @test telemetry_run_columns(run_dir) == ["Amplitude"]
        @test_throws ArgumentError telemetry_run_columns(joinpath(dir, "absent"))
        @test_throws ArgumentError open_telemetry_run(pair_dir; columns = ["A", "A"])
        @test_throws ArgumentError open_telemetry_run(pair_dir; columns = ["A", "T"])
        pair_run = open_telemetry_run(pair_dir; columns = ["A", "E"])
        e_run = open_telemetry_run(pair_dir; columns = "E")
        pair_batch = first(b for b in list_batches(pair_run) if b.state == :ground)
        @test read_batch(pair_run, pair_batch.name) ==
              Float32.(hcat(payload, second)[pair_batch.rows, :])
        @test read_batch(e_run, pair_batch.name) == Float32.(second[pair_batch.rows])
        @test read_batch(
            open_telemetry_run(pair_dir; columns = ["E", "A"]),
            pair_batch.name,
        ) == Float32.(hcat(second, payload)[pair_batch.rows, :])
        # The first channel of the pair is conditioned as the single column
        @test replay_run(pair_run, pair_detector).score ==
              replay_run(open_telemetry_run(pair_dir; columns = "A"), detector).score

        # A scheduled generation gap: the delivered batches hold the rows of
        # their content epochs, and the producer declares the rows it never
        # produced, which a stateful estimator is told of with that cause
        gap_dir = tick_mission(
            dir,
            "gap",
            payload_path;
            epoch = epoch,
            disruption = Dict{String,Any}(
                "events" => [
                    Dict{String,Any}(
                        "type" => "antenna_repointing",
                        "label" => "repointing",
                        "start_day" => 0.1,
                        "duration_hours" => 1.0,
                    ),
                ],
            ),
        )
        gap_run = open_telemetry_run(gap_dir)
        gap_delivered =
            filter(b -> b.state == :ground && last(b.rows) <= n_rows, list_batches(gap_run))
        @test all(
            b -> read_batch(gap_run, b.name) == Float32.(payload[b.rows]),
            gap_delivered,
        )
        gap_rows =
            time_row(geometry, epoch+Dates.Minute(144)):(time_row(
                geometry,
                epoch+Dates.Minute(204),
            )-1)
        @test all(b -> isempty(intersect(b.rows, gap_rows)), gap_delivered)
        scheduled_holes = filter(h -> h.cause == :scheduled, declared_holes(gap_run))
        @test !isempty(scheduled_holes)
        @test any(h -> issubset(gap_rows, h.rows), scheduled_holes)
        scorer = SequenceRMS()
        gap_state = replay_state(
            gap_run,
            StreamingDetector(scorer, 1.0; conditioning...);
            tdi_gap_dilation_sec = 100.0,
        )
        @test "scheduled" in gaps_table(gap_state).cause
        @test any(g -> g.cause == :scheduled, scorer.gaps)

        # Run directories derived from the snapshot of the mission: producer
        # versions before 2.1.0 misplace an external payload after a scheduled
        # gap or an emitter restart, payload row 1 must lie at the mission
        # epoch, and a stamped payload row must agree with the content epoch
        template = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
        function derived_run(
            name;
            version = "2.0.1",
            source = "external",
            origin = :keep,
            downtime = 0.0,
            columns = nothing,
            tx = String[],
            components = String[],
            sentinels = ("RUN_COMPLETE",),
        )
            d = joinpath(dir, "derived", name)
            mkpath(d)
            foreach(s -> touch(joinpath(d, s)), sentinels)
            cfg = deepcopy(template)
            cfg["provenance"]["platform"]["package_version"] = version
            cfg["physics"]["data_source"] = source
            cfg["simulation"]["initial_downtime_days"] = downtime
            origin === :keep || (
                origin === nothing ? delete!(cfg["provenance"], "payload_origin") :
                (cfg["provenance"]["payload_origin"] = origin)
            )
            columns === nothing || (cfg["provenance"]["external_data_columns"] = columns)
            open(io -> TOML.print(io, cfg), joinpath(d, "config_snapshot.toml"), "w")
            isempty(tx) || write(
                joinpath(d, "events_tx.csv"),
                join(["SimTime,Batch,Event"; tx], "\n") * "\n",
            )
            isempty(components) || write(
                joinpath(d, "component_events.csv"),
                join(["SimTime,Component,Event"; components], "\n") * "\n",
            )
            return d
        end
        gap = [
            "2035-01-01T08:00:00.0,SCHEDULED,gap_start",
            "2035-01-01T09:00:00.0,SCHEDULED,gap_end",
        ]
        restart = ["2035-01-01T10:00:00.0,emitter,restart"]
        @test_throws ArgumentError open_telemetry_run(derived_run("a"; tx = gap))
        @test_throws ArgumentError open_telemetry_run(
            derived_run("b"; components = restart),
        )
        @test open_telemetry_run(derived_run("c"; version = "2.1.1", tx = gap)) isa
              AbstractTelemetryRun
        @test open_telemetry_run(derived_run("d"; source = "synthetic", tx = gap)) isa
              AbstractTelemetryRun
        @test open_telemetry_run(
            derived_run("e"; tx = ["2035-01-01T08:00:00.0,RECORDER,gap_start"]),
        ) isa AbstractTelemetryRun
        @test_throws ArgumentError open_telemetry_run(
            derived_run("f"; version = "2.1.1", origin = "2034-12-31T12:00:00"),
        )
        @test_throws ArgumentError open_telemetry_run(
            derived_run("g"; origin = nothing, downtime = 0.5),
        )
        # Several payload columns are served only by name
        @test_throws ArgumentError open_telemetry_run(
            derived_run("h"; version = "2.6.0", columns = ["A", "E"]),
        )
        @test open_telemetry_run(
            derived_run("i"; version = "2.6.0", columns = ["A", "E"]);
            columns = ["A", "E"],
        ) isa AbstractTelemetryRun
        # While the producer post-processes, the record is final
        post = open_telemetry_run(
            derived_run(
                "j";
                version = "2.6.0",
                sentinels = ("RUN_ACTIVE", "RUN_POSTPROCESSING"),
            ),
        )
        @test run_state(post) == :active && record_final(post)
        @test !record_final(
            open_telemetry_run(
                derived_run("k"; version = "2.6.0", sentinels = ("RUN_ACTIVE",)),
            ),
        )
        stamped = derived_run("l"; version = "2.1.1")
        batch = joinpath(stamped, "ground", "LIVE_batch_7")
        mkpath(batch)
        write(
            joinpath(batch, "metadata.json"),
            """{"segment_count":10,"content_epoch":"2035-01-01T06:50:00","payload_row":601,"batch_id":7}""",
        )
        stamped_run = open_telemetry_run(stamped)
        @test only(list_batches(stamped_run)).rows == 601:700
        @test only(batch_records(stamped_run, ["LIVE_batch_7"])).rows == 601:700
        write(
            joinpath(batch, "metadata.json"),
            """{"segment_count":10,"content_epoch":"2035-01-01T06:50:00","payload_row":501,"batch_id":7}""",
        )
        @test_throws ArgumentError list_batches(stamped_run)
    end
end
