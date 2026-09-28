# ThermalForge

**Free, open-source fan control for Apple Silicon Macs.** Menu bar app + CLI.

Built in 2026 with Swift. No subscriptions, no telemetry, no ads.

[![CI](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml/badge.svg)](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-orange)](https://support.apple.com/en-us/116943)

---

## Why ThermalForge?

Tools like **Macs Fan Control** and **TG Pro** charge $15–$20 for fan control that hasn't fundamentally improved in years. Both require manual configuration, and both have documented problems on Apple Silicon.

| Feature | ThermalForge | Macs Fan Control | TG Pro |
|---|---|---|---|
| Multi-sensor safety | **Yes — all sensors** | [One sensor per fan](https://github.com/crystalidea/macs-fan-control/issues/266) | Manual rules only |
| Proactive cooling (ramps before throttle) | **Yes** | No | No |
| Fan curve type | Per-profile shapes (ease-in, linear, S-curve, instant) | Linear between 2 points | Manual step-function |
| Real-time temp monitoring | Yes | Yes | Yes |
| Menu bar app | Yes | Yes | Yes |
| CLI access | **Yes** | No | No |
| Thermal data logging (CSV) | **Yes** | No | Yes |
| Process correlation in logs | **Yes** | No | No |
| Sleep/wake re-apply | Yes | Yes | Yes |
| Safety override (95°C, sustained) | **Yes — daemon-enforced, works with app closed** | No | Requires manual setup |
| Crash recovery (heartbeat watchdog) | **Yes — daemon-enforced, holds during overheat** | Reverts on quit only | Override removes macOS safety |
| Open source | **Yes** | No | No |
| Price | **Free** | $15 | $20 |

### Known problems with alternatives

**Macs Fan Control** monitors only one temperature sensor per fan. Users have reported [GPU overheating while monitoring CPU only](https://github.com/crystalidea/macs-fan-control/issues/266), leading to system lockups. Fan control is [broken on M3/M4 Pro and Max](https://github.com/crystalidea/macs-fan-control/issues/785) due to Apple firmware changes.

**TG Pro** offers more flexibility but requires users to manually configure step-function rules for each fan speed threshold. Its "Override System" mode removes macOS thermal safety entirely — if your rules are wrong, there's no backstop.

**AlDente Pro** ($30) is a battery management tool with no fan control features. It monitors battery temperature and pauses charging — it does not control fans.

## Features

- Real-time CPU, GPU, RAM, SSD, and ambient temperatures in the menu bar
- Four fan profiles with proportional curves (not binary on/off)
- Thermal logging — CSV + JSON data export with process correlation for research
- Automatic fan re-apply after sleep/wake
- Fahrenheit / Celsius toggle
- Safety override: fans go to maximum when a critical sensor *stays* above 95°C for 2 seconds while a manual hold is keeping them too low — a momentary single-core boost spike won't trigger it. Enforced in the daemon (works with the app closed) and mirrored in the app's monitor with a 5°C release hysteresis. In Silent (Apple Default) ThermalForge never seizes control at all: Apple's own thermal management is the safety there
- Crash recovery: the daemon's heartbeat watchdog resets fans to Apple defaults if the app dies — and if a thermal safety override is active, it holds fans at max and defers the reset until the machine cools, so it never hands hot fans back to auto
- Temperature anomaly detection: logs instant spikes (>5°C in 2s) and sustained changes (>10°C in 30s) with process capture
- Privileged daemon — one-time sudo, zero password prompts after
- Native Swift — lightweight, no Electron, no bloat

## Profiles

Balanced and Performance use proportional curves with per-profile curve shapes — fans ramp gradually with temperature, not as binary switches. Max is the exception: fans pinned at 100% with no temperature conditions. The temperature-gated profiles share a unified 50°C off threshold (matching Apple's observed behavior) and each has its own sustained trigger duration — fans only engage after temperature stays above the start threshold for a profile-specific number of seconds, filtering transient spikes that resolve on their own. Reacting to transient spikes would cause the start/stop cycling that is the #1 cause of fan bearing wear (source: [Analog Devices fan control](https://www.analog.com/en/analog-dialogue/articles/how-to-control-fan-speed.html)).

Thermal polling runs at 100ms (matching Apple's own thermalmonitord cadence) for smooth fan transitions. Each profile has its own ramp rates and curve shape tuned to its purpose. Ramp governor design sourced from [MAX31760 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/max31760.pdf) and [Microchip AN771](https://ww1.microchip.com/downloads/en/appnotes/00771a.pdf).

| Profile | Fans off | Fans start | Ceiling | Max fan | Curve | Sustained trigger | Behavior |
|---|---|---|---|---|---|---|---|
| **Silent (Apple Default)** | N/A | N/A | N/A | Apple | N/A | N/A | Monitoring only. Apple controls fans. |
| **Balanced** | 50°C | 55°C | 70°C | 60% | Ease-in (pos²) | 8 seconds | Quiet at low temps, ramps harder as heat builds. |
| **Performance** | 50°C | 55°C | 65°C | 85% | Linear | 4 seconds | Direct proportional response, 2× ramp-up speed. |
| **Max** | N/A | N/A | N/A | 100% | Always on | N/A | Fans pinned at 100% until you switch profiles or press Default. |

**How profiles work:**
- **Below 50°C:** All fans off. Machine is at idle. (Does not apply to Max.)
- **50°C–start (hysteresis zone):** Fans maintain current state. Already running → stay at minimum. Already off → stay off. (Does not apply to Max.)
- **Above start for N seconds:** Fans engage. Balanced and Performance ramp proportionally using their curve shape.
- **Max:** No temperature conditions — fans pin at 100% immediately (within one 100ms tick) and stay there until you switch profiles or press Default.
- **Between start and ceiling:** Fan speed scales based on the profile's curve shape. Balanced (ease-in) is quiet at low temps — at 62.5°C (midpoint of 55–70°C), fans run at only 15% of max RPM instead of 30% linear. Performance (linear) is proportional.
- **At ceiling and above:** Fan speed at the profile's maximum (60%/85%).
- **Ramp down:** Balanced and Performance each have their own ramp-down rate.
- **0 to minimum RPM is binary:** Apple Silicon MacBook fans cannot spin below their minimum RPM (2317 on M5 Max, 1200 on M1 Max). When a profile engages, fans jump directly to minimum — a hardware limitation of brushless DC motors that require a startup burst to overcome static friction. Above minimum, all speed changes are smooth and governed.

## Install

### Option A: Homebrew (recommended)

```bash
brew tap ProducerGuy/tap
brew trust --formula ProducerGuy/tap/thermalforge
brew install thermalforge
sudo thermalforge install
```

Homebrew requires third-party taps to be trusted before it will run their formula, which is the `brew trust` step (per-formula, Homebrew's recommended form). `brew install` builds and installs the **CLI**. `sudo thermalforge install` then sets up the background daemon (so the app can control fans without a password every time) **and copies the menu bar app into `/Applications`**. You only run it once.

### Option B: From source

```bash
git clone https://github.com/ProducerGuy/ThermalForge.git
cd ThermalForge
./setup.sh
```

Builds everything, installs the CLI, creates the menu bar app in `/Applications`, and sets up the daemon. One password prompt, fully automatic.

### After install

Open ThermalForge from Spotlight, Finder (Applications > ThermalForge), or terminal:

```bash
open /Applications/ThermalForge.app
```

Turn on **Launch at Login** in the menu bar dropdown and it starts automatically on every boot.

## Security

ThermalForge controls fans through a background daemon, and 0.2.0 locks down how you talk to it:

- **Private control socket.** The daemon listens on `/var/run/thermalforge.sock`, mode `0600`, owned by the user who ran `sudo thermalforge install`. Only that user and root can send fan commands — no other local account can drive your fans.
- **Structured, versioned protocol.** The CLI, app, and daemon speak a size-capped, versioned message format. Oversized or malformed input is rejected rather than parsed, and a version mismatch surfaces as an "Update needed" prompt instead of silent divergence.
- **Safety enforced in the daemon.** RPM requests above a fan's maximum are clamped in the daemon, not just the app. Commands are rate-limited. A thermal floor forces fans to maximum when a critical sensor stays above 95°C for 2 seconds while a manual hold is keeping them too low — and it runs in the background service, so it works even with the menu bar app closed.
- **Robust connection handling.** Connections are handled concurrently, bounded, and timed out, so a stuck or slow client can't stall fan control.

## FAQ

**What if ThermalForge closes during normal use?**
The daemon's heartbeat watchdog detects the app is gone within 15 seconds and resets fans to Apple defaults. On next launch, the app syncs to whatever the daemon is currently holding rather than forcing a reset — so a hold you set deliberately (e.g. `sudo thermalforge max`) survives. If a thermal safety override is active when the app dies, the watchdog keeps fans at maximum and defers the reset until the machine has cooled below the safety threshold — it never drops fans back to auto while the machine is hot.

## Resets and troubleshooting

**Reset fans right now:**
```bash
thermalforge auto
```
Resets the fans to Apple defaults and leaves your menu bar app running. Add `--stop-app` if you also want to quit the app so the reset sticks — otherwise a running profile re-applies its curve within seconds. With `--stop-app` the menu bar icon disappears (that's expected); relaunch from Spotlight or `/Applications` when you're done.

**Fans loud and won't stop? Reset them now:**
```bash
sudo killall ThermalForgeApp; sudo /usr/local/bin/thermalforge auto
```
This always works, even if the app isn't running. It stops ThermalForge and hands fan control straight back to macOS — your fans will settle to normal within a few seconds. It writes directly to the hardware, so it doesn't depend on the app or the background service being healthy.

**Completely remove ThermalForge:**
```bash
sudo thermalforge uninstall
```
Removes the daemon, binary, app, and all logs. Clean slate.

If installed via Homebrew, run `brew uninstall thermalforge` first.

**"Update needed" after a Homebrew upgrade:** `brew upgrade` updates the app and CLI, but the background daemon keeps running the old build until you re-sync it. While they differ, the menu bar shows an **"Update needed"** banner and the CLI prints a version-mismatch warning, both naming the two versions. Fix it once with `sudo thermalforge install`; the banner clears when they match again.

### Disclaimer

ThermalForge is provided as-is with no warranty. Use at your own risk.

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans — no sudo when the daemon is running
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM — no sudo when the daemon is running
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch         # Monitor mode with auto-boost profiles (requires sudo)
thermalforge log           # Record thermal data to CSV (1Hz, auto-delete 24h)
thermalforge log --rate 10 --duration 1h --no-expire   # 10Hz for 1 hour, keep forever
```

`max` and `set` need root to unlock the fans, so when the daemon is installed they route through it and **don't need `sudo`**; without a daemon (e.g. an uninstalled from-source build) they write the hardware directly and need `sudo`. `auto` also routes through the daemon but never needed the unlock — resetting just hands control back to macOS. `watch` always needs `sudo` (it runs its own root monitor loop). Control a single fan with `--fan`, e.g. `thermalforge set 3000 --fan 1`.

Fans settle **near** a commanded target rather than exactly on it, so `status` and the menu bar report an RPM slightly above or below what you set — that's the live tach reading, not an error.

Set fans from the terminal and the menu bar app shows a **"Fans held from Terminal"** banner and pauses its automatic control so it won't fight you — press **Default** (or pick a profile) to release the hold.

## Compatibility

Tested on MacBook Pro M5 Max (Mac17,7). Should work on M1–M5 MacBooks.
Run `thermalforge discover` on your machine and [submit a compatibility report](../../issues/new?template=compatibility-report.md).

| Machine | Chip | Status |
|---|---|---|
| MacBook Pro 16" (2025) | M5 Max | Tested |
| Mac Studio (2022) | M2 Ultra | Tested |
| MacBook Pro 16" (2021) | M1 Max | Tested |
| MacBook Pro 16" M5 Pro (Mac17,8) | M5 Pro | Reported |
| MacBook Pro 14" M5 Pro (Mac17,9) | M5 Pro | Reported |
| MacBook Pro M4 Max (Mac16,5) | M4 Max | Reported |
| MacBook Pro M3 Max (2023, 128GB) | M3 Max | Reported |
| MacBook Pro 14" M2 Pro (2023) | M2 Pro | Reported |
| MacBook Pro 14" M2 Max (2023) | M2 Max | Reported |
| MacBook Pro M1 (2020) | M1 | Reported |

SMC key names vary across chip generations — ThermalForge auto-detects at startup. The `discover` command dumps all keys so we can verify what your hardware uses. The more machines tested, the more robust ThermalForge becomes.

## Uninstall

### Homebrew

```bash
brew uninstall thermalforge
sudo thermalforge uninstall
```

`thermalforge uninstall` removes the daemon, binary, app, user data, and all logs.

### From source

```bash
sudo thermalforge uninstall
```

This removes the daemon, binary, app bundle, user data, and all logs.

## Contributing

ThermalForge is a solo project but compatibility reports are hugely valuable. If you have an Apple Silicon Mac:

1. Install ThermalForge
2. Run `thermalforge discover --output discover.txt`
3. [Open a compatibility report](../../issues/new?template=compatibility-report.md) and attach the file

That's it. Every new machine tested makes ThermalForge better for everyone.

## Thermal Logging

No existing macOS tool exports structured thermal data with process correlation in a format designed for research. ThermalForge does.

### Who this is for

- **Data scientists** studying thermal behavior across Apple Silicon generations
- **Hardware engineers** validating cooling solutions or thermal pad mods
- **Developers** profiling how their apps affect system thermals
- **Researchers** who need reproducible, citable thermal data for papers

### What it captures

```bash
thermalforge log                                          # 1Hz, auto-delete after 24h
thermalforge log --rate 10 --duration 1h --no-expire      # 10Hz, 1 hour, keep forever
```

Each session produces a self-contained folder:

| File | Contents |
|---|---|
| **thermal.csv** | Timestamped readings from every detected temperature sensor, fan RPM (actual + target), fan mode, at every sample interval |
| **processes.csv** | Top 5 processes by CPU utilization at every sample — the missing link between thermal data and what caused it |
| **metadata.json** | Machine model, chip, OS version, ThermalForge version, fan count, RPM range, sample rate, complete sensor dictionary, session start/end, total sample count |

### Why this format

- **CSV + JSON sidecar** — loads directly in pandas, R, Excel, or any data tool without a custom parser
- **Raw SMC key names** — no friendly labels that could be wrong across chip generations. Cross-reference against Apple hardware documentation directly
- **Self-describing sessions** — every log folder contains everything needed to interpret the data. Hand it to someone with no context and they can work with it
- **Auto-delete by default (24h)** — prevents disk bloat for casual users. `--no-expire` for researchers who need to keep data

### Storage

ThermalForge has three types of stored data, all automatically managed:

**App log** (daily files in `~/Library/Logs/ThermalForge/`) — one file per day (`thermalforge-2026-04-05.log`). Records all app events: profile changes, fan commands, temperature spikes, safety overrides, sustained trigger events. Auto-deletes files older than 7 days on app launch. Each daily file is small and easy to open or share.

**Research session logs** (`thermalforge log` exports in `~/Library/Application Support/ThermalForge/logs/`) — CSV/JSON research data. Auto-delete after 24 hours by default. Use `--no-expire` to keep permanently.

Nothing accumulates indefinitely. All cleanup runs automatically on app launch.

## Future Specs

### Enhanced Logging

- **Thermal throttle state** — capture Apple's `ProcessInfo.thermalState` (nominal/fair/serious/critical) at every sample. Know exactly when and how hard the chip throttled.
- **Power draw** — SMC power keys (PSTR, PCPT) to capture wattage alongside temperature. Watts correlate directly with heat generation.
- **GPU utilization** — current logging captures CPU processes but GPU compute workloads (Metal, ML inference) are invisible. GPU utilization fills that gap.
- **Memory pressure** — system memory pressure percentage at every sample
- **Delta-T over ambient** — report temperatures as both absolute and delta above ambient. This is the standard comparison metric used by hardware reviewers (Gamers Nexus, Notebookcheck) because absolute temps vary with room temperature.
- **User markers** — annotate the log mid-session ("started render", "switched profile") so data points have context when analyzed later
- **Statistical summary** — min, max, mean, standard deviation, P95/P99 for all sensors across the session. Time spent in each thermal state. Peak fan RPM.

### Experiment Mode

A controlled testing framework for anyone who wants to understand their Mac's thermal behavior — modders validating thermal pad swaps, developers profiling their apps, engineers comparing cooling strategies.

```bash
thermalforge experiment --workload cpu --fan balanced --duration 10m --label "balanced-baseline"
thermalforge experiment --workload cpu --fan 75%  --duration 10m --label "fixed-75"
thermalforge compare balanced-baseline fixed-75
```

**Controlled variables:**
- Fan speed: any profile, or a fixed percentage
- Workload type: CPU stress, GPU stress (Metal compute), CPU+GPU combined, idle baseline, or any custom command
- Duration with automatic steady-state detection (temp change <0.5°C over 2 minutes)
- Ambient temperature input for Delta-T calculations

**Metrics generated per experiment:**
- Time-to-throttle — how long before the chip starts losing performance
- Time-to-steady-state — how long before temperature stabilizes
- Sustained performance score — average clock throughput over the test duration
- Statistical summary — mean, std dev, min, max, P95/P99 temps

**Comparison reports:**
- Side-by-side A/B results across experiments
- Automatic detection of statistically significant differences
- Export as CSV or formatted summary

**Built-in workloads:**
- CPU stress: saturates all cores with compute-bound work
- GPU stress: Metal compute shaders that load the GPU pipeline
- Combined: CPU + GPU simultaneously (the real-world worst case for Apple Silicon where CPU, GPU, and Neural Engine share the same die and unified memory)
- Idle baseline: 5-minute idle measurement before and after tests to establish reference

### Community Thermal Database

Opt-in anonymous upload of experiment results. Compare your machine against others with the same chip. See how your M5 Max thermal performance ranks against the distribution. Modeled after [OpenBenchmarking.org](https://openbenchmarking.org) — standardized methodology, community validation, machine fingerprinting by chip model (not serial number).

See [ROADMAP.md](ROADMAP.md) for full specs and build plans.

## License

[MIT](LICENSE) — free to use, modify, and distribute.
