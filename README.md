# Application build helper

Build utility for the configured Electron AppImage.

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
```

`OUTPUT_FILE_PREFIX` is required for every build. `DEFAULT_APP_SOURCE` is
required when you do not provide an AppImage path in the command.

When logging is disabled, leave the license key empty. When it is enabled, set
its value before building.
`NEW_RELIC_SERVICE_NAME` controls the New Relic `service.name` attribute for
both installer and kiosk logs.

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

## Optional application values

```bash
./make-kiosk-iso.sh \
  --fingerprint=VALUE \
  --api-key=VALUE \
  --api-secret=VALUE
```

Keep real values in the ignored `.env` file or pass them from your shell.
Never add them to Git.
