# #342 web.server-build - GHCR web image uses the server path

## Intent and scope

The web image produced by .github/workflows/flutter.yml is the deployable VM
client. It must compile with USE_API_WRITES=true so unauthenticated users are
sent to /login, and with an empty API_BASE_URL so API paths resolve against
the page's own origin.

Only the CI workflow and this handoff record change. The shop's installed
Drift-only build is not rebuilt or replaced.

## Build and publication behavior

- The image build runs flutter build web --no-tree-shake-icons with
  --dart-define=USE_API_WRITES=true and --dart-define=API_BASE_URL=.
- A manually dispatched branch run builds and publishes the immutable
  ghcr.io/nuimanlp/srisurart-pos-web:<commit-sha> tag. This is the pre-merge
  proof path because pull-request runs do not publish release images.
- Only a main run tags or pushes ghcr.io/nuimanlp/srisurart-pos-web:main.
  A feature-branch verification therefore cannot move the release alias.

## User-visible side effect

The deployed web URL is no longer an offline Drift application. It opens at the
login screen and sends API requests to the same origin. Anyone who previously
opened that URL as an offline app will now see login instead. The real shop is
unaffected because it still runs its separately installed Drift build, not this
GHCR image.

## Verification record

The final CI run, image digest, commit provenance, runtime login evidence, and
same-origin request evidence are recorded in the #342 pull request and issue
after the branch workflow has produced the image.
