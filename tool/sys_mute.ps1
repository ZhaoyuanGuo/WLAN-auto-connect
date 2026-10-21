param(
    [ValidateSet('mute', 'unmute', 'status')][string]$Action = 'status'
)

# Read / set system mute on the default render endpoint via Core Audio (IAudioEndpointVolume). ASCII-only.
# CLSID_MMDeviceEnumerator is registered as ..1692E on this machine; the ..1695E spelling seen in some
# samples is not, so both are attempted.
$sig = @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr pNotify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr pNotify);
    [PreserveSig] int GetChannelCount(out int pnChannelCount);
    [PreserveSig] int SetMasterVolumeLevel(float fLevelDB, ref Guid ctx);
    [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, ref Guid ctx);
    [PreserveSig] int GetMasterVolumeLevel(out float pfLevelDB);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float pfLevel);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float fLevelDB, ref Guid ctx);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float fLevel, ref Guid ctx);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float pfLevelDB);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float pfLevel);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}

public static class Audio {
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint ctx, ref Guid iid, out IntPtr ppv);

    public static string Err;
    public static bool Muted;
    public static float Level = -1;
    public static string Device;

    private static IMMDeviceEnumerator Enumerator() {
        Guid iid = typeof(IMMDeviceEnumerator).GUID;
        Guid[] clsids = {
            new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"),
            new Guid("BCDE0395-E52F-467C-8E3D-C4579291695E"),
        };
        Err = "";
        foreach (Guid g in clsids) {
            Guid c = g;
            IntPtr p;
            int hr = CoCreateInstance(ref c, IntPtr.Zero, 23, ref iid, out p); // CLSCTX_ALL
            if (hr == 0 && p != IntPtr.Zero) return (IMMDeviceEnumerator)Marshal.GetTypedObjectForIUnknown(p, typeof(IMMDeviceEnumerator));
            Err += "0x" + hr.ToString("X8") + " ";
        }
        Err = "CoCreateInstance(MMDeviceEnumerator) failed " + Err.Trim();
        return null;
    }

    private static IAudioEndpointVolume Open() {
        var enumerator = Enumerator();
        if (enumerator == null) return null;
        IMMDevice device;
        int hr = enumerator.GetDefaultAudioEndpoint(0, 0, out device); // eRender, eConsole
        if (hr != 0) { Err = "GetDefaultAudioEndpoint failed 0x" + hr.ToString("X8"); return null; }
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object obj;
        hr = device.Activate(ref iid, 23, IntPtr.Zero, out obj); // CLSCTX_ALL
        if (hr != 0) { Err = "Activate(IAudioEndpointVolume) failed 0x" + hr.ToString("X8"); return null; }
        string id;
        if (device.GetId(out id) == 0) Device = id;
        return (IAudioEndpointVolume)obj;
    }

    private static bool Poll(IAudioEndpointVolume vol) {
        bool m;
        if (vol.GetMute(out m) != 0) { Err = "GetMute failed"; return false; }
        Muted = m;
        float l;
        if (vol.GetMasterVolumeLevelScalar(out l) == 0) Level = l;
        return true;
    }

    public static bool Read() {
        var vol = Open();
        return vol != null && Poll(vol);
    }

    public static bool Write(bool mute) {
        var vol = Open();
        if (vol == null) return false;
        if (!Poll(vol)) return false;       // keep the pre-change level in the report
        if (Muted == mute) return true;     // already in the requested state
        Guid ctx = Guid.Empty;
        int hr = vol.SetMute(mute, ref ctx);
        if (hr != 0 && hr != 1) { Err = "SetMute failed 0x" + hr.ToString("X8"); return false; } // S_FALSE = no change
        return Poll(vol);
    }
}
'@
Add-Type -TypeDefinition $sig

$ok = $false
switch ($Action) {
    'mute' { $ok = [Audio]::Write($true) }
    'unmute' { $ok = [Audio]::Write($false) }
    'status' { $ok = [Audio]::Read() }
}
if (-not $ok) { Write-Output ("FAILED: " + [Audio]::Err); exit 1 }

$state = if ([Audio]::Muted) { 'muted' } else { 'unmuted' }
$level = if ([Audio]::Level -lt 0) { '?' } else { [Math]::Round([Audio]::Level * 100) }
Write-Output ("system: $state  master=$level%")
