# Duck Disk

A native macOS disk cleaner in the spirit of DiskBuddy. One scan maps every byte of a drive or folder. What you keep is shown in grey and what you could clear is shown in colour. Nothing is ever deleted: everything you clear goes to the Trash, after you review it. There is no account, no network access and no analytics.

Requires macOS 14 or later. Builds with the Swift 6 Command Line Tools; Xcode is not needed.

## The nine rooms

| Room | What it does |
|------|--------------|
| Overview | A donut chart of the whole drive, a "ready to clear" total and one button to move the selection to the Trash. |
| Find | Searches every file name from the scan as you type, hidden folders included, sorted by size. The last scan's index is saved, so Find works right after launch. |
| Space | Drills into folders largest-first, shows the drive as a treemap (by size, file count or age, with adjustable depth), or lists the largest files. |
| Cleanup | Caches, logs, app leftovers, developer files, local AI models (Ollama, LM Studio, Hugging Face and others) and old downloads, grouped, totalled and selectable item by item. |
| Duplicates | Files with identical contents (size → partial hash → full SHA-256). Hard links and APFS clones are not counted as waste. One copy per set is always kept. |
| Applications | Every app with its data across `~/Library`, launch agents and running processes. Clear Cache removes only caches and web data; Uninstall moves the app and its data to the Trash. |
| Monitor | Live CPU, memory, top processes, listening ports and battery health. |
| Compress | Re-encodes videos (HEVC/H.264) and photos (HEIC). A result is kept only when it is smaller; originals go to the Trash. |
| Activity | Space recovered per week, a log of cleanups, and snapshot comparisons that show which folders grew or shrank. |

## Build and run

```bash
scripts/package-app.sh
```

This builds for Apple silicon and creates `dist/Duck Disk.app`. Add `--dmg` to also create `dist/DuckDisk-<version>.dmg`. The version comes from `Resources/Info.plist`.

```bash
open "dist/Duck Disk.app"
```

During development you can also run the executable directly with `swift run DuckDisk`.

### Signing and notarization

The script picks the signing mode on its own:

- **Developer ID:** when a "Developer ID Application" certificate is in the keychain (or `DEVELOPER_ID` names one), the app and disk image are signed with the hardened runtime. If `NOTARY_PROFILE` is also set, both are notarized and stapled, and other Macs open them without a warning.
- **Ad-hoc:** without a certificate the app runs on this Mac, but other Macs show a Gatekeeper warning. People can still open it from System Settings → Privacy & Security → Open Anyway.

To set up notarization once (it needs a paid Apple Developer account and an app-specific password):

```bash
xcrun notarytool store-credentials duckdisk --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
```

Then package with:

```bash
NOTARY_PROFILE=duckdisk scripts/package-app.sh --dmg
```

Before publishing, work through the [release checklist](release-checklist.md).

## Full Disk Access

Without Full Disk Access, macOS hides Mail, Messages, Safari and some app data from the scan, and asks separately before Duck Disk can read Desktop, Documents and Downloads. A scan waits while such a prompt is on screen. To see everything, grant access in System Settings → Privacy & Security → Full Disk Access (the app links there from the Overview and Settings).

The app is ad-hoc signed, so each rebuild has a new signature. After a rebuild, switch Full Disk Access off and on again for Duck Disk.

## Safety model

- Every removal goes through `TrashService`, which moves items with `FileManager.trashItem` and never deletes them.
- `SafetyGuard` runs before every move. It refuses macOS system folders, standard folders themselves (Home, Library, Documents…), iCloud and sign-in caches, Photos, Music, iMovie and Final Cut libraries (whole or in part), the Trash, items owned by another user in shared folders, and any path that is not plain and absolute. Comparisons ignore letter case, as APFS does.
- Cleanup categories marked "Safe to clear" start selected. "Worth a look" categories (developer files, old downloads, duplicates) start unselected.
- Folders nested inside a selected folder are never counted twice.
- Each duplicate set always keeps one copy. If the kept copy disappears, another is chosen, and no request can remove every copy of a set. Clones that share storage are not offered, because removing them frees nothing.
- Each data folder in `~/Library` belongs to at most one app, so uninstalling an app never takes another app's data.
- Compress only re-encodes JPEG, PNG, HEIC, WebP and BMP photos. RAW, PSD, TIFF and GIF files are left alone.

## Settings

- Appearance: system, light or dark.
- Folders that are never scanned.
- When downloads count as old (default 90 days) and when build folders count as stale (default 30 days).
- Minimum file size for the duplicate search (default 1 MB).
- Whether a snapshot is saved after every scan.
- Whether Find remembers file names between launches (turning it off deletes the saved indexes).

App data (cleanup history, snapshots and the Find index) is stored in `~/Library/Application Support/Duck Disk`. The index of a full scan of about 2.5 million files takes around 50 MB.

## Project layout

```
Package.swift
Sources/DuckDiskCore/    scanning, classification, safety, trash, duplicates, apps, monitor, compression, history
Sources/DuckDisk/        SwiftUI app: AppModel, theme, the nine rooms, inspector, settings
Sources/DuckDiskChecks/  check runner with a fixture home folder
Resources/Info.plist     bundle metadata and privacy usage strings
scripts/package-app.sh   release build and .app assembly
scripts/make-icon.swift  renders the app icon from Sources/DuckDisk/DuckArtwork.swift
```

## Checks

XCTest is not available with the Command Line Tools, so the core is verified by an executable check runner. It builds a fixture home folder in the temporary directory and checks scanning, classification, the safety rules, duplicates (including hard links and clones), search, snapshots, the system monitor, and photo and video compression.

```bash
swift build --product DuckDiskChecks && ./.build/debug/DuckDiskChecks
```

Other modes: `--apps` also measures installed applications; `--scan <path>` times a scan; `--fixture-only <dir ending in duckdisk-fixture>` writes the fixture and exits.

## Development flags

Debug builds accept flags that help you work on the UI without scanning protected folders. Release builds ignore them.

```bash
swift build --product DuckDisk && ./.build/debug/DuckDisk -scanPath <folder> -homeOverride <folder> -snapshotDir <out> -autoSnapshot NO
```

- `-scanPath` scans a folder on launch.
- `-homeOverride` treats that folder as the home folder when classifying, for example a fixture written by `--fixture-only`.
- `-snapshotDir` renders each room to PNG and then quits. `<room>.png` is the window; `<room>-render.png` is the room drawn by SwiftUI alone, which also shows scrolled content.

## License

Duck Disk is released under the [MIT License](../LICENSE).
