# benkesmith-force-mobile-data

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A Cordova plugin for **forcing mobile data network routing** even if a strong Wi-Fi signal is available (e.g., when connected to a Wi-Fi network that lacks internet access). Works on both **Android** and **iOS**.

---

## Features

* 🚀 **Process-Level Routing (Android):** Forces the entire application process to bind to cellular data interfaces automatically.
* 🌐 **Selective Request Routing (iOS):** Exposes hooks to configure native HTTP connection sessions to actively ignore or fallback from dead Wi-Fi connections via `Multipath Service Handover`.
* 🔋 **Simple Toggle API:** Easily enable or disable the network override using simple asynchronous JavaScript calls.

---

## Installation

You can install the plugin directly via Cordova CLI from your local machine or your GitHub repository:

```bash
# Install from GitHub
cordova plugin add https://github.com/ragcsalo/benkesmith-force-mobile-data.git

# Install from a local directory (for development)
cordova plugin add /path/to/benkesmith-force-mobile-data
