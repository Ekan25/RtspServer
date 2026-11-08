using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CameraController;

public sealed class RtspVideoPlayer : IDisposable
{
    private readonly PlayerHandle _handle;
    private bool _disposed;

    static RtspVideoPlayer()
    {
        string gstreamerRoot = Environment.GetEnvironmentVariable("GSTREAMER_1_0_ROOT_MSVC_X86_64")
            ?? @"C:\Program Files\gstreamer\1.0\msvc_x86_64";
        string gstreamerBin = Path.Combine(gstreamerRoot, "bin");
        if (Directory.Exists(gstreamerBin))
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            Environment.SetEnvironmentVariable("PATH", gstreamerBin + Path.PathSeparator + path);
            NativeMethods.AddDllSearchDirectory(gstreamerBin);
        }

        NativeLibrary.SetDllImportResolver(typeof(RtspVideoPlayer).Assembly, (libraryName, assembly, searchPath) =>
        {
            if (!string.Equals(libraryName, "GStreamerNative.dll", StringComparison.OrdinalIgnoreCase))
                return IntPtr.Zero;
            string assemblyDirectory = Path.GetDirectoryName(assembly.Location)
                ?? throw new DllNotFoundException("Could not locate the WPF application directory.");
            string nativePath = Path.Combine(assemblyDirectory, libraryName);
            if (!File.Exists(nativePath))
                throw new DllNotFoundException($"The GStreamer native player is missing: {nativePath}");
            return NativeLibrary.Load(nativePath);
        });
    }

    public RtspVideoPlayer()
    {
        _handle = NativeMethods.Create();
        if (_handle.IsInvalid)
        {
            _handle.Dispose();
            throw new InvalidOperationException("Could not create the native GStreamer player.");
        }
    }

    public void Start(string url, uint latencyMilliseconds)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(url);
        int result = NativeMethods.Start(_handle, url, latencyMilliseconds);
        if (result != 0)
        {
            string message = "The native GStreamer pipeline could not be started.";
            while (NativeMethods.PollEvent(_handle, out RtspPlayerEvent playerEvent) == 1)
            {
                if (playerEvent.Type == 3 && !string.IsNullOrWhiteSpace(playerEvent.Message))
                    message = playerEvent.Message;
            }
            throw new InvalidOperationException(message);
        }
    }

    public void Stop()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        NativeMethods.Stop(_handle);
    }

    public int CopyLatestFrame(byte[] destination, out RtspFrameInfo info)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(destination);
        return NativeMethods.CopyLatestFrame(_handle, destination, (ulong)destination.Length, out info);
    }

    public bool TryPollEvent(out RtspPlayerEvent playerEvent)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        int result = NativeMethods.PollEvent(_handle, out playerEvent);
        return result == 1;
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _handle.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RtspFrameInfo
    {
        public uint Width;
        public uint Height;
        public uint Stride;
        public uint FrameRateNumerator;
        public uint FrameRateDenominator;
        public ulong Sequence;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct RtspPlayerEvent
    {
        public int Type;
        public int OldState;
        public int NewState;
        public uint Width;
        public uint Height;
        public uint FrameRateNumerator;
        public uint FrameRateDenominator;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
        public string Message;
    }

    private sealed class PlayerHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public PlayerHandle() : base(true) { }

        protected override bool ReleaseHandle()
        {
            NativeMethods.Destroy(handle);
            return true;
        }
    }

    private static class NativeMethods
    {
        private const string Library = "GStreamerNative.dll";

        [DllImport("kernel32.dll", EntryPoint = "SetDllDirectoryW", CallingConvention = CallingConvention.Winapi,
            CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AddDllSearchDirectory(string path);

        [DllImport(Library, EntryPoint = "gst_player_create", CallingConvention = CallingConvention.Cdecl)]
        internal static extern PlayerHandle Create();

        [DllImport(Library, EntryPoint = "gst_player_start", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int Start(PlayerHandle player, [MarshalAs(UnmanagedType.LPUTF8Str)] string url, uint latencyMilliseconds);

        [DllImport(Library, EntryPoint = "gst_player_stop", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void Stop(PlayerHandle player);

        [DllImport(Library, EntryPoint = "gst_player_destroy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void Destroy(IntPtr player);

        [DllImport(Library, EntryPoint = "gst_player_copy_latest_frame", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int CopyLatestFrame(PlayerHandle player, [Out] byte[] destination, ulong capacity, out RtspFrameInfo info);

        [DllImport(Library, EntryPoint = "gst_player_poll_event", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int PollEvent(PlayerHandle player, out RtspPlayerEvent playerEvent);
    }
}