# Get-Fido2Aaguid

Reads the **AAGUID** of a connected FIDO2 security key (e.g. a YubiKey) from PowerShell by calling [libfido2](https://github.com/Yubico/libfido2) (`fido2.dll`) directly through P/Invoke. Useful when you need the AAGUID to allow-list a key model, for example in an Entra ID FIDO2 authentication method policy with attestation enforcement.

## Contents

| Path | Description |
| --- | --- |
| `Get-Fido2Aaguid.ps1` | The script. Emits one object per FIDO2 device it can open. |
| `dynamic/` | Prebuilt Win64/Release **v143** (Visual Studio 2022 toolset) DLLs and import libs: `fido2.dll`, `cbor.dll`, `crypto-56.dll`, `zlib1.dll`. **These are what the script loads.** |
| `static/` | Prebuilt static `.lib` files (`fido2`, `cbor`, `crypto`, `zlib`). Not used by the script. Only needed if you're linking libfido2 into your own C/C++ project. |

`.pdb` files are included for debugging only.

## Requirements

- 64-bit Windows PowerShell 5.1 or PowerShell 7 (the DLLs are x64 only, so a 32-bit host will fail to load them).
- A FIDO2 key plugged in.
- Run from an **elevated** prompt. Windows only allows raw HID access to FIDO devices for administrators.
- Keep `fido2.dll`, `cbor.dll`, `crypto-56.dll` and `zlib1.dll` together in the same folder. The script warns if any dependency is missing.

## Usage

```powershell
# Default: uses .\dynamic\fido2.dll next to the script
.\Get-Fido2Aaguid.ps1

# Show device enumeration details
.\Get-Fido2Aaguid.ps1 -Verbose

# Use a different build of fido2.dll
.\Get-Fido2Aaguid.ps1 -Fido2DllPath 'C:\libfido2\fido2.dll'
```

### Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Fido2DllPath` | `.\dynamic\fido2.dll` | Path to `fido2.dll`. The dependent DLLs must sit beside it. |
| `-MaxDevices` | `64` | Capacity of the device list to scan. |

### Output

```
Path         : \\?\hid#vid_1050&pid_0407...
Manufacturer : Yubico
Product      : YubiKey OTP+FIDO+CCID
AAGUID       : 2fc0579f-8113-47ea-b116-bb5a8db9202a
AAGUIDGuid   : 2fc0579f-8113-47ea-b116-bb5a8db9202a
```

(Values above are illustrative.)

`AAGUID` is the canonical string, in the same byte order as `fido2-token -I` and FIDO Metadata Service entries. `AAGUIDGuid` is a real `System.Guid` with bytes reordered so it prints identically. Building a `Guid` straight from the raw bytes would swap the first 8 bytes and give the wrong value.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `No FIDO2/U2F devices found` | Key not plugged in, or the shell isn't elevated. |
| `fido_dev_open failed ... rc=...` | Another process has the device, or not running as administrator. |
| `fido_dev_get_cbor_info failed ... Device may be U2F-only` | The key doesn't support FIDO2/CTAP2, so it has no AAGUID. |
| `BadImageFormatException` / DLL load failure | 32-bit PowerShell host, or a missing dependency DLL. |

## Notes

- The script only reads device info. It doesn't register credentials or change anything on the key.
- Only opaque handles are passed across the P/Invoke boundary, and `size_t` values are marshaled as `UIntPtr`. See the header comment in the script for the reasoning behind each marshaling choice.
- The DLLs are third-party binaries (libfido2, libcbor, OpenSSL, zlib). Rebuild them from source if you need to verify provenance.
