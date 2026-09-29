<#
.SYNOPSIS
    Reads the AAGUID from the first openable FIDO2 device via libfido2 (fido2.dll).

.DESCRIPTION
    P/Invokes fido2.dll (vcpkg-style Win64/Release/v143 build) to:
      fido_dev_info_new -> fido_dev_info_manifest -> fido_dev_info_ptr ->
      fido_dev_new -> fido_dev_open -> fido_dev_get_cbor_info -> fido_cbor_info_aaguid_ptr

    Verified against the actual export table of the shipped fido2.dll (objdump -p) and
    against upstream libfido2 1.17.0 src/fido.h. Notes on why things are done this way:

      - The DLL is 64-bit (PE32+, coff-x86-64). On x64 there is only one Windows calling
        convention, so Cdecl vs Stdcall cannot itself cause a crash here - but Cdecl is
        declared below because that's what the C source actually uses (no __stdcall).

      - fido_dev_info_t / fido_dev_t / fido_cbor_info_t are OPAQUE to callers. We never
        define their internal layout in C# - we only ever hold IntPtr handles to them and
        go through the library's own accessor functions. This removes the single biggest
        source of struct-layout risk.

      - fido_dev_info_free / fido_dev_free / fido_cbor_info_free take a POINTER TO POINTER
        (T**) so the library can null out the caller's handle. These are marshaled as
        `ref IntPtr`, not `IntPtr` - passing plain IntPtr here would hand the library a
        raw handle value where it expects an address to write back through, i.e. an
        access violation or a wild write.

      - Every size_t (the device-list capacity/count in fido_dev_info_new /
        fido_dev_info_manifest / fido_dev_info_free) is marshaled as UIntPtr, never
        int/uint. On x64, size_t is 8 bytes; if you declare the manifest's `size_t *olen`
        out-parameter as `out int`, the CLR only reserves 4 bytes for it but the native
        call still writes a full 8-byte size_t through that pointer - a 4-byte stack
        corruption on every call. UIntPtr is the correct, safe mapping.

      - fido_dev_info_free must be called with the ORIGINAL CAPACITY passed to
        fido_dev_info_new (i.e. MaxDevices below), not the `olen` count of devices actually
        found. This matches upstream's own fido2-token reference tool.

      - fido_dev_info_path / manufacturer / product strings are owned by the devlist
        entry and must NOT be freed separately - they die when fido_dev_info_free runs.
        We marshal them as raw IntPtr and convert with Marshal.PtrToStringAnsi, rather
        than letting the P/Invoke marshaler auto-convert-and-maybe-free a return string,
        so there's no ambiguity about ownership.

      - fido_cbor_info_aaguid_ptr returns a pointer to a raw 16-byte buffer owned by the
        fido_cbor_info_t. We defensively check fido_cbor_info_aaguid_len == 16 before
        copying, and never construct `New-Object Guid(,$bytes)` directly from those raw
        bytes: System.Guid's binary constructor reinterprets the first 8 bytes as
        little-endian integers, so its .ToString() would NOT match the canonical AAGUID
        hex string (e.g. what `fido2-token -I` or a metadata-service entry shows). We
        format the canonical string by hand, and only optionally build a byte-reordered
        System.Guid for callers who specifically want a .NET Guid object.

.PARAMETER Fido2DllPath
    Path to fido2.dll. Defaults to .\dynamic\fido2.dll next to this script (the
    vcpkg-style dynamic build folder that also contains cbor.dll, crypto-56.dll, zlib1.dll).

.PARAMETER MaxDevices
    Capacity of the device list to allocate/scan. Default 64.
#>
[CmdletBinding()]
param(
    [string]$Fido2DllPath = (Join-Path $PSScriptRoot 'dynamic\fido2.dll'),
    [int]$MaxDevices = 64
)

$ErrorActionPreference = 'Stop'

$Fido2DllPath = (Resolve-Path -LiteralPath $Fido2DllPath -ErrorAction Stop).ProviderPath
$dllDir = Split-Path -Parent $Fido2DllPath

foreach ($dep in 'cbor.dll', 'crypto-56.dll', 'zlib1.dll') {
    $depPath = Join-Path $dllDir $dep
    if (-not (Test-Path -LiteralPath $depPath)) {
        Write-Warning "Expected dependency '$dep' not found next to fido2.dll at '$dllDir'. Load will likely fail."
    }
}

