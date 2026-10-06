# Application build helper

Build utility for the configured Electron AppImage.

## Quick start

Run these commands from the repository root. If `.env` is already configured,
the usual local-only build is:

```bash
./build-premium-isos.sh
```

This builds every product listed in `PREMIUM_PRODUCTS` and keeps the new ISO
and AppImage files locally. This is the same as `--no-upload`. To build debug
ISOs:

```bash
./build-premium-isos.sh --debug --no-upload
```

After checking the local output, build and upload instead:

```bash
./build-premium-isos.sh --upload
```

Upload is opt-in. It removes local outputs only after Dropbox reports a
confirmed sync.

To see the options without loading `.env` or starting a build:

```bash
./build-premium-isos.sh --help
```

### Build only one product

The wrapper has no product-name option. `PREMIUM_PRODUCTS` controls what runs.
To run only one configured product for one command, temporarily override it
with that product's row from `.env`:

```bash
PREMIUM_PRODUCTS='Product Name|app-filter|dist-directory|iso-prefix' \
  ./build-premium-isos.sh --no-upload
```

The four fields are `display name|pnpm script|output directory under dist|ISO
prefix`. This override is temporary and does not edit `.env`.

## Configuration

Create or update the ignored `.env` file before building. Put these values at
the top of the file:

```bash
DEFAULT_APP_SOURCE=/path/to/project/dist/your-app
OUTPUT_FILE_PREFIX=your-output-prefix
UPDATE_FEED_URL=https://your-update-host.example/path/
APP_UPDATER_CACHE_DIR_NAME=your-electron-app-updater
VNC_PASSWORD=replace-with-a-local-password
NEW_RELIC_LOG_ENABLED=false
NEW_RELIC_LOG_ENDPOINT=https://log-api.newrelic.com/log/v1
NEW_RELIC_LICENSE_KEY=
NEW_RELIC_ENVIRONMENT=production
NEW_RELIC_SERVICE_NAME=kiosk-production
NEW_RELIC_LOGTYPE=kiosk
NEW_RELIC_SOURCE=kiosk.kiosk
NEW_RELIC_SERVICE_NAMESPACE=kiosk
```

`OUTPUT_FILE_PREFIX` is required for every build. `DEFAULT_APP_SOURCE` is
required when you do not provide an AppImage path in the command.

When logging is disabled, leave the license key empty. When it is enabled, set
its value before building.
`NEW_RELIC_SERVICE_NAME` controls the New Relic `service.name` attribute for
both installer and kiosk logs.
The `--debug` build option enables verbose application logging and DevTools in
the packaged Electron launch. Verbose application lines are forwarded as
`level: DEBUG`, and the default service name becomes
`kiosk-production-debug`.

## Run

Requirements: Linux, Docker, and a built x64 AppImage in the configured local
build-output directory.

```bash
./make-kiosk-iso.sh
```

The script selects the highest-version `*-x64.AppImage` from the `dist`
directory configured by `DEFAULT_APP_SOURCE`. To use another directory for one
command:

```bash
DEFAULT_APP_SOURCE=/path/to/build-output ./make-kiosk-iso.sh
```

You can also provide one AppImage directly:

```bash
./make-kiosk-iso.sh /path/to/application-x64.AppImage
```

## Build multiple installer ISOs

`build-premium-isos.sh` builds the shared package, then builds and verifies each
configured product in order. Product names, source paths, build filters, output
prefixes, and upload destinations belong only in the ignored `.env` file.

### Requirements and configuration

Use Linux, Bash 4+, Docker, pnpm, GNU tools (including `realpath`), and `flock`.
Install the application workspace dependencies first. Uploads also require the
configured Dropbox desktop client, its `dropbox` CLI, and `rsync`.

Add these settings to your local `.env`. The values below are placeholders;
replace them locally. `.env` is trusted Bash syntax. Quote spaces and special
characters. Shell environment overrides take precedence for wrapper settings.

