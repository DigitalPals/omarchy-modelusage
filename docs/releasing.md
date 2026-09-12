# Release checklist

1. Update `manifest.json`, `CHANGELOG.md`, and `COMPATIBILITY.md` together.
2. Run `./tests/run` from the development checkout.
3. Create a clean archive or clone and run `omarchy plugin validate` against it.
   The packaged tree must contain no symlinks.
4. Smoke-test Limits and Costs with each available provider account. Record any
   provider that could only be fixture-tested in `COMPATIBILITY.md`.
5. Refresh the README screenshots under `docs/model-usage-*.png` when visible UI
   changes. Use fixture data or owner-approved captures with account identities
   hidden. Crop to the widget; never publish unrelated desktop content or account
   tooltips. Label fixture examples in the README.
   Update root `preview.png` separately: the marketplace reads this image, not
   the README gallery. The current 1920×1080 composition uses the menu bar,
   three Codex account cards, and Costs. Check both the full image and a small
   landscape crop so the marketplace card retains the title and main views.
6. Push the release commit, create an annotated `vX.Y.Z` tag, and publish release
   notes from `CHANGELOG.md`.
7. Install the public repository URL on a clean user checkout:

   ```bash
   omarchy plugin add https://github.com/DigitalPals/omarchy-modelusage.git --enable
   ```

8. Confirm update, disable, enable, and remove behavior in an isolated installation.
   To update the [marketplace listing](https://plugins.omarchy.org/plugin.html?id=digitalpals.model-usage),
   use the [plugin verification form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
   and select **Verify and publish a newer upstream commit**. Enter
   `digitalpals.model-usage`, the repository root URL, and the full SHA from
   `git rev-parse HEAD` after the final push. The description and version come
   from `manifest.json`; the description is limited to 500 characters.
   The update needs automated checks and marketplace maintainer approval before
   deployment. Pushing upstream alone does not replace the approved snapshot.
