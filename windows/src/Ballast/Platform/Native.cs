using System.Runtime.InteropServices;

namespace Ballast.Platform;

internal static unsafe class Native
{
    public const int StatusInfoLengthMismatch = unchecked((int)0xC0000004);
    public const int SystemProcessInformation = 5;
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint ProcessQueryInformation = 0x0400;
    public const uint ProcessVmRead = 0x0010;
    public const int GwOwner = 4;
    public const int GwlExStyle = -20;
    public const long WsExToolWindow = 0x00000080;
    public const long WsExNoActivate = 0x08000000;
    public const long WsExAppWindow = 0x00040000;
    public const uint WmClose = 0x0010;
    public const int DwmwaCloaked = 14;
    public const int DwmwaUseImmersiveDarkMode = 20;
    public const int DwmwaWindowCornerPreference = 33;
    public const int DwmwaBorderColor = 34;
    public const int DwmwcpRound = 2;
    public const uint SherbNoConfirmation = 0x1;
    public const uint SherbNoProgressUi = 0x2;
    public const uint SherbNoSound = 0x4;
    public const uint FoDelete = 0x0003;
    public const ushort FofSilent = 0x0004;
    public const ushort FofNoConfirmation = 0x0010;
    public const ushort FofAllowUndo = 0x0040;
    public const ushort FofNoErrorUi = 0x0400;
    public const ushort FofWantNukeWarning = 0x4000;

    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PerformanceInformation
    {
        public uint Size;
        public nuint CommitTotal;
        public nuint CommitLimit;
        public nuint CommitPeak;
        public nuint PhysicalTotal;
        public nuint PhysicalAvailable;
        public nuint SystemCache;
        public nuint KernelTotal;
        public nuint KernelPaged;
        public nuint KernelNonpaged;
        public nuint PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct UnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public nint Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SystemProcessInfo
    {
        public uint NextEntryOffset;
        public uint NumberOfThreads;
        public long WorkingSetPrivateSize;
        public uint HardFaultCount;
        public uint NumberOfThreadsHighWatermark;
        public ulong CycleTime;
        public long CreateTime;
        public long UserTime;
        public long KernelTime;
        public UnicodeString ImageName;
        public int BasePriority;
        public nint UniqueProcessId;
        public nint InheritedFromUniqueProcessId;
        public uint HandleCount;
        public uint SessionId;
        public nuint UniqueProcessKey;
        public nuint PeakVirtualSize;
        public nuint VirtualSize;
        public uint PageFaultCount;
        public nuint PeakWorkingSetSize;
        public nuint WorkingSetSize;
        public nuint QuotaPeakPagedPoolUsage;
        public nuint QuotaPagedPoolUsage;
        public nuint QuotaPeakNonPagedPoolUsage;
        public nuint QuotaNonPagedPoolUsage;
        public nuint PagefileUsage;
        public nuint PeakPagefileUsage;
        public nuint PrivatePageCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessBasicInformation
    {
        public nint ExitStatus;
        public nint PebBaseAddress;
        public nint AffinityMask;
        public nint BasePriority;
        public nint UniqueProcessId;
        public nint InheritedFromUniqueProcessId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ShQueryRbInfo
    {
        public uint Size;
        public long SizeBytes;
        public long NumItems;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct ShFileOpStruct
    {
        public nint Hwnd;
        public uint Func;
        public string From;
        public string? To;
        public ushort Flags;
        public int AnyOperationsAborted;
        public nint NameMappings;
        public string? ProgressTitle;
    }

    public enum MemoryResourceNotificationType
    {
        Low = 0,
        High = 1,
    }

    public delegate bool EnumWindowsProc(nint hwnd, nint lParam);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);

    [DllImport("kernel32.dll", EntryPoint = "K32GetPerformanceInfo", SetLastError = true)]
    public static extern bool GetPerformanceInfo(out PerformanceInformation info, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern nint CreateMemoryResourceNotification(MemoryResourceNotificationType type);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool QueryMemoryResourceNotification(nint handle, out int state);

    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(int infoClass, void* buffer, int length, out int returnLength);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(nint process, int infoClass, out ProcessBasicInformation info, int length, out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern nint OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(nint handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageName(nint process, int flags, char* buffer, ref int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(nint process, nint address, void* buffer, nint size, out nint read);

    [DllImport("kernel32.dll")]
    public static extern bool AttachConsole(int pid);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, nint lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(nint hwnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(nint hwnd);

    [DllImport("user32.dll")]
    public static extern nint GetWindow(nint hwnd, int command);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(nint hwnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(nint hwnd, out int pid);

    [DllImport("user32.dll")]
    public static extern nint GetForegroundWindow();

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern nint GetWindowLongPtr(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHQueryRecycleBin(string? rootPath, ref ShQueryRbInfo info);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHEmptyRecycleBin(nint hwnd, string? rootPath, uint flags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref ShFileOpStruct operation);
}
