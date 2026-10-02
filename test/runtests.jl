# Static QA, signal processing, features, evaluation, configuration and provenance,
# figures and animations, and the streamed replay of StreamingInference.
include(joinpath(@__DIR__, "activate.jl"))

using Test
using Statistics, Random, TOML, Dates
using FFTW: rfft, rfftfreq
using CSV, DataFrames
using StableRNGs
using Aqua, JET, ExplicitImports
using StreamingInference
using CairoMakie: CairoMakie

const PROJECT_ROOT = dirname(@__DIR__)
# The pipeline root of the whole run: a sandboxed test environment lies
# outside the repository
ENV["STREAMINGINFERENCE_ROOT"] = PROJECT_ROOT

# Generic one-sided PSD [Hz⁻¹]: white above 1 mHz, rising as f⁻² below it
noise_psd(f) = 1e-40 * (1 + (1e-3 / f)^2)

@testset "Static QA (Aqua)" begin
    # The persistent-tasks check precompiles a wrapper package against the
    # live registry; it is gated off CI, where it fails for environmental
    # reasons, and runs locally.
    Aqua.test_all(StreamingInference; persistent_tasks = get(ENV, "CI", "") != "true")
end

@testset "Static QA (ExplicitImports)" begin
    @test ExplicitImports.check_no_stale_explicit_imports(StreamingInference) === nothing
    @test ExplicitImports.check_no_implicit_imports(StreamingInference) === nothing
    @test ExplicitImports.check_all_explicit_imports_via_owners(StreamingInference) ===
          nothing
    @test ExplicitImports.check_all_explicit_imports_are_public(StreamingInference) ===
          nothing
    @test ExplicitImports.check_all_qualified_accesses_via_owners(StreamingInference) ===
          nothing
    @test ExplicitImports.check_all_qualified_accesses_are_public(StreamingInference) ===
          nothing
    @test ExplicitImports.check_no_self_qualified_accesses(StreamingInference) === nothing
end

@testset "Static QA (JET)" begin
    JET.test_package(StreamingInference; target_modules = (StreamingInference,))
end

@testset "Noise synthesis calibration" begin
    rng = StableRNG(2026)
    fs = 0.2
    n = 2^15
    x = synthesize_noise(rng, n, fs; psd = noise_psd)
    @test length(x) == n
    @test eltype(x) == Float64
    @test isapprox(mean(x), 0.0; atol = 3 * std(x) / sqrt(n))
    # Whitening the record turns the noise into unit-variance white noise;
    # 655 bins in 1-5 mHz give a 4 % standard error on the mean power
    w = whiten_record(x, fs; psd = noise_psd)
    @test isapprox(var(w), 1.0; atol = 0.05)
    power = tapered_periodogram(w; taper = :none)
    freqs = rfftfreq(n, fs)
    inband = (freqs .>= 1e-3) .& (freqs .<= 5e-3)
    @test isapprox(mean(power[inband]), 1.0; atol = 0.15)
    @test power[1] == 0
    # Seeded synthesis is reproducible
    @test synthesize_noise(StableRNG(5), 64, fs; psd = noise_psd) ==
          synthesize_noise(StableRNG(5), 64, fs; psd = noise_psd)
    # Bins below the synthesis floor carry no power
    floored = synthesize_noise(StableRNG(5), 4096, fs; f_min = 1e-3, psd = noise_psd)
    spectrum = abs.(rfft(floored))
    low_bins = rfftfreq(4096, fs) .< 1e-3
    @test maximum(spectrum[low_bins]) < 1e-10 * maximum(spectrum)
    @test_throws ArgumentError synthesize_noise(rng, 64, fs; f_min = -1.0, psd = noise_psd)
    @test_throws ArgumentError synthesize_noise(rng, 1, fs; psd = noise_psd)
    @test_throws ArgumentError synthesize_noise(rng, 64, 0.0; psd = noise_psd)
end

@testset "Tapered periodogram" begin
    rng = StableRNG(99)
    white = randn(rng, 8192)
    for taper in (:hann, :none)
        p = tapered_periodogram(white; taper = taper)
        @test length(p) == 4097
        @test p[1] == 0
        @test isapprox(mean(p[2:end]), 1.0; atol = 0.05)
    end
    @test_throws ArgumentError tapered_periodogram(white; taper = :tukey)
    @test_throws ArgumentError tapered_periodogram([1.0])
end

@testset "Matched-filter SNR" begin
    fs = 0.2
    n = 4096
    T = n / fs
    t = (0:(n-1)) ./ fs
    # An on-bin sinusoid of amplitude A has ρ = A sqrt(T / S_n(f0)) exactly
    k = 60
    f0 = k * fs / n
    A = 1e-20
    h = A .* cos.(2π * f0 .* t)
    ρ_expected = A * sqrt(T / noise_psd(f0))
    @test isapprox(matched_filter_snr(h, fs; psd = noise_psd), ρ_expected; rtol = 1e-6)
    # Linear in amplitude and rescalable to a target
    @test isapprox(matched_filter_snr(3h, fs; psd = noise_psd), 3ρ_expected; rtol = 1e-6)
    @test isapprox(
        matched_filter_snr(scale_to_snr(h, fs, 12.0; psd = noise_psd), fs; psd = noise_psd),
        12.0;
        rtol = 1e-6,
    )
    @test_throws ArgumentError scale_to_snr(zeros(n), fs, 10.0; psd = noise_psd)
    @test_throws ArgumentError scale_to_snr(h, fs, 0.0; psd = noise_psd)
end

@testset "Signal placement" begin
    strain = zeros(10)
    signal = [1.0, 2.0, 3.0, 4.0]
    # Anchor sample 3 of the signal on sample 2 of the record: sample 1 is dropped
    covered = place_signal!(strain, signal, 2, 3)
    @test covered == 1:3
    @test strain[1:3] == [2.0, 3.0, 4.0]
    @test all(iszero, strain[4:end])
    # Truncation at the end of the record
    strain2 = zeros(10)
    @test place_signal!(strain2, signal, 10, 1) == 10:10
    @test strain2[10] == 1.0
    # No overlap
    strain3 = zeros(10)
    @test isempty(place_signal!(strain3, signal, 20, 1))
    @test_throws BoundsError place_signal!(strain3, signal, 5, 9)
end

