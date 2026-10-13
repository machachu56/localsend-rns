# LocalSend over Reticulum (RNS)

This fork adds [Reticulum](https://reticulum.network) as a second transport to LocalSend. Besides the usual LAN discovery, devices can find each other and send files **through any Reticulum network** (a shared TCP node, a LoRa/serial link, ...), so they no longer need to be on the same Wi-Fi.

This tutorial covers what is specific to this fork. The original LocalSend documentation follows after it.

- [How it works](#how-it-works-rns)
- [Quick start](#quick-start)
- [1. Install](#1-install)
- [2. Connect to a Reticulum network](#2-connect-to-a-reticulum-network)
- [3. Optional: set a network password](#3-optional-set-a-network-password)
- [4. Find devices and send files](#4-find-devices-and-send-files)
- [Where things are stored](#where-things-are-stored)
- [Troubleshooting](#troubleshooting-rns)

## How it works (RNS)

- Each device runs a small **bridge** (`rns_bridge.py`) that talks to Reticulum.
  - **Linux / Windows / macOS:** the app starts `python3 rns_bridge.py` as a child process. You need Python 3 with the `rns` package.
  - **Android:** Python and `rns` are embedded in the APK. Nothing to install.
- Devices **announce** themselves on the network. A device only shows up in the list after a *live* announce from it. Cached peers are never shown, because a cached destination may be dead.
- A file transfer opens an encrypted Reticulum link to the other device. The receiver has to accept first, exactly like in normal LocalSend.
- Scanning is deliberately gentle: public Reticulum nodes silently drop announces that come too fast, so announces are spaced out (see [Troubleshooting](#troubleshooting-rns)).

## Quick start

1. Install the app on two devices ([step 1](#1-install)).
2. On **both**, open **Settings → Advanced → Reticulum Network** and add the **same Reticulum node** as a TCP client interface ([step 2](#2-connect-to-a-reticulum-network)). **Restart the app.**
3. On the **Send** tab, press the sync button. The other device appears with an **RNS** badge.
4. Pick files, tap the device, accept on the other side.

## 1. Install

### Android

Build the APK (JDK 17 or 21, Android SDK with platform 36):

```bash
cd app
flutter build apk --release --target-platform android-arm64
# output: app/build/app/outputs/flutter-apk/app-release.apk
```

- Use `--target-platform android-arm` (32-bit phones) or `android-x64` (emulators/tablets) for the other ABIs. Build one APK per ABI.
- **Do not use `--split-per-abi`.** It conflicts with the embedded Python runtime (Chaquopy).
- If there is no `app/android/key.properties`, create one pointing at a keystore, otherwise the release APK cannot be signed. The file is git-ignored.
- The APK is large (about 130 MB) because Python ships for all ABIs.

### Linux / macOS

```bash
pip install rns                      # the bridge needs it
cd app
flutter build linux --release        # or: flutter build macos --release
cp ../rns_bridge.py build/linux/x64/release/bundle/
```

`rns_bridge.py` must sit **next to the executable** (the app also finds it in the current or parent directory when you run from the repo). Run `build/linux/x64/release/bundle/localsend_app`.

### Windows

Windows cannot be built from Linux. Use the GitHub Actions workflow **Build windows zip** (`.github/workflows/test_zip.yml`, run it manually with *Run workflow*). It produces `LocalSend.zip` with `rns_bridge.py` already next to the `.exe`.

On the Windows machine you also need Python 3 in `PATH` and `pip install rns`.

## 2. Connect to a Reticulum network

Without extra configuration the app only creates an `AutoInterface`, which discovers peers on the **local network** (multicast). It does nothing if the device is not on the same LAN, for example a phone on mobile data. To reach other devices anywhere, connect both to a common Reticulum node.

1. Open **Settings → Advanced → Reticulum Network**.
2. Press **+** (Add Interface) and fill in:
   - **Type:** `TCP Client` to connect to a node, or `TCP Server` to be the node.
   - **Target host / port:** address of a Reticulum TCP node, e.g. one you run yourself.
   - **Bandwidth (Mbit/s, optional):** a hint for RNS to size its packets. Empty uses the default (10 Mbit/s for TCP). `100` allows larger packets; it does not make the connection itself faster.
3. **Restart the app.** Reticulum reads its configuration only at startup, so interface changes apply after a restart.

Both devices must be connected to the **same node, or to nodes that are connected to each other**.

To host your own node, add a `TCP Server` interface on a machine with a reachable IP/port (open the port in the firewall or forward it), and point every device's `TCP Client` at it. See the [Reticulum manual](https://markqvist.github.io/Reticulum/manual/) for details on interfaces.

The same page shows **your RNS identity**: a QR code and your destination hash. That hash is what other devices use to reach you.

## 3. Optional: set a network password

By default anybody on the same Reticulum network who runs this app can see you and offer you files. A **network password** limits that to devices that know it.

1. Open **Settings → Advanced → Reticulum Network**.
2. Fill in **Network password** and press **Save**. It applies immediately, no restart.
3. Use the **identical** password (case sensitive) on every device that should see each other.

What it does:

- The password is turned into a tag (PBKDF2-SHA256) that becomes part of your Reticulum destination. Devices with another password, or none, **never appear in your list**, and nobody can compute your destination or open a link to you without it.
- Changing the password moves you to a new network. Old peers are removed from the list, and the devices you leave are told to forget you.
- Leave it empty for an open network.

What it does **not** do:

- It does not encrypt files differently. Transfers are already encrypted by the Reticulum link; the password only controls who can find you and connect.
- The tag travels in announces, so someone capturing them could try to brute-force a weak password offline. Use a long one.
- The password is stored in the app preferences in plain text, like the other settings.
- You cannot change it while a transfer is running.

## 4. Find devices and send files

1. Open the **Send** tab and press the **sync** button. Reticulum devices show an **RNS** badge.
   - Starting the app already announces you, and other devices answer within seconds.
   - A manual scan announces again, at most every 20 seconds. Automatic answers wait up to a minute.
2. Choose files, then tap the device.
3. The receiver sees the usual accept dialog. After accepting, the sender switches to the progress page.
4. Received files are saved to the normal LocalSend destination.

**Sending to a device that is not in the list:** use the **RNS Address** button on the Send tab and paste its destination hash (from its Reticulum Network page). The device has to be reachable on your network and use the same password.

## Where things are stored

| | Desktop | Android |
|---|---|---|
| Reticulum config | `~/.reticulum/config` (`%USERPROFILE%` on Windows) | app support directory, `.reticulum/config` |
| Identity | `~/.localsend_reticulum_identity` | app support directory |
| Received files (before saving) | system temp, `localsend_rns_staging` | app cache, `localsend_rns_staging` |

Desktop shares `~/.reticulum` with other Reticulum software. Running a second Reticulum program on the same directory can produce harmless warnings such as a `FileNotFoundError` in `persist_job` for ratchets.

## Troubleshooting (RNS)

**The Reticulum Network page shows "Reticulum is not available".** The bridge did not start. The message says why. On desktop it is usually missing Python or `rns` (`pip install rns`) or `rns_bridge.py` not next to the executable.

**I don't see the other device.**
- Did you restart the app after adding an interface?
- Are both devices on the same node (or connected nodes), with the **same password**?
- A phone on mobile data has no LAN, so `AutoInterface` is useless there. You need a TCP interface.
- After opening both apps within seconds of each other, one can take up to about a minute to see the other. Wait 20 seconds and press sync again.
- Public nodes may drop announces that arrive too fast. Don't spam the sync button.

**A device I changed the password on is still listed.** It disappears when the other device receives its goodbye, or on the next scan. If the app was force-closed, no goodbye is sent. Press sync to rebuild the list.

**Large files are slow or fail.**
- Reticulum over a public node starts slowly (small window) and the speed depends on the whole path.
- Keep the phone's screen on and the app in the foreground during the transfer. Android can cut the network of apps in the background, which aborts the link.
- Test with a smaller file first. Very large transfers over mobile data were not fully verified in this fork.

**Android build fails with Gradle/AGP errors.** The project needs AGP 8.9.1 with compile SDK 36 (install platform 36) and Chaquopy 16.1.0 (Python 3.11, the last line that still supports 32-bit ABIs).

---

# LocalSend

[![CI status][ci-badge]][ci-workflow]
[![Translations][translate-badge]][translate-link]
[![Packaging status][packaging-badge]][packaging-link]

[ci-badge]: https://github.com/localsend/localsend/actions/workflows/ci.yml/badge.svg
[ci-workflow]: https://github.com/localsend/localsend/actions/workflows/ci.yml
[translate-badge]: https://hosted.weblate.org/widget/localsend/app/svg-badge.svg
[translate-link]: https://hosted.weblate.org/engage/localsend/
[packaging-badge]: https://repology.org/badge/tiny-repos/localsend.svg
[packaging-link]: https://repology.org/project/localsend/versions

[Homepage][homepage] • [Discord][discord] • [GitHub][github] • [Codeberg][codeberg]

[English (Default)](README.md) • [Español](readme_i18n/README_ES.md) • [فارسی](readme_i18n/README_FA.md) • [Filipino](readme_i18n/README_PH.md) • [Français](readme_i18n/README_FR.md) • [Indonesia](readme_i18n/README_ID.md) • [Italiano](readme_i18n/README_IT.md) • [日本語](readme_i18n/README_JA.md) • [ភាសាខ្មែរ](readme_i18n/README_KM.md) • [한국어](readme_i18n/README_KO.md) • [Polski](readme_i18n/README_PL.md) • [Português Brasil](readme_i18n/README_PT_BR.md) • [Русский](readme_i18n/README_RU.md) • [ภาษาไทย](readme_i18n/README_TH.md) • [Türkçe](readme_i18n/README_TR.md) • [Українська](readme_i18n/README_UK.md) • [Tiếng Việt](readme_i18n/README_VI.md) • [中文](readme_i18n/README_ZH.md)

[homepage]: https://localsend.org
[discord]: https://discord.gg/GSRWmQNP87
[github]: https://github.com/localsend/localsend
[codeberg]: https://codeberg.org/localsend/localsend

LocalSend is a free, open-source app that allows you to securely share files and messages with nearby devices over your local network without needing an internet connection.

- [About](#about)
- [Sponsors](#sponsors)
- [Screenshots](#screenshots)
- [Download](#download)
- [How It Works](#how-it-works)
- [Getting Started](#getting-started)
- [Contributing](#contributing)
  - [Translation](#translation)
  - [Bug Fixes and Improvements](#bug-fixes-and-improvements)
- [Troubleshooting](#troubleshooting)
- [Building](#building)
  - [Android](#android)
  - [iOS](#ios)
  - [macOS](#macos)
  - [Windows](#windows)
  - [Linux](#linux)

## About

LocalSend is a cross-platform app that enables secure communication between devices using a REST API and HTTPS encryption. Unlike other messaging apps that rely on external servers, LocalSend doesn't require an internet connection or third-party servers, making it a fast and reliable solution for local communication.

## Sponsors

Browser testing via

<a href="https://www.testmuai.com/?utm_medium=sponsor&utm_source=localsend" target="_blank">
    <img src="https://localsend.org/img/sponsors/tesmu.svg" style="vertical-align: middle;" width="250" height="45" />
</a>

## Screenshots

<img src="https://localsend.org/img/screenshot-iphone.webp" alt="iPhone screenshot" height="300"/> <img src="https://localsend.org/img/screenshot-pc.webp" alt="PC screenshot" height="300"/>

## Download

[![Packaging status](https://repology.org/badge/tiny-repos/localsend.svg)](https://repology.org/project/localsend/versions)

It is recommended to download the app either from an app store or from a package manager because the app does not have an auto-update.

| Windows                 | macOS                   | Linux              | Android        | iOS           | Fire OS    |
|-------------------------|-------------------------|--------------------|----------------|---------------|------------|
| [Winget][]              | [App Store][]           | [Flathub][]        | [Play Store][] | [App Store][] | [Amazon][] |
| [Scoop][]               | [Homebrew][]            | [Nixpkgs][]        | [F-Droid][]    |               |            |
| [Chocolatey][]          | [DMG Installer][latest] | [Snap][]           | [APK][latest]  |               |            |
| [EXE Installer][latest] |                         | [AUR][]            |                |               |            |
| [Portable ZIP][latest]  |                         | [TAR][latest]      |                |               |            |
|                         |                         | [DEB][latest]      |                |               |            |
|                         |                         | [AppImage][latest] |                |               |            |

Read more about [distribution channels][].

> [!CAUTION]
> **Unofficial MSIX preview:** you can try builds from the latest commits at [localsend.ob-buff.dev](https://localsend.ob-buff.dev/). Stability is not guaranteed and all custom code tweaks are listed on that site.

[windows store]: https://www.microsoft.com/store/apps/9NCB4Z0TZ6RR
[app store]: https://apps.apple.com/us/app/localsend/id1661733229
[play store]: https://play.google.com/store/apps/details?id=org.localsend.localsend_app
[f-droid]: https://f-droid.org/packages/org.localsend.localsend_app
[amazon]: https://www.amazon.com/dp/B0BW6MP732
[winget]: https://github.com/microsoft/winget-pkgs/tree/master/manifests/l/LocalSend/LocalSend
[scoop]: https://scoop.sh/#/apps?s=0&d=1&o=true&q=localsend&id=fb88113be361ca32c0dcac423cb4afdeda0b0c66
[chocolatey]: https://community.chocolatey.org/packages/localsend
[homebrew]: https://formulae.brew.sh/cask/localsend
[flathub]: https://flathub.org/apps/details/org.localsend.localsend_app
[nixpkgs]: https://search.nixos.org/packages?show=localsend
[snap]: https://snapcraft.io/localsend
[aur]: https://aur.archlinux.org/packages/localsend-bin
[latest]: https://github.com/localsend/localsend/releases/latest
[distribution channels]: https://github.com/localsend/localsend/blob/main/CONTRIBUTING.md#distribution

**Compatibility**

| Platform | Minimum Version | Note                                                                                                                        |
|----------|-----------------|-----------------------------------------------------------------------------------------------------------------------------|
| Android  | 5.0             | -                                                                                                                           |
| iOS      | 12.0            | -                                                                                                                           |
| macOS    | 11 Big Sur      | Use OpenCore Legacy Patcher 2.0.2 (See [#1005](https://github.com/localsend/localsend/issues/1005#issuecomment-2449899384)) |
| Windows  | 10              | The last version to support Windows 7 is v1.15.4. There might be backports of newer versions for Windows 7 in the future.   |
| Linux    | N.A.            | Deps: Gnome: `xdg-desktop-portal` and `xdg-desktop-portal-gtk`, KDE: `xdg-desktop-portal` and `xdg-desktop-portal-kde`      |

## Setup

In most cases, LocalSend should work out of the box. However, if you are having trouble sending or receiving files, you may need to configure your firewall to allow LocalSend to communicate over your local network.

| Traffic Type | Protocol | Port  | Action |
|--------------|----------|-------|--------|
| Incoming     | TCP, UDP | 53317 | Allow  |
| Outgoing     | TCP, UDP | Any   | Allow  |

Also make sure to disable AP isolation on your router. It should be usually disabled by default but some routers may have it enabled (especially guest networks).
See [troubleshooting](#troubleshooting) for more information.

**Portable Mode**

(Introduced in v1.13.0)

Create a file named `settings.json` located in the same directory as the executable.
This file can be empty.
The app will use this file to store settings instead of the default location.

**Start hidden**

(Updated in v1.15.0)

To start the app hidden (only in tray), use the `--hidden` flag (example: `localsend_app.exe --hidden`).

On v1.14.0 and earlier, the app starts hidden if `autostart` flag is set, and the hidden setting is enabled.

## How It Works

LocalSend uses a secure communication protocol that allows devices to communicate with each other using a REST API. All data is sent securely over HTTPS, and the TLS/SSL certificate is generated on the fly on each device, ensuring maximum security.

For more information on the LocalSend Protocol, see the [documentation](https://github.com/localsend/protocol).

## Getting Started

To compile LocalSend from the source code, follow these steps:

1. Install Flutter [directly](https://flutter.dev) or using [fvm](https://fvm.app) (see [version required](.fvmrc))
2. Install [Rust](https://www.rust-lang.org/tools/install)
3. Clone the `LocalSend` repository
4. Run `cd app` to enter the app directory
5. Run `flutter pub get` to download dependencies
6. Run `flutter run` to start the app

> [!NOTE]
> LocalSend currently requires an older Flutter version (specified in [.fvmrc](.fvmrc))
> and thus build issues may be caused by a mismatch between the required and the (system-wide) installed Flutter version.  
> To make development more consistent, LocalSend uses [fvm](https://fvm.app) to manage the project Flutter version.
> After installing `fvm`, run `fvm flutter` instead of `flutter`.

## Contributing

We welcome contributions from anyone interested in helping improve LocalSend. If you'd like to contribute, there are a few ways to get involved:

### Translation

You can help translate LocalSend into other languages. We use the [Weblate](https://hosted.weblate.org/projects/localsend/app) platform to manage translations.

Alternatively, you can also contribute by forking this repository and adding translations manually.

The translations are located in the [app/assets/i18n](https://github.com/localsend/localsend/tree/main/app/assets/i18n) directory. Edit the `_missing_translations_<locale>.json` or `strings_<locale>.i18n.json` file to add or update translations.

<a href="https://hosted.weblate.org/engage/localsend/">
<img src="https://hosted.weblate.org/widget/localsend/app/multi-auto.svg" alt="Translation status" />
</a>

**_Take note:_ Fields decorated with `@` are not meant to be translated; they are not used in the app in any way, being merely informative text about the file or to give context to the translator.**

### Bug Fixes and Improvements

- **Bug Fixes:** If you find a bug, please create a pull request with a clear description of the issue and how to fix it.
- **Improvements:** Have an idea for how to improve LocalSend? Please create an issue first to discuss why the improvement is needed.

For more information, see the [contributing guide](https://github.com/localsend/localsend/blob/main/CONTRIBUTING.md).

## Troubleshooting

| Issue              | Platform (Sending) | Platform (Receiving) | Solution                                                                                                                                |
|--------------------|--------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| Device not visible | Any                | Any                  | Make sure to disable AP-Isolation on your router. If it is enabled, connections between devices are forbidden.                          |
| Device not visible | Any                | Windows              | Make sure to configure your network as a "private" network. Windows might be more restrictive when the network is configured as public. |
| Device not visible | macOS, iOS         | Any                  | You can try to toggle the "Local Network" permission under "Privacy" in the OS settings.                                                |
| Speed too slow     | Any                | Any                  | Use 5 Ghz; Disable encryption on both devices                                                                                           |
| Speed too slow     | Any                | Android              | Known issue. https://github.com/flutter-cavalry/saf_stream/issues/4                                                                     |

## Building

These commands are intended for maintainers only. Make sure to run them from the `app` directory.

### Android

Traditional APK

```bash
flutter build apk
```

AppBundle for Google Play

```bash
flutter build appbundle
```

### iOS

```bash
flutter build ipa
```

### macOS

```bash
flutter build macos
```

### Windows

**Traditional**

```bash
flutter build windows
```

**Local MSIX App**

```bash
flutter pub run msix:create
```

**Store ready**

```bash
flutter pub run msix:create --store
```

### Linux

**Traditional**

```bash
flutter build linux
```

**AppImage**

```bash
appimage-builder --recipe AppImageBuilder.yml
```

**Snap**

Instructions in [localsend/snap/README.md](https://github.com/localsend/snap/blob/main/README.md)

## Contributors

<a href="https://github.com/localsend/localsend/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=localsend/localsend"  alt="Localsend Contributors"/>
</a>
