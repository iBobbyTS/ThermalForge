# ThermalForge Roadmap

## Built Features

### Thermal Logging (Built)

Research-grade data export: `thermalforge log`

- CSV with all temperature sensors, fan RPM (actual + target), fan mode per sample
- Process CSV: top 5 processes by CPU at every sample
- JSON metadata: machine, OS, sensor dictionary, session info
- Configurable rate (1-10 Hz), duration, output directory
- Auto-delete after 24h by default, `--no-expire` for researchers

### Safety Systems (Built)

- 95°C safety override: forces max fans regardless of profile
- Per-profile sustained triggers (4-8 seconds) — filters transient spikes
- Heartbeat watchdog: daemon resets fans if app dies (15s timeout)
- Clean state on app launch: fans reset to auto before any profile activates
- Clean shutdown: fans reset on normal app quit
- SMC lock: serializes all fan control operations across daemon threads
- Duplicate instance prevention
- Temperature anomaly detection: instant spikes (>5°C in 2s) and sustained changes (>10°C in 30s) with 30-second rolling process buffer
- Error logging to ~/Library/Logs/ThermalForge/ (daily rotation, 7-day retention)

---

## Profile Redesign v2 (Complete)

Complete profile system redesign with per-profile curve shapes, ramp rates, sustained triggers, and a dual-cadence 100ms thermal tick. Each profile now has a distinct personality tuned to its purpose. Driven by thermal log analysis showing the previous uniform design failed catastrophically — the sustained trigger prevented Max from engaging fans while temps rocketed from 56°C to 98°C in 6 seconds.

### Research basis

Apple's fan hardware behavior (sources: macos-smc-fan reverse engineering, Tunabelly blog, NMB/Nidec fan motor engineering docs, Analog Devices fan controller datasheets):

- **0 to minimum RPM is binary** — fans jump from off to minimum (2317 RPM on M5 Max, 1200 on M1 Max, 1000 on Mac Studio). No slow start possible — brushless DC motors require a startup burst to overcome static friction. Hardware limitation, not software.
- **Above minimum, smooth ramping** — Apple ramps at ~350-550 RPM/sec up, ~150-300 RPM/sec down. Evaluated every 100ms with small increments.
- **Start/stop cycles are the #1 fan bearing wear factor** — fluid dynamic bearings suffer contact wear during startup (boundary lubrication before hydrodynamic film builds). Minimize on/off cycling.
- **Once spinning, keep spinning** — Apple holds fans at minimum RPM with hysteresis rather than cycling between 0 and spinning. At least 5°C hysteresis between start and stop thresholds.
- **Smoother transitions extend lifespan up to 50%** — per fan engineering literature. Abrupt speed jumps while running cause acoustic and mechanical transients.
- **Ramp-up rate while spinning is NOT a wear factor** — not documented by any fan motor source. Ramp governors are for acoustic comfort only (MAX31760, EMC2301, Microchip AN771).

### Dual-cadence architecture