@testset "Whitened features" begin
    rng = StableRNG(11)
    fs = 0.2
    # Unit-mean band powers for noise, independent of the window length
    record = highpass_record(
        synthesize_noise(rng, 40000, fs; psd = noise_psd),
        fs;
        cutoff = 5e-4,
    )
    long = whiten_record(record, fs; psd = noise_psd)
    p_low_long, p_high_long, ent_long, lstd_long = extract_features(long, fs)
    @test isapprox(p_low_long, 1.0; atol = 0.15)
    @test isapprox(p_high_long, 1.0; atol = 0.15)
    @test 0.85 < ent_long <= 1.0
    @test abs(lstd_long) < 0.15
    # Windows cut from the whitened record
    p_low_short, p_high_short, ent_short, _ = extract_features(view(long, 1:4000), fs)
    @test isapprox(p_low_short, 1.0; atol = 0.35)
    @test isapprox(p_high_short, 1.0; atol = 0.15)
    @test 0.8 < ent_short <= 1.0
    p_low_win, _, _, _ = extract_features(view(long, 10001:11000), fs)
    @test isapprox(p_low_win, 1.0; atol = 0.7)
    # A strong in-band sinusoid raises the low-band power and lowers the entropy
    t = (0:39999) ./ fs
    strong = long .+ cos.(2π * 2e-3 .* t)
    p_low_strong, p_high_strong, ent_strong, _ = extract_features(strong, fs)
    @test p_low_strong > 5 * p_low_long
    @test isapprox(p_high_strong, p_high_long; atol = 0.3)
    @test ent_strong < ent_long
    @test_throws ArgumentError extract_features(long, 0.0)
    # 16 samples at 0.2 Hz resolve no bin inside the 1-5 mHz band
    @test_throws ArgumentError extract_features(view(long, 1:16), fs)
    # A constant window yields finite features
    @test all(isfinite, extract_features(zeros(1000), fs))

    # The bands set with the default edges reproduces the whitened set exactly
    bands =
        extract_features(long, fs; feature_set = :bands, band_edges = [1e-3, 5e-3, 1e-1])
    @test collect(bands) == collect(extract_features(long, fs))
    @test feature_names(:bands; n_bands = 2) ==
          [:p_band_1, :p_band_2, :spectral_entropy, :log_power_std]
    @test length(feature_names(:bands; n_bands = 5)) == 7
    @test feature_names(:whitened; n_bands = 5) == feature_names(:whitened)
    @test feature_names(:whitened) == [:p_low, :p_high, :spectral_entropy, :log_power_std]
    # Finer bands: unit mean on white noise; a 1.5 mHz tone lands in the
    # (1, 2] mHz band and leaves the others alone
    edges = [5e-4, 1e-3, 2e-3, 4e-3, 1e-2, 4e-2]
    fine = extract_features(long, fs; feature_set = :bands, band_edges = edges)
    @test length(fine) == 7
    @test all(isapprox.(fine[1:5], 1.0; atol = 0.35))
    tone = long .+ cos.(2π * 1.5e-3 .* t)
    fine_tone = extract_features(tone, fs; feature_set = :bands, band_edges = edges)
    @test fine_tone[2] > 5 * fine[2]
    @test isapprox(fine_tone[4], fine[4]; atol = 0.3) && fine_tone[6] < fine[6]
    @test_throws ArgumentError extract_features(long, fs; feature_set = :bands)
    @test_throws ArgumentError extract_features(
        long,
        fs;
        feature_set = :bands,
        band_edges = [5e-3, 1e-3],
    )
    @test_throws ArgumentError extract_features(
        view(long, 1:1000),
        fs;
        feature_set = :bands,
        band_edges = [1e-5, 5e-5, 1e-1],
    )
    @test_throws ArgumentError feature_names(:bands; n_bands = 0)

    # The raw-window set: four finite values, entropy in [0, 1]
    paper = extract_features(record[1:1000], fs; feature_set = :paper)
    @test length(paper) == 4 && all(isfinite, paper) && 0 <= paper[1] <= 1
    @test feature_names(:paper) ==
          [:spectral_entropy, :log_power_mean, :log_power_std, :log_power_max]
    @test_throws ArgumentError feature_names(:other)
    @test_throws ArgumentError extract_features(record[1:1000], fs; feature_set = :other)
end

@testset "Multichannel features" begin
    rng = StableRNG(12)
    fs = 0.2
    channels = hcat(
        (
            whiten_record(
                highpass_record(
                    synthesize_noise(rng, 20000, fs; psd = noise_psd),
                    fs;
                    cutoff = 5e-4,
                ),
                fs;
                psd = noise_psd,
            ) for _ in 1:3
        )...,
    )
    window = channels[5001:6000, :]
    # The periodogram of several channels is the average of theirs
    spectra = [tapered_periodogram(window[:, c]) for c in 1:3]
    @test network_periodogram(window) ≈ (spectra[1] .+ spectra[2] .+ spectra[3]) ./ 3
    @test network_periodogram(window[:, 1]) == spectra[1]
    @test network_periodogram(window[:, 1:1]) == spectra[1]
    @test network_periodogram(hcat(window[:, 1], window[:, 1])) == spectra[1]
    @test_throws ArgumentError network_periodogram(zeros(1000, 0))
    # Features: one channel as a matrix or a vector alike; the count does not
    # grow with the channels; band powers are the channel means
    edges = [1e-3, 2e-3, 5e-3, 1e-1]
    single = extract_features(window[:, 1], fs; feature_set = :bands, band_edges = edges)
    @test extract_features(window[:, 1:1], fs; feature_set = :bands, band_edges = edges) ==
          single
    network = extract_features(window, fs; feature_set = :bands, band_edges = edges)
    @test length(network) == length(single) == 5
    per_channel = [
        extract_features(window[:, c], fs; feature_set = :bands, band_edges = edges) for
        c in 1:3
    ]
    for band in 1:3
        @test network[band] ≈ sum(f[band] for f in per_channel) / 3 rtol = 1e-6
    end
    # Under noise the averaged periodogram keeps its unit mean and its
    # spread falls as 1/√C: log₁₀ of the standard deviation goes from 0
    # towards -log₁₀(√3)
    long_single = extract_features(channels[:, 1], fs)
    long_network = extract_features(channels, fs)
    @test isapprox(long_network[1], 1.0; atol = 0.1)
    @test isapprox(long_network[4] - long_single[4], -log10(sqrt(3)); atol = 0.05)
    # A signal common to the channels keeps its band power; the noise does not add to it
    t = (0:19999) ./ fs
    tone = cos.(2π * 2e-3 .* t)
    @test isapprox(
        extract_features(channels .+ tone, fs)[1],
        extract_features(channels[:, 1] .+ tone, fs)[1];
        rtol = 0.05,
    )
    # Sliding windows of a multichannel record
    table = window_features(
        channels,
        fs;
        window_size = 1000,
        step_size = 500,
        low_band = (1e-3, 5e-3),
        high_band = (5e-3, 1e-1),
        feature_set = :whitened,
    )
    @test size(table) == (39, 4)
    @test Tuple(table[11, :]) == extract_features(channels[5001:6000, :], fs)
    @test window_features(
        channels[:, 1],
        fs;
        window_size = 1000,
        step_size = 500,
        low_band = (1e-3, 5e-3),
        high_band = (5e-3, 1e-1),
        feature_set = :whitened,
    ) == window_features(
        channels[:, 1:1],
        fs;
        window_size = 1000,
        step_size = 500,
        low_band = (1e-3, 5e-3),
        high_band = (5e-3, 1e-1),
        feature_set = :whitened,
    )
end