# Escaped for use inside the C# string literal below (DllImport needs the literal path).
$dllPathLiteral = $Fido2DllPath.Replace('\', '\\')

$src = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Fido2Native
{
    private const string DLL = "$dllPathLiteral";

    // Ensure sibling DLLs (cbor.dll, crypto-56.dll, zlib1.dll) resolve even if the
    // process CWD or PATH doesn't include the dynamic\ folder.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string lpPathName);

    // void fido_init(int flags);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fido_init(int flags);

    // const char *fido_strerr(int n);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_strerr(int n);

    // fido_dev_info_t *fido_dev_info_new(size_t n);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_info_new(UIntPtr n);

    // void fido_dev_info_free(fido_dev_info_t **devlist_p, size_t n);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fido_dev_info_free(ref IntPtr devlist_p, UIntPtr n);

    // int fido_dev_info_manifest(fido_dev_info_t *devlist, size_t ilen, size_t *olen);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int fido_dev_info_manifest(IntPtr devlist, UIntPtr ilen, out UIntPtr olen);

    // const fido_dev_info_t *fido_dev_info_ptr(const fido_dev_info_t *devlist, size_t i);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_info_ptr(IntPtr devlist, UIntPtr i);

    // const char *fido_dev_info_path(const fido_dev_info_t *di);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_info_path(IntPtr di);

    // const char *fido_dev_info_manufacturer_string(const fido_dev_info_t *di);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_info_manufacturer_string(IntPtr di);

    // const char *fido_dev_info_product_string(const fido_dev_info_t *di);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_info_product_string(IntPtr di);

    // fido_dev_t *fido_dev_new(void);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_dev_new();

    // void fido_dev_free(fido_dev_t **dev_p);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fido_dev_free(ref IntPtr dev_p);

    // int fido_dev_open(fido_dev_t *dev, const char *path);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int fido_dev_open(IntPtr dev, string path);

    // int fido_dev_close(fido_dev_t *dev);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int fido_dev_close(IntPtr dev);

    // fido_cbor_info_t *fido_cbor_info_new(void);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_cbor_info_new();

    // void fido_cbor_info_free(fido_cbor_info_t **info_p);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void fido_cbor_info_free(ref IntPtr info_p);

    // int fido_dev_get_cbor_info(fido_dev_t *dev, fido_cbor_info_t *info);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int fido_dev_get_cbor_info(IntPtr dev, IntPtr info);

    // const unsigned char *fido_cbor_info_aaguid_ptr(const fido_cbor_info_t *info);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr fido_cbor_info_aaguid_ptr(IntPtr info);

    // size_t fido_cbor_info_aaguid_len(const fido_cbor_info_t *info);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern UIntPtr fido_cbor_info_aaguid_len(IntPtr info);

    public static string PtrToStringAnsiSafe(IntPtr p)
    {
        return p == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(p);
    }
}
"@

Add-Type -TypeDefinition $src -ErrorAction Stop

# Belt-and-suspenders: also add the dll directory to the search path explicitly.
[void][Fido2Native]::SetDllDirectory($dllDir)

[Fido2Native]::fido_init(0)

# [UIntPtr] has no direct conversion from a signed Int32; go through [uint64] first.
$maxDevicesU = [UIntPtr][uint64]$MaxDevices
$devlist = [Fido2Native]::fido_dev_info_new($maxDevicesU)
if ($devlist -eq [IntPtr]::Zero) {
    throw "fido_dev_info_new failed (out of memory or invalid MaxDevices)."
}

try {
    $olen = [UIntPtr]::Zero
    $rc = [Fido2Native]::fido_dev_info_manifest($devlist, $maxDevicesU, [ref]$olen)
    if ($rc -ne 0) {
        $err = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_strerr($rc))
        throw "fido_dev_info_manifest failed: rc=$rc ($err)"
    }

    $deviceCount = [uint64]$olen
    if ($deviceCount -eq 0) {
        throw "No FIDO2/U2F devices found. Is the YubiKey plugged in?"
    }

    Write-Verbose "Found $deviceCount device(s)."

    for ($i = 0; $i -lt $deviceCount; $i++) {
        $di = [Fido2Native]::fido_dev_info_ptr($devlist, [UIntPtr][uint64]$i)
        if ($di -eq [IntPtr]::Zero) { continue }

        $path = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_dev_info_path($di))
        $manufacturer = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_dev_info_manufacturer_string($di))
        $product = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_dev_info_product_string($di))

        Write-Verbose "Device $i : $path ($manufacturer $product)"

        $dev = [Fido2Native]::fido_dev_new()
        if ($dev -eq [IntPtr]::Zero) {
            Write-Warning "fido_dev_new failed for device $i, skipping."
            continue
        }

        $info = [IntPtr]::Zero
        try {
            $openRc = [Fido2Native]::fido_dev_open($dev, $path)
            if ($openRc -ne 0) {
                $err = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_strerr($openRc))
                Write-Warning "fido_dev_open failed for '$path': rc=$openRc ($err)"
                continue
            }

            $info = [Fido2Native]::fido_cbor_info_new()
            if ($info -eq [IntPtr]::Zero) {
                Write-Warning "fido_cbor_info_new failed for device $i, skipping."
                continue
            }

            $cborRc = [Fido2Native]::fido_dev_get_cbor_info($dev, $info)
            if ($cborRc -ne 0) {
                $err = [Fido2Native]::PtrToStringAnsiSafe([Fido2Native]::fido_strerr($cborRc))
                Write-Warning "fido_dev_get_cbor_info failed for '$path': rc=$cborRc ($err). Device may be U2F-only."
                continue
            }

            $aaguidLen = [uint64][Fido2Native]::fido_cbor_info_aaguid_len($info)
            $aaguidPtr = [Fido2Native]::fido_cbor_info_aaguid_ptr($info)

            if ($aaguidPtr -eq [IntPtr]::Zero -or $aaguidLen -eq 0) {
                Write-Warning "Device '$path' returned no AAGUID."
                continue
            }
            if ($aaguidLen -ne 16) {
                Write-Warning "Unexpected AAGUID length $aaguidLen (expected 16) for '$path' - truncating/skipping display of extra bytes."
            }

            $copyLen = [Math]::Min([int]$aaguidLen, 16)
            $bytes = New-Object byte[] $copyLen
            [System.Runtime.InteropServices.Marshal]::Copy($aaguidPtr, $bytes, 0, $copyLen)

            if ($copyLen -lt 16) {
                Write-Warning "AAGUID shorter than 16 bytes; cannot form a full GUID for '$path'."
                continue
            }

            # Canonical AAGUID hex string, byte order exactly as returned by the device -
            # matches what fido2-token / MDS entries show. Deliberately NOT built via
            # `New-Object Guid(,$bytes)`, which would byte-swap the first 8 bytes.
            $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
            $canonical = "{0}-{1}-{2}-{3}-{4}" -f `
                $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), `
                $hex.Substring(16, 4), $hex.Substring(20, 12)

            # Optional: a real System.Guid object, byte-reordered so its .ToString() matches
            # $canonical above (System.Guid's constructor treats the first 8 bytes as
            # little-endian integers, so a naive New-Object Guid(,$bytes) would NOT match).
            $reordered = New-Object byte[] 16
            $reordered[0] = $bytes[3]; $reordered[1] = $bytes[2]; $reordered[2] = $bytes[1]; $reordered[3] = $bytes[0]
            $reordered[4] = $bytes[5]; $reordered[5] = $bytes[4]
            $reordered[6] = $bytes[7]; $reordered[7] = $bytes[6]
            for ($k = 8; $k -lt 16; $k++) { $reordered[$k] = $bytes[$k] }
            $guidObject = New-Object System.Guid (,$reordered)

            [pscustomobject]@{
                Path         = $path
                Manufacturer = $manufacturer
                Product      = $product
                AAGUID       = $canonical
                AAGUIDGuid   = $guidObject
            }
        }
        finally {
            if ($info -ne [IntPtr]::Zero) { [Fido2Native]::fido_cbor_info_free([ref]$info) }
            [void][Fido2Native]::fido_dev_close($dev)
            if ($dev -ne [IntPtr]::Zero) { [Fido2Native]::fido_dev_free([ref]$dev) }
        }
    }
}
finally {
    if ($devlist -ne [IntPtr]::Zero) {
        [Fido2Native]::fido_dev_info_free([ref]$devlist, $maxDevicesU)
    }
}
