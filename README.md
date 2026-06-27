# benkesmith-force-mobile-data

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A Cordova plugin for **forcing mobile data network routing** even if a strong Wi-Fi signal is available (e.g., when connected to a Wi-Fi network that lacks internet access). Works on both **Android** and **iOS**.

---

## Features

* 🚀 **Process-Level Routing (Android):** Forces the entire application process to bind to cellular data interfaces automatically.
* 🔍 **Smart Wi-Fi Monitoring (Android):** Once cellular routing is forced, the plugin monitors the Wi-Fi connection in the background. As soon as a stable internet uplink is restored on the Wi-Fi network, it automatically drops the cellular lock and restores default OS routing.
* 📢 **Real-Time Events (Android):** Exposes an event stream listener to notify your JavaScript layer immediately when a routing override or automatic recovery occurs.
* 🌐 **Selective Request Routing (iOS):** Exposes hooks to configure native HTTP connection sessions to actively ignore or fallback from dead Wi-Fi connections via `Multipath Service Handover`.

---

## Installation

You can install the plugin directly via Cordova CLI from your local machine or your GitHub repository:

```bash
# Install from GitHub
cordova plugin add [https://github.com/ragcsalo/benkesmith-force-mobile-data.git](https://github.com/ragcsalo/benkesmith-force-mobile-data.git)

# Install from a local directory (for development)
cordova plugin add /path/to/benkesmith-force-mobile-data