@testset "Record high-pass" begin
    fs = 0.2
    n = 20000
    t = (0:(n-1)) ./ fs
    low = cos.(2π * 1e-4 .* t)
    inband = cos.(2π * 5e-3 .* t)
    y = highpass_record(low .+ inband, fs; cutoff = 5e-4, order = 8)
    # The 0.1 mHz component is suppressed by more than 1e5 in power, the 5 mHz
    # component is preserved to better than 1 %
    Xy = abs.(rfft(y))
    Xl = abs.(rfft(low .+ inband))
    k_low = round(Int, 1e-4 * n / fs) + 1
    k_in = round(Int, 5e-3 * n / fs) + 1
    @test (Xy[k_low] / Xl[k_low])^2 < 1e-5
    @test isapprox(Xy[k_in] / Xl[k_in], 1.0; atol = 1e-2)
    @test highpass_record(inband, fs; cutoff = 0.0) == inband
    @test_throws ArgumentError highpass_record(inband, fs; cutoff = -1.0)
    @test_throws ArgumentError highpass_record(inband, fs; cutoff = 1e-3, order = 0)
end

@testset "PSD estimation and tables" begin
    # Welch estimate: white noise of variance σ² has one-sided PSD 2σ²/fs
    rng = StableRNG(5)
    fs = 0.2
    σ = 3.0
    white = σ .* randn(rng, 200_000)
    fw, sw = welch_psd(white, fs; segment_length = 1024)
    @test length(fw) == length(sw) == 512 && fw[1] == fs / 1024
    @test isapprox(median(sw), 2σ^2 / fs; rtol = 0.03)
    fw2, sw2 = welch_psd(white, fs; segment_length = 1024, average = :mean)
    @test isapprox(mean(sw2), 2σ^2 / fs; rtol = 0.03)
    # Coloured noise synthesised from a PSD is recovered in band
    colored = synthesize_noise(StableRNG(6), 400_000, fs; f_min = 1e-5, psd = noise_psd)
    fc, sc = welch_psd(colored, fs; segment_length = 8192)
    inband = (fc .>= 1e-3) .& (fc .<= 5e-2)
    @test isapprox(median(sc[inband] ./ noise_psd.(fc[inband])), 1.0; rtol = 0.1)
    @test_throws ArgumentError welch_psd(white, fs; segment_length = 1)
    @test_throws ArgumentError welch_psd(white, fs; segment_length = 1024, overlap = 1.0)
    @test_throws ArgumentError welch_psd(white, fs; segment_length = 1024, average = :max)
    # Pooling the segments of several records: two copies of one record give
    # the record's own estimate, a record shorter than a segment is skipped,
    # and no record holding a segment is an error
    fp, sp = welch_psd([white, white], fs; segment_length = 1024)
    @test fp == fw && sp == sw
    @test welch_psd([white, white[1:100]], fs; segment_length = 1024)[2] == sw
    @test_throws ArgumentError welch_psd([white[1:100]], fs; segment_length = 1024)

    # Log-frequency smoothing: a power law is left as it is away from the
    # ends of the table, a one-bin line is diluted by the ≈ 600 bins of a
    # 0.01-dex kernel at 10 mHz, and zero width is the identity
    fg = collect(rfftfreq(65536, fs)[2:end])
    power_law = 1e-40 .* (fg ./ 1e-2) .^ -2
    smoothed = smooth_psd(fg, power_law, 0.01)
    interior = (fg .>= 1e-4) .& (fg .<= 5e-2)
    @test maximum(abs.(smoothed[interior] ./ power_law[interior] .- 1)) < 1e-2
    k0 = searchsortedfirst(fg, 1e-2)
    line = copy(power_law)
    line[k0] *= 100
    diluted = smooth_psd(fg, line, 0.01)
    @test diluted[k0] / power_law[k0] < 1.1
    @test smooth_psd(fg, line, 0.0) == line
    @test_throws ArgumentError smooth_psd(fg, line, -0.01)
    @test_throws DimensionMismatch smooth_psd(fg, line[1:10], 0.01)
    @test_throws ArgumentError smooth_psd(reverse(fg), line, 0.01)
    @test_throws ArgumentError smooth_psd(fg, -line, 0.01)

    # Log-log interpolation: exact at the knots, geometric in between, flat outside
    S = interpolated_psd([1e-3, 1e-2, 1e-1], [1.0, 100.0, 1.0])
    @test S(1e-3) == 1.0 && S(1e-2) == 100.0
    @test isapprox(S(sqrt(1e-3 * 1e-2)), 10.0; rtol = 1e-12)
    @test S(1e-4) == 1.0 && S(1.0) == 1.0 && S(0.0) == Inf
    @test_throws ArgumentError interpolated_psd([1e-2, 1e-3], [1.0, 2.0])
    @test_throws ArgumentError interpolated_psd([1e-3, 1e-2], [1.0, 0.0])
    @test_throws DimensionMismatch interpolated_psd([1e-3, 1e-2], [1.0])
end

@testset "Labelled spans and window tables" begin
    fs = 0.2
    n = 20_000
    @test fixed_spans([8500], fs, n; before = 100.0, after = 50.0) == [8480:8510]
    @test fixed_spans([5], fs, n; before = 100.0, after = 0.0) == [1:5]
    labels = span_labels(n, [10:20, 15:30])
    @test count(==(1), labels) == 21 && labels[9] == 0 && labels[31] == 0
    @test_throws ArgumentError span_labels(10, [5:12])
    @test_throws ArgumentError fixed_spans([0], fs, n; before = 1.0, after = 1.0)

    # Windows 1:10, 6:15, 11:20, 16:25, 21:30: positive where they touch the
    # span 12:14, carrying the largest SNR inside them
    raw = zeros(Int, 30)
    raw[12:14] .= 1
    snr = zeros(30)
    snr[13] = 7.0
    window_y, window_snr = window_labels(raw, snr; window_size = 10, step_size = 5)
    @test window_y == [0, 1, 1, 0, 0] && window_snr == Float32[0, 7, 7, 0, 0]
    @test_throws DimensionMismatch window_labels(
        raw,
        snr[1:29];
        window_size = 10,
        step_size = 5,
    )
    @test_throws ArgumentError window_labels(raw, snr; window_size = 40, step_size = 5)
    # One feature row per window, each that of the window cut by hand
    x = randn(StableRNG(8), 3000)
    geometry = (window_size = 1000, step_size = 500, low_band = (1e-3, 5e-3))
    X = @test_logs (:info, "feature extraction") match_mode = :any window_features(
        x,
        fs;
        geometry...,
        high_band = (5e-3, 1e-1),
        feature_set = :whitened,
    )
    @test size(X) == (5, 4)
    @test X[3, :] == collect(extract_features(view(x, 1001:2000), fs))

    # Feature and label tables: the label-free path yields the identical raw matrix
    mktempdir() do dir
        feat_path = joinpath(dir, "test_feats.csv")
        lab_path = joinpath(dir, "test_labs.csv")
        df_f = DataFrame(
            p_low = [0.5, 3.0, 1.0],
            p_high = [1.0, 0.9, 1.1],
            spectral_entropy = [0.95, 0.6, 0.9],
            log_power_std = [0.0, 0.8, 0.1],
        )
        CSV.write(feat_path, df_f)
        CSV.write(lab_path, DataFrame(Label = [0, 1, 0], SNR = [0.0, 12.0, 0.0]))
        Xf, y, df_l = load_data(feat_path, lab_path)
        @test Xf == Matrix{Float32}(df_f)
        @test y == [0, 1, 0]
        @test df_l.SNR == [0.0, 12.0, 0.0]
        @test load_features(feat_path) == Xf
        CSV.write(lab_path, DataFrame(Label = [0, 1]))
        @test_throws DimensionMismatch load_data(feat_path, lab_path)
    end
