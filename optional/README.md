# Optional apps

Extra apps you can add: they work with the launcher but aren't part of the main install.
Each one is a plugin folder here, and a zip of it built by `build-zip.py`:

| App | What it does | Install |
| --- | --- | --- |
| [FlashForge](flashforge.koplugin/README.md) | A FlashForge 3D printer over the Wi-Fi: the print, temperatures, pause and cancel, the light, the camera, starting a recent file | Settings > Updates > **Optional apps** on the Kindle, or System > Update from GitHub on the web page. By hand: unzip `kindle-flashforge.zip` (from a release) into `koreader/plugins/` and restart KOReader |
| [Pangolin](pangolin.koplugin/README.md) | A Pangolin server's organization: sites online, each resource's health, resources and clients turned on or off | The same way (`kindle-pangolin.zip`) |

The launcher, its search, settings, notifications and the web page pick an optional app up when it's
installed, and show nothing of it otherwise. The launcher's updater (appsupdate.lua) lists them, installs
one on request (a release's kindle-<app>.zip, which the release workflow makes, or the optional/ folder of
a branch's zip) and updates the installed ones with the rest.

After changing an app here, build its zip again: `python optional/build-zip.py`.
