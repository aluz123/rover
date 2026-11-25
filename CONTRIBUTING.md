# Contributing to Rover

Thanks for helping. Rover is small on purpose: plain Swift, no dependencies, builds with just the Command Line Tools.

```bash
./scripts/build.sh          # builds dist/Rover.app
python3 bench/phrases.py    # plain-English checks against a fake home folder
```

- **Search changes** (`Sources/RoverCore/Query.swift`, `Search.swift`): add a case to `bench/phrases.py`, and if you can, run `python3 bench/vs_spotlight.py` before and after and paste both summaries in the PR.
- **Keep it fast.** A search should stay in the low milliseconds on a few hundred thousand files.
- **Keep it private.** Nothing leaves the Mac unless the person asks the assistant something.
- Don't include your own file names in tests or screenshots; use `launch/demo/make_home.py` and `ROVER_DEMO_HOME`.