end

@testset "Evaluation protocol" begin
    # Chronological split: 70/15/15 of 100 windows with a five-window buffer
    blocks = chronological_split(100; buffer = 5)
    @test blocks.train == 1:70
    @test blocks.validation == 76:90
    @test blocks.test == 96:100
    @test chronological_split(20).test == 18:20
    @test_throws ArgumentError chronological_split(10; buffer = 10)
    @test_throws ArgumentError chronological_split(100; train_fraction = 0.9)
    @test_throws ArgumentError chronological_split(100; train_fraction = 0.0)
    @test_throws ArgumentError chronological_split(100; buffer = -1)

    # Calibration block: the validation block alone, or validation and test
    # pooled across the buffer so that the range stays contiguous in time
    @test threshold_rows(blocks, "validation") == 76:90
    @test threshold_rows(blocks, "held_out") == 76:100
    @test length(threshold_rows(blocks, "held_out")) ==
          length(blocks.validation) + length(blocks.test) + 5
    @test_throws ArgumentError threshold_rows(blocks, "test")

    # ROC: one misordered positive among six windows
    y6 = [1, 1, 0, 1, 0, 0]
    s6 = [0.9, 0.8, 0.7, 0.4, 0.3, 0.1]
    fpr, tpr, thr = roc_curve(y6, s6)
    @test thr == [Inf, 0.9, 0.8, 0.7, 0.4, 0.3, 0.1]
    @test fpr ≈ [0, 0, 0, 1, 1, 2, 3] ./ 3
    @test tpr ≈ [0, 1, 2, 2, 3, 3, 3] ./ 3
    @test roc_auc(fpr, tpr) ≈ 8 / 9
    @test roc_auc(roc_curve([1, 1, 0, 0], [0.9, 0.8, 0.2, 0.1])[1:2]...) == 1.0
    @test roc_auc(roc_curve([1, 0, 1, 0], fill(0.5, 4))[1:2]...) ≈ 0.5
    @test isnan(roc_auc(roc_curve([1, 1], [0.2, 0.3])[1:2]...))
    @test_throws DimensionMismatch roc_curve([1, 0], [0.5])

    # Contiguous runs
    @test contiguous_runs([false, true, true, false, true]) == [2:3, 5:5]
    @test isempty(contiguous_runs(falses(3)))
    @test contiguous_runs(trues(4)) == [1:4]

    # Event metrics: two events (3:5, 9:10), one detected; alarms at 4 and at
    # 7:8 (one false-alarm episode); half-day windows, hence six days
    labels = [0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0]
    decisions = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0]
    m = event_metrics(decisions, labels; step_size = 43200, sample_rate = 1.0)
    @test m.precision ≈ 1 / 3
    @test m.recall ≈ 1 / 5
    @test m.f1 ≈ 1 / 4
    @test m.balanced_accuracy ≈ 16 / 35
    @test m.n_events == 2 && m.n_detected == 1 && m.event_recall == 0.5
    @test m.n_false_alarm_episodes == 1
    @test m.observation_days ≈ 6.0
    @test m.false_alarms_per_30d ≈ 5.0
    # A permanent alarm detects every event and counts one false-alarm
    # episode in every unlabelled stretch (before, between, after)
    m_all = event_metrics(ones(Int, 12), labels; step_size = 43200, sample_rate = 1.0)
    @test m_all.n_detected == 2 && m_all.n_false_alarm_episodes == 3
    @test m_all.recall == 1.0
    m_none = event_metrics(zeros(Int, 12), labels; step_size = 1, sample_rate = 1.0)
    @test isnan(m_none.precision) && m_none.recall == 0.0
    @test_throws DimensionMismatch event_metrics(
        [1, 0],
        [1];
        step_size = 1,
        sample_rate = 1.0,
    )
    @test_throws ArgumentError event_metrics([1], [1]; step_size = 0, sample_rate = 1.0)

    # Threshold selection on a validation block of twenty half-day windows
    # (ten days): one event at 8:10 (scores 0.90, 0.95, 0.85), two spurious
    # noise scores 0.60 (window 3) and 0.70 (window 15), the rest below 0.25
    scores = [
        0.10,
        0.12,
        0.60,
        0.11,
        0.13,
        0.14,
        0.15,
        0.90,
        0.95,
        0.85,
        0.16,
        0.17,
        0.18,
        0.19,
        0.70,
        0.20,
        0.21,
        0.22,
        0.23,
        0.24,
    ]
    yv = zeros(Int, 20)
    yv[8:10] .= 1
    geometry = (step_size = 43200, sample_rate = 1.0)
    # The sweep: ascending candidates, monotone window rates, one event
    sweep = threshold_sweep(yv, scores; geometry...)
    @test issorted(sweep.threshold) && allunique(sweep.threshold)
    @test issorted(sweep.fpr; rev = true) && issorted(sweep.recall; rev = true)
    @test all(==(1), sweep.n_events)
    @test first(sweep.threshold) == 0.10 && first(sweep.recall) == 1.0
    @test first(sweep.fpr) == 1.0 && first(sweep.n_false_alarm_episodes) == 2
    @test last(sweep.threshold) == 0.95 && last(sweep.recall) ≈ 1 / 3
    @test last(sweep.fpr) == 0.0 && last(sweep.event_recall) == 1.0
    @test all(sweep.false_alarms_per_30d .≈ sweep.n_false_alarm_episodes .* 3.0)
    @test_throws ArgumentError threshold_sweep(Int[], Float64[]; geometry...)
    @test_throws ArgumentError threshold_sweep(yv, scores; n_candidates = 1, geometry...)
    @test_throws DimensionMismatch threshold_sweep(yv, scores[1:19]; geometry...)
    # far, one episode per 30 d: no episode is admissible on ten days, so the
    # lowest threshold clearing both spurious scores is chosen
    t_far, info = select_threshold(
        yv,
        scores;
        criterion = "far",
        target_far_per_30d = 1.0,
        geometry...,
    )
    @test 0.70 < t_far <= 0.85
    @test info["criterion"] == "far"
    @test info["fit_recall"] == 1.0
    @test info["fit_fpr"] == 0.0
    @test info["fit_false_alarms_per_30d"] == 0.0
    # far, three episodes per 30 d: one episode (window 15) is admitted once
    # the duty-cycle guard allows one of seventeen negatives
    t_far3, info3 = select_threshold(
        yv,
        scores;
        criterion = "far",
        target_far_per_30d = 3.0,
        target_fpr = 0.1,
        geometry...,
    )
    @test 0.60 < t_far3 <= 0.70
    @test info3["fit_false_alarms_per_30d"] ≈ 3.0
    @test info3["fit_fpr"] ≈ 1 / 17
    # The duty-cycle guard alone (every episode rate admissible) stops at
    # the first false positive
    t_guard, _ = select_threshold(
        yv,
        scores;
        criterion = "far",
        target_far_per_30d = 100.0,
        target_fpr = 0.05,
        geometry...,
    )
    @test 0.70 < t_guard <= 0.85
    # Descending scan: with the event at the start of the block, a permanent
    # alarm is one long episode (3 per 30 d) and admissible by rate alone;
    # the operating point must nevertheless stay on the branch of short
    # episodes, above the second spurious score
    y_head = zeros(Int, 20)
    y_head[1:3] .= 1
    s_head = fill(0.2, 20)
    s_head[1:3] .= [0.90, 0.95, 0.85]
    s_head[8] = 0.60
    s_head[15] = 0.70
    t_head, info_head = select_threshold(
        y_head,
        s_head;
        criterion = "far",
        target_far_per_30d = 3.0,
        target_fpr = 1.0,
        geometry...,
    )
    @test 0.60 < t_head <= 0.70
    @test info_head["fit_false_alarms_per_30d"] ≈ 3.0
    @test event_metrics(ones(Int, 20), y_head; geometry...).false_alarms_per_30d ≈ 3.0
    # fpr: 5 % of 17 negatives admits none, 10 % admits one
    t_fpr, _ =
        select_threshold(yv, scores; criterion = "fpr", target_fpr = 0.05, geometry...)
    @test 0.70 < t_fpr <= 0.85
    t_fpr10, _ =
        select_threshold(yv, scores; criterion = "fpr", target_fpr = 0.10, geometry...)
    @test 0.60 < t_fpr10 <= 0.70
    # youden: TPR - FPR peaks at the lowest event score
    t_youden, info_y = select_threshold(yv, scores; criterion = "youden", geometry...)
    @test t_youden == 0.85
    @test info_y["criterion"] == "youden"
    # youden without positives warns and falls back to fpr
    y0 = zeros(Int, 20)
    t_fb, info_fb = @test_logs (:warn, r"Youden") match_mode = :any select_threshold(
        y0,
        scores;
        criterion = "youden",
        target_fpr = 0.05,
        geometry...,
    )
    @test info_fb["criterion"] == "fpr" && info_fb["requested_criterion"] == "youden"
    @test 0.90 < t_fb <= 0.95
    # far without positives and no admissible episode disables the alarm
    t_inf, _ =
        @test_logs (:warn, r"alarms are disabled") match_mode = :any select_threshold(
            y0,
            scores;
            criterion = "far",
            target_far_per_30d = 0.0,
            geometry...,
        )
    @test t_inf == Inf
    @test_throws ArgumentError select_threshold(
        yv,
        scores;
        criterion = "bogus",
        geometry...,
    )
    @test_throws ArgumentError select_threshold(Int[], Float64[]; geometry...)
    @test_throws DimensionMismatch select_threshold(yv, scores[1:19]; geometry...)
