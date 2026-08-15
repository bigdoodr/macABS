# macABS

A native macOS menu bar app that runs [Audiobookshelf](https://github.com/advplyr/audiobookshelf) as a supervised background server. No Docker, no Homebrew, no external dependencies — everything Audiobookshelf needs (a pinned Node.js runtime and a pre-built copy of the server) ships inside the app itself.

> **Unofficial.** This project is not affiliated with, endorsed by, or supported by the Audiobookshelf team. It's a community-built wrapper around their open-source server, in the same spirit as how Radarr/Sonarr-style menu bar apps wrap other self-hosted services. For issues with Audiobookshelf itself (the server, its features, its web UI), please use the [official Audiobookshelf repo](https://github.com/advplyr/audiobookshelf) — file issues here only for problems with this wrapper (the menu bar app, packaging, launch-at-login, etc).

## What it does

- Adds a menu bar icon with Start / Stop / Restart controls for the Audiobookshelf server
- Runs entirely locally — server config and metadata live in `~/Library/Application Support`, your library files stay wherever you point Audiobookshelf's web UI at them
- Optional "Launch at Login"
- Self-contained: the `.app` bundles its own Node runtime and Audiobookshelf build, so there's nothing to install separately

## Requirements

- macOS 13 or later
- Apple Silicon (the bundled Node runtime is currently built for `darwin-arm64` only)

## Building from source

Run `vendor-audiobookshelf.sh` once to produce the bundled runtime, then build the Xcode project as normal. See comments in `vendor-audiobookshelf.sh` and `ServerProcessManager.swift` for details on the pinned versions and bundle layout.

## License

Audiobookshelf itself is licensed under GPL-3.0 — see the [upstream repo](https://github.com/advplyr/audiobookshelf) for its license terms. This wrapper's own code is GPL-3.0.