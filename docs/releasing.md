# Release checklist

1. Update `manifest.json`, `CHANGELOG.md`, and `COMPATIBILITY.md` together.
2. Run `./tests/run` from the development checkout.
3. Create a clean archive or clone and run `omarchy plugin validate` against it.
   The packaged tree must contain no symlinks.
4. Smoke-test Limits and Costs with each available provider account. Record any
   provider that could only be fixture-tested in `COMPATIBILITY.md`.
5. Refresh `docs/model-usage-panel.png` if the release changes visible UI. Use
   synthetic fixture data and capture the panel surface only; never publish a
   desktop, account tooltip, or live account identity.
6. Push the release commit, create an annotated `vX.Y.Z` tag, and publish release
   notes from `CHANGELOG.md`.
7. Install the public repository URL on a clean user checkout:

   ```bash
   omarchy plugin add https://github.com/DigitalPals/omarchy-modelusage.git --enable
   ```

8. Confirm update, disable, enable, and remove behavior, then submit or refresh
   the listing on [omarchyplugins.com](https://omarchyplugins.com/).