end

@testset "Configuration and provenance" begin
    @test isfile(joinpath(project_root(), "Project.toml"))
    # The pipeline root: the scope, then the environment variable, then the
    # active environment; a configuration's root from its [paths] root or the
    # nearest Project.toml above it
    @test project_root() == PROJECT_ROOT
    mktempdir() do dir
        @test with_pipeline_root(project_root, dir) == abspath(dir)
        @test with_pipeline_root(() -> resolvepath("data"), dir) ==
              joinpath(abspath(dir), "data")
        config = joinpath(dir, "configs", "run.toml")
        mkpath(dirname(config))
        write(config, "[paths]\nroot = \"..\"\n")
        @test config_root(config) == normpath(abspath(dir))
        write(config, "[paths]\ninputs = \"in\"\n")
        @test config_root(config) == project_root()
        touch(joinpath(dir, "Project.toml"))
        @test config_root(config) == abspath(dir)
        nested = joinpath(dir, "configs", "experiments", "run.toml")
        mkpath(dirname(nested))
        write(nested, "[paths]\ninputs = \"in\"\n")
        @test config_root(nested) == abspath(dir)
    end
    if startswith(Base.active_project(), PROJECT_ROOT)
        @test withenv(project_root, "STREAMINGINFERENCE_ROOT" => nothing) == PROJECT_ROOT
    end
    @test resolvepath("data") == joinpath(project_root(), "data")
    @test resolvepath("/abs/x") == "/abs/x"
    @test rootrelative(joinpath(project_root(), "data", "x.csv")) ==
          joinpath("data", "x.csv")
    @test rootrelative("/elsewhere/x.csv") == "/elsewhere/x.csv"
    # A sibling directory whose name extends the root's lies outside it
    @test rootrelative(project_root() * "x/data.csv") == project_root() * "x/data.csv"
    @test rootrelative(project_root()) == "."
    # Provenance paths: relative inside the root, bare file name outside,
    # so that no snapshot carries the account name of the running machine
    @test provenance_path(joinpath(PROJECT_ROOT, "data", "x.csv")) ==
          joinpath("data", "x.csv")
    @test provenance_path(joinpath(homedir(), "elsewhere", "product.h5")) == "product.h5"
    @test !occursin(homedir(), provenance_path(joinpath(homedir(), "p.h5")))
    # The fingerprint identifies the host without naming it
    fp = hardware_fingerprint()
    @test !haskey(fp, "hostname")
    @test length(fp["machine_id"]) == 12 &&
          all(c -> c in "0123456789abcdef", fp["machine_id"])
    @test fp["machine_id"] == StreamingInference.machine_id()
    @test !occursin(gethostname(), fp["machine_id"])
    @test !occursin(homedir(), fp["versioninfo"])
    @test_throws ArgumentError load_config(joinpath(project_root(), "absent.toml"))
    sec = Dict{String,Any}("a" => 3, "b" => 2.5, "c" => "x", "d" => [1, 2])
    @test cfgget(sec, "a", 0; type = Float64) === 3.0
    @test cfgget(sec, "missing", 7; type = Int) == 7
    @test_throws ArgumentError cfgget(sec, "c", "y"; type = Int)
    @test_throws ArgumentError cfgget(sec, "a", 0; type = Int, min = 4)
    @test_throws ArgumentError cfgget(sec, "b", 0.0; type = Float64, max = 2.0)
    @test_throws ArgumentError cfgget(sec, "c", "x"; choices = ("y", "z"))
    @test override(nothing, 1) == 1 && override(2, 1) == 2
    @test analysis_band(Dict{String,Any}("band" => [1e-3, 5e-3]), "band", nothing) ==
          (1e-3, 5e-3)
    @test_throws ArgumentError analysis_band(
        Dict{String,Any}("band" => [5e-3, 1e-3]),
        "band",
        nothing,
    )
    # An empty configuration yields the documented, validated defaults
    empty = Dict{String,Any}()
    @test pipeline_paths(empty).inputs == joinpath(project_root(), "data", "inputs")
    @test inference_settings(empty).block == "all"
    mktempdir() do dir
        geometry = @test_logs (:warn, r"no feature sidecar") feature_geometry(
            joinpath(dir, "absent_features.csv"),
            empty,
        )
        @test geometry.first_window == 1
    end
    # Resources: machine-derived defaults, ordered thresholds
    r = resource_settings(empty)
    @test r.warn_memory_gib <= r.max_memory_gib <= r.total_memory_gib
    r16 = resource_settings(
        Dict{String,Any}(
            "resources" =>
                Dict{String,Any}("max_memory_gib" => 16.0, "warn_memory_gib" => 8.0),
        ),
    )
    @test r16.max_memory_gib == 16.0
    @test_throws ArgumentError resource_settings(
        Dict{String,Any}(
            "resources" =>
                Dict{String,Any}("max_memory_gib" => 1.0, "warn_memory_gib" => 2.0),
        ),
    )
    @test record_memory_estimate_gib(2^30 ÷ 8) == 6.0
    @test check_memory(0.1, r16; stage = "test") == 0.1
    @test_logs (:warn, r"warning threshold") match_mode = :any check_memory(
        9.0,
        r16;
        stage = "test",
    )
    @test_throws ArgumentError check_memory(17.0, r16; stage = "test")
    # Provenance: run identifiers, fingerprint, git, overwrite-safe writing
    @test length(new_run_id()) == 8 && new_run_id() != new_run_id()
    hw = hardware_fingerprint()
    @test hw["julia_version"] == string(VERSION)
    @test hw["cpu_threads_logical"] == Sys.CPU_THREADS
    g = git_provenance()
    @test haskey(g, "git_commit") &&
          g["package_version"] == string(pkgversion(StreamingInference))
    @test g["streaminference_version"] == string(pkgversion(StreamingInference))
    # The package version is that of the pipeline at the root, not of this library
    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), "name = \"Pipeline\"\nversion = \"2.5.0\"\n")
        @test with_pipeline_root(git_provenance, dir)["package_version"] == "2.5.0"
        rm(joinpath(dir, "Project.toml"))
        @test with_pipeline_root(git_provenance, dir)["package_version"] == "unknown"
    end
    mktempdir() do dir
        path = joinpath(dir, "snap.toml")
        write_toml(path, Dict("stage" => Dict("a" => 1)))
        snap = TOML.parsefile(path)
        @test snap["stage"]["a"] == 1
        @test haskey(snap, "hardware") && haskey(snap, "git") && haskey(snap, "written_at")
        write_toml(path, Dict("stage" => Dict("a" => 2)))
        @test TOML.parsefile(path)["stage"]["a"] == 2
        @test TOML.parsefile(joinpath(dir, "snap_#1.toml"))["stage"]["a"] == 1
        @test backup_existing!(joinpath(dir, "absent.toml")) === nothing
        csv = joinpath(dir, "t.csv")
        write_csv(csv, DataFrame(x = [1, 2]))
        write_csv(csv, DataFrame(x = [3]))
        @test nrow(CSV.read(csv, DataFrame)) == 1 && isfile(joinpath(dir, "t_#1.csv"))
        plain = joinpath(dir, "plain.toml")
        write_toml(plain, Dict("k" => "v"); tag = false)
        @test !haskey(TOML.parsefile(plain), "git")
    end
    @test occursin("Time", sprint(report_timing))

    # Resolved environment: manifests are not tracked, so the digest in every
    # tagged record and the copy in the run directory carry it instead.
    manifest = active_manifest_path()
    @test manifest !== nothing && isfile(manifest)
    @test dirname(manifest) == dirname(Base.active_project())
    digest = manifest_sha256()
    @test occursin(r"^[0-9a-f]{64}$", digest)
    env = provenance()["environment"]
    @test Set(keys(provenance())) ==
          Set(["hardware", "git", "layers", "environment", "written_at"])
    @test env["manifest_sha256"] == digest
    @test !isabspath(env["active_project"])
    # Packages of the pipeline: this one first, tracked by path in the test
    # environment, so with the git state of its directory
    layers = layer_provenance()
    @test first(layers)["name"] == "StreamingInference"
    @test first(layers)["version"] == string(pkgversion(StreamingInference))
    @test first(layers)["git_commit"] == g["git_commit"]
    @test !isabspath(first(layers)["path"])
    @test [l["name"] for l in provenance()["layers"]] == [l["name"] for l in layers]
    mktempdir() do dir
        synthetic = joinpath(dir, "Manifest.toml")
        write(
            synthetic,
            """
            julia_version = "1.13.1"
            manifest_format = "2.0"

            [[deps.Domain]]
            deps = ["StreamingInference"]
            git-tree-sha1 = "bbbb"
            uuid = "00000000-0000-0000-0000-000000000001"
            version = "1.2.3"

            [[deps.Method]]
            path = "sub/../method"
            uuid = "00000000-0000-0000-0000-000000000002"
            version = "0.3.0"

                [deps.Method.deps]
                Domain = "00000000-0000-0000-0000-000000000001"

            [[deps.StreamingInference]]
            deps = ["TOML"]
            git-tree-sha1 = "aaaa"
            repo-rev = "1111"
            repo-url = "https://example.org/StreamingInference.jl.git"
            uuid = "16c4c904-5ec2-451a-8da3-97d89c4aed49"
            version = "0.1.0"

            [[deps.TOML]]
            uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
            version = "1.0.3"

            [[deps.Unrelated]]
            deps = ["TOML"]
            uuid = "00000000-0000-0000-0000-000000000003"
            version = "9.9.9"
            """,
        )
        records = layer_provenance(synthetic)
        @test [r["name"] for r in records] == ["StreamingInference", "Domain", "Method"]
        @test records[1] == Dict(
            "name" => "StreamingInference",
            "version" => "0.1.0",
            "tree_hash" => "aaaa",
            "revision" => "1111",
            "url" => "https://example.org/StreamingInference.jl.git",
        )
        @test records[2] ==
              Dict("name" => "Domain", "version" => "1.2.3", "tree_hash" => "bbbb")
        # A path outside any repository has no established git state
        @test records[3]["path"] == "method"
        @test records[3]["git_commit"] == "unknown" && records[3]["git_dirty"]
        @test isempty(layer_provenance(joinpath(dir, "absent.toml")))
        write(synthetic, "[[deps.TOML]]\nversion = \"1.0.3\"\n")
        @test isempty(layer_provenance(synthetic))
    end
    mktempdir() do dir
        target = snapshot_manifest(joinpath(dir, "run"))
        @test target == joinpath(dir, "run", "manifest_snapshot.toml")
        @test read(target) == read(manifest)
        snapshot_manifest(joinpath(dir, "run"))
        @test isfile(joinpath(dir, "run", "manifest_snapshot_#1.toml"))
        @test read(target) == read(manifest)
    end
