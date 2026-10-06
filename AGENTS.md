# Workspace instructions

Use STE English. Keep explanations short. Preserve unrelated local changes.

## Public repository privacy

This repository is public. Keep all real company/product names, private paths,
usernames, domains, upload destinations, service labels, identifiers, and
credentials in the ignored root `.env`. Source, comments, tests, documentation,
and this file must use generic names or configuration keys only. Never copy
private values into output shared publicly. Do not repeat private names even
as examples of forbidden terms.

Before handing off any change, and before any authorized publication workflow:

1. Review all changed and newly added files for private information. Move new
   private settings to `.env` while preserving local behavior.
2. Run `python3 scripts/check-public-repo.py`. Its private denylist lives in
   `.env` as `PRIVATE_TERMS`; extend it there when private identifiers are added.
   Confirm `.env`, `.env.*`, `.notes/`, `.serena/`, logs, and build artifacts are
   not staged or tracked. Never force-add these paths.
3. Before publication, also run `python3 scripts/check-public-repo.py --history`
   and an available secret scanner. Review staged contents separately from the
   working tree. A clean working tree scan does not prove history is clean.
4. Stop handoff as publication-ready if any check fails. Report affected files
   without exposing matched private values. Do not rewrite Git history or push;
   provide the user with the remaining action.

Do not broaden operational authority by changing `.env`. The historical task
exception below applies only to its originally authorized products and destination.
Local agent context is ignored and is not public documentation. Recheck source
when those notes are stale; the root build helper is authoritative for paths.

## Project context and Serena

At the start of each session, read `.serena/project.yml` and
`.serena/memories/project_overview.md` before investigating or editing this project.
For application or AppImage work, use the private application context under
`.serena/memories/` and `APP_WORKSPACE_DIR` from `.env`. Before builds or checks, read
`.serena/memories/suggested_commands.md`.

When Serena tools are available, activate this repository by its absolute path
and use its project context and relevant memories. When Serena is unavailable
or activation fails, read the same files directly and continue with filesystem
tools. Do not treat the presence of `.serena/` as proof it has been loaded.

The external portal source is not indexed by this project's Bash configuration.
For application symbol navigation, activate its external workspace when available
and read its applicable instructions before editing there. Context loading
does not authorize builds, cleanup, uploads, or notifications. The safety rules
in this file remain authoritative; recheck source when context notes are stale.

## Premium build helper

The entry point is `./build-premium-isos.sh` in the project root. Read its manual
in `README.md` before changing or running it. Older Serena notes may still name
the previous `.notes/` location; use the root script.

Keep the run lock and upload receipts under the ignored `.notes/` directory.
Upload is disabled by default. `--upload` is required for Dropbox. Every build,
including the default and `--no-upload`, deletes previous ISO and AppImage
outputs at startup; inspect artifacts and active builds before running.
For script relocation or documentation changes, use `bash -n build-premium-isos.sh`,
`./build-premium-isos.sh --help`, and `git diff --check`. Do not run a build or
upload just to validate documentation. Operational authority remains scoped below.

## Default restrictions

Do not execute commands that change external or production state, except for the
specific task authorized below.

Never run Terraform or OpenTofu apply, destroy, import, or state mutations;
cloud-provider write commands; Kubernetes apply, delete, patch, or rollout;
Helm upgrade or uninstall; deployment, release, or CI-trigger commands;
database migrations; or Git commit, branch creation, push, or merge.

For infrastructure work, use read-only checks. Edit local files only when
requested. Provide production commands for the user to execute. A general
request such as "run it" or "fix it" does not remove these restrictions.

## Explicit exception: premium ISO build and upload task

The user explicitly authorized this exception on 2026-09-08 and requested this
file to record it. For this task only, this section replaces the earlier blanket
ban on external writes for the actions listed here. All other restrictions above
remain in force. This exception ends when the task is complete or the user
cancels it. It does not authorize unrelated future uploads or messages.

Complete the authorized task: build and verify the originally authorized
installer ISOs configured in `.env`; upload them to the configured Dropbox destination;
remove their confirmed local copies; and send one final Discord notification.

The agent may:

- Edit and test `build-premium-isos.sh` and its local build helpers.
- Run `./build-premium-isos.sh`, its required AppImage builds in
  the `APP_WORKSPACE_DIR` configured in `.env`, and the local Docker
  ISO build and verification commands. Required dependency downloads are allowed.
- Start the installed Dropbox client when needed. Upload only these installer
  ISOs under the destination configured in `.env`.
- Check each file's Dropbox sync status. After confirmed upload, use Dropbox
  selective-sync exclusion to remove its local staging folder while retaining
  the online copy. Do not delete remote files or create public sharing links.
- Remove the generated ISO and its corresponding AppImage output after upload
  confirmation. Keep fresh ISOs when `--no-upload` is used. Preserve unconfirmed
  uploads for diagnosis and retry.
- Inspect disk use and remove confirmed obsolete or failed build artifacts to
  recover space. Limit cleanup to this task's files in `iso/output`,
  `iso/work/kiosk-installer`, the originally authorized product output
  directories configured by `PREMIUM_PRODUCTS` in `.env`, and exact temporary
  paths verified as belonging to this build. Check for active processes and
  mounts first. Do not remove unknown temporary files, unrelated data, or Docker
  volumes. Do not run broad Docker system prune commands.
- Fix recoverable errors and retry until all authorized uploads are verified. Keep
  build logs and upload records. Do not report a partial run as successful.
- Read the `NOTIFICATION_MONITOR_SCRIPT` path from `.env` and the configuration
  it references to obtain the existing Discord webhook. Use that webhook's
  configured channel to send one completion or failure message for this task.
  Do not start the monitor to send the message. Do not print, copy into source,
  log, or include credentials in the message. Confirm delivery before reporting
  that the notification was sent.

Do not request the same task authorization again. Tool approval controls still
apply. If an approval review blocks execution, report the specific rejection;
do not bypass it with another tool or indirect execution. If completion requires
new access or cleanup outside this scope, preserve the remaining data and report
the blocker.
