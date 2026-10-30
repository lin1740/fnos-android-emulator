# androidemu — Android Emulator / Cloud Phone

[中文](README.md) | **English**

![version](https://img.shields.io/badge/version-v3.9.2-blue) ![arch](https://img.shields.io/badge/arch-x86__64%20%7C%20arm64-orange) ![image](https://img.shields.io/badge/image-~2GB-green) ![stars](https://img.shields.io/github/stars/lin1740/fnos-android-emulator) ![last-commit](https://img.shields.io/github/last-commit/lin1740/fnos-android-emulator) ![license](https://img.shields.io/github/license/lin1740/fnos-android-emulator)

📚 **User Manual & FAQ**: See sections below

Run an Android 12 virtual machine on fnOS with one click, remote control via browser, supporting WebRTC / WebSocket dual screen casting modes, ADB connection, APK installation, file management, and more.

Based on Android container + Scrcpy over WebRTC (screen service) dual-container architecture, adapted for fnOS unified gateway.
<img width="1288" height="900" alt="firefox exe_20260927_095032" src="https://github.com/user-attachments/assets/da7718fc-c490-4f35-be32-572f0f1a3849" />

---

## Table of Contents

- [Features](#features)
- [Installation Requirements](#installation-requirements)
- [Port Reference](#port-reference)
- [Installation Methods](#installation-methods)
- [GMS Service](#gms-service)
- [Access Methods](#access-methods)
- [Default Account](#default-account)
- [Quick Start (Cloud Phone Usage Guide)](#quick-start-cloud-phone-usage-guide)
- [ADB Connection](#adb-connection)
- [APK Installation](#apk-installation)
- [Performance Optimization](#performance-optimization)
- [Serial Console (Developer Debugging)](#serial-console-developer-debugging)
- [Container Architecture](#container-architecture)
- [Tech Stack & Translation Layers](#tech-stack--translation-layers)
- [Audit Compliance Notes](#audit-compliance-notes)
- [FAQ](#faq)
- [Known Limitations](#known-limitations)
- [Feedback Links & Channels](#feedback-links--channels)
- [Support the Publisher & Contributors](#support-the-publisher--contributors)
- [Open Source License & Disclaimer](#open-source-license--disclaimer)
- [Acknowledgements & Links](#acknowledgements--links)

---



## Features

**System & performance**
- Android 12 (x86_64) with Google libndk_translation built in; x86/ARM dual-platform auto adaptation
- 60fps screen casting; GPU acceleration (Intel/AMD/NVIDIA auto-detected, software fallback when absent)
- Startup optimization: readiness check <=30s, dex precompile, dynamic CPU governor
- VAAPI HW codec auto-detection (enabled only when supported, sw fallback otherwise)
- Memory/background optimization (no global background ban, mainstream apps run normally)

**Access & control**
- Browser-based remote control (no client): WebRTC low-latency / WebSocket compatibility, auto-switch
- fnOS unified gateway integration: one-click from App Center, login state injected
- ADB debugging (5556), file manager, terminal, serial console (off by default)
- Cloud-phone agent support for managing multiple devices

**Install & operations**
- Pre-install checks: binder driver, memory (<1GB blocks), Docker, disk (<2GB blocks), GPU capability
- Optional GMS install (wizard choice, separate carrier image, auto cleanup; auto retry on failure)
- Multi-tier domestic mirrors: fnOS CDN -> NJU GHCR -> DaoCloud
- Interruption-safe install/upgrade (temporary data cleaned on cancel)
- Container health checks + one-click repair on the status page
- Connection stability: exponential-backoff reconnect + heartbeat; fixed TURN relay port range

**Security**
- App itself runs non-root (Go gateway under a low-privilege user)
- Container "fresh-phone profile": user build, release-keys, ro.debuggable=0, no su/magisk
- seccomp hardening: blocks kernel module load, kexec, reboot, clock changes affecting the whole NAS
- Least privilege: webrtc keeps only CAP_SYS_NICE; security.status audit trail generated per deploy

**Compatibility**
- Dual translation-layer management: libndk_translation by default, houdini selectable per app list
- Simplified Chinese + China timezone by default; domestic connectivity checking (no false "no network")
- Optional LAN direct access (container gets a LAN IP so fnOS App can auto-discover the NAS; WAN access unaffected)

## Port Reference

This application uses the following ports. Only 8443 is automatically reverse-proxied by fnOS; all other ports must be handled manually depending on your use case:

| Port | Protocol | Purpose | LAN Use | External Access |
|------|----------|---------|---------|-----------------|
| 8443 | TCP | scrcpy-over-webrtc Web UI + signaling | Auto (fnOS reverse proxy) | Requires manual reverse proxy / tunnel |
| 3478 | TCP+UDP | TURN/STUN relay (required for WebRTC casting) | Auto (host port mapping) | Requires manual port mapping / tunnel |
| 5556 | TCP | ADB debugging (external adb connect) | **Localhost only by default** (manual open required for LAN) | Requires manual port mapping / tunnel |
| 50000-50100 | UDP | WebRTC media (TURN relay port range) | Auto (host port mapping) | Must also be forwarded if media goes through TURN relay |

> **Notes:**
> - The fnOS App Center `service_port` only declares 8443 for the unified gateway reverse proxy — it does not mean the app only listens on this one port.
> - Since v3.8.9 the webrtc container is back on the default `bridge` network: 8443/3478/50000-50100 are published via Docker port mapping (`host` mode is deprecated — in practice it broke ICE negotiation for the agent inside the redroid container, leaving devices offline).
> - ADB 5556 is forwarded by a host socat process to the Android container's port 5555 — not a Docker mapping.
> - 8443, 3478, and 50000-50100 work automatically on the LAN with no configuration.
> - **The TURN relay range is fixed at 50000-50100 and never self-adjusts**: compose `ports` and the in-container `COTURN_MIN_PORT`/`COTURN_MAX_PORT` must match (coturn does no port translation), so the range **does not change between versions**. The earlier "auto-avoidance / 25000-25099" experiment was reverted — it rewrites the port mapping and breaks port-forwarding rules existing users already configured. To change it, use `bash /vol1/@appcenter/androidemu/scripts/set_ports.sh` and update your router or tunnel accordingly.
> - For external access: 8443 goes through a reverse proxy; if using WebRTC casting externally, port 3478 (TCP+UDP) must also be reachable, otherwise you get a black screen or endless loading. If the direct candidates don't work and media switches to TURN relay, UDP 50000-50100 (the coturn relay port range inside the container) must be reachable as well.



## Installation Requirements

| Item | Minimum | Recommended |
|------|---------|-------------|
| System | fnOS 1.1.8+ | Latest fnOS |
| Architecture | x86_64 / aarch64 | x86_64 |
| CPU | 2 cores | 4 cores+ |
| Memory | 2 GB | 4 GB+ |
| Storage | 4 GB free | 8 GB+ (including ~2GB image) |
| Network | LAN | — |

> **Dependency app (required on both architectures)**: this app declares a dependency on the App Center app "binder_linux" (`binder_linux_driver`), which provides the kernel binder support that containerized Android requires. Install and enable it first; if it is missing or disabled, the App Center blocks installing/enabling this app and tells you why. On x86 and on kernels without built-in binder, that dependency app loads the kernel module and mounts binderfs (fnOS 6.18.18 and later already build binder in; the dependency app then only pulls it up and verifies).
> **X86 devices**: Docker needs `/dev/dri` passthrough for hardware acceleration; auto-fallback to software rendering if no GPU.
> **ARM devices**: Auto uses software rendering (gpu_mode=guest); most ARM kernels already have binder/binderfs built in, but the "binder_linux" dependency app still has to be installed and enabled.
>
> **Architecture Compatibility**: x86_64 has been thoroughly tested on fnOS. ARM64 (aarch64) is adapted at the code level (auto software rendering, in-container binderfs, architecture detection), but due to limited test devices, ARM users are advised to monitor boot status after installation. Feedback is welcome via the channels below.

---

## Installation Methods

### Method 1: fnOS App Center (Recommended)

1. Open fnOS App Center
2. Search for "Android Emulator" or "androidemu"
3. Click install, follow the wizard:
   - **Google Services (GMS)**: Choose whether to install Google Services Framework and Play Store (default: not installed, lightweight and stable)
   - **Resolution**: Optional, auto-adapts to multiple devices
   - **Ports**: Optional, defaults work fine
4. Wait for image pull to complete (~2GB, priority DaoCloud/fnOS mirror)
5. Click "Open" after installation to enter Scrcpy interface

> **Note**: If GMS installation is selected, the container will automatically detect system architecture (x86_64/arm64) on first boot, pull the corresponding GMS image and extract files to install to system partitions, then restart automatically. The whole process takes about 3-5 minutes (depending on network speed). GMS requires a network environment to log in and use normally.

### Method 2: Manual fpk Installation

1. Download latest `androidemu_all_x.x.x.fpk`
2. Select "Manual Install" in fnOS App Center, upload fpk file
3. Wait for installation and image pull to complete

### Image Acceleration

Installation automatically tries image sources in this order:
1. fnOS mirror `docker.fnnas.com`
2. DaoCloud free mirror `docker.m.daocloud.io`
3. Docker Hub official repository

If all fail, configure image accelerator (registry-mirrors) in fnOS Docker settings and retry.

> **Download Speed Note**: First-time installation pulls ~2GB Android container image. During peak evening hours (typically 20:00-24:00), international bandwidth is congested and slower download speeds are normal — please be patient or retry during daytime. It is recommended to configure an appropriate mirror accelerator in fnOS **Docker → Image Registry → Settings → Mirror Settings**.

---

## GMS Service

### Overview

GMS (Google Mobile Services) is a set of proprietary service components provided by Google, including Google Play Services, Google Play Store, Google Services Framework, Google Account Manager, etc. After installing GMS, you can use the Play Store to download apps, receive Google push notifications, and use apps that rely on Google services.

GMS in this app is **optional**: the installation wizard defaults to "Do not install", keeping a pure Android system that is lightweight and stable. Users must actively select "Install" and confirm the legal notice before installation is triggered. The app installation package itself **does not contain any GMS binary files**; GMS files are extracted from a separate file carrier image at installation time.

### Architecture Support

GMS service supports both x86_64 and arm64 architectures. The installation script automatically detects the system architecture (`uname -m`) and pulls the corresponding version:

| Architecture | GMS Image | Source |
|--------------|-----------|--------|
| x86_64 | `ghcr.io/lin1740/androidemu-gms:x86_64-1.0.0` | Extracted from third-party redroid derivative image (whojk/redroid:12.0.0_mindthegapps) |
| arm64 | `ghcr.io/lin1740/androidemu-gms:arm64-1.0.0` | Extracted from official MindTheGapps 12.1.0-arm64 package |

- x86_64 version: MindTheGapps officially does not provide x86_64 prebuilt packages, so system files are extracted from a third-party redroid image with GMS integrated
- arm64 version: Uses the official MindTheGapps arm64 release package
- Both images are pushed to GitHub Container Registry (GHCR) and are publicly pullable

### Installation

**Step 1: Select in Installation Wizard**

In the "Google Services (GMS)" step of the installation wizard, select "Install GMS Service and Play Store", read and confirm the legal notice, then continue.

**Step 2: Auto-detect Architecture and Pull Image**

After the container first starts, the installation script automatically detects the system architecture and pulls the corresponding GMS file carrier image (~560-700MB) from GHCR. Pulling supports multi-source fallback:
1. Nanjing University mirror `ghcr.nju.edu.cn`
2. DaoCloud mirror `docker.m.daocloud.io`
3. GHCR official `ghcr.io`

> **Download Speed Note**: The GMS image is ~560-700MB. Slower download speeds during peak evening hours are normal — please be patient or retry during daytime. If pulling fails, the script automatically tries the next mirror source.

**Step 3: Extract Files and Install to System Partition**

After the image is pulled, the script creates a temporary container via `docker create`, extracts GMS files using a `docker export | tar -x` pipeline, and copies them to `/system/priv-app/`, `/system/app/`, `/system/framework/`, `/system/etc/` and other directories according to the Android 12 partition structure, with correct permissions (chmod 644/755).

**Step 4: Wait for System Ready and Restart Container**

The script waits for `sys.boot_completed=1` and core services (surfaceflinger/mediaserver/adbd) to be ready, then restarts the Android container for GMS to take effect.

**Step 5: Automatic Cleanup**

After successful GMS installation, the script automatically deletes the GMS file carrier image (~560-700MB) to free disk space — no manual cleanup required.

The entire installation process takes approximately 3-10 minutes (depending on network speed and NAS performance).

### Verification After Installation

After installation, you can verify whether GMS was installed successfully via:

**Method 1: Check App List**

Open scrcpy-over-webrtc; the "Play Store" (Google Play Store) icon should appear in the Android app list.

**Method 2: Command Line Check**

```bash
docker exec androidemu-android pm list packages | grep google
```

You should see these packages:
- `com.google.android.gsf` — Google Services Framework
- `com.google.android.gms` — Google Play Services
- `com.android.vending` — Google Play Store

**Method 3: Check Installation Log**

```bash
cat /var/apps/androidemu/var/gms_install.log
```

The log records each step's execution status and result.

### GMSFAQ

**Q: GMS image pull fails, what should I do?**

A: The script automatically tries multiple mirror sources (Nanjing University → DaoCloud → GHCR official). If all fail:
1. Check NAS network connection and DNS configuration
2. Configure an available mirror accelerator in fnOS **Docker → Image Registry → Settings → Mirror Settings**
3. Configure a proxy in fnOS **Docker → Image Registry → Settings → Proxy Settings** (if network egress is restricted)
4. Manually pull the image then retry: `docker pull ghcr.io/lin1740/androidemu-gms:x86_64-1.0.0` (x86_64) or `docker pull ghcr.io/lin1740/androidemu-gms:arm64-1.0.0` (arm64)

**Q: After installing GMS, scrcpy keeps connecting/disconnecting, then stabilizes after a while — is this normal?**

A: This is normal. After GMS installation completes, the Android container restarts. After restart, GMS core components (GmsCore, GoogleServicesFramework, Play Store, etc.) need to perform first-boot dex optimization, service registration, permission initialization, and network handshake. This process typically lasts 1-3 minutes. During this time, scrcpy may show "Connecting" or repeatedly disconnect/reconnect. Please be patient and do not frequently refresh or restart the container.

**Q: Black screen or boot failure after installing GMS?**

A: GMS installation failure may cause system issues. Solution:
1. Check installation log: `cat /var/apps/androidemu/var/gms_install.log`
2. If installation failed, uninstall the current app (select "Keep data"), reinstall and select "Do not install GMS"
3. After reinstallation, the system returns to normal and data is preserved

**Q: Already installed Standard Edition, want to add GMS?**

A: Currently GMS can only be selected during installation. Users who already installed Standard Edition need to:
1. Uninstall the current app (select "Keep data" — installed apps and data will not be lost)
2. Reinstall, select "Install GMS Service and Play Store" in the wizard
3. After installation, data is preserved and GMS is automatically installed

**Q: After GMS installation completes, can the GMS image be deleted?**

A: Yes. The GMS image is only used for file extraction during installation and is no longer needed afterward. In v3.8.7+, the installation script **automatically deletes** the GMS image after successful installation. To manually clean up:
```bash
docker rmi ghcr.io/lin1740/androidemu-gms:x86_64-1.0.0   # x86_64
docker rmi ghcr.io/lin1740/androidemu-gms:arm64-1.0.0    # arm64
```
After deletion, if you need to reinstall GMS in the future (e.g., after uninstalling and reinstalling), the image will be re-pulled from the registry.

**Q: What's the difference between this GMS and the old GMS edition image?**

A:
- **Old GMS edition (before 3.8.7)**: Directly used the third-party whojk/redroid image as the Android container; GPU host mode was incompatible with some hardware causing black screen
- **New GMS (3.8.7+)**: Always uses the official redroid standard image as the Android container; GPU mode works normally. During installation, architecture is auto-detected and files are extracted from a separate GMS file carrier image into the system partition — no black screen issues. The app package itself does not contain GMS binary files

### Uninstall & Reinstall

- **Uninstall app**: Click "Uninstall" in fnOS App Center, choose whether to keep data. When keeping data, apps and data inside the Android container are not lost, but GMS service is removed along with the container
- **Reinstall**: During reinstallation, select "Install GMS" again in the wizard; the script will re-pull the GMS image and install
- **Remove GMS only without reinstalling**: Currently not supported. To remove GMS, you need to uninstall the app then reinstall and select "Do not install GMS"

### Legal Notice

GMS (Google Mobile Services) is proprietary software of Google LLC, protected by copyright law and relevant international treaties. The app installation package itself does not contain any GMS binary files; only after the user actively selects "Install GMS Service" are files extracted at runtime from a separate GMS file carrier image and installed into the Android container.

- Use of GMS is subject to Google's relevant terms of service and privacy policy
- This project has not obtained official Google authorization or MADA certification; distribution and use of GMS may carry legal risks, and is limited to personal learning and research purposes
- For commercial use or large-scale distribution, you must obtain formal authorization from Google yourself
- Commercial users are recommended to prioritize open-source compliant alternatives such as microG

> For the complete GMS legal notice, license terms, and disclaimer, see the "Open Source License & Disclaimer" section of this document.

---

## Access Methods

### LAN (Recommended, Full Features)

Click "Open" in fnOS App Center, or directly access:
```
https://<NAS_IP>:<NAS_PORT>/app/androidemu/
```
Can also directly access screen service native port:
```
http://<NAS_IP>:8443
```

WebRTC casting works normally in LAN, low latency, high framerate, all features (file management, terminal, casting settings etc.) available.

### fnOS Official Remote Domain (xxx.fnos.net)

When accessing via fnOS official remote domain:
- ✅ WebSocket casting auto-enabled, can view and control screen
- ✅ **Since v3.8.8 (scrcpy-over-webrtc 0.4.1)**: scrcpy-over-webrtc specifically adapts to the fnOS gateway, auto-switching to WebSocket over fnOS official gateway port 443 when detecting fnOS environment, more stable for external network access
- ⚠️ File management, terminal, etc. relying on WebRTC DataChannel (UDP) may be limited externally (fnOS reverse proxy only passes TCP)
- ⚠️ Framerate and latency affected by upstream bandwidth

> Reason: fnOS reverse proxy only passes TCP (HTTP/HTTPS/WebSocket), not UDP. WebRTC media stream uses UDP, so auto-downgrades to WebSocket casting.
>
> v3.6.7+ enhanced external network auto-adaptation: auto-detect and switch to WebSocket casting mode, if switch fails then provide MJPEG fallback screen, ensuring external network access always available.
>
> **v3.8.8 external terminal/file center note**: scrcpy-over-webrtc 0.4.1 adds "dynamic TURN server allocation", which attempts to carry DataChannel data over WebSocket in fnOS gateway environment. If terminal/file center still doesn't work externally, recommend using on LAN, or exposing both TCP 8443 and UDP 3478 via frp or similar tools (see below).

### fnOS APP

When accessing via fnOS mobile APP built-in browser:
- ⚠️ Some versions of fnOS APP WebView have limited WebSocket proxy support, may show "waiting for device push stream timeout"
- ✅ Recommended to use mobile browser (Chrome / Edge / system browser) to open fnOS remote domain directly

### Public IP / Intranet Penetration / Reverse Proxy

If you have public IP or use intranet penetration (frp, ZeroTier, Tailscale etc.):
- ✅ Map port 8443 to external network, can use WebRTC casting directly
- ✅ Need to set "External access address (WebRTC media stream)" in "Casting Settings" to your public domain or IP
- ✅ TURN relay server built-in, ensure UDP 3478 port reachable; if media has to go through TURN relay (the fallback when direct candidates fail), also forward UDP 50000-50100 (the relay port range)

#### External Network Access Guide (Important)

**Limitations of fnOS remote domain (xxx.fnos.net):**
- fnOS reverse proxy **only passes TCP**, WebRTC UDP media streams cannot pass through
- Therefore, when accessing via fnOS remote domain, **only WS casting works** (TCP), WebRTC casting will fail
- File management, terminal (ADB), etc. rely on WebRTC DataChannel (UDP), **not available externally**
- WS casting first tries WebRTC (UDP), then falls back to WS after timeout, so **initial connection may take 10-30 seconds**

**Recommended external access solution (full functionality):**

Use frp or other intranet penetration tools to **expose both TCP 8443 and UDP 3478**:

```ini
# frpc.ini example
[androidemu_web]
type = tcp
local_ip = 127.0.0.1
local_port = 8443
remote_port = 8443

[androidemu_turn]
type = udp
local_ip = 127.0.0.1
local_port = 3478
remote_port = 3478
```

After configuration, access via `http://<your-domain>:8443`, all features including WebRTC casting, file management, and terminal are available.

> Note: the TURN server (coturn) inside the container relays media over **UDP 50000-50100** (see the port mapping in `docker-compose.yaml`). When the direct ICE candidates (STUN/srflx) are unreachable, media falls back to TURN relay, so that UDP port range must be reachable too (forward the range if your tunnel tool supports port ranges, otherwise use plain port mapping or a firewall/route rule).

**How to fix slow WS casting connection:**
1. Wait 10-30 seconds patiently, WebRTC will timeout and auto-fallback to WS
2. Or manually click "Switch to WebSocket casting" button on the connection page to use WS immediately
3. After exposing UDP 3478 via frp, WebRTC connects directly without waiting

---

## Default Account

Scrcpy screen service default login account:

| Item | Value |
|------|-------|
| Username | `admin` |
| Password | `admin123` |

> Login state auto-injected when accessing via fnOS unified gateway, no manual input needed. Manual login required when directly accessing port 8443, please change password after login.

---
## Quick Start (Cloud Phone Usage Guide)

### 1. Login

- Access via fnOS App Center "Open" button — auto-login, no credentials needed
- Direct access at `http://<NAS_IP>:8443` uses default account `admin` / `admin123`
- After login, change the password in「Settings」

### 2. Main Interface

Left sidebar menu:

| Menu | Function |
|------|----------|
| Cloud VM | View and manage connected Android devices, click to open screen |
| Dashboard | Device status overview (online count, CPU, memory, etc.) |
| Files | File center, batch install/transfer APKs and files |
| Deploy | Device deployment configuration |
| Terminal | Android shell command line (ADB debugging) |
| Peripherals | Peripheral management |
| User Management | Manage scrcpy-over-webrtc login users |
| Device Ops | Device grouping and tag management |
| Share | Generate device share links |
| Audit | Operation audit logs |
| Settings | System settings (change password, ports, etc.) |

### 3. View Devices

- Click「Cloud VM」in the sidebar — connected Android devices appear in the list
- Device status: **Online** (green) / **Offline** (gray)
- After normal installation, the device auto-registers and shows online (default ID: `androidemu`)
- If showing "0 devices online", see the FAQ troubleshooting section

### 4. Screen Casting

1. In「Cloud VM」, click an online device to open the screen
2. First connection uses **WebRTC** mode (best quality, low latency)
3. If WebRTC fails, use the mode switch button at the top to switch to **WebSocket (WS)** mode
4. Screen controls:
   - **Click**: Left mouse click = Android touch
   - **Swipe**: Hold left button and drag = Android swipe gesture
   - **Zoom**: Mouse wheel = pinch-to-zoom
   - **Back**: Side toolbar back button, or press Esc
   - **Home**: Side toolbar home button, or press Home
   - **Recent apps**: Side toolbar recent button
   - **Keyboard input**: Type directly on keyboard — input goes to the focused field
   - **Volume**: Side toolbar volume +/- buttons

### 5. Install APK

**Method 1: Batch install (recommended)**
1. Click「Files」→ select「Batch Install/Transfer」tab
2. Drag APK files to the upload area, or click to upload
3. Select target devices (check the devices to install on)
4. Task type:「Silent install APK」
5. Click「Dispatch batch task」and wait for completion

**Method 2: Single device install**
1. Open the device screen
2. Find the「Install APK」button in the side toolbar
3. Select a local APK file to upload and install

> Uploaded APK files are not auto-deleted after installation. Manually click「Remove」on the Files page, or see the FAQ for cleanup methods.

### 6. Terminal (ADB Debugging)

1. Click「Terminal」in the sidebar
2. Select target device
3. Enter Android shell commands directly. Common commands:

   List installed apps:
   ```
   pm list packages
   ```

   Uninstall an app (replace `<package>` with the actual package name):
   ```
   pm uninstall <package>
   ```

   Check if Android finished booting:
   ```
   getprop sys.boot_completed
   ```
4. You can also connect externally with `adb connect <NAS_IP>:5556`

### 7. File Management

- 「Files」→「File Center」to browse and manage files on the Android device
- Supports upload to device, download from device, and delete files
- 「Batch Install/Transfer」for sending APKs or files to multiple devices simultaneously

### 8. Using the Mobile APP (Optional)

Cloud Phone officially provides a standalone **Android APP client**, offering a better mobile experience than browser (true fullscreen, no address bar, background keep-alive).

**Download and install:**
1. Open https://webrtc-phone.com/#download in your phone browser
2. Download `ScrcpyOverWebRTC-release.apk` and install it
3. Open the APP, enter your access address in the address bar:
   - LAN: `http://<NAS_IP>:8443`
   - External: your fnOS remote domain or reverse proxy address
4. Log in with default account `admin` / `admin123` (or your modified account)
5. Tap a device to start screen mirroring and control

> The APP and browser access the same server, with fully synchronized data and configuration. The APP's advantages are mobile-optimized UX and background keep-alive; core features are identical to the browser.

### 9. Quick Reference

| Action | Method |
|--------|--------|
| Screenshot | Side toolbar screenshot button |
| Rotate screen | Side toolbar rotate button |
| Lock/Wake screen | Single-click power button in side toolbar |
| Power off/Reboot | Long-press power button in side toolbar → select from Android power menu |
| Switch cast mode | Top of screen: WebRTC/WS toggle |
| Change password | Sidebar「Settings」→ Change password |
| Share device | Sidebar「Share」→ Generate share link |

---

## ADB Connection

> **Important**: ADB is an Android debugging channel — **it only runs commands, installs APKs, and debugs; it does NOT stream the screen**. To view the Android screen, use the Scrcpy-over-WebRTC web interface (`http://<NAS_IP>:8443`) or the Scrcpy-over-WebRTC mobile APP. Remote control tools like Scrcpy / QtScrcpy that depend on scrcpy-server are **incompatible** (this container uses cloudphone-agent, no scrcpy-server), and will show endless loading with no screen.

ADB 5556 **binds to 127.0.0.1 by default** (security: ADB has no password), accessible from the NAS itself only. To connect from another LAN device (e.g. your PC), first manually open the port:

> ⚠️ **Security note**: the container ships with a "fresh-phone profile" — user build, release-keys, `ro.debuggable=0`, no su/magisk; normal apps' root detection will not trigger. adb (port 5556) runs as shell (non-root) but is still a management entry from host into the container — only expose it on a trusted LAN and **switch back to `ADB_BIND=127.0.0.1`** after use; never map 5556 to the public internet.

### 1. Open ADB Port 5556

**Step 1: SSH into the NAS and edit the config file**

```bash
nano /var/apps/androidemu/var/ports.conf
```

Add or modify the following line:

```
ADB_BIND=0.0.0.0
```

> nano controls: press `Ctrl+O` to save, press `Enter` to confirm filename, press `Ctrl+X` to exit.

**Step 2: Restart the ADB forwarder**

```bash
sudo pkill -f redroid_adb_forward.sh && sudo bash /vol1/@appcenter/androidemu/scripts/redroid_adb_forward.sh install
```

**Step 3: Verify the port is open**

```bash
ss -tln | grep 5556
```

It should show `0.0.0.0:5556`, meaning it's listening on all network interfaces.

### 2. Connect to Android Container

**Step 4: Connect from your PC**

Replace `<NAS_IP>` with your NAS's actual LAN IP address:

```bash
adb connect <NAS_IP>:5556
```

A successful connection shows `connected to <NAS_IP>:5556`.

**Step 5: Enter Android shell**

```bash
adb shell
```

Once inside, you can run Android commands (e.g. `pm list packages` to list installed apps).

> You can also skip ADB and use Android shell directly in the "Terminal" of the Scrcpy interface.

> ⚠️ **Security note**: ADB has no password authentication. When done, change back to `ADB_BIND=127.0.0.1` and restart the forwarder to avoid leaving the port exposed.

---

## APK Installation

1. Click "File" or "Upload" in Scrcpy interface
2. Select APK file to upload
3. Click APK in file manager within Android container to install

> **Note**: This app is x86_64 architecture. Image has built-in ARM translation layer, most ARM apps can run; but ARM64 apps with anti-emulator detection or complex JIT may crash on startup (translation layer capability boundary).

---

## Performance Optimization

This app has multiple built-in performance optimizations to reduce access and usage latency:

### 1. Process Priority Boost

webrtc signaling service and TURN relay service both start with `nice=-10` (higher than default priority), reducing CPU scheduling latency, avoiding screen stutter.

> Technical detail: Docker containers default drop `CAP_SYS_NICE`, this app explicitly adds `cap_add: SYS_NICE` in compose, this capability only affects process scheduling priority, not device/network/filesystem access.

### 2. Background Service Streamlining

After container startup, automatically disable unnecessary Android system services, releasing CPU and memory:
- Bluetooth services (`com.android.bluetooth`, `com.android.bluetoothmidiservice`) — container has no Bluetooth hardware
- NFC service (`com.android.nfc`) — container has no NFC hardware
- Print service (`com.android.printspooler`) — container doesn't need printing
- Backup services (`com.android.backupconfirm`, `com.android.sharedstoragebackup`) — container doesn't need backup

> **Note**: `com.android.location.fused` (location fused service) cannot be disabled, it's a dependency of LocationManagerService, disabling will cause system_server crash and Android won't boot.

### 3. CPU Dynamic Frequency Scaling

Installation auto-configures CPU governor to dynamic frequency mode (schedutil/ondemand), sets minimum frequency to 40% of maximum:
- Light load: CPU won't drop too low, ensuring operation response speed
- Heavy load: auto-rise to maximum frequency, full performance
- Only works on devices supporting cpufreq, silently skips if not supported
- Won't go below quad-core CPU limit (dynamic adjustment, won't over-restrict performance)

### 4. Serial Console Disabled by Default

Android serial console (`androidboot.console=0`) disabled by default, reducing performance overhead from kernel log output. Developers can manually enable if needed (see below).

### 5. GPU Hardware Acceleration

- **X86 devices**: Auto-detect `/dev/dri`, uses `gpu_mode=host` hardware acceleration when GPU present, 60fps

**GPU platform support matrix** (dual-machine tested + driver source-level conclusions):

| Platform | OpenGL | Vulkan | HW decode | HW encode |
|---|---|---|---|---|
| Intel (iHD) | ✅ | ✅ | ✅ | ✅ |
| AMD amdgpu cards (Polaris+) | ✅ | ✅ | ✅ | ✅ |
| AMD legacy (radeon KMD, GCN APU) | ✅ | ❌ | ❌ (driver-level; switching to amdgpu KMD resolves it, advanced option) | ✅ |
| ARM Mali (Panfrost) | ✅ | ✅ | V4L2 route | upstream pending |
| NVIDIA | ✅ | ✅ | ✅ NVDEC | ✅ NVENC |

> Platforms without HW decode/encode automatically fall back to software; functionality is unaffected with higher CPU usage. Host VAAPI capability is auto-detected at install time (vainfo).
- **ARM devices**: Auto uses `gpu_mode=guest` software rendering, 60fps (unified high frame rate; low-end devices can revert to 30fps in compose if laggy)

### 6. Domestic App Optimization 

Domestic App Performance Optimization : System-level optimizations for high-resource domestic apps (Douyin/Kuaishou etc.):

| Optimization | Description |
|--------------|-------------|
| **Background process limit** | `background_process_limit=4`, system more aggressively reclaims excess processes |
| **Disable auto-sync** | `auto_sync=0`, reduces background sync overhead |
| **Disable background data** | `mobile_data_always_on=0`, prevents background data/CPU usage |
| **Disable scanning** | WiFi/BLE scan off, reduces location and background wakeups |
| **Disable network optimizers** | Turn off network recommendations, adaptive connectivity |
| **Animation half-speed** | Window/transition/animator scale set to 0.5, smooth yet CPU-efficient |
| **GPU forced rendering** | `debug.hwui.renderer=skiagl`, GPU renders UI |
| **Layer composition optimization** | `disable_backpressure=1`, `latch_unsignaled=1`, reduces composition latency |
| **Memory management optimization** | Adjusted lmkd thresholds, more aggressive background app memory reclamation |

### 7. Optional Resource Limits 

If your NAS has limited performance, enable resource limits in `docker-compose.yaml` (commented by default, uncomment to enable):

```yaml
deploy:
  resources:
    limits:
      cpus: '4.0'      # Max 4 CPU cores
      memory: 4G       # Max 4GB memory
```

> Restart container after modification: `docker compose -f /vol1/@appcenter/androidemu/app/docker/docker-compose.yaml restart`

---


## App Compatibility (honest tiers)

This app runs Android apps on an x86_64 container with an ARM translation layer. Compatibility has clear boundaries:

### ✅ Supported
Most utility, productivity, media and system apps (x86-native or regular ARM translation paths). The mass-crash issue caused by the previous global background restriction has been fixed; **WeChat (including its Tinker hotfix mechanism) now runs normally after the missing 32-bit ARM library set was added**.

### ⚠️ Partially supported
- **Slow cold start for large apps**: ARM apps may take 20-40 s to launch on low-end CPUs (translation overhead), then run normally
- **Apps requiring GMS**: only work when Google services are installed during setup

### ❌ Not supported (known boundaries)
| Type | Example | Reason |
|---|---|---|
| Hardened/obfuscated apps | Coolapk (new builds) | Uses NetEase Yidun hardening; its native verification lib fails symbol resolution under translation |
| Pending verification | Huawei AppGallery | Works cross-device on regular phones (no HMS required); container failure cause TBD (suspected hardening/native incompatibility) |
| Anti-emulator apps | Coolapk | Detects the container/emulator and exits |
| Apps with their own unstable SDKs | Bilibili (some builds) | Its crash-reporting SDK misbehaves in containers |

> These are common boundaries of all x86 Android container solutions (Android-x86 / BlissOS alike). This app targets idle/automation/tool scenarios; social apps are out of scope.

## Hardware Passthrough & Acceleration

This app passes the host GPU's graphics and video capabilities straight into the Android container (GPU host mode: `/dev/dri` device passthrough + shared host mesa/driver stack), automatically choosing the route per platform and falling back when unsupported — zero user intervention.

### 1. Video HW decode/encode (three-layer architecture)

```
In-container player/app -> C2 plugin (forwarding) -> Host daemon (VAAPI/NVDEC) -> GPU hardware
```

- **Host daemon**: resident after install; talks to hardware via standard VAAPI (covers Intel iHD/i965, AMD radeonsi/r600 backends, auto-detected) and a dedicated NVIDIA route (NVDEC/NVENC + nvidia-vaapi-driver);
- **In-container C2 plugin**: pure forwarding layer, GPU-brand agnostic — one plugin serves every GPU host;
- **Auto-detection**: vainfo probes encode (EncSlice/EncPicture) and decode (H264 VLD) at install; hardware routes are enabled only when supported, otherwise the software codecs take over (no black-screen/garble risk).

**Video HW decode/encode support list** (host side, daemon-tested + driver source-level conclusions):

| Host GPU | HW decode | HW encode | Notes |
|---|---|---|---|
| Intel iGPU/dGPU (iHD, HD 500-series+) | ✅ | ✅ | newer iGPUs auto-select iHD |
| Intel legacy iGPUs (i965, HD 2000-series+) | ✅ | some models | same VAAPI standard interface |
| AMD dGPUs RX 400 ~ RX 7000 (amdgpu) | ✅ | ✅ | RDNA2+ adds AV1 decode |
| AMD R9 285~390 / R7 260X (switchable to amdgpu) | ✅ | ✅ | grub driver switch required (advanced) |
| AMD early GCN (R9 270/280 etc., radeon KMD) | ❌ | ✅ | driver-level limitation (source-confirmed) |
| AMD legacy (HD 2000~6000, TeraScale) | ✅ H264 | some models | old-card UVD path |
| AMD APUs (Kaveri etc., GCN APU) | ❌ | ✅ | same logic as dGPUs; amdgpu switch fixes decode |
| NVIDIA (NVDEC/NVENC, GTX 10-series+) | ✅ | ✅ | 1050 Ti verified upstream; full userland driver stack mounted since 3.8.9 |
| ARM Mali (Panfrost) | V4L2 route (in progress) | upstream pending | graphics rendering tested ✅ |

> The above is host-side capability. The in-container plugin is built per Android major version (Android 12 build ready; 12L/13 producible with the same pipeline). Unsupported combos fall back to software decode — functionality is unaffected with higher CPU usage.

### 2. Audio path (no hardware acceleration needed)

Audio uses Codec2 software encoding (OPUS) — OPUS costs <2% of a single core, and consumer audio hardware has no universal hardware encoder, so audio does not depend on GPU passthrough. 3.8.9 fixed the OPUS init issue with an audio_fix.py daemon (30s patrol auto-restore); the no-audio/connection-crash issues are fully resolved.

### 3. OpenGL / Vulkan passthrough

- **OpenGL (EGL/GLES)**: the container loads the host mesa driver stack directly — Intel/AMD (mesa) ✅, ARM Mali (Panfrost) ✅ tested, NVIDIA via GPU host mode ✅;
- **Vulkan**: follows the host ICD — ARM Mali (panvk) ✅ verified on the ARM machine; Intel/AMD/NVIDIA per driver support;
- **No GPU / unsupported platforms**: automatic `swiftshader` software rendering keeps boot and display working (stable since 3.8.x).

### 4. Capability self-check

The status page shows the current GPU mode (hardware/software), VAAPI codec capabilities and the rendering route in real time; the "Fix GPU/Display" button self-heals common passthrough issues.

## Serial Console (Developer Debugging)

Serial console disabled by default to reduce performance overhead. To enable for debugging:

```bash
# Temporarily enable (lost after container restart)
docker exec -u 0 androidemu-android setprop persist.sys.serialconsole 1
docker exec -u 0 androidemu-android start console

# View console output
docker exec -u 0 androidemu-android dmesg -w

# Disable
docker exec -u 0 androidemu-android stop console
docker exec -u 0 androidemu-android setprop persist.sys.serialconsole 0
```

> Note: Enabling serial console increases kernel log output, may slightly affect performance, recommended to disable after debugging.

---

## Container Architecture

```
┌─────────────────────────────────────────────┐
│  fnOS Host                                  │
│                                             │
│  ┌──────────────────┐  ┌─────────────────┐  │
│  │  androidemu-     │  │  androidemu-    │  │
│  │  android         │  │  webrtc         │  │
│  │  (redroid)       │  │  (scrcpy+TURN)  │  │
│  │                  │  │                 │  │
│  │  Android 12      │  │  Signaling :8443│  │
│  │  ADB :5556       │  │  TURN  :3478    │  │
│  │  bridge network  │  │  bridge network │  │
│  │  privileged      │  │  SYS_NICE       │  │
│  └──────────────────┘  └─────────────────┘  │
│            │                    │           │
│            └────── scrcpy ──────┘           │
│                  (ADB over TCP)             │
└─────────────────────────────────────────────┘
                       │
                       ▼
            fnOS Unified Gateway
                       │
                       ▼
                   Browser
```

---

## Tech Stack & Translation Layers

androidemu goes through **3 core translation/conversion layers** from hardware to browser display, plus 1 optional instruction-set translation layer:

### Layer 1: Containerization Layer (Docker)

- Not a full VM, but **process-level container isolation**. Android userspace runs directly on the host Linux kernel
- Shares the same kernel with the host, **does not translate CPU instructions**, near-native performance
- Provides filesystem, network, and process isolation; the Android container runs in `privileged` mode (required by upstream redroid for binder device access)

### Layer 2: GPU Rendering Translation Layer

| Mode | Scenario | Mechanism | FPS |
|------|----------|-----------|-----|
| GPU passthrough (guest) | X86 with iGPU/dGPU | Android OpenGL ES commands sent directly to host GPU driver, almost no translation overhead | 60fps |
| Software rendering (swiftshader) | No GPU / ARM devices | **swiftshader** translates OpenGL ES into CPU instructions, with translation overhead | 60fps (low-end devices can revert to 30fps) |

- Install script automatically detects host GPU capability; uses GPU passthrough when `/dev/dri` exists, otherwise falls back to software rendering
- ARM devices use software rendering (swiftshader) by default

### Layer 3: Display Capture & Encoding Layer

- **scrcpy** captures frames via Android's surfaceflinger
- Encodes into **H.264** video stream (2-10Mbps bitrate, 960px long edge)
- Transmits to browser via **WebRTC** (TURN/STUN relay + P2P)
- Browser decodes and displays; **audio is enabled** (v3.8.9 fix: enables the Codec2 software codec so scrcpy-over-webrtc's default OPUS codec initializes correctly, kept alive by the audio_fix.py watchdog; audio streams reliably)

### Layer 4: ABI Instruction-Set Translation Layer (libndk_translation)

- x86 images ship with Google's **libndk_translation**, translating ARM instructions to x86 via the Native Bridge mechanism
- Current config (Android 12 image): `ro.dalvik.vm.native.bridge=libnb.so` (pointing at `libndk_translation.so`), `ro.enable.native.bridge.exec=1`
- **Only 64-bit ARM (arm64-v8a) actually works**: the Android 12 image ships only the 64-bit translator; the 32-bit parts of `/system/lib/libndk_translation.so` and `libnb.so` are absent
- `armeabi-v7a` (32-bit ARM) **installs but cannot run**: the app installs and shows an icon, then fails at launch because the 32-bit translator is missing (`dlopen` reports `is for EM_ARM (40) instead of EM_386`, or the process crashes during init). Apps that only ship 32-bit builds (JD, Xiaohongshu, Toutiao) fall into this category; use a 64-bit APK instead
- A 32-bit translator does exist elsewhere: the complete 32-bit + 64-bit translator set has been extracted from Google's official **Android 11 (API 30) x86_64** image (`libndk_translation.so`, 22 proxy libs, `lib/arm` and `lib64/arm64` guest libs, `bin/arm{,_64}/linker`, `ndk_translation.rc` and `binfmt_misc` configs), and 32-bit apps (JD, Xiaohongshu) launch normally on an Android 11 container. **Cross-version injection does not work**: putting the Android 11 translator into an Android 12 container boots and installs fine, but app processes crash during init (`SIGSEGV` in `AppProcessPostInit`). This capability is not shipped in the package yet; if you need 32-bit support, select Android 11 in the installer
- Image does **not** include libhoudini (Intel's other closed-source solution, must be obtained separately) or QEMU translator (only related property files, not an actual translator)
- ARM devices: Android arm64 native, no translation layer needed

### Full Data Flow

```
User clicks in browser
    │
    ▼
WebRTC receives H.264 ←── TURN/STUN relay ←── scrcpy encodes ←── surfaceflinger captures
    │                                                          │
    │                                                          ▼
    │                                                   Android 12 (redroid)
    │                                                          │
    │                                                          ▼
    │                                                   GPU Rendering Layer
    │                                                   (GPU passthrough / swiftshader)
    │                                                          │
    ▼                                                          ▼
Browser display ←──── fnOS Gateway ←──── Docker Container ←──── Host Linux Kernel
```

---

## Audit Compliance Notes

This app has passed fnOS official 7-point self-check (basic info, permission declaration, network ports, data storage, start/stop, uninstall cleanup, compatibility). Below are detailed explanations of audit focus points:

### 1. Privileged Container

- **Status**: Only `androidemu-android` (redroid Android main container) uses `privileged: true`, `androidemu-webrtc` (screen service) runs non-privileged
- **Necessity**: redroid upstream (remote-android/redroid-doc) official deployment requires `--privileged`, Android depends on kernel binder communication, container needs to mount/access binder device and create device nodes
- **Non-privileged alternative tested infeasible**: Non-privileged + device_cgroup_rule + mount binderfs + cap-add=ALL + seccomp=unconfined, container exits with ExitCode 0 silently, can't boot (redroid-doc issue #591 still open)
- **Impact control**: Privilege only applies inside container (container root = Android system initialization needs), not equal to host root; app itself runs as `docker-androidemu` user, doesn't request host root

### 2. Non-root App Process 

- The Go gateway (gateway_amd64/arm64), audio_fix.py and other background processes all run as the `docker-androidemu` user
- Auto-downgrade via `_drop_privileges()` function (auto-switch when uid=0)
- config/privilege declares `run-as=package`

### 3. Network Mode (v3.8.9: bridge + host port mapping)

- `androidemu-webrtc` (screen service) uses the default `bridge` network since v3.8.9, publishing only 8443 TCP, 3478 TCP/UDP, 50000-50100 UDP
- **Reason**: fnOS blocks "bridge container → host LAN IP" access; v3.8.8 switched to `host` mode for that reason, but testing showed that in host mode the agent inside the redroid container can only reach signaling/TURN through the bridge gateway, so the ICE negotiation path fails (WebRTC connection failure, device never comes online). v3.8.9 therefore switches back to bridge: redroid and webrtc share the `androidemu_default` network, and the agent connects directly to signaling (8443) and TURN (3478) via the compose service name `webrtc` — pure container-to-container traffic that never crosses the host firewall
- **Impact**: Listening ports are exactly the same as the original port mapping (8443 TCP, 3478 TCP/UDP, 50000-50100 UDP), no new ports; the container still doesn't use privileged; browser-side TLS is terminated by the fnOS unified gateway (USE_TLS=false inside the container, since the agent doesn't support TLS)

### 4. Docker Group Permission

- App user `docker-androidemu` belongs to `docker` group
- This is standard configuration for fnOS Docker apps, required to run containers
- Only used for app scripts to orchestrate and clean up this app's containers, doesn't affect other apps

### 5. Multi-port Listening

| Port | Protocol | Purpose | Auth |
|------|----------|---------|------|
| 8443 | TCP | WebRTC signaling + screen | Account login |
| 3478 | TCP/UDP | TURN relay | TURN credentials |
| 5556 | TCP | ADB debugging | Default localhost only, manual open needed |
| 50000-50100 | UDP | WebRTC media stream | Session-level auth |

- App doesn't do any automatic port mapping (no UPnP/hole punching), public exposure decided by user
- Each port has independent auth mechanism

### 6. Paid Features Note

- This app itself is completely free
- Built-in Scrcpy screen service uses upstream third-party authorization: free version can use all basic features (screen casting, ADB debugging etc.), only "addable device count" is limited
- Paid only increases device count limit, doesn't affect any functionality
- Fees collected by upstream authorization service provider, unrelated to fnOS official
<img width="1288" height="900" alt="firefox exe_20260927_092044" src="https://github.com/user-attachments/assets/44afdf11-2112-4ae7-8544-89e6bfa0238b" />

### 7. GMS (Google Mobile Services) Compliance Note

- **App package does not contain GMS binaries**: The FPK package is only ~150KB, no Google proprietary software included
- **GMS is optional**: Installation wizard defaults to "Do not install"; user must actively select "Install" and confirm the legal notice before triggering
- **Runtime acquisition**: After selecting install, the script automatically detects system architecture (x86_64/arm64), extracts files from a separate GMS file carrier image, and installs to the standard redroid container's system partitions
- **GMS source**: x86_64 GMS files extracted from third-party redroid derivative image (whojk/redroid); arm64 version from the MindTheGapps open project; both are third-party repackaging of Google proprietary software
- **Legal responsibility**: GMS (Google Mobile Services) is proprietary software of Google LLC, protected by copyright. This project does not directly distribute GMS binaries, for personal research only. Use of GMS is subject to Google's Terms of Service, and legal responsibility rests with the user
- **Compliant alternative**: If only basic features like push notifications, location, and maps are needed, the open-source microG (Apache 2.0 license) is recommended, with no legal risk
- **Auto-cleanup after GMS install**: After successful GMS installation, the GMS file carrier image (~700MB) is automatically removed to free disk space, no manual cleanup needed
- **GMS parallel pre-download**: When GMS is selected during installation, the GMS image is downloaded in parallel with the Android system image in the background; after container boot, files are extracted directly, significantly reducing total installation time
- **Domestic mirror acceleration**: GMS image pull supports multi-source fallback (Nanjing University ghcr.nju.edu.cn → DaoCloud docker.m.daocloud.io → GHCR official), automatically selecting the fastest available source in domestic network environments
- **Auto-retry on failure**: If GMS installation encounters boot timeout or image pull failure, the installation marker file is not removed; it automatically retries on next container boot, avoiding the "thought it was installed but actually wasn't" issue

### 8. TUN Device & VPN/Proxy App Compatibility

- **Status**: Since v3.8.8, the `/dev/net/tun` virtual network device is mounted into the Android container; the install script auto-detects and creates the host tun device
- **Purpose**: Only for compatibility with apps requiring virtual network interfaces (e.g. enterprise remote access, legitimate VPN services), scoped to the container only, does not affect host network security
- **Security statement**: This application does not encourage or support any use of proxy or VPN tools that violates national communications regulations; users must comply with local laws, and all liability for illegal use rests with the user
- **Permission impact**: TUN is a standard Linux virtual network device, does not add host privileges, and does not break container isolation boundaries

### 9. SELinux, In-Container Root and the v3.8.9 seccomp Hardening

- **SELinux status**: `getenforce` inside the container returns `Disabled` because the fnOS kernel **does not load the SELinux LSM** (verified: `/sys/kernel/security/lsm` = `capability,landlock,lockdown,yama,bpf,apparmor,ima,evm` — the host uses AppArmor), and `/sys/fs/selinux` is absent inside the container. SELinux therefore **cannot** be enabled by this application (the kernel does not provide the module — it was not "left unpatched"); forcing it via redroid boot parameters blocks in-container system services and prevents the container from booting (tested, reverted in v3.8.8)
- **The real boundary of in-container root (stated plainly)**: the Android main container `androidemu-android` must run `privileged` because of the upstream redroid requirement (non-privileged variants never reach the boot stage — see [redroid-doc #591](https://github.com/remote-android/redroid-doc/issues/591)). Because of that, in-container root is **not** the same as root in an ordinary unprivileged container: Docker lifts the default seccomp/AppArmor constraints under `privileged`, and `cap_drop` / device rules **no longer take effect** (verified: CapEff stays at the full `0x1ffffffffff`). What this application does to narrow it down: ① the passed-through devices are trimmed to the three required ones (`/dev/dri`, `/dev/binder`, `/dev/net/tun`); ② a custom seccomp filter rejects the most dangerous syscalls with `EPERM` (next bullet)
- **v3.8.9 seccomp hardening**: the redroid service in `docker-compose.yaml` uses `security_opt: seccomp=<app-dir>/docker/androidemu-redroid-seccomp.json` (default-allow + deny `init_module`/`finit_module`/`delete_module`, `kexec_load`/`kexec_file_load`, `reboot`, `swapon`/`swapoff`, `acct`, `iopl`/`ioperm`, `settimeofday`/`clock_settime`). Inside a container these calls would otherwise act on the whole NAS (e.g. `reboot` would reboot the NAS, changing the clock would affect other services on it). Verified: `Seccomp: 2` inside the container, `insmod` returns Operation not permitted, while boot, casting/audio (Codec2 Opus), ADB, APK installs and container stop/rebuild all still work
- **Existing attack-surface reductions**: ADB 5556 binds to `127.0.0.1` only by default (opt-in from the panel; the image is a userdebug build, i.e. whoever reaches 5556 gets in-container root — close it when done); the image's userdebug `su` is set to mode `000` on every deployment (re-applied after container rebuilds); no Magisk is bundled; the app itself runs as the `docker-androidemu` user (run-as=package) with no host root resident processes
- **Residual risk (not glossed over)**: if in-container root is obtained (e.g. from outside via self-opened ADB, or by installing an untrusted APK carrying a privilege-escalation exploit), its reach is **not limited to the container** — a privileged container's `/dev` contains host device nodes (disks, `/dev/mem`, …). That is an inherent property of the upstream-required `privileged` flag, and Docker cannot narrow it while keeping privileged (`cap_drop` is ignored — verified). The v3.8.9 seccomp filter closes the most direct escape/damage paths, but it cannot remove that inherent property. Therefore: do not expose this app's ports directly to the internet; open ADB on the LAN only when needed and close it afterwards; install only APKs from trusted sources
- **Self-check commands** (with the container running):
  ```bash
  docker exec androidemu-android sh -c 'grep ^Seccomp /proc/1/status'   # expect Seccomp: 2
  docker exec androidemu-android ls -l /system/xbin/su                   # expect ----------
  ss -tln | grep 5556                                                    # expect 127.0.0.1
  cat /vol1/@appdata/androidemu/security.status                          # written by each deployment
  ```
- **Relationship with fnOS audit**: fnOS security audit focuses on whether the application runs as host root or breaks container isolation to affect the host. The in-container root is a necessary condition for Android system operation (upstream redroid technical requirement), and the application itself does not request host root; the mitigation measures and residual risk are stated above and can all be reproduced and verified on the device

---

## FAQ

### Q: "Unable to install Android Emulator (China) - Unknown error" when installing via fnOS mobile app

A: This is a generic error from the **fnOS mobile app** App Center, occurring at the app center level (before the installation script runs). It is not an issue with this application.

**Possible causes and solutions:**
1. **Use the web version first**: Open the fnOS management page in a desktop browser and install via the web App Center. The mobile app occasionally throws this "Unknown error", while the web version usually works fine
2. **Check disk space**: The Android image is about 2GB, plus temporary files require at least 4GB of free space
3. **Restart the fnOS app**: Fully close the app and reopen it, then try again
4. **Manual installation**: Download the fpk package and upload it via the web version's "Manual Install"

If none of the above works, please feedback via any link in the "Feedback Links & Channels" section below, including your NAS model, system version, and screenshots.

### Q: "Unable to install - State operation not supported, returns current app state and business state" when installing via fnOS mobile app

A: This is a state machine error from the **fnOS mobile app** App Center, usually caused by the app being in an abnormal state (e.g., previous installation/update cancelled midway, repeatedly clicking the install button, leftover installation process).

**Solutions:**
1. **Don't click repeatedly**: Wait for the current operation to complete. Do not repeatedly click install/update buttons during installation
2. **Restart the fnOS app**: Fully close the app and reopen it to refresh app state
3. **Use the web version**: Open the fnOS management page in a desktop browser and perform install/update/uninstall operations via the web App Center
4. **Clean up leftover state**: If the app shows "Installed" but is actually unusable, uninstall it first in the web version, then reinstall

### Q: "Unable to install androidemu - script execution error with unknown reason" during first-time installation

A: First check whether the **dependency app "binder_linux"** is installed and enabled:
- This app's manifest declares the dependency `binder_linux_driver` (display name "binder_linux"). Install and enable it in the fnOS App Center, then install this app; the App Center blocks the install while the dependency is unmet ("dependency binder_linux not installed or not enabled").
- **x86 and kernels without built-in binder**: the dependency app loads the kernel module, mounts `/dev/binderfs` and creates `/dev/binder` etc. (fnOS 6.18.18 and later already build binder in — the dependency app then only pulls it up and verifies).
- **ARM devices**: Most devices have binder built into the kernel (e.g., RK3588), but some stripped kernels may not have it enabled. Verify kernel support for `CONFIG_ANDROID_BINDER_IPC` / binderfs

If the driver is already installed (or the ARM device natively supports it) but this error still appears, please feedback via any link in the "Feedback Links & Channels" section below, and include `/var/apps/androidemu/var/uninstall_init.log` or the corresponding installation log so we can investigate the specific cause.

### Q: Installation fails with "App Android Emulator (China) installation failed. Reason: Application callback script execution exception."

A: This is caused by an error when fnOS App Center executes the installation callback script (install_callback). Common causes and troubleshooting:

**1. Check installation log**
```bash
cat /var/apps/androidemu/var/install.log
```
The log records each step of script execution and specific error messages.

**2. Common causes:**
| Cause | Solution |
|-------|----------|
| dependency app not installed/enabled | Install and enable the "binder_linux" dependency app (`binder_linux_driver`) from the App Center first, then retry |
| Insufficient disk space (<4GB) | Free up disk space, ensure at least 4GB available |
| Insufficient memory (<2GB) | Close other memory-intensive apps, ensure at least 2GB available |
| Docker service abnormal | Restart Docker service in fnOS Docker settings, then retry |
| Script missing execute permission | Rare case, try re-downloading the fpk installation package |
| Old version residue | Uninstall old version (select delete data), then reinstall |

**3. Manual troubleshooting steps:**
```bash
# Check binder device
ls -la /dev/binder*

# Check disk space
df -h /

# Check memory
free -h

# Check Docker status
docker info | head -5
```

If none of the above resolves the issue, please send the install.log content to us via the feedback channels below.

### Q: Can't open after installation, page shows 400 error (may affect multiple apps simultaneously)

A: This is caused by the request header size limit of fnOS nginx gateway, **not an issue with this app**.

**Cause**: fnOS nginx defaults to `large_client_header_buffers 4 8k`. When browser cookies are too large (cumulative cookies injected by fnOS gateway such as `fnos-token`, `osrt`, etc. exceed 8KB), nginx directly returns 400. This issue affects all apps going through the fnOS gateway simultaneously (such as gxsales, hddlocator, etc.). Clearing browser cache temporarily fixes it, but cookies grow again after re-login.

**Solution A (recommended, works immediately): Bypass fnOS nginx, access port directly**

Access directly within LAN:
```
http://<NAS_IP>:8443
```

Or access through your own reverse proxy (e.g. Lucky, Nginx Proxy Manager), bypassing the fnOS gateway.

**Solution B (permanent fix): Modify fnOS nginx config to increase header buffer size**

> Requires SSH login to NAS with root permission. Backup config file before modifying.

Step 1: Backup nginx config
```bash
sudo cp /usr/trim/nginx/conf/nginx.conf /usr/trim/nginx/conf/nginx.conf.bak
```

Step 2: Edit config file
```bash
sudo nano /usr/trim/nginx/conf/nginx.conf
```

Add the following two lines inside the `http {}` block:
```
client_header_buffer_size 16k;
large_client_header_buffers 4 32k;
```

Step 3: Test config and reload
```bash
sudo nginx -t && sudo nginx -s reload
```

> Note: fnOS system updates may overwrite nginx config. If the issue reappears after an update, re-add the lines.

### Q: Shows "Bad Gateway" (502 error) after opening

A: This is the default prompt from fnOS nginx gateway when it can't reach the backend service, **not an error page from this app**.

**Most common cause: Just installed/just started, backend service not ready yet**

The Android container takes 1-2 minutes on first boot (pulling image, initializing, starting system services). During this time the Go gateway or the webrtc container is not ready yet, and fnOS gateway directly returns 502. **Wait 1-2 minutes then refresh the page.**

**By version:**

- **v3.6.8 and below**: Showing plain text "Bad Gateway" is normal. Older versions don't have a friendly status page, this is what you see when upstream is not ready. Refresh after the container finishes starting.
- **v3.7.0 and above**: Normally shows a friendly status page (with container status table and refresh button) when upstream is not ready. If you still see plain text "Bad Gateway", it means the gateway process didn't start at all. Troubleshoot:

Step 1: Check if port 8443 is listening
```bash
ss -tln | grep 8443
```

Step 2: Check if the gateway process is running
```bash
ps aux | grep -E "gateway_(amd64|arm64)" | grep -v grep
```

Step 3: If port is not listening or process doesn't exist, click "Stop" then "Start" in the App Center, or restart the app.

Step 4: You can also bypass fnOS gateway and access directly to confirm if it's a gateway-layer issue:
```
http://<NAS_IP>:8443
```

### Q: Shows "Unauthorized" or "0 devices online" after opening

A: This is Scrcpy License authorization prompt. Newly installed devices currently have a 20-device 3-month free trial (this offer is valid until Nov 1, 2026; after expiration, the free quota will be reduced to 10 devices; other basic features remain unaffected). Wait for container to fully start (~1-2 minutes) then refresh page. If still unauthorized, check if container is running:
```bash
docker ps --filter name=androidemu
```

### Q: "Unable to update - script execution error with unknown reason" during upgrade

A: This is caused by `uninstall_init` script exception during upgrade in old versions (v3.6.5 and before). Fixed in v3.6.6:
- Rewrote uninstall script with more robust upgrade guard
- Added `set +e` to ensure no command failure causes abnormal script exit
- All output redirected to log, stdout stays clean

**Solution**: Download v3.6.6+ and install via "Manual Install" to overwrite. If still fails, check log on NAS:
```bash
cat /var/apps/androidemu/var/uninstall_init.log
```

### Q: WebRTC casting connection failed

A: Troubleshoot in this order:
1. Confirm using in LAN (external network auto-downgrades to WebSocket casting)
2. Confirm TURN server running: `docker exec androidemu-webrtc netstat -ulnp | grep 3478`
3. Confirm PUBLIC_IP is LAN IP not 127.0.0.1: `docker exec androidemu-webrtc env | grep PUBLIC_IP`
4. Confirm ICE_SERVERS contains correct LAN IP: `docker exec androidemu-webrtc env | grep ICE_SERVERS`
5. Try clicking "Switch to WebSocket casting"

### Q: WebSocket (WS) casting shows connection failed

A: When using WebSocket casting (LAN or external network), if "Connection failed" page appears, please wait patiently:
- **Within 2 minutes**: System will automatically retry and connect, eventually showing Android container homepage, no action needed
- **Still connection failed after 2 minutes**: Troubleshoot as follows:
  1. Confirm Android container has fully started (first boot takes ~1-2 minutes), check container status in fnOS Docker
  2. Refresh page and re-enter
  3. LAN users can try directly accessing `http://<NAS_IP>:8443`
  4. External network users can use MJPEG fallback screen from top-right prompt
  5. If still unresolved, check container logs or contact us via feedback channels

### Q: Container restarts repeatedly

A: Common causes and troubleshooting:

**1. Check Android container logs**

```bash
docker logs androidemu-android
```

**2. Identify cause by log keywords:**

| Log keyword | Cause | Solution |
|------------|-------|----------|
| Errors related to `gpu`, `dri`, `SurfaceFlinger` | GPU passthrough failed | See GPU fix commands in "Android container memory very low" below |
| `out of memory`, `lowmemory` | Insufficient RAM | Close other apps, keep at least 2GB free |
| Errors related to `binder`, `binderfs` | binder support missing | Install and enable the `binder_linux` dependency app (`binder_linux_driver`) from App Center first |

**3. ARM device extra check:** Confirm compose has `androidboot.redroid_gpu_mode=guest` (software rendering), ARM devices usually have no GPU passthrough.

**4. webrtc container restarts repeatedly:** Search logs for `nice: setpriority(-10): Permission denied`. If present, confirm compose includes `cap_add: SYS_NICE`.

Check webrtc container logs:
```bash
docker logs androidemu-webrtc --tail 50
```

### Q: I selected GMS during installation, how to verify it's installed?

A: After installation, open Scrcpy and you should see the "Play Store" icon in the app list. You can also check via command:
```bash
docker exec androidemu-android pm list packages | grep google
```
You should see `com.google.android.gsf` (Services Framework), `com.google.android.gms` (Play Services), `com.android.vending` (Play Store).

If not, check the GMS installation log:
```bash
cat /var/apps/androidemu/var/gms_install.log
```

### Q: Black screen or boot failure after installing GMS?

A: GMS installation failure may cause system issues. Solution:
1. Uninstall the current app (select "Keep data")
2. Reinstall, select "Do not install GMS" in the wizard
3. System returns to normal after installation

GMS installation log is at `/var/apps/androidemu/var/gms_install.log`, check for specific failure reasons.

### Q: Already installed Standard Edition, want to add GMS?

A: Currently GMS can only be selected during installation. Users with Standard Edition need to:
1. Uninstall the current app (select "Keep data" — installed apps and data will not be lost)
2. Reinstall, select "Install GMS services and Play Store" in the wizard
3. Data is preserved after installation, GMS is installed automatically

### Q: What's the difference between this GMS and the old GMS edition image?

A:
- **Old GMS edition (before 3.8.7)**: Used third-party whojk/redroid image, GPU host mode incompatible with some hardware causing black screen
- **New GMS (3.8.7+)**: Uses official redroid Standard Edition image, GPU mode works normally; during installation, automatically detects architecture (x86_64/arm64) and extracts files from a separate GMS file carrier image to install to system partitions — no black screen issues; the app package itself does not contain GMS binaries, size is only ~150KB

### Q: Installation fails with "all mirror sources and Docker Hub official are unreachable"?

A: This happens when NAS Docker cannot access the image registry (the ~2GB Redroid system image pull fails).

**Cause:** The default fnOS mirror accelerator (docker.fnnas.com) or Docker Hub official source is unreachable in the current network environment.

**Solutions (in recommended order):**

1. **Configure a domestic mirror accelerator (recommended)**: Open fnOS **Docker → Image Registry → Settings → Mirror Settings**, add any of the following working addresses:
   - DaoCloud: `https://docker.m.daocloud.io`
   - Nanjing University: `https://docker.nju.edu.cn`
   - Shanghai Jiao Tong University: `https://docker.mirrors.sjtug.sjtu.edu.cn`
   
   Save, wait for Docker to restart, then retry installation.

2. **Check proxy settings**: If NAS has a proxy configured, verify in **Docker → Image Registry → Settings → Proxy Settings** that the proxy can access Docker Hub; if no proxy but network egress is restricted, configure an accelerator first.

3. **Manual image import (offline)**: On a computer with internet, run `docker save redroid/redroid:12.0.0-latest -o redroid.tar`, transfer the tar file to NAS, then run `docker load -i redroid.tar`, and retry installation.

> The pre-install check detects network before pulling images. On failure, installation aborts and **existing data is not deleted**. Simply retry after fixing the network.

### Q: After installing GMS, scrcpy keeps connecting/disconnecting, then stabilizes after a while — is this normal?

A: Yes, this is normal behavior, not a bug.

**Cause:** After GMS installation completes, the Android container restarts. During reboot, the system reinitializes GMS core components (GmsCore, GoogleServicesFramework, Play Store, etc.), which perform in the background:
- First-boot dex optimization (dex2oat)
- Google Services Framework registration and permission initialization
- Play Store app list sync
- Network connection and Google server handshake (may timeout and retry on domestic networks)

This process typically lasts **1~3 minutes**, during which scrcpy shows "connecting" or repeatedly disconnects and reconnects — this is expected.

**Recommendations:**
- Wait patiently for 3 minutes after GMS installation; do not frequently refresh or restart the container
- If still unable to connect after 5 minutes, check container logs: `docker logs androidemu-android --tail 50`
- Google server connection timeout on domestic networks is normal and does not affect local app running — only affects Play Store login and cloud sync

### Q: After GMS installation completes, can the GMS image be deleted?

A: Yes. The GMS image (`ghcr.io/lin1740/androidemu-gms:x86_64-1.0.0` or `arm64-1.0.0`, ~700MB) is only used during installation to extract GMS files and is no longer needed afterward.

**Automatic cleanup (3.8.7+ default enabled):** The install script automatically deletes the GMS image after successful installation, freeing ~700MB.

**Manual deletion:** If you need to clean up manually:
```bash
docker rmi ghcr.io/lin1740/androidemu-gms:x86_64-1.0.0   # x86_64
docker rmi ghcr.io/lin1740/androidemu-gms:arm64-1.0.0    # arm64
```

> Note: After deletion, if you need to reinstall GMS in the future (e.g., after uninstalling and reinstalling), the image (~700MB) will be re-pulled from the registry.

### Q: Terminal docker commands fail with `permission denied while trying to connect to the Docker daemon socket`

A: Your current user is not in the docker group and lacks permission to access the Docker daemon directly.

**Solutions (choose one):**
1. **Temporary**: Prefix all docker commands with `sudo`, e.g. `sudo docker ps`, `sudo docker exec androidemu-android ...`
2. **Permanent**: Add your user to the docker group, then re-login for changes to take effect:
```bash
sudo usermod -aG docker <your-username>
```
> Note: After adding to the docker group, you must **exit the terminal and log back in** for it to take effect.

### Q: How to configure multi-device resolution and switch dynamically?

A: Since v3.8.4, multi-device resolution configuration is supported. During installation, you can separately set resolutions for **PC, phone, and tablet**. The container starts with the phone resolution by default, and you can switch dynamically during use (takes effect immediately, no container restart needed).

**1. Set during installation (recommended)**

In the "Resolution Settings" step of the installation wizard, fill in resolutions for each device (format: width×height, e.g., 1920×1080):
- **PC**: e.g., 1920×1080 (landscape) or 1280×720
- **Phone**: e.g., 720×1440 (9:18 bezel-less, default) or 720×1280 (9:16)
- **Tablet**: e.g., 1200×2000 (3:5) or 800×1280

Leave blank to use defaults for that device (PC 1920×1080, phone 720×1440, tablet 1200×2000); if all blank, defaults are used.

**2. Auto-switch resolution **

After installation, the app automatically starts a "resolution auto-switch daemon". When you open the Chuanyun Cast page on different devices, the page automatically detects the device type and reports it. The daemon then **automatically switches to the corresponding resolution** (takes effect immediately).

- Opening on PC → auto-switches to PC resolution
- Opening on phone → auto-switches to phone resolution
- Opening on tablet → auto-switches to tablet resolution

> Cooldown 60 seconds: after a switch, no further switches for 60 seconds to avoid affecting experience. When multiple devices open simultaneously, the most recently opened device takes precedence.

**View auto-switch logs:**
```bash
cat /var/apps/androidemu/var/resolution_autoswitch.log
```

**3. Manually switch resolution**

If auto-switching does not work as expected, you can manually run:
```bash
# Switch to PC resolution
bash /vol1/@appcenter/androidemu/scripts/switch_resolution.sh pc

# Switch to phone resolution
bash /vol1/@appcenter/androidemu/scripts/switch_resolution.sh phone

# Switch to tablet resolution
bash /vol1/@appcenter/androidemu/scripts/switch_resolution.sh tablet

# Specify custom resolution directly
bash /vol1/@appcenter/androidemu/scripts/switch_resolution.sh 1080x1920
```

Switching is done via `adb shell wm size`, **takes effect immediately**, no container restart or reconnection needed.

**3. View current configuration**
```bash
cat /var/apps/androidemu/var/resolution.conf
```

**4. Permanently change default resolution (modify compose)**

To change the default resolution at container startup (takes effect after restart), edit the compose file:
```bash
nano /vol1/@appcenter/androidemu/docker/docker-compose.yaml
```
Find the `command` section of the `redroid` service and modify:
```yaml
- androidboot.redroid_width=720
- androidboot.redroid_height=1600
```
Then restart the container:
```bash
cd /vol1/@appcenter/androidemu/docker
docker compose up -d --force-recreate redroid
```

> **Notes**:
> - The container can only use one resolution at a time; after switching, all connected clients will see the new resolution
> - Dynamic switching does not delete data or installed apps
> - When resolution ratio matches the device screen ratio, immersive borderless fullscreen is achieved
> - 1080p and higher resolutions demand more NAS performance; low-spec devices are recommended to use 720p series

### Q: Container is laggy, frozen, unresponsive to clicks or gestures

A: **v3.7.0+ users**: Open the app page. If the upstream service is temporarily unavailable, a friendly status page will automatically appear, including:
- **Health Status**: Auto-detects boot status, uptime, OOM kills, whether surfaceflinger/agent are running
- **One-Click Fix Buttons**:
  - "Fix GPU/Screen": Auto chmod /dev/dri + restart surfaceflinger (fixes screen freeze caused by GPU permission issues)
  - "Restart Android Container": Restarts the entire Android container
  - "Restart Screen Service": Restarts only surfaceflinger, other processes unaffected

**General troubleshooting (all versions):**
1. Close the app page (or browser tab), reopen it and try clicking/swiping again
2. If still unresponsive, go to the app detail page in fnOS App Center, click "Stop", then "Start" again
3. If only one container is laggy, find that container in Docker and click "Restart"
4. Manually check health status (run one by one):

   Check if container is running:
   ```bash
   docker ps --filter name=androidemu
   ```

   Check if Android finished booting:
   ```bash
   docker exec androidemu-android getprop sys.boot_completed
   ```

   Check if killed by OOM:
   ```bash
   docker inspect -f '{{.State.OOMKilled}}' androidemu-android
   ```
5. If none of the above works, please capture a screenshot or screen recording of the lag, and export the Docker container logs as a text file, then submit via any of the feedback channels below

### Q: Android container memory is very low (<300MB), device stays offline

A: A normal Android 12 should use 300MB+ after boot. If the container is running but memory is only 100-200MB, Android has not finished booting (`boot_completed != 1`), so the agent cannot be deployed and the device never comes online. Troubleshoot:

**1. Check boot status:**
```bash
docker exec androidemu-android getprop sys.boot_completed
```
- Returns `1` → booted, skip to step 3
- Returns empty or `0` → not booted, continue to step 2

**2. Read the diagnostics file (real logs live here, not in docker logs):**

> ⚠️ **Do not troubleshoot with `docker logs`**: this app disables the serial console for performance (`androidboot.console=0`), so **`docker logs androidemu-android` is always empty** (verified: 0 bytes / 0 lines). `docker logs | grep error` returns nothing — that is expected, not a sign that "there are no logs". Real boot logs exist only in the container's logcat.
> Since v3.8.9 a **boot guard** (`scripts/boot_guard.sh`) continuously watches the boot state, writes diagnostics (with real logcat evidence) to `/var/apps/androidemu/var/boot_diag.status`, and **automatically falls back to software rendering and recreates the container when there is clear GPU/DRM crash evidence** (one-shot), so manual intervention is usually unnecessary.

```bash
cat /var/apps/androidemu/var/boot_diag.status         # diagnostics written by the guard
bash /var/apps/androidemu/scripts/boot_guard.sh once  # run a diagnosis right now
bash /var/apps/androidemu/scripts/boot_guard.sh status
```

| Diagnosis / keyword | Cause | Fix |
|--------------------|-------|-----|
| `privileged=false` | container lost privileges (Android cannot initialize) | App Center "Disable → Enable" to recreate the container; if it persists, report it |
| logcat shows `binder` errors, `container_binder` empty | kernel binder unavailable | Install and enable the `binder_linux` dependency app from App Center, then `docker restart androidemu-android` |
| `logcat_gpu_drm_hits` high / `EGLConfig` / `Failed to open /dev/dri` | GPU passthrough fails inside the container | The guard falls back to software rendering automatically; you may also run the GPU fix commands below |
| `out of memory`, `lowmemory` | Insufficient RAM | Close other apps, keep at least 2GB free |
| `zygote` restarting | System service crash | Reinitialize data volume (wipes Android data): `docker compose -p androidemu down && docker volume rm androidemu-data && docker compose -p androidemu up -d` |

> When reporting a boot problem, simply attach the contents of `boot_diag.status` — it already includes container state, privileged/devices, binder, GPU hit counts and the key logcat lines.

**3. GPU fix (for graphical glitches or SurfaceFlinger crashes, run in order):**

Step 1: Fix GPU device permissions
```bash
docker exec -u 0 androidemu-android chmod 666 /dev/dri/card0 /dev/dri/renderD128
```

Step 2: Restart screen service
```bash
docker exec -u 0 androidemu-android sh -c 'setprop ctl.restart surfaceflinger'
```

Step 3: Wait 60 seconds for service restart
```bash
sleep 60
```

Step 4: Confirm Android boot completed
```bash
docker exec androidemu-android getprop sys.boot_completed
```

**4. Manual agent injection (when boot_completed=1 but device still offline, run in order):**

> Note: Replace `<NAS_IP>` with your NAS actual LAN IP; use `amd64` for x86 devices, `arm64` for ARM devices.
>
> **Permission note**: If docker commands fail with `permission denied while trying to connect to the Docker daemon socket`, your user is not in the docker group. Prefix all docker commands with `sudo`, or add your user to the docker group (`sudo usermod -aG docker <username>`, then re-login).

Step 1: Extract agent from scrcpy-over-webrtc image (first time only)
```bash
docker run --rm -v /var/apps/androidemu/var/agent:/out --entrypoint /bin/sh docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest -c "cp /app/agent_binaries/cloudphone-agent-amd64 /app/agent_binaries/libsys_core.so /out/ && chmod 755 /out/cloudphone-agent-amd64"
```

Step 2: Copy agent binary to Android container
```bash
docker cp /var/apps/androidemu/var/agent/cloudphone-agent-amd64 androidemu-android:/data/local/tmp/cloudphone-agent
```

Step 3: Copy dependency library to Android container
```bash
docker cp /var/apps/androidemu/var/agent/libsys_core.so androidemu-android:/data/local/tmp/libsys_core.so
```

Step 4: Inject and start agent (since v3.8.9 signaling is plaintext inside the container; use `host.docker.internal` to point at the bridge gateway — **do NOT use the host LAN IP**; or simply use the bundled `scripts/agent_helper.sh deploy <dir>`)
```bash
docker exec -u 0 androidemu-android sh -c "chmod 755 /data/local/tmp/cloudphone-agent && export CP_AGENT_JAR=/data/local/tmp/libsys_core.so && nohup /data/local/tmp/cloudphone-agent -signaling ws://host.docker.internal:8443 -id androidemu -ice-servers 'turn:cloudphone_user:cloudphone_secure_password@host.docker.internal:3478?transport=udp' -jar /data/local/tmp/libsys_core.so > /data/local/tmp/agent.log 2>&1 &"
```

Step 5: Wait 3 seconds
```bash
sleep 3
```

Step 6: Confirm agent is running (returns PID means success)
```bash
docker exec androidemu-android pidof cloudphone-agent
```

### Q: Android container starts very slowly (over 5 minutes), memory fluctuates a lot, system unstable

A: Versions before v3.8.3 had an issue with lmkd (Low Memory Killer Daemon) thresholds being too low: the default maximum threshold was only 315MB, which was too aggressive for large memory systems, causing frequent killing of empty processes during startup and repeated restarts of system services. This manifested as slow startup, memory fluctuating between 2.0-2.5GB, and the device staying offline for a long time.

**Fixed in v3.8.3+**: lmkd thresholds raised to 512/768/1024/1280/2048/3072MB, dex2oat uses verify-only mode on first boot to speed up startup, and key process priorities are automatically raised after boot. Upgrading to v3.8.3+ will resolve this.

If the problem persists, please check:
1. Host available memory ≥2GB (`free -h`)
2. Whether other apps are consuming large amounts of memory (e.g., fnOS Photos, downloads, etc.)
3. Container logs for OOM or crashes (`docker logs androidemu-android --tail 50`)

### Q: WebRTC connection fails, black screen, or endless loading

A: The most common cause is `PUBLIC_IP` being reset to `127.0.0.1` (after container recreation, the compose default takes effect), so the TURN relay address handed to clients is `127.0.0.1`, which clients cannot reach.

**Diagnostic commands (run one by one to check results):**

Check PUBLIC_IP configuration:
```bash
docker inspect androidemu-webrtc --format '{{range .Config.Env}}{{println .}}{{end}}' | grep PUBLIC_IP
```

Check if agent is running:
```bash
docker exec androidemu-android pidof cloudphone-agent || echo "agent not running"
```

Check agent log (last 20 lines):
```bash
docker exec androidemu-android tail -20 /data/local/tmp/agent.log 2>/dev/null
```

Check errors in webrtc container log:
```bash
docker logs androidemu-webrtc --tail 40 2>&1 | grep -iE 'relay addr|allocation|error|fail|Unauthorized' | tail -15
```

**Fix (when PUBLIC_IP=127.0.0.1, run in order, replace `<NAS_IP>` with your NAS LAN IP):**

Step 1: Enter docker config directory
```bash
cd /var/apps/androidemu/target/docker
```

Step 2: Replace PUBLIC_IP (replace `<NAS_IP>` with your NAS LAN IP)
```bash
sed -i 's/PUBLIC_IP=127\.0\.0\.1/PUBLIC_IP=<NAS_IP>/g' docker-compose.yaml
```

Step 3: Recreate webrtc container
```bash
docker compose -p androidemu up -d --force-recreate webrtc
```

Step 4: Wait 10 seconds
```bash
sleep 10
```

Step 5: Confirm PUBLIC_IP updated
```bash
docker inspect androidemu-webrtc --format '{{range .Config.Env}}{{println .}}{{end}}' | grep PUBLIC_IP
```

After confirming `PUBLIC_IP` is your LAN IP, reopen the cloud phone page to connect.

### Q: No sound / Low volume

A: **OPUS audio encoder is fully fixed in v3.8.9 (Codec2)**, enabled by default. If still no sound, please check the following points:

1. **Manually enable audio in connection settings**:
   - Desktop (fnOS Web interface): Check the "Audio" option in CloudPhone connection settings
   - Mobile (CloudPhone APP): Audio stream is pass-through, no additional setup needed; ensure APP version supports audio
2. **Volume is linked with host system volume**:
   - Final volume = in-container volume × host system volume
   - Example: container set to 100%, but host system volume only at 50%, actual output is 50%
   - Please check both in-container media volume and host system volume
3. **When using third-party control/connection software**:
   - If using software other than CloudPhone (such as scrcpy, QtScrcpy, ADB remote control, etc.), be sure to **disable audio** in that software's settings, or configure audio correctly according to the software's instructions
   - Third-party software may not be compatible with CloudPhone's Opus audio stream protocol; forcing audio on may cause connection failure or no sound
   - CloudPhone APP and fnOS Web interface have built-in audio support; official clients are recommended

> Technical note: v3.8.9 fixes the OPUS audio encoder by enabling the Codec2 software codec (setprop debug.stagefright.ccodec=1, c2software=1, restart media service) so the c2.android.opus.encoder already shipped in the container's swcodec config is properly registered; the audio_fix.py watchdog re-applies it every 30 seconds. The older "inject OMX.google.opus.encoder / media_codecs_google_audio.xml" approach is deprecated.

### Q: External network screen laggy

A: External network via fnOS reverse proxy auto-uses WebSocket casting, framerate limited by upstream bandwidth. If you have public IP, recommend directly mapping port 8443 for WebRTC casting.

### Q: Clicking "Terminal" pops up print dialog

A: This is Scrcpy frontend shortcut conflict bug. Fixed via RUNTIME_SHIM blocking `window.print()` and Ctrl+P shortcut, clicking terminal no longer triggers printing.

### Q: Audit log loading failed

A: Audit log function depends on Scrcpy backend `/api/audit` endpoint, some versions may not support. This is upstream image feature, doesn't affect core casting function.

### Q: How to delete uploaded APK files in scrcpy-over-webrtc? "Remove" button doesn't work

A: The "Remove" button only removes the file from the current install task — it does **not** delete the file from the cloud file center. Files are stored in the webrtc container at `/app/data/downloads/`. Delete them from the container:

Step 1: List uploaded files
```bash
docker exec androidemu-webrtc ls -la /app/data/downloads/
```

Step 2: Delete all APKs (or specify a filename to delete one)
```bash
sudo docker exec androidemu-webrtc sh -c 'rm -rf /app/data/downloads/*'
```

Step 3: Clear file metadata (otherwise the dropdown still shows filenames)
```bash
docker exec androidemu-webrtc sh -c 'echo "{}" > /app/data/files_meta.json'
```

Refresh the page after deletion, and the "Select existing file from cloud" dropdown will be empty.

### Q: APK upload via scrcpy-over-webrtc fails to install, how to install manually?

A: Uploaded APKs are stored in the webrtc container at `/app/data/downloads/`. If the UI install fails, you can install manually via command line:

**Step 1: List uploaded APK files**
```bash
sudo docker exec androidemu-webrtc ls -la /app/data/downloads/
```

**Step 2: Copy APK to host temp directory**
```bash
sudo docker cp androidemu-webrtc:/app/data/downloads/your-app.apk /tmp/
```

**Step 3: Copy to Android container**
```bash
sudo docker cp /tmp/your-app.apk androidemu-android:/data/local/tmp/
```

**Step 4: Install inside Android container**
```bash
sudo docker exec androidemu-android pm install /data/local/tmp/your-app.apk
```

**Step 5 (optional): Clean up temp files**
```bash
sudo docker exec androidemu-android rm /data/local/tmp/your-app.apk
sudo rm /tmp/your-app.apk
```

> The above commands have been verified on both x86 and ARM platforms. Replace `your-app.apk` with the actual filename.

### Q: How to uninstall

A: Click "Uninstall" in fnOS App Center. Container data (Android /data partition) kept in Docker volume, to completely remove:
```bash
docker volume rm androidemu_data androidemu-webrtc-data
```

### Q: Can't reinstall after cancelling installation/update midway

A: Fixed in v3.6.0+, auto-cleans temporary data on interruption. If using old version and encountering this, manually clean:
Step 1: Clean temporary files
```bash
rm -rf /tmp/androidemu_*
```

Step 2: Remove leftover containers
```bash
docker rm -f androidemu-android androidemu-webrtc 2>/dev/null
```

### Technical Notes & Development Pitfalls

Key technical conclusions verified during development, for secondary development reference:

- **com.android.location.fused absolutely cannot be disabled**: It's a dependency of LocationManagerService, disabling causes system_server crash, Android won't boot
- **androidboot.use_memfd=1 unsafe on redroid 12**: Causes LocationManagerService crash, init kills zygote, memory drops from 600-700MB to 400MB, container can't start
- **Detect dependency apps by device node not directory name**: App Center display name and actual directory name may differ, detecting `/dev/binder` more reliable than `/var/apps/binder_linux_driver`
- **WebSocket proxy must cover all ws/wss URLs**: Can't only cover specific paths, otherwise other paths will directly connect to port 8443 causing CORS failure when accessed via gateway
- **BusyBox su resets environment variables**: Non-root transformation can't use su -c internal export to pass env vars, should set directly in docker-compose environment
- **Disable Bluetooth with pm disable not svc disable**: svc disable gets auto-restarted by system, pm disable can completely disable
- **fnOS Docker no host hairpin capability**: Bridge containers can't access host LAN IP, ADB port needs socat forwarding
- **redroid Android main container must be privileged**: Upstream official requirement, non-privileged tested can't boot, but only applies inside container, app itself doesn't request host root
- **Upgrade scripts must be robust**: fnOS upgrade process first executes old version uninstall_init, any command failure or stdout output causes "script execution error with unknown reason", must set +e + output redirect + all commands || true
- **CRLF line endings cause Linux script errors**: All shell/Python scripts must use LF line endings, otherwise `$'\r': command not found`
- **App process downgrade needs attention to IPC**: After gateway.py downgrade, `is_mine(pid)` can only check current user processes, audio watchdog must also downgrade to same user, otherwise gets repeatedly started
- **webrtc container cannot cap_drop ALL**: coturn/node processes need basic capabilities; `cap_drop: ALL` causes the container to repeatedly crash and restart, memory drops to 0B, UI shows 502; only `cap_add: SYS_NICE` is needed
- **redroid container cannot force selinux=enforcing**: Docker containers share the host kernel, and SELinux policies inside the container are incomplete; forcing enforcing blocks system services, causing container crashes and memory dropping to 0B; keeping default Disabled is the standard upstream redroid configuration
- **redroid container cannot use ro.secure=1/adb.secure=1**: affects scrcpy-over-webrtc's ADB connection to the Android container, causing device to stay offline; keeping default ro.secure=0 is the standard redroid container configuration
- **The webrtc container must not use host network mode**: v3.8.8 switched to `host` because fnOS blocks "bridge container → host LAN IP", but testing showed that in host mode the agent inside the redroid container can only reach signaling/TURN via the bridge gateway, so the ICE negotiation path fails (WebRTC handshake failure, device never comes online); v3.8.9 switched back to bridge, publishing 8443/3478/TURN relay range (fixed 50000-50100) on the host, with the agent connecting directly to the compose service name `webrtc`
- **The TURN relay range is deliberately kept at 50000-50100 (even though it sits inside the OS ephemeral range)**: during v3.8.9 development the range was moved to 25000-25099 with "auto-avoidance", because the Linux ephemeral range defaults to 32768-60999 and a single occupied port (measured: `pxy` holding 50054/UDP on an ARM NAS) makes Docker's per-port binding fail — the **whole webrtc container stays in `Created` and never starts**, so the app looks installed but devices never come online. **That change was reverted**: rewriting the port mapping breaks port-forwarding rules existing users already configured, which costs far more than it saves. Final decision: **keep 50000-50100, no auto-avoidance**, and document the risk honestly. If you do hit a conflict, change it with `scripts/set_ports.sh` and update your router; compose `ports` and the in-container `COTURN_MIN_PORT`/`COTURN_MAX_PORT` must change together (coturn does no port translation)
- **A top-level `scripts/` directory in the FPK is never deployed by fnOS**: on the test machine, 30+ installed apps all have the layout `cmd/ config/ etc→ home→ ICON* LICENSE manifest meta→ target→ tmp→ var→ wizard/` — there is no `scripts/`. The Go supervisor/unified daemon we had shipped under the FPK top-level `scripts/` had therefore **never been installed anywhere** (cmd/main logged "script not found" on every start); v3.8.9 removed those binaries from the package and cleaned up the dead start-up calls. Executables must live under `app/` so they land in `${TRIM_APPDEST}/` via `app.tgz`
- **OPUS encoder is enabled via Codec2**: the redroid image already has the opus library (/system/lib64/libcodec2_soft_opusenc.so) and the swcodec c2.android.opus.encoder entry, but the Codec2 software codec is disabled by default; v3.8.9 enables it via setprop debug.stagefright.ccodec=1 + c2software=1 and a media service restart (no OMX alias injection needed; the old media_codecs_google_audio.xml approach is deprecated)
- **`cap_drop` is ignored under privileged; seccomp still applies**: with `privileged: true` plus `cap_drop`, CapEff inside the container remains the full `0x1ffffffffff` (Docker records the CapDrop entry but does not apply it), so capabilities cannot be used to narrow a privileged container; however `security_opt: seccomp=<profile>` **is** applied under privileged (`Seccomp: 2` inside the container), which is what v3.8.9 uses to deny module loading / kexec / reboot / swap / clock changes
- **no-new-privileges is NOT enabled in this app**: testing showed it breaks in-container process permissions (audio/video encoding, signaling) for both redroid and webrtc, so it has been removed from both containers; escalation protection is instead provided by binding ADB to 127.0.0.1 only, disabling the userdebug `su`, running the webrtc container without extra privileges, and attaching a custom seccomp filter to the redroid container (v3.8.9)
- **The casting entrypoint is a full fork — track upstream drift**: this app replaces the upstream `/app/entrypoint.sh` with `entrypoint_custom.sh` (to fix coturn listening only on the bridge, add de-privileging and JS injection). The cost: new upstream entrypoint contracts are not picked up automatically — upstream has since added `CLOUDPHONE_DEVICE_SECRET` (device registration secret); v3.8.9 added the passthrough plus `-device-secret` on the agent side. **Diff the upstream entrypoint after every image update**: `docker run --rm --entrypoint cat <img> /app/entrypoint.sh`
- **The keystore fix must tolerate a missing file**: `/data/misc/keystore/persistent.sqlite` is the keystore2 (Android 11+) database; treating "owner mismatch = corrupt" would flag Android 9/10 (which have no such file) as corrupt → delete DB + restart the container every 60s → infinite restart loop. Since v3.8.9 it is treated as "not applicable" when the file is absent
- **The gateway asset rewrite regex must tolerate subdirectories**: if upstream moves frontend assets from `/assets/<name>.js` to `/assets/js/chunk-*.js`, a flat-only regex silently drops the `?v=` cache-buster (stale chunks get cached); since v3.8.9 the character class includes `/`, a strict superset

---

### Q: What is the TLS policy for direct port 8443 access? How do I switch back to plaintext?

A: **Since 3.9.1, direct 8443 access defaults to HTTPS on both LAN and WAN** (`USE_TLS=true` — encryption first in every environment).

Background: the signaling binary supports TLS, and the early plaintext default was a deliberate trade-off — the certificate is self-signed (`/app/certs/create_certs.sh` signs with `openssl x509 -req -signkey`, CN hardcoded to `localhost`), so `https://<NAS_IP>:8443` triggers an "untrusted certificate" warning, and when entering via the app center the fnOS unified gateway already terminates TLS. Since 3.9.1 the agent speaks wss and trusts the self-signed certificate automatically (devices no longer drop offline over certificates), so per user request HTTPS is now the default everywhere. Only the first browser visit needs a manual confirmation.

TLS per network mode plus the dedicated toggle (`scripts/net_mode.sh`):

| Mode / command | `USE_TLS` | Use case |
|------|-----------|----------|
| `lan` / `lanhttp` | `true` | Direct LAN access (HTTPS by default); can be overridden to `false` by `https off` |
| `wan` | `true` | Public/domain access (HTTPS by default); can be overridden to `false` by `https off` |
| `proxy` | `false` | Tunnel / reverse proxy (TLS terminated upstream; toggle has no effect) |
| `https on` / `https off` | dedicated toggle | Switches TLS on 8443 without changing the mode; persisted in `var/tls.conf` and survives upgrades/port changes |

**Switch back to plaintext**: run `bash scripts/net_mode.sh https off` (proxy mode is always plaintext, TLS terminated upstream). **For warning-free HTTPS**, replace `/app/certs/server.crt|key` with a **real CA-signed certificate matching your domain** (e.g. Let's Encrypt). After a toggle the webrtc container is recreated, the gateway restarts automatically and the agent follows ws/wss; settings persist in `var/tls.conf`.

## Known Limitations

> **About Standalone Docker Container Version**: This project is currently published as an fnOS App Center FPK package. Standalone Docker Compose deployment is not yet available. The standalone Docker container version is planned for release after the app is stable on the App Center. Stay tuned.

1. **Audio**: v3.8.9 has fully fixed the OPUS audio encoder (via Codec2), enabled by default; 3.9.2 fixed an audio-repair watchdog lock-contention issue (audio now self-heals after container restarts). Note: output volume matches host system volume (if container is at 100% but host is at 50%, output is 50%)
7. **Video hardware codec**: the container has no hardware video codec HAL (redroid architectural limitation) — playback and streaming encode are software-based; the host-side hardware solution source is bundled (`app/hwenc/`) and will ship as an optional plugin
2. **External network access**: fnOS reverse proxy only passes TCP, WebRTC media stream (UDP) can't pass, auto-downgrades to WebSocket casting
3. **fnOS APP**: Some versions WebView has limited WebSocket proxy support, recommend mobile browser
4. **ARM app compatibility**: ARM64 apps with anti-emulator detection or complex JIT may crash (translation layer capability boundary)
5. **redroid privileged mode**: Android main container needs privileged (redroid upstream official requirement, non-privileged tested can't boot), but only applies inside container, app itself doesn't request host root
6. **Scrcpy device count authorization**: Free version has device count limit, paid only increases device count, doesn't affect functionality

---

## Feedback Links & Channels

1. **Publisher email**: andforlin@foxmail.com
2. **Suggestion & issue feedback survey**: https://wj.qq.com/s2/28029808/2aab/
3. **Communication, feedback & beta testing QQ group**: https://qm.qq.com/q/DF7nsBatFu
4. **Special feedback links for redroid container and Scrcpy container authors**: See "Acknowledgements & Links" section

> Feedback links and channels except #4 will be replied to, because #4 is special feedback channel for container issues and suggestions, unrelated to the app itself; if not satisfied with feedback results or want to contribute to the app, you can modify using source code, package according to fnOS official tutorial, then upload via first three feedback links and channels. Publisher will audit uploaded code and invite you to become a contributor; also thanks to those who provide feedback, suggestions or substantial help for the app. For details, see the official website: https://www.lin1740.de5.net/

---

## Support the Publisher & Contributors
<img width="4096" height="2926" alt="a61d0506ea65c87e4dd005f21325eda6" src="https://github.com/user-attachments/assets/1ad0e1e8-e03e-4966-a94d-24dff71981ba" />

If you find this app useful or are satisfied with the publisher, please consider supporting via donation to help the publisher and other contributors continue maintaining the app. Any amount or no donation is appreciated; please note "donation" in payment remarks, thanks.
Or give a star to support the project.

> Note: Above donation codes are only for this project's maintenance and development support, please do not misappropriate or use for other purposes, thanks for understanding.

---

## Open Source License & Disclaimer

### Open Source License

This application pulls the following public images via Docker at runtime, without modifying, bundling, or redistributing their source code or binaries:

#### 1. redroid (Android Container)
- Project: https://github.com/remote-android/redroid-doc
- Author: zhouziyang (remote-android organization)
- License Status:
  - redroid itself: [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) (explicitly stated in upstream README)
  - redroid-modules kernel module repo: [GPL-2.0](https://github.com/remote-android/redroid-modules/blob/master/LICENSE)
  - In-container AOSP (Android Open Source Project): [Apache 2.0](https://source.android.com/setup/start/licenses)
  - In-container Linux kernel related: GPL-2.0, Project: https://www.kernel.org/
- Major in-container AOSP components (only important components listed, complete list subject to AOSP official statements):
  - Bionic (Android C standard library): BSD, Project: https://android.googlesource.com/platform/bionic/
  - Skia (2D graphics engine): BSD, Project: https://skia.org/
  - Chromium (WebView browser engine): BSD / GPL / LGPL mixed, Project: https://www.chromium.org/
  - OpenSSL (cryptography library): Apache 2.0, Project: https://www.openssl.org/
  - zlib (compression library): zlib License, Project: https://zlib.net/
  - libpng (PNG image library): libpng License, Project: http://www.libpng.org/
  - FreeType (font rendering library): FreeType License / GPL, Project: https://www.freetype.org/
  - FFmpeg (media codec, some versions): LGPL / GPL, Project: https://ffmpeg.org/
- Built-in translation layers:
  - libndk_translation (Google official NDK translation layer): Google proprietary component, built into redroid image, license terms see Google related agreements
  - libhoudini (Intel translation layer, auto-downloaded in v3.8.1+): Intel proprietary component, downloaded from public sources, license terms see Intel related agreements

#### 2. scrcpy-over-webrtc (Cloud Phone Screen Service)
- Project: https://github.com/hqw700/ScrcpyOverWebRTC
- Author: hqw700 (buutuu)
- License Status:
  - Frontend source code (web-app): [MIT License](https://opensource.org/licenses/MIT)
  - Official binary core components (server, Agent deployment package, APK runtime): For personal learning, technical research, and non-commercial testing only
- Major direct dependencies:
  - scrcpy (Author: Genymobile): [Apache 2.0](https://github.com/Genymobile/scrcpy/blob/master/LICENSE), Project: https://github.com/Genymobile/scrcpy
  - ya-webadb / Tango (Author: yume-chan): [MIT](https://github.com/yume-chan/ya-webadb/blob/master/LICENSE), Project: https://github.com/yume-chan/ya-webadb
  - Pion WebRTC (Author: pion organization): [MIT](https://github.com/pion/webrtc/blob/master/LICENSE), Project: https://github.com/pion/webrtc
  - xterm.js (Author: xtermjs organization): [MIT](https://github.com/xtermjs/xterm.js/blob/master/LICENSE), Project: https://github.com/xtermjs/xterm.js
  - coturn TURN Server (Author: coturn project): [BSD 3-Clause](https://github.com/coturn/coturn/blob/master/LICENSE), Project: https://github.com/coturn/coturn
- Major transitive dependencies (only important components listed, complete list subject to each project's official statements):
  - Go language runtime and standard library: BSD, Project: https://go.dev/
  - Frontend frameworks and utility libraries (React/Vue, etc.): MIT, see frontend package.json for details
  - WebRTC related Go libraries (pion series): MIT, Project: https://github.com/pion
  - Logging, config, WebSocket and other Go third-party libraries: MIT / Apache 2.0, see go.mod for details

#### 3. This Project's Packaging Scripts and Configs
- Project: https://github.com/lin1740/fnos-android-emulator
- Author: 键盘敲粥香 (lin1740)
- License: [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
  > Brief: The Apache License 2.0 allows anyone to freely use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of this software, provided that copyright notices, license copies, and NOTICE files (if any) are retained, and modifications to original files are stated. The software is provided "AS IS" without any express or implied warranty. This license includes explicit patent grant terms.
- Includes: docker-compose configs, install/upgrade scripts, the Go gateway (gateway_amd64/arm64), status page, performance optimization scripts, relay-port precheck (turn_ports), locale/timezone fix (fix_locale), GPU render-mode switch (switch_render), etc. (all self-developed by this project, adapted for fnOS platform)
- Project source code link: See the "Publisher" blue link on the app detail page in fnOS App Center, or the project link in the app description
- Note: This application does not develop its own UI; the screen management page relies on scrcpy-over-webrtc's native UI, which is not within this project's modification scope

> **License Notice**: scrcpy-over-webrtc official binary core components are for personal learning, technical research, and non-commercial testing only; please confirm authorization with the author before commercial use; libndk_translation and libhoudini are vendor proprietary components, only used with upstream images or auto-downloaded at runtime, not redistributed.

### Disclaimer

1. This project is an unofficial third-party application, provided "AS IS", use at your own risk.
2. This project is for learning and research purposes only, and must not be used for any illegal purpose.
3. The publisher is not responsible for any data loss, system failure, or service interruption caused by using this application.
4. Third-party components integrated in the application (redroid, scrcpy-over-webrtc, etc.) are maintained by their respective authors, and their functionality, stability, and compliance are not controlled by this project.
5. Users should back up important data themselves; this application does not guarantee the security and integrity of data in the container.
6. This application itself does not actively collect your personal privacy data; all runtime data is stored on your local device. However, please note that when using third-party authorized services such as scrcpy-over-webrtc, necessary data such as your device identifier and network requests will be sent to upstream official servers for authorization verification and signaling connections. Please refer to the upstream service's privacy policy for details.
7. **Regarding GMS (Google Mobile Services)**: GMS (including Google Play Services, Google Play Store, Google Services Framework, etc.) is proprietary software of Google LLC, protected by copyright law and relevant international treaties. The application package itself **does not contain any GMS binaries**; only after the user actively selects "Install GMS" does the script extract files from a separate GMS file carrier image at runtime and install them into the Android container. By selecting to install GMS, you acknowledge and understand that: (1) Use of GMS is subject to Google's Terms of Service and Privacy Policy; (2) This project has not obtained official authorization or MADA certification from Google, and the distribution and use of GMS may carry legal risks, limited to personal learning and research purposes only; (3) After installation, GMS may have compatibility issues with some applications or system components, and this project is not responsible for any functional abnormalities, data loss, or system instability resulting therefrom; (4) If you intend to use it for commercial purposes or large-scale distribution, you must obtain formal authorization from Google yourself, otherwise you may face legal risks. Commercial users are recommended to consider open-source compliant alternatives such as microG.

### Open Source Obligations

1. **GPL-2.0 Component Obligations**: redroid-modules (kernel modules) and in-container Linux kernel related code follow the GPL-2.0 license. This application only pulls the redroid image from public repositories at runtime, without modifying or redistributing its source code or binaries. Legally, this constitutes "mere aggregation" and does not constitute a derivative work. However, if users modify, recompile, or redistribute the above GPL-2.0 components, they must strictly comply with GPL-2.0 open source obligations (including publishing modified source code, retaining copyright notices, etc.).
2. **Apache 2.0 Component Obligations**: Components following the Apache 2.0 license such as AOSP and scrcpy must retain copyright notices, license copies, and NOTICE files when redistributed.
3. **MIT / BSD Component Obligations**: Components following MIT or BSD licenses such as ya-webadb, Pion WebRTC, xterm.js, coturn, and Go standard library must retain copyright notices, license statements, and disclaimers when redistributed. MIT/BSD licenses are relatively permissive, allowing modification, redistribution, and commercial use, but original copyright and license statements must be retained.
4. **Proprietary Components**: libndk_translation (Google) and libhoudini (Intel) are vendor proprietary components; this application does not redistribute them, only uses them with upstream images or auto-downloads at runtime; users should comply with the corresponding vendor's terms of use.
5. **scrcpy-over-webrtc Components**: Frontend source code is under MIT license, freely modifiable; official binary core components are for personal learning, technical research, and non-commercial testing only.
⚠️ **Commercial Use Warning**: If you plan to use this software in any commercial environment (including but not limited to internal corporate commercial use, providing commercial cloud phone services to external parties, etc.), you must contact upstream author hqw700 in advance to obtain commercial authorization, or replace the core components with open-source alternatives that permit commercial use.
   > **Commercial Use Definition**: Any use involving financial gain or organizational/business purposes constitutes commercial use, including but not limited to: paid sales/subscriptions, fee-based external services, internal business use by enterprises, pre-installation on hardware for sale, advertising/data monetization, as part of custom development deliverables, etc. Personal learning/research and non-commercial home use are generally not considered commercial use. Commercial use of GMS additionally requires formal authorization from Google (e.g., MADA).
6. **This Project's Code**: Packaging scripts and configs are released under the Apache License 2.0, freely usable, modifiable, and distributable, with copyright notices, license copies, and NOTICE files (if any) retained, and modifications to original files stated.

### Additional Notes

1. **Trademarks and Logos**: The names, trademarks, and logos of redroid, scrcpy-over-webrtc, scrcpy, WebRTC, and other projects belong to their respective authors or organizations. This project uses these names only for technical integration descriptions, does not claim any trademark rights, and does not imply any official partnership or endorsement with these projects.
2. **Project Endorsement**: The integration and use of upstream open source components in this project only represents technical compatibility adaptation, and does not represent the upstream authors' recognition, recommendation, or endorsement of this project; the quality, security, and maintenance of each upstream component are the responsibility of its original authors.
3. **Upstream Changes**: Upstream open source projects may adjust features, interfaces, or license terms with version iterations. This project will try to follow up and adapt, but is not responsible for compatibility issues or license status changes caused by upstream changes; in case of major changes, please refer to the official announcements of each upstream project.
4. **Component Integrity**: This application pulls upstream official images from public container repositories at runtime, and does not modify or repackage the code inside the images; if users replace or modify upstream images on their own, any functional anomalies or compliance issues resulting therefrom are the user's responsibility.
5. **Patent Licensing**: The Apache 2.0 license includes patent grant clauses from contributors, while MIT and BSD licenses do not involve explicit patent grants; users should assess patent risks on their own when using, modifying, or redistributing related components.
6. **Export Control**: Some codec and encryption technologies involved in this project may be subject to export control regulations of certain countries or regions; users should ensure compliance with relevant local laws and regulations when using or redistributing across borders.
7. **Omission & Errata Notice**: Due to the complex dependency relationships of upstream open source projects, the license information, project links of some transitive dependencies or sub-components may not be fully listed or accurately noted in this section. If you find any open source project that should be listed but is omitted, any license status errors, or any incorrect project links, we sincerely apologize and welcome you to inform us through any of the "Feedback Links & Channels" below (except for the 4th channel, which is the dedicated feedback channel for upstream components). We will verify and supplement/correct it in a timely manner.
8. **Source Code Release**: The packaging scripts and configs of this project are released under the Apache License 2.0, but the publication of source code may be handled at our discretion based on actual circumstances. For example, the source code of beta/inner-test versions may not be publicly available temporarily due to stability, security, or other reasons, while the source code of public release versions is usually published to this repository simultaneously. The actual content published in this repository shall prevail.

---

## Acknowledgements & Links

### Links

1. redroid container project: https://github.com/remote-android/redroid-doc
2. Scrcpy container project: https://github.com/hqw700/ScrcpyOverWebRTC
3. Scrcpy official docs: https://webrtc-phone.com/docs/
4. Scrcpy official website: https://webrtc-phone.com/
5. Android Emulator (China) Official Website: https://www.lin1740.de5.net/

### Acknowledgements

- [redroid project] — Android in Docker
- [Scrcpy scrcpy-over-webrtc] — WebRTC screen service
- fnOS development community
- QQ user 「还得你老汪」 (HaiDeNiLaoWang) — provided the ARM test device for dual-platform real-hardware testing