end

@testset "Product identity" begin
    p = Dict{String,Any}("b" => 2, "a" => [1.0, 2.0])
    q = Dict{String,Any}("a" => [1.0, 2.0], "b" => 2)
    @test parameter_digest(p) == parameter_digest(q)
    @test length(parameter_digest(p)) == 64 &&
          all(in("0123456789abcdef"), parameter_digest(p))
    @test parameter_digest(merge(p, Dict{String,Any}("b" => 3))) != parameter_digest(p)
    table = product_table("features"; channels = "A", parents = Dict("source" => "x"))
    @test table["kind"] == "features" && table["channels"] == "A" && table["schema"] == 1
    @test table["parents"] == Dict{String,Any}("source" => "x")
    @test_throws ArgumentError product_table("features"; channels = "A", schema = 0)
    mktempdir() do dir
        path = joinpath(dir, "record.bin")
        write(path, "abc")
        digest = content_digest(path)
        # FIPS 180-2 reference value: SHA-256 of "abc"
        @test digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        # Location and modification time leave the identity unchanged, other
        # content changes it
        moved = joinpath(dir, "moved.bin")
        cp(path, moved)
        touch(path)
        @test content_digest(path) == content_digest(moved) == digest
        write(path, "abd")
        @test content_digest(path) != digest
    end
