<p align="center"><img src="assets/icon.png" width="128" alt="Rover"></p>

<h1 align="center">Rover</h1>
<p align="center"><b>Find any file the way you remember it.</b><br>
Free, open-source file search for your Mac. Press <kbd>⌥</kbd> <kbd>Space</kbd>, type like you talk, found in about 2 ms.</p>

<p align="center">
  <a href="https://github.com/aluz123/rover/releases/latest/download/Rover.zip"><b>Download for Mac</b></a> ·
  <a href="https://getrover.dev/">Website</a> ·
  <a href="#benchmark-vs-spotlight">Benchmark</a> ·
  <a href="#build">Build from source</a>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-1b1452?style=flat-square">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-1b1452?style=flat-square">
  <img alt="MIT License" src="https://img.shields.io/badge/license-MIT-ff8a3d?style=flat-square">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-3cf2d0?style=flat-square">
</p>

<p align="center"><a href="https://getrover.dev/"><img src="docs/assets/demo.gif" width="900" alt="Rover finding “latest pitch deck short”: newest first, decks only, short versions preferred"></a></p>

<p align="center"><sub>Built by <b>Alex Towfigh</b> · MIT License · results shown are Rover’s real output on a demo folder</sub></p>

---

## Install

1. [Download Rover](https://github.com/aluz123/rover/releases/latest/download/Rover.zip), unzip it, and drag **Rover** into Applications.
2. Open it. Rover isn’t notarized by Apple yet, so the first time macOS will block it: open **System Settings → Privacy & Security** and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/Rover.app`.)
3. Rover shows a one-click setup for file access, indexes your Mac in a few seconds, and lives in the menu bar. Press **⌥ Space**.

Prefer to build it yourself? It takes one command; see [Build](#build).

## Why it's better than Spotlight

- **Fast.** Its own index searches 225,000 files in 1 to 2 ms, and results update as you type. Built in Swift with no dependencies.
- **Understands plain English.** `pdf from last week`, `big videos`, `invoice in downloads`, `screenshots yesterday`, `tax 2024`, `.py newest`. It shows what it understood as small chips under the search box. Describing words help without being required: `latest pitch deck short` finds the newest short pitch deck, and "short" also matches names like *2min pitch* or *one-pager*. If no file has every word, you get the closest matches instead of nothing.
- **Talk to it normally, no AI needed.** `can you find the deck I made a couple weeks ago`, `stuff I downloaded this morning`, `photos from last summer`, `invoices since march`, `contracts before 2025`, `videos from last weekend`. Chatty words are dropped, and number words and date phrases are understood. A hand-built list of file words that mean the same thing (`cv`/`resume`, `contract`/`agreement`, `tax`/`W-2`/`1099`, `quote`/`estimate`) and word roots (`presented` → *Presentation*) do the rest, all in under 15 ms. `python3 bench/phrases.py` checks 21 phrases like these.
- **Your files first.** Copies inside toolkits, SDKs, caches and other-language resource folders still show up, but below your own documents.
- **Forgives you.** Typos (`recieve`), initials (`tr24` → `Tax_Return_2024`), plurals and camelCase all work. When nothing matches, it tries related words on-device (`invoice` → `receipt`, `billing`).
- **Looks inside files.** Put words in "quotes", or let it fall back to Spotlight's content index when names don't match.
- **Learns.** Files you open, and the words you used to find them, rise to the top next time.
- **Indexes the right places.** Home folder, iCloud Drive and Apps, without the junk (`node_modules`, `.git`, caches, Library). It stays current live through FSEvents.

## Find it, look at it, move it

| Key | Does |
| --- | --- |
| ↩ | Open |
| ⌘↩ | Show in Finder (opens the folder with the file selected) |
| ⌘M | **Move to…** Type a folder name, press ↩. Type `~/Documents/New Folder` to create one. |
| ⌘R | Rename |
| ⌘⌫ | Move to Trash |
| ⌘Z | Undo the last move, rename or Trash |
| ⇧↑ ⇧↓, ⌘-click | Select several files |
| Space | Quick Look, like Finder: point at a result (or move with ↑↓) and press Space. Space again closes it, and ↑↓ flip through results while it's open. While you're typing, Space is just a space. ⌘Y always works too. A live preview pane is always on the right (⌘P toggles it). |
| ⌥↩ | Copy path · ⌘⇧C copy the file itself |
| ⌘1…9 | Open result 1–9 |
| Drag | Drag any result into another app or a Finder window |
| Right-click | Everything above, from a menu |

## Free up space

Menu bar → **Free Up Space…** (or type `free up space` and press ↩). Rover lists what's taking space and hasn't been touched in ages, grouped so it's easy to decide:

- **Old installers**: disk images and packages you already used (30+ days).
- **Duplicate copies**: same name and size, untouched for 3 months; the most recently used copy stays.
- **Apps you haven't opened in 6 months** (never Apple's own).
- **Old videos and screen recordings** (100 MB+, 6 months), **big files untouched for a year** (200 MB+), and **old downloads** you never opened again.

Choose what goes, then **Move to Trash** or **Move to Backup Drive** (copied into `Rover Backup/` on the drive with the same folders, each copy checked, then the original goes to the Trash). Nothing is ever permanently deleted and ⌘Z undoes it. Rover never suggests iCloud files, code projects (folders with `.git`), or libraries other apps manage (Music, Photos, TV). `rover junk` shows the same report in the terminal.

## Ask Rover (Tab)

Press **⇥ Tab** to ask in your own words:

- "Which PDF has my lease renewal date?"
- "Find the photo of my passport"
- "Sort my Downloads into folders by type"
- "From now on, move screenshots off my Desktop into Pictures/Screenshots"

Rover searches, reads documents and photos, and answers with clickable files. **No API key needed:** it uses your existing [Claude Code](https://claude.com/claude-code) login. Optionally, add a Claude API key from the menu bar icon for faster answers.

**It never changes anything on its own.** Moves, renames and Trash come back as a plan that you approve with one click (or ⌘↩), and ⌘Z undoes it. There is no permanent delete, and it won't touch Library, apps, or anything outside your home folder.

### Automations

Ask for "from now on…" and Rover sets up a rule that runs by itself while the app is open. Examples: new invoice PDFs in Downloads go to Documents/Invoices; installers older than 30 days go to the Trash. Every automatic move is undoable. You can see, pause or remove rules from the menu bar icon.

## Benchmark vs Spotlight

`bench/vs_spotlight.py` picks 80 random files from your Desktop, Documents, Downloads and iCloud Drive. It only picks files Spotlight has indexed, so the test isn't about coverage. For each file it generates the queries people type when they half-remember something: one word from the name, two words, a typo, a partial word, a word plus a kind ("pdf"), a date ("last month") or a folder ("in downloads"). Spotlight is measured through `mdfind`, which uses the same index as the Spotlight UI. There are two samples: **any file** (on a developer Mac that's mostly toolkit and SDK clutter) and **documents & media** (`SAMPLE=docs`: PDFs, slides, sheets, images, video, CAD, outside toolkit folders). Results from one Mac (225k files):

| | Rover, any file | Spotlight, any file | Rover, docs & media | Spotlight, docs & media |
| --- | --- | --- | --- | --- |
| Queries | 394 | 394 | 465 | 465 |
| Median search time | **2.0 ms** | 242 ms | **2.4 ms** | 242 ms |
| Slowest 5% | **14 ms** | 5.1 s | **15 ms** | 3.4 s |
| Right file found at all | **97%** | 54% | **95%** | 58% |
| Right file in top 5 | **37%** | 5% | **47%** | 8% |
| Right file at #1 | **16%** | 1.3% | **20%** | 5.8% |
| …with a typo, found at all | **91%** | 9% | **92%** | 2% |
| …with folder words, found at all | **92%** | 1% | **88%** | 2% |
| …with date words, found at all | **100%** | 29% | **99%** | 14% |

The docs & media sample leaves out junk nobody searches for (Office `~$` lock files, CAD/PCB history copies, files in toolkit, cache and log folders).

Caveats: `mdfind` doesn't return results in the Spotlight UI's ranked order, so the top-5 and #1 rows understate Spotlight. "Found at all" doesn't depend on order, so that row is the fair comparison. With only one word from the name, both tools find the file 98–100% of the time. Kind words like "photo" or "presentation" now also find files named with them. One word is still hard to rank when hundreds of files share it: Rover puts the file at #1 for 10% of documents and 9% of random files. Run it on your own Mac with `python3 bench/vs_spotlight.py` and `SAMPLE=docs python3 bench/vs_spotlight.py`.

## FAQ

**Why does Rover ask for Full Disk Access?**  
macOS hides folders like Documents, Desktop and Downloads from apps until you allow it. Rover reads file names (not contents) to build its index. You can also allow just Desktop, Documents and Downloads instead.

**Does anything leave my Mac?**  
No. The index lives on your Mac and holds names, dates and sizes only. The one exception is the optional assistant (⇥ Tab), which sends your question and file names to Claude only when you ask it something.

**Is there AI in the search?**  
No. Search is a fast index plus a plain-English parser, a hand-made synonym list and a ranking function, all in Swift with no dependencies. That is why it takes about 2 ms and works offline.

**How is it different from Spotlight, Raycast or Alfred?**  
Spotlight finds files if you remember their name. Raycast and Alfred are launchers that use Spotlight's file search. Rover keeps its own index and understands how people actually remember files: typos, “last summer”, “in downloads”, “the short version”. In our benchmark it found the right file 95% of the time, versus 58% for Spotlight.

**Why does macOS warn me the first time I open it?**  
Rover isn't notarized by Apple yet. Open System Settings → Privacy & Security and click Open Anyway, or build it from source with one command.

**Will Free Up Space delete my files?**  
Never permanently. It only suggests; you choose. Files go to the Trash, or to a backup drive with the original sent to the Trash after the copy is checked, and ⌘Z puts everything back. It never suggests iCloud files, code projects or Apple's apps.

**Does it slow my Mac down?**  
It indexes about 225,000 files in about 2 seconds at launch, then follows changes live. At rest it uses close to 0% CPU and about 30 MB of memory.

**How do I uninstall it?**  
Quit Rover from its menu, drag it from Applications to the Trash, and delete ~/Library/Application Support/Rover.

## Command line

The app binary doubles as a CLI. Link it once, then:

```bash
ln -sf ~/Applications/Rover.app/Contents/MacOS/Rover ~/.local/bin/rover
```

```bash
rover invoice last month          # search
rover -c "lease renewal"          # also search inside files
rover ask "what's my biggest video?"
rover mv ~/Downloads/a.pdf ~/Documents/Taxes
rover undo
rover rule add ~/Downloads "invoice pdf" move ~/Documents/Invoices
rover rules
rover --bench
```

## Build

Requires macOS 13 or later. The Xcode Command Line Tools are enough; full Xcode isn't needed.

```bash
./scripts/build.sh && cp -R dist/Rover.app ~/Applications/ && open ~/Applications/Rover.app
```

On first launch, macOS asks for access to Desktop, Documents and Downloads, so Rover can index those folders. Granting Full Disk Access in System Settings → Privacy & Security avoids the prompts.

Optional settings go in `~/.config/rover/config.json`:

```json
{ "extraRoots": ["/Volumes/Work"], "skipNames": ["build"], "includeHidden": [".ssh"] }
```

## Privacy

The index, your history and your rules stay in `~/Library/Application Support/Rover` on your Mac. Search never touches the network. The assistant only runs when you press Tab. It sends your question, plus the file names and contents it decides to read, to Claude.

## License

MIT © 2026 Alex Towfigh. See [LICENSE](LICENSE).