Thermal polling now runs at 100ms (matching Apple's thermalmonitord) for smooth fan transitions. Heavy operations run at a slower 2-second cadence to avoid overhead:

| Cadence | Interval | Operations |
|---|---|---|
| **Thermal tick** | 100ms | Read temps, calculate curve, apply ramp governor, write fan speed |
| **Monitor tick** | 2 seconds (every 20th tick) | Process capture (sysctl), anomaly detection |
| **UI update** | 500ms (every 5th tick) | Push status to SwiftUI menu bar |

### Profile curve design

Each profile has three zones and a per-profile curve shape:

**Zone 1: Off** — below the stop threshold (50°C), fans stay at 0 RPM (Apple auto).
**Zone 2: Minimum hold** — between stop threshold and start threshold (hysteresis band), fans stay at minimum RPM if already running, stay off if already off.
**Zone 3: Proportional curve** — above the start threshold, fan speed scales from minimum RPM to the profile's max using the profile's curve shape.

**Curve shapes:**
- **Ease-in** (pos²): quiet at low temps, ramps harder as heat builds — used by Balanced
- **Linear** (pos): direct proportional response — used by Performance
- **S-curve** (pos²(3-2pos)): smooth at both ends
- **Instant engage**: binary on/off, no proportional curve — used by Max

### Profile specifications

| Profile | Fans off | Start | Ceiling | Max fan | Curve | Trigger | Ramp up | Ramp down |
|---|---|---|---|---|---|---|---|---|
| **Silent** | N/A | N/A | N/A | Apple | N/A | N/A | N/A | N/A |
| **Balanced** | 50°C | 55°C | 70°C | 60% | Ease-in | 8s | ~400 RPM/s | ~200 RPM/s |
| **Performance** | 50°C | 55°C | 65°C | 85% | Linear | 4s | ~800 RPM/s | ~300 RPM/s |
| **Max** | N/A | N/A | N/A | 100% | Always on | N/A | N/A | N/A |

**Balanced example curve (55-70°C, ease-in, 0-60% of max RPM):**
- 55°C (after 8s sustained): fans jump to minimum RPM (2317)
- 59°C: position 0.27, ease-in 0.07 → fans at ~4% of max RPM
- 62.5°C: position 0.50, ease-in 0.25 → fans at 15% of max RPM (~1172 RPM above min)
- 67°C: position 0.80, ease-in 0.64 → fans at 38% of max RPM
- 70°C: fans at 60% of max RPM (~4696 RPM) — cap reached
- Below 50°C and stable: fans off

The ease-in curve keeps Balanced quiet at low temperatures — at the midpoint, fans are at only 15% instead of the 30% a linear curve would give.

**Max behavior:**
- Always-on: fans pinned at 100% at any temperature — no trigger, no hysteresis, no proportional zone
- Engages within one thermal tick (~100ms) of selecting the profile
- Stays at 100% until another profile (or Default) takes over

**Silent (Apple Default)** is purely hands-off: ThermalForge monitors temperatures but Apple controls the fans entirely.

### What was built

1. Added CurveShape enum (linear, easeIn, easeOut, sCurve) and per-profile curve shape application in targetPercent()
2. Added per-profile ramp rates (rampUpPerSec, rampDownPerSec) to Curve struct
3. Added per-profile sustained trigger duration (sustainedTriggerSec) to Curve struct
4. Added instantEngage flag for Max — skips ramp-up governor entirely
5. Switched thermal tick from 2000ms to 100ms for smooth fan transitions
6. Split tick() into dual-cadence: 100ms thermal + 2s monitor (process capture, anomaly detection)
7. UI updates gated to 500ms cadence to avoid excessive redraws
8. Redesigned Max as "attack dog": instant 100% at 65°C, gentle ramp-down governor
9. Redesigned Balanced with ease-in curve for quiet low-temp operation
10. Redesigned Performance with linear curve and 2× ramp-up speed
11. Updated all tests for new profile parameters, curve shapes, and per-profile behavior
12. Updated MenuBarView labels: Max shows "65°C instant", others show start→ceiling range
13. Updated all documentation

---

## Planned Features

### Enhanced Logging

Additional data points for research-grade logging:

- **Thermal throttle state** — `ProcessInfo.thermalState` (nominal/fair/serious/critical) and `com.apple.system.thermalpressurelevel` (5 levels). Captured at every sample.
- **Power draw** — SMC power keys (PSTR, PCPT, PCPG) for package and per-domain wattage.
- **GPU utilization** — Metal performance statistics or IOKit GPU activity.
- **Memory pressure** — system memory pressure percentage.
- **Delta-T over ambient** — temperatures as both absolute °C and delta above ambient. Standard comparison metric (Gamers Nexus, Notebookcheck, Jarrod's Tech).
- **User markers** — `thermalforge mark "started render"` inserts annotated timestamp into active session.
- **Statistical summary** — min, max, mean, std dev, P95, P99 for all sensors. Time in each thermal state. Peak fan RPM.

Sources: Gamers Nexus methodology, Notebookcheck stress tests, NASA MIL-STD-1540E, Apple WWDC 2019 Session 422.

### Experiment Mode

Controlled thermal testing framework. No existing macOS tool offers this.

```bash
thermalforge experiment --workload cpu --fan balanced --duration 10m --label "balanced-baseline"
thermalforge experiment --workload gpu --fan 75%  --duration 10m --label "gpu-fixed-75"
thermalforge compare balanced-baseline gpu-fixed-75
```

- Built-in workloads: CPU, GPU (Metal compute), CPU+GPU combined, idle baseline
- Custom command as workload
- Automatic baseline capture (5 min idle before/after)
- Steady-state detection (<0.5°C over 2 minutes)
- Throttle detection with exact timestamps
- A/B comparison reports with statistical significance
- Delta-T over ambient

Sources: Gamers Nexus, Notebookcheck, Jarrod's Tech, Phoronix Test Suite, NASA/JEDEC.

### Community Thermal Database

Opt-in anonymous upload of experiment results. Modeled after OpenBenchmarking.org.

- Anonymous machine fingerprinting (chip + core count + fan count, never serial number)
- Standardized experiment profiles for cross-machine comparison
- Delta-T over ambient as comparison metric
- "Compare my machine" queries
- Community validation and outlier detection
- Local-first: all data stored locally, upload always opt-in

### Update Notifications

Lightweight version check on app launch.

- Hit GitHub releases API, compare against running version
- Show "Update available" in menu bar dropdown with link
- Non-intrusive — no popups
- Homebrew: `brew upgrade thermalforge`
- Future: Sparkle framework for in-place auto-update (requires Xcode project)

### SEO / AI Discoverability

- GitHub topics set (18 topics)
- Repo description keyword-optimized
- README structured for AI extraction
- Consider: GitHub Discussions, blog post, landing page

### Other

- **Control Center widget** — requires Xcode project + WidgetKit
- **FORGE process auto-detection**