end

@testset "Figures (CairoMakie extension)" begin
    # Plain-decimal labels of a sparse logarithmic axis: below unity the
    # mantissa follows the leading zeros (0.2, not "2.1").
    ext = Base.get_extension(StreamingInference, :StreamingInferenceCairoMakieExt)
    @test ext !== nothing
    SI = StreamingInference
    @test SI.decade_label.([-2, -1, 0, 1, 2]) == ["0.01", "0.1", "1", "10", "100"]
    @test SI.decade_label(-1, 2) == "0.2"
    @test SI.decade_label(-2, 5) == "0.05"
    @test SI.decade_label(1, 2) == "20"
    @test ext.count_ticks(134) == [0, 50, 100] && ext.count_ticks(23) == [0, 5, 10, 15, 20]
    @test ext.count_ticks(1) == [0, 1] && ext.count_ticks(0) == [0]
    @test_throws ArgumentError ext.count_ticks(-1)
    @test SI.dense_log_ticks(0.35, 37.0) ==
          ([0.5, 1.0, 2.0, 5.0, 10.0, 20.0], ["0.5", "1", "2", "5", "10", "20"])
    @test SI.dense_log_ticks(1e-3, 1e3) == SI.log_ticks(1e-3, 1e3)
    # Alert labels: a right-hand label that would cover the next marker moves
    # to the left, and so does one that would leave the axis
    @test ext.alert_label_placement([0.5, 0.56], [0.5, 0.52], ["−27.8 h", "−21.1 h"]) ==
          [:above_left, :above_right]
    @test ext.alert_label_placement([0.95], [0.5], ["15.1 h"]) == [:above_left]
    @test_throws DimensionMismatch ext.alert_label_placement([0.1], [0.1, 0.2], ["a"])
    @test_throws ArgumentError SI.decade_label(0, 10)
    values, ticklabels = SI.log_ticks(0.15, 3.0)
    @test values == [0.2, 0.5, 1.0, 2.0]
    @test ticklabels == ["0.2", "0.5", "1", "2"]
    values, ticklabels = SI.log_ticks(0.01, 100.0)
    @test ticklabels == ["0.01", "0.1", "1", "10", "100"]

    rng = StableRNG(21)
    n = 2000
    labels = zeros(Int, n)
    labels[400:500] .= 1
    labels[1200:1350] .= 1
    probs = clamp.(0.3 .+ 0.08 .* randn(rng, n) .+ 0.3 .* labels, 0, 1)
    snrs = 8 .+ 40 .* rand(rng, n) .* labels
    decisions = Int.(probs .>= 0.55)
    fpr, tpr, _ = roc_curve(labels, probs)
    @test figure_roc(fpr, tpr, roc_auc(fpr, tpr)) isa CairoMakie.Figure
    sweep = threshold_sweep(labels, probs; step_size = 432, sample_rate = 1.0)
    @test figure_threshold_sweep(sweep, 0.55; target_far_per_30d = 3.0) isa
          CairoMakie.Figure
    @test figure_threshold_sweep(
        sweep,
        0.55;
        target_far_per_30d = 3.0,
        operating_point = (n_detected = 2, n_events = 2, false_alarms_per_30d = 1.5),
    ) isa CairoMakie.Figure
    @test_throws ArgumentError figure_threshold_sweep(
        sweep,
        0.55;
        operating_point = (n_detected = 2,),
    )
    @test figure_threshold_sweep(sweep, Inf) isa CairoMakie.Figure
    # A block without negatives has no false alarm at any threshold
    clean = threshold_sweep(ones(Int, n), probs; step_size = 432, sample_rate = 1.0)
    @test all(==(0), clean.false_alarms_per_30d) && all(isnan, clean.fpr)
    @test figure_threshold_sweep(clean, 0.55; target_far_per_30d = 3.0) isa
          CairoMakie.Figure
    @test_throws ArgumentError figure_threshold_sweep(DataFrame(), 0.5)
    @test_throws ArgumentError figure_threshold_sweep(DataFrame(threshold = [Inf]), 0.5)
    @test figure_sensitivity(snrs, labels, decisions) isa CairoMakie.Figure
    @test figure_sensitivity(snrs, zeros(Int, n), decisions) === nothing
    @test figure_score_distribution(probs, 0.55; labels = labels) isa CairoMakie.Figure
    @test figure_score_distribution(probs, 0.55) isa CairoMakie.Figure
    # Score axes follow the scorer: by default they span the scores and the
    # threshold widened by 5 %; `score_range` fixes them
    @test all(
        isapprox.(StreamingInference.score_limits([0.2, 0.6], 0.4, nothing), (0.18, 0.62)),
    )
    @test all(
        isapprox.(
            StreamingInference.score_limits([2.0, 3.0, NaN], 5.0, nothing),
            (1.85, 5.15),
        ),
    )
    @test all(
        isapprox.(StreamingInference.score_limits([1.0, 1.0], 1.0, nothing), (0.95, 1.05)),
    )
    @test StreamingInference.score_limits([0.5], 0.5, (0, 1)) == (0.0, 1.0)
    @test_throws ArgumentError StreamingInference.score_limits([0.5], 0.5, (1, 0))
    @test figure_score_distribution(
        2 .+ probs,
        2.55;
        labels = labels,
        score_label = "RMS",
    ) isa CairoMakie.Figure
    roc = figure_roc(fpr, tpr, 0.9; label = "RMS")
    @test any(
        p -> p isa CairoMakie.Lines && p.label[] == "RMS, AUC 0.9",
        only(filter(a -> a isa CairoMakie.Axis, roc.content)).scene.plots,
    )
    # Alert figure: of two alerts close in mission time and in latency, the
    # lower one is labelled beneath its marker; labels give the data latency
    # t_alarm − t_merger with a typographic minus.
    epoch = DateTime(2035, 1, 1)
    content_end = [epoch + Hour(3i) for i in 1:200]
    alert_windows = DataFrame(
        content_end = content_end,
        complete_at = content_end .+ Hour(30),
        score = rand(StableRNG(7), 200),
        decision = rand(StableRNG(8), 0:1, 200),
    )
    alert_rows = DataFrame(
        detected = [true, true, true, false],
        t_alarm = Union{Missing,DateTime}[
            epoch+Hour(75),
            epoch+Hour(78),
            epoch+Hour(410),
            missing,
        ],
        t_merger = [epoch + Hour(h) for h in (100, 106, 400, 500)],
    )
    alert_figure = figure_telemetry_alerts(
        alert_windows,
        0.5;
        epoch = epoch,
        label_spans = [(epoch + Hour(90), epoch + Hour(100))],
        latencies = alert_rows,
    )
    @test alert_figure isa CairoMakie.Figure
    ax_latency = only(
        filter(
            a -> a isa CairoMakie.Axis && a.ylabel[] == "Latency [h]",
            alert_figure.content,
        ),
    )
    alert_labels = Dict(
        first(vcat(p.text[])) => p.align[] for
        p in ax_latency.scene.plots if p isa CairoMakie.Text
    )
    @test alert_labels == Dict(
        "−25.0 h" => (:left, :bottom),
        "−28.0 h" => (:left, :top),
        "10.0 h" => (:left, :bottom),
    )
    y_limits = ax_latency.limits[][2]
    @test y_limits[1] < -28 && y_limits[2] > 30
    # Scores beyond the unit interval stay inside the score axis
    rms_windows = transform(alert_windows, :score => (s -> 2 .* s .+ 1) => :score)
    rms_figure = figure_telemetry_alerts(
        rms_windows,
        2.0;
        epoch = epoch,
        latencies = alert_rows,
        score_label = "RMS",
        event_label = "Merger",
    )
    ax_rms =
        only(filter(a -> a isa CairoMakie.Axis && a.ylabel[] == "RMS", rms_figure.content))
    lo, hi = ax_rms.limits[][2]
    @test lo < minimum(rms_windows.score) && hi > maximum(rms_windows.score)
    @test_throws ArgumentError figure_telemetry_alerts(
        alert_windows[1:0, :],
        0.5;
        epoch = epoch,
    )
    # The base layout: a 900 × 600 pt single panel, 350 pt per further main
    # panel, 180 pt per auxiliary strip
    @test_throws ArgumentError figure_theme(; size = (0, 600))
    @test_throws ArgumentError figure_theme(; fontsize = 0)
    theme = figure_theme()
    @test theme.size[] == (900, 600) && theme.fontsize[] == 26
    @test figure_size() == (900, 600)
    @test figure_size(2) == (900, 950) && figure_size(1, 1) == (900, 780)
    @test figure_size(2, 2) == (900, 1310)
    @test_throws ArgumentError figure_size(0)
    @test_throws ArgumentError figure_size(1, -1)
    @test keys(FIGURE_STROKES) == keys(FIGURE_COLORS)
    mktempdir() do dir
        stem = joinpath(dir, "roc_curve")
        written = save_figure(figure_roc(fpr, tpr, 0.9), stem; run_id = "unit")
        @test written == ["$stem.pdf", "$stem.png"]
        @test all(isfile, written) && filesize("$stem.pdf") > 1000
        side = TOML.parsefile("$stem.toml")
        @test side["figure"]["run_id"] == "unit" && haskey(side, "git")
        # The sidecar records the canvas actually exported
        # (the ROC axis is square, on a canvas of the base height)
        @test side["figure"]["size_pt"][2] == 600 && !haskey(side["figure"], "width_mm")
        save_figure(figure_score_distribution(probs, 0.55), joinpath(dir, "single"))
        @test TOML.parsefile(joinpath(dir, "single.toml"))["figure"]["size_pt"] ==
              [900, 600]
        save_figure(figure_threshold_sweep(sweep, 0.55), joinpath(dir, "stacked"))
        @test TOML.parsefile(joinpath(dir, "stacked.toml"))["figure"]["size_pt"] ==
              [900, 950]
        save_figure(figure_roc(fpr, tpr, 0.9), stem; run_id = "unit")
        @test isfile(joinpath(dir, "roc_curve_#1.pdf"))
        @test_throws ArgumentError save_figure(
            figure_roc(fpr, tpr, 0.9),
            stem;
            formats = ("bmp",),
        )
    end
