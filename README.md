# BetterKnownInstalled (BKI)

This Magisk/KernelSU/APatch module patches `packages.xml` to address DroidGuard's `UNKNOWN_INSTALLED` status. This helps resolve issues related to app installation and verification on devices with Play Services.

---

## Description

DroidGuard uses several attributes within the `packages.xml` file to track app installations. This module modifies these attributes on **user-installed apps** to ensure that apps are recognized as properly installed, preventing the `UNKNOWN_INSTALLED` status and related problems. Specifically, it:

* Targets only packages with `codePath` under **`/data/app/`**, skipping everything else (system, vendor, APEX, etc.).
* Still skips packages explicitly flagged with **`system="true"`** or **`system="1"`** as a safety guard.
* Sets the **`installer`**, **`installInitiator`**, and **`installerUid`** attributes within each targeted `<package>` tag to `com.android.vending` (the Google Play Store's package name identifier) and the corresponding user ID. This helps DroidGuard recognize the installation source as legitimate.
* Removes the **`installOriginator`** attribute, as it can sometimes cause conflicts.
* Removes the **`isOrphaned`** and **`installInitiatorUninstalled`** attributes if their values are set to `true` or `1`, as these can flag an app as incorrectly installed.
* Changes the **`packageSource`** attribute to the constant value `2` (which represents **`PACKAGE_SOURCE_STORE`**), **adding it when missing** or replacing it when set to another value.

This module uses `abx2xml` and `xml2abx` binaries if not in your system by default (provided by [rhythmcache/android-xml-converter](https://github.com/rhythmcache/android-xml-converter)) to convert between binary and text XML formats, as `packages.xml` is typically in binary XML format. The module includes architecture-specific binaries for `aarch64`, `armv7aeabi`, `i686`, `x86_64`, and `riscv64`.

**Important Warning:** The environment check verdict modification implemented by this module is a relatively new technique. Google's implementation of this check is not yet robust enough to guarantee that all your packages will be correctly identified. It's possible that some apps might still trigger Play Protect warnings or behave unexpectedly, even after using this module. This is due to limitations and potential inconsistencies in how Google verifies app installations. Use this module with caution and be aware of the potential for these issues.

---

## Installation

1.  Install this module through Magisk Manager, KernelSU, or APatch.
2.  Reboot your device for the changes to take effect.

**Important:** Installation from recovery is **not** supported. You **must** install this module from within a running Android environment (Magisk/KernelSU/APatch).

---

## Usage

This module works automatically upon installation and reboot. No further user interaction is required. It modifies the necessary XML file during the boot process.

---

## Backups

The module creates backups of the original `packages.xml` file in `/data/adb/modules/BetterKnownInstalled/backup/` before making any changes. Up to five backups are kept, including the latest one. The backups are timestamped for easy identification.

---

## Logging

The module logs its activity to `/data/adb/modules/BetterKnownInstalled/BetterKnownInstalled.log`. This log file can be helpful for troubleshooting.

---

## Credits

* [rhythmcache aka winter](https://github.com/rhythmcache/android-xml-converter) for the `abx2xml` and `xml2abx` binaries.
* [@gavdoc38](https://github.com/gavdoc38) for the PR updating problematic attributes.
* [@T3SL4](https://t.me/T3SL4) (Me) for creating this module.

---

## License

This project is licensed under the terms of the GNU General Public License v3.0. See the [LICENSE](./LICENSE) file for details.