```bash
APP_WORKSPACE_DIR='/path/to/application-workspace'
NODE24_BIN='/path/to/node-v24/bin'
APPIMAGE_RUNTIME='/path/to/appimage-runtime'
SHARED_BUILD_FILTER='shared'
PREMIUM_PRODUCTS='Product A|app-a|app-a|app-a-installer
Product B|app-b|app-b|app-b-installer'
DROPBOX_DIR='/path/to/Dropbox'
DROPBOX_INSTALLERS_PATH='installers'
PRIVATE_TERMS='private-company-name|private-product-name|private-username'
```

Each `PREMIUM_PRODUCTS` row has four fields separated by `|`:
`display name|pnpm script|output directory under dist|ISO prefix`.
The wrapper runs `pnpm "$SHARED_BUILD_FILTER" build` once, then
`pnpm "<pnpm script>" make:linux` for each row in `APP_WORKSPACE_DIR`.
It selects the highest-version `*-x64.AppImage` under the configured output
directory. Output directory names and prefixes must be unique, and contain only
letters, numbers, underscores, dots, or hyphens, starting with a letter, number,
or underscore. Build filters use the same characters. Output directories cannot
resolve through symlinks. Configure the other ISO settings described above;
the wrapper supplies each AppImage path and output prefix. It requires Node 24.
Relative `APPIMAGE_RUNTIME` paths resolve from this project root.

### Commands

Build locally and keep the new outputs:

```bash
./build-premium-isos.sh --no-upload
```

Build local debug ISOs with verbose logging, DevTools, and `DEBUG-` prefixes:

```bash
./build-premium-isos.sh --debug --no-upload
```

Build and upload each product, then remove its local outputs after confirmed sync:

```bash
./build-premium-isos.sh --upload
```

**Local-only mode is enabled by default.** Running without options is the same
as `--no-upload`. Use `--upload` to upload to Dropbox. `./build-premium-isos.sh
--help` displays usage without loading private configuration or building.

### Outputs and cleanup

**Every build run deletes existing `iso/output/*.iso` files and the configured
application output directories at startup, after product configuration checks.
This also applies to `--no-upload`.** Save required previous outputs before
running. Check failed uploads before retrying.

New ISOs are written to `iso/output/` using the configured prefixes.
`--no-upload` keeps the fresh ISOs and AppImage outputs.

Upload mode copies one ISO to Dropbox, compares the copy, and waits for
`dropbox filestatus` to report `up to date`. It then excludes the staging folder
from local sync, keeps the online copy, and removes that product's local ISO
and AppImage output before building the next product. Failed upload or staging
cleanup stops the run and keeps the remaining outputs for inspection.

The run lock stays at `.notes/premium-build.lock`. Sync and cleanup records,
including size and SHA-256, are appended to `.notes/premium-upload-receipts.tsv`.

Uploads use `DROPBOX_DIR/DROPBOX_INSTALLERS_PATH/<Mon-DD-YYYY>/<run>/`.
The script starts the installed Dropbox client if needed. Optional settings
`DROPBOX_SYNC_TIMEOUT_SECONDS` (default `3600`) and
`DROPBOX_CLEANUP_TIMEOUT_SECONDS` (default `300`) must be positive integers.

## Public repository privacy check

Keep real identifiers, paths, domains, labels, and credentials in `.env` only.
Use generic placeholders in public examples. Private agent context and build
records are ignored, but must never be force-added to Git.

Before preparing changes for publication, run:

```bash
python3 scripts/check-public-repo.py
python3 scripts/check-public-repo.py --history
```

The check reads the literal, case-insensitive denylist `PRIVATE_TERMS` from
`.env`, without executing it. List company and product names, private domains,
usernames, and other identifying terms separated by `|`. It checks filenames and
contents in the working tree and index, including untracked files eligible for
Git. `--history` also checks reachable commits. It also rejects private artifact
paths and common credential formats. This check is a review aid; inspect the
full changes and run an available secret scanner before publication. It cannot
detect every unknown secret or private identifier. No command here pushes changes.

## Optional application values

```bash
./make-kiosk-iso.sh \
  --fingerprint=VALUE \
  --api-key=VALUE \
  --api-secret=VALUE
```

Keep real values in the ignored `.env` file or pass them from your shell.
Never add them to Git.