end

@testset "Animations (CairoMakie extension)" begin
    # Arrival out of mission order: two windows reach the ground swapped
    n = 12
    content_end = [DateTime(2035, 1, 1) + Dates.Minute(10 * k) for k in 1:n]
    arrival = content_end .+ Dates.Hour(3)
    arrival[3], arrival[4] = arrival[4], arrival[3]
    windows = DataFrame(
        window = 1:n,
        content_end = content_end,
        complete_at = arrival,
        coverage = fill(1.0, n),
        score = range(0.1, 0.9; length = n),
        decision = [k > 9 ? 1 : 0 for k in 1:n],
    )
    theme = animation_theme()
    @test all(isinteger, theme.size[])
    mktempdir() do dir
        stem = joinpath(dir, "mission_replay")
        written = save_animation(stem; run_id = "unit") do target
            animate_mission_replay(
                windows,
                0.8,
                target;
                n_frames = 3,
                framerate = 4,
                hold_frames = 0,
                label_spans = [(content_end[2], content_end[5])],
                score_range = (0.0, 1.0),
            )
        end
        @test written == "$stem.gif"
        @test isfile(written) && filesize(written) > 1000
        side = TOML.parsefile("$stem.toml")
        @test side["animation"]["run_id"] == "unit" && haskey(side, "git")
        # The sidecar records the frame size of the written GIF: the canvas
        # at the raster scale
        @test side["animation"]["frame_px"] == 2 .* collect(figure_size(2, 2))
        @test side["animation"]["px_per_unit"] == 2
        # An animation is written as GIF, and a fractional raster scale renders
        # frames the encoder does not reproduce
        @test_throws ArgumentError animate_mission_replay(
            windows,
            0.8,
            joinpath(dir, "replay.mp4"),
        )
        @test_throws ArgumentError animate_mission_replay(
            windows,
            0.8,
            joinpath(dir, "replay.gif");
            px_per_unit = 2.5,
        )
        @test_throws ArgumentError animate_mission_replay(
            select(windows, Not(:score)),
            0.8,
            joinpath(dir, "replay.gif"),
        )
        @test_throws ArgumentError animate_mission_replay(
            windows[1:1, :],
            0.8,
            joinpath(dir, "replay.gif"),
        )
    end
end

include("telemetry_tests.jl")
