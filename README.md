# SteadyFrame

SteadyFrame is a Windows 10/11 tune-up script for gaming PCs. It checks your PC for common problems,
removes some background clutter, and applies a set of settings aimed at smoother, more consistent
frame times.

It won't turn a slow PC into a fast one. What it can do is fix setup mistakes (RAM running at stock
speed, a monitor stuck at 60 Hz, leftovers from old "FPS booster" tools) and cut down on background
stuff that causes random stutters. How much you notice depends on your PC, so the README explains how
to measure it yourself. SteadyFrame doesn't promise better performance; it tries, and it tells you
which settings have proof behind them and which don't.

Everything it changes is shown to you first, and the changes can be undone.

I made this for me and my friends, because it was easier than setting up every PC by hand. If you
want to improve it, you're welcome to: open an issue or a pull request.

## How to use it

1. Download the zip and extract it (right-click, *Extract All*). Running it from inside the zip
   doesn't work. Keep the files together.
2. Double-click **`HealthCheck.bat`**. This only looks, it changes nothing. At the end it lists
   things to fix outside Windows, for example turning on XMP/EXPO in the BIOS.
3. (Optional) Record a benchmark in your main game first. See [Checking the results](#checking-the-results).
4. Double-click **`Run.bat`** and pick the option marked *recommended for this PC*.
5. It asks whether to run the debloat tools (WinUtil and Win11Debloat). If the PC already went
   through Talon, WinUtil or Win11Debloat, choose *Skip* and only SteadyFrame's own settings are
   applied. It looks for the folders those tools leave behind and suggests an answer.
6. Go through the lists. Everything that will change is ticked; type a number to untick it,
   press Enter to continue. Nothing happens until you type `YES` on the summary screen.
7. Restart the PC when it's done.

To undo, double-click **`Revert.bat`** and pick the run you want to undo. SteadyFrame also creates a
Windows restore point before changing anything, which undoes everything at once
(press Win+R, type `rstrui`, press Enter).

### Warnings you might see

"Windows protected your PC" is SmartScreen. Windows shows it for any script downloaded from the
internet that isn't signed by a company. Click *More info* and then *Run anyway*, or read the files
first, they're plain text.

"Do you want to allow this app to make changes" is the admin prompt. It's needed to change system
settings. `HealthCheck.bat` asks too, so it can read things like TPM and BitLocker status.

## What it does

The health check only reads. It looks for:

- RAM running at default speed (XMP/EXPO off), a single RAM stick (single channel), less than 16 GB
- Windows installed on a hard drive, a nearly full system drive
- an old graphics driver, Resizable BAR off (NVIDIA), a graphics card not using MSI interrupts,
  a monitor running below its max refresh rate
- background apps known to cause stutter (Armoury Crate, iCUE, Nahimic, Wallpaper Engine and others)
- leftovers from old tweak tools: page file disabled, forced HPET, CPU security fixes turned off,
  Windows Update disabled
- Intel 13th/14th gen CPUs: whether the BIOS has Intel's fix for the voltage problem (microcode 0x12F or newer)

The changes, grouped the same way as in the menu:

- Power: a performance power plan, USB and PCIe power saving off, Fast Startup off (desktops only)
- Gaming: Game Mode on, background game recording off, mouse acceleration off, the Windows 11 setting
  for windowed games
- Background: you pick which startup apps to disable, Store apps stop running in the background,
  Edge and Chrome stop running after you close them, telemetry services and tasks off, Windows
  Update stops uploading to other PCs, and Windows stops turning your game down during voice calls
- Network: power saving on the network adapter off
- Windows Update: big yearly updates wait about 9 months, security updates keep installing, and no
  automatic restarts while you're signed in. Windows Home can't postpone updates, so there it locks
  the current Windows version instead, but only if that version still gets security updates for 3+
  months. Run SteadyFrame again a few months before that date (the health check shows it) and it
  offers to unlock it. A locked version that runs out of support goes without security updates
  until Windows forces the upgrade, up to 60 days later.
- Debloat and privacy: runs [WinUtil](https://github.com/ChrisTitusTech/winutil) by Chris Titus Tech
  and [Win11Debloat](https://github.com/Raphire/Win11Debloat) by Raphire with a fixed list of options
  (removes preinstalled apps like Candy Crush and Clipchamp, turns off ads, tips, Copilot and telemetry)

Each item in the menu shows why it's there and what it may stop working. Type `i` and the number to
see it. The summary screen lists everything that could stop working before you confirm.

### Evidence tiers

Every SteadyFrame setting has a letter next to it in the menu. A means it's backed by testing or
documented by Microsoft, AMD, Intel or NVIDIA, and it's on by default. B means it helps on some PCs,
so it's only turned on when it applies to yours. C means it's popular online but the evidence is weak
or it's placebo.

Tier C is where the popular tweak-pack settings live: smaller mouse/keyboard input buffers, network
adapter interrupt moderation and flow control off, socket (AFD) values, undocumented MMCSS and kernel
values, Nagle off, timer and priority tweaks, faster shutdown. They're included because people ask
for them, not because they're proven. They're hidden unless you open Advanced, never on by default,
and the menu says so above the list. If you try one, benchmark it.

Some popular tweaks are left out on purpose because they make things worse or break things:
- turning off Windows Update or its services, or firewall rules that block IP ranges
- turning off CPU C-states, core parking or power throttling for every PC (this hurts the 7950X3D and
  9950X3D and Intel CPUs with E-cores; SteadyFrame picks the power plan per CPU instead)
- turning off GPU power states and thermal throttling through driver registry keys
- turning off network RSS or checksum offload (moves work onto the CPU), shrinking socket buffers
  (slower downloads), turning off TCP auto-tuning, disabling IPv6 or Teredo (breaks Xbox networking)
- disabling services like ClipSVC, TokenBroker or wlidsvc (breaks Microsoft Store, Game Pass and
  Xbox sign-in) or XboxGipSvc (breaks Xbox controllers)
- forcing HPET, disabling the page file, turning Game Mode off

### What it never touches

These are blocked in the code, not just left unticked, so games with anti-cheat (Valorant, FACEIT,
and others) keep working and the PC stays protected:

- Windows Defender protection (real-time, tamper protection, cloud protection)
- Memory integrity / VBS, Secure Boot, TPM, anti-cheat services
- UAC, SmartScreen, the firewall, CPU security fixes (Spectre/Meltdown)
- Windows Update can be postponed, but never turned off

After every run it checks these again and warns you if anything changed.

### What it downloads

Only WinUtil and Win11Debloat, from their official GitHub releases. By default it uses specific
versions that were read through before being added, and checks each download's SHA256 fingerprint
before running it. If the fingerprint doesn't match, the file is deleted and not run.

SteadyFrame itself doesn't send any data anywhere. It only connects to GitHub: to download those two
tools, and when the menu opens, to ask for the latest SteadyFrame version number. If you don't want the
tools at all, open Advanced (type `adv` in the main menu) and set the source to *None*. With
`-Prefetch` you can download them once and then use the folder on PCs without internet.

### Updates

When a newer version is out, the menu says so. Type `U` to see what changed and download it. It goes
into a new folder next to the current one (for example `SteadyFrame-0.1.3`), and the GitHub checksum
is checked first. Nothing updates by itself and nothing runs until you open `Run.bat` in the new folder.
The undo history keeps working from either folder. `-NoUpdateCheck` skips the version check.

## Games

If TEKKEN 8, VALORANT or Counter-Strike 2 is installed, SteadyFrame:

- sets Windows to run the game on the main graphics card (matters on PCs that also have integrated
  graphics enabled)
- shows a settings card for each game (main menu option 7): the in-game and driver settings that
  help frame pacing, each with the reason, plus popular tweaks that don't help. The card is also
  saved as `game-settings.txt` in the run folder, easy to send to a friend.
- also shows a card for your graphics driver (NVIDIA Control Panel or AMD Adrenalin): shader cache
  size, low latency, G-SYNC/FreeSync setup and the settings that make frame times uneven. These are
  steps you click yourself; SteadyFrame doesn't change driver settings or bundle third-party tools
  for it.
- CS2 only, in Advanced: it can add an fps cap to your `autoexec.cfg`. It asks for the number first,
  keeps your own lines, and undo removes only what it added.

It doesn't edit TEKKEN 8 or VALORANT files. VALORANT syncs settings from Riot's servers and would
overwrite them, and Bandai Namco bans TEKKEN 8 accounts for modified game files.

## Checking the results

Average FPS doesn't tell you much about stutter. The useful numbers are the 1% low and the 0.1% low,
which show the frame rate during the worst moments.

1. Install [CapFrameX](https://www.capframex.com/) (free, open source) or Intel PresentMon.
2. Pick a repeatable test: a replay, a benchmark mode, or the same route in the same map.
3. Record 3 runs of 60 to 90 seconds before running SteadyFrame.
4. Run SteadyFrame, restart, then record 3 runs again.
5. Compare the 1% and 0.1% lows.

If a specific setting makes things worse on your PC, undo just that one with `Revert.bat`.

## Options

Type `adv` in the main menu for:

- where the debloat tools come from: the checked versions (default), the latest versions (not
  checked), or none
- Windows Update: postpone big updates (default), security-focused, or leave it alone
- show tier C settings
- games to always start at High priority (tier C, see its warning)
- whether the PC uses Game Pass / the Xbox app
- dry run: shows exactly what would change without changing anything

There are three presets. HighEnd is everything above and keeps the normal Windows look. MidRange also
uses lighter visual effects and turns off Windows Search indexing; it's suggested when the PC has less
than 16 GB of RAM, 8 or fewer CPU threads, or Windows on a hard drive. Minimal only makes the safest
changes and skips the debloat tools.

## Where things are saved

Each run that changes something gets a folder in `C:\ProgramData\SteadyFrame\runs\` with the list
of changes (used by `Revert.bat`), a log and a summary. It's kept outside the SteadyFrame folder so
you can still undo after deleting that folder or downloading a newer version. Only administrators can
change those files. Health checks, dry runs and game settings cards go in `runs\` inside the
SteadyFrame folder. Downloaded copies of WinUtil and Win11Debloat go in `tools\cache\`. WinUtil and
Win11Debloat may keep their own logs as well.

## Command line

For people who prefer it, or for scripting:

```powershell
.\SteadyFrame.ps1                                    # the menu
.\SteadyFrame.ps1 -DiagnoseOnly                      # health check only
.\SteadyFrame.ps1 -Preset HighEnd -DryRun            # show what would change
.\SteadyFrame.ps1 -Preset MidRange -Unattended -UpdatePolicy SecurityOnly
.\SteadyFrame.ps1 -Exclude bg.print-spooler-off,WPFTweaksLocation
.\SteadyFrame.ps1 -GameCards                         # game settings cards
.\SteadyFrame.ps1 -Revert                            # undo menu
.\SteadyFrame.ps1 -Prefetch                          # download the two tools now, for offline use later
.\SteadyFrame.ps1 -ListTweaks -Json                  # every setting and whether it applies, as JSON
.\SteadyFrame.ps1 -NoUpdateCheck                     # don't ask GitHub for the latest version
```

## For contributors

```
Run.bat, HealthCheck.bat, Revert.bat   launchers
How to use.txt                         short guide for people who won't open this README
SteadyFrame.ps1                        menu and command line
lib\                                   the engine (Guard.ps1 holds the never-touch rules)
catalog\*.json                         SteadyFrame's settings: tier, reason, what it may break, source
games\games.json                       supported games and their settings cards
external\                              options passed to WinUtil / Win11Debloat, pinned versions and hashes
tools\Update-Pin.ps1                   move a pinned tool to a newer version
tests\Run-Tests.ps1                    tests (no admin needed, only touch a test registry key and %TEMP%)
```

`tests\`, `tools\` and the git files are left out of the release zip (see `.gitattributes`); clone the
repo to get them.

Run the tests with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

To add a setting, add an entry to the right file in `catalog\` with an `id`, `name`, `tier`, `why`,
`breaks`, `source`, `presets`, optional `requires` (for example `Desktop`, `Win11`, `!Printer`) and
`actions`. The tests reject anything the never-touch rules block, and any tier C setting placed in a
preset.

To update WinUtil or Win11Debloat, read what changed in the new release, run
`.\tools\Update-Pin.ps1 -Tool winutil -Tag <version> -Write`, check that the option names in
`external\` still exist, and run the tests.

To add a game, add it to `games\games.json`. Only put settings on its card that have testing or the
developer behind them, with a source.

## Known limits

- Changes made by WinUtil and Win11Debloat, and removed apps, aren't in SteadyFrame's undo list. The
  restore point covers them, and removed apps can be reinstalled from the Microsoft Store.
- Run it from the account you game on. Settings like mouse acceleration apply to the account that runs it.
- Boot settings are skipped while BitLocker is on, since changing them can trigger the BitLocker recovery screen.
- The menus are in English.

## Credits

- [WinUtil](https://github.com/ChrisTitusTech/winutil) by Chris Titus Tech
- [Win11Debloat](https://github.com/Raphire/Win11Debloat) by Raphire
- Testing and research by [djdallmann](https://github.com/djdallmann/GamingPCSetup) and
  [valleyofdoom](https://github.com/valleyofdoom/PC-Tuning)
- Inspired by [Talon](https://github.com/ravendevteam/talon) by Raven

Use it at your own risk. It changes system settings; that's why it shows everything first, makes a
restore point, and keeps an undo list.

## License

MIT, see [LICENSE](LICENSE). WinUtil and Win11Debloat are separate projects with their own licenses; SteadyFrame downloads them, it does not include them.
