using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ZeroStutter.Native
{
    public sealed class CpuSetInfo
    {
        public uint Id { get; set; }
        public ushort Group { get; set; }
        public byte LogicalProcessorIndex { get; set; }
        public byte CoreIndex { get; set; }
        public byte LastLevelCacheIndex { get; set; }
        public byte EfficiencyClass { get; set; }
        public bool Parked { get; set; }
        public bool Allocated { get; set; }
        public bool AllocatedToTargetProcess { get; set; }
    }

    public sealed class CpuTopology
    {
        public CpuSetInfo[] CpuSets { get; set; }
        public int LogicalProcessorCount { get; set; }
        public bool PerformanceAvailable { get; set; }
        public uint[] PerformanceCpuSetIds { get; set; }
        public string Reason { get; set; }
    }

    // This snapshot contains no handles. It can be journaled before Apply and used by a recovery process.
    public sealed class ProcessTuningState
    {
        public int SchemaVersion { get; set; }
        public int ProcessId { get; set; }
        public long CreationFileTime { get; set; }
        public DateTime CreationTimeUtc { get { return DateTime.FromFileTimeUtc(CreationFileTime); } }
        public string CpuPolicy { get; set; }
        public bool HighQoSRequested { get; set; }
        public uint[] OriginalCpuSetIds { get; set; }
        public uint[] AppliedCpuSetIds { get; set; }
        public bool CpuSetsChanged { get; set; }
        public uint PowerThrottlingVersion { get; set; }
        public uint OriginalPowerControlMask { get; set; }
        public uint OriginalPowerStateMask { get; set; }
        public uint AppliedPowerControlMask { get; set; }
        public uint AppliedPowerStateMask { get; set; }
        public bool PowerThrottlingChanged { get; set; }
        public string Status { get; set; }
    }

    public sealed class RestoreResult
    {
        public int ProcessId { get; set; }
        public string Status { get; set; }
        public string CpuSetsStatus { get; set; }
        public string PowerThrottlingStatus { get; set; }
        public string[] Errors { get; set; }
        public bool Succeeded { get { return Errors.Length == 0; } }
    }

    public sealed class TuningStatus
    {
        public int ProcessId { get; set; }
        public bool ProcessAlive { get; set; }
        public bool SameProcess { get; set; }
        public string CpuSetsStatus { get; set; }
        public string PowerThrottlingStatus { get; set; }
        public uint[] CurrentCpuSetIds { get; set; }
        public uint CurrentPowerControlMask { get; set; }
        public uint CurrentPowerStateMask { get; set; }
    }

    public sealed class TuningApplyException : Exception
    {
        public ProcessTuningState RecoveryState { get; private set; }
        public RestoreResult RollbackResult { get; private set; }
        public TuningApplyException(string message, Exception cause, ProcessTuningState state, RestoreResult rollback)
            : base(message, cause) { RecoveryState = state; RollbackResult = rollback; }
    }

    internal sealed class ProcessHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private ProcessHandle() : base(true) { }
        protected override bool ReleaseHandle() { return NativeMethods.CloseHandle(handle); }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PowerThrottling
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    internal static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern ProcessHandle OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetProcessTimes(ProcessHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetSystemCpuSetInformation(IntPtr information, uint bufferLength, out uint returnedLength, IntPtr process, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetProcessDefaultCpuSets(ProcessHandle process, [Out] uint[] cpuSetIds, uint capacity, out uint requiredCount);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetProcessDefaultCpuSets(ProcessHandle process, [In] uint[] cpuSetIds, uint count);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetProcessInformation(ProcessHandle process, int informationClass, ref PowerThrottling information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetProcessInformation(ProcessHandle process, int informationClass, ref PowerThrottling information, uint size);
    }

    public static class ProcessTuner
    {
        private const uint QueryLimitedInformation = 0x1000;
        private const uint SetLimitedInformation = 0x2000;
        private const uint SetInformation = 0x0200;
        private const int InsufficientBuffer = 122;
        private const uint ExecutionSpeed = 1;
        private const int ProcessPowerThrottling = 4;

        private static Exception Error(string operation)
        {
            int error = Marshal.GetLastWin32Error();
            return new Win32Exception(error, operation + " failed (Win32 " + error + "): " + new Win32Exception(error).Message);
        }

        private static ProcessHandle Open(int processId, uint access)
        {
            if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
            ProcessHandle result = NativeMethods.OpenProcess(access, false, processId);
            if (result.IsInvalid) { Exception error = Error("OpenProcess for PID " + processId); result.Dispose(); throw error; }
            return result;
        }

        private static long Identity(ProcessHandle handle, out bool alive)
        {
            long creation, exit, kernel, user;
            if (!NativeMethods.GetProcessTimes(handle, out creation, out exit, out kernel, out user)) throw Error("GetProcessTimes");
            alive = exit == 0;
            return creation;
        }

        private static void RequireSameProcess(ProcessHandle handle, ProcessTuningState state)
        {
            bool alive;
            long creation = Identity(handle, out alive);
            if (creation != state.CreationFileTime) throw new InvalidOperationException("PID was reused; the original process is no longer running.");
            if (!alive) throw new InvalidOperationException("The target process has exited.");
        }

        private static bool SameSets(uint[] left, uint[] right)
        {
            return left != null && right != null && left.OrderBy(x => x).SequenceEqual(right.OrderBy(x => x));
        }

        private static uint[] ReadCpuSets(ProcessHandle handle)
        {
            uint count;
            bool first = NativeMethods.GetProcessDefaultCpuSets(handle, null, 0, out count);
            if (!first && Marshal.GetLastWin32Error() != InsufficientBuffer) throw Error("GetProcessDefaultCpuSets");
            for (int attempt = 0; attempt < 4; attempt++)
            {
                if (count == 0) return new uint[0];
                if (count > 1048576) throw new InvalidOperationException("Invalid CPU Set count returned by Windows.");
                uint[] values = new uint[count];
                uint actual;
                if (NativeMethods.GetProcessDefaultCpuSets(handle, values, count, out actual))
                {
                    if (actual > count) throw new InvalidOperationException("Invalid CPU Set count returned by Windows.");
                    return values.Take((int)actual).ToArray();
                }
                if (Marshal.GetLastWin32Error() != InsufficientBuffer) throw Error("GetProcessDefaultCpuSets");
                count = actual;
            }
            throw new InvalidOperationException("CPU Sets changed repeatedly during the query. Try again.");
        }

        private static void WriteCpuSets(ProcessHandle handle, uint[] ids)
        {
            if (!NativeMethods.SetProcessDefaultCpuSets(handle, ids.Length == 0 ? null : ids, (uint)ids.Length)) throw Error("SetProcessDefaultCpuSets");
        }

        private static PowerThrottling ReadPower(ProcessHandle handle)
        {
            PowerThrottling value = new PowerThrottling { Version = 1 };
            if (!NativeMethods.GetProcessInformation(handle, ProcessPowerThrottling, ref value, 12)) throw Error("GetProcessInformation (power throttling)");
            return value;
        }

        private static void WritePower(ProcessHandle handle, PowerThrottling value)
        {
            if (!NativeMethods.SetProcessInformation(handle, ProcessPowerThrottling, ref value, 12)) throw Error("SetProcessInformation (power throttling)");
        }

        private static bool SamePower(PowerThrottling value, uint control, uint state)
        {
            return value.ControlMask == control && value.StateMask == state;
        }

        public static CpuTopology AnalyzeTopology(CpuSetInfo[] sets)
        {
            if (sets == null) throw new ArgumentNullException("sets");
            CpuTopology report = new CpuTopology { CpuSets = sets, LogicalProcessorCount = sets.Length, PerformanceCpuSetIds = new uint[0] };
            if (sets.Length == 0) { report.Reason = "Windows reported no CPU Sets."; return report; }
            if (sets.Any(x => x == null) || sets.Select(x => x.Id).Distinct().Count() != sets.Length)
                throw new ArgumentException("CPU topology contains missing or duplicate CPU Sets.");
            byte[] classes = sets.Select(x => x.EfficiencyClass).Distinct().OrderBy(x => x).ToArray();
            if (classes.Length < 2)
            {
                report.Reason = "Windows reports one efficiency class; performance cores cannot be distinguished.";
                return report;
            }
            byte fastest = classes[classes.Length - 1];
            report.PerformanceCpuSetIds = sets.Where(x => x.EfficiencyClass == fastest && (!x.Allocated || x.AllocatedToTargetProcess)).Select(x => x.Id).OrderBy(x => x).ToArray();
            report.PerformanceAvailable = report.PerformanceCpuSetIds.Length > 0;
            report.Reason = report.PerformanceAvailable ? "Highest reported efficiency class selected; CPU Sets are soft scheduling preferences." : "All CPU Sets in the highest efficiency class are reserved for other processes.";
            return report;
        }

        private static CpuTopology ReadTopology(ProcessHandle process)
        {
            IntPtr processPointer = process == null ? IntPtr.Zero : process.DangerousGetHandle();
            uint size;
            bool first = NativeMethods.GetSystemCpuSetInformation(IntPtr.Zero, 0, out size, processPointer, 0);
            if (!first && Marshal.GetLastWin32Error() != InsufficientBuffer) throw Error("GetSystemCpuSetInformation");
            for (int attempt = 0; attempt < 4; attempt++)
            {
                if (size == 0) return AnalyzeTopology(new CpuSetInfo[0]);
                if (size > 64 * 1024 * 1024) throw new InvalidOperationException("Invalid CPU topology buffer size returned by Windows.");
                IntPtr buffer = Marshal.AllocHGlobal((int)size);
                try
                {
                    uint actual;
                    if (!NativeMethods.GetSystemCpuSetInformation(buffer, size, out actual, processPointer, 0))
                    {
                        if (Marshal.GetLastWin32Error() != InsufficientBuffer) throw Error("GetSystemCpuSetInformation");
                        size = actual;
                        continue;
                    }
                    if (actual > size) throw new InvalidOperationException("Invalid CPU topology length returned by Windows.");
                    List<CpuSetInfo> values = new List<CpuSetInfo>();
                    int offset = 0;
                    while (offset < actual)
                    {
                        if (actual - offset < 8) throw new InvalidOperationException("Truncated CPU topology record.");
                        IntPtr entry = IntPtr.Add(buffer, offset);
                        uint entrySize = unchecked((uint)Marshal.ReadInt32(entry, 0));
                        int type = Marshal.ReadInt32(entry, 4);
                        if (entrySize < 8 || entrySize > actual - offset) throw new InvalidOperationException("Invalid CPU topology record size.");
                        if (type == 0)
                        {
                            if (entrySize < 32) throw new InvalidOperationException("Truncated CPU Set record.");
                            byte flags = Marshal.ReadByte(entry, 19);
                            values.Add(new CpuSetInfo {
                                Id = unchecked((uint)Marshal.ReadInt32(entry, 8)),
                                Group = unchecked((ushort)Marshal.ReadInt16(entry, 12)),
                                LogicalProcessorIndex = Marshal.ReadByte(entry, 14),
                                CoreIndex = Marshal.ReadByte(entry, 15),
                                LastLevelCacheIndex = Marshal.ReadByte(entry, 16),
                                EfficiencyClass = Marshal.ReadByte(entry, 18),
                                Parked = (flags & 1) != 0,
                                Allocated = (flags & 2) != 0,
                                AllocatedToTargetProcess = (flags & 4) != 0
                            });
                        }
                        offset += (int)entrySize;
                    }
                    return AnalyzeTopology(values.ToArray());
                }
                finally { Marshal.FreeHGlobal(buffer); GC.KeepAlive(process); }
            }
            throw new InvalidOperationException("CPU topology changed repeatedly during the query. Try again.");
        }

        public static CpuTopology GetTopology(int processId)
        {
            if (processId == 0) return ReadTopology(null);
            using (ProcessHandle handle = Open(processId, QueryLimitedInformation)) { return ReadTopology(handle); }
        }

        // cpuSetIds=null leaves the existing CPU Sets unchanged. An empty array explicitly clears them.
        public static ProcessTuningState Prepare(int processId, uint[] cpuSetIds, bool highQoS, string cpuPolicy)
        {
            using (ProcessHandle handle = Open(processId, QueryLimitedInformation))
            {
                bool alive;
                long creation = Identity(handle, out alive);
                if (!alive) throw new InvalidOperationException("The target process has exited.");
                if (cpuSetIds != null)
                {
                    uint[] available = ReadTopology(handle).CpuSets.Where(x => !x.Allocated || x.AllocatedToTargetProcess).Select(x => x.Id).ToArray();
                    if (cpuSetIds.Distinct().Count() != cpuSetIds.Length || cpuSetIds.Any(x => !available.Contains(x)))
                        throw new ArgumentException("Requested CPU Sets are duplicated or unavailable for the target process.");
                }
                uint[] original = ReadCpuSets(handle);
                uint[] applied = cpuSetIds == null ? (uint[])original.Clone() : (uint[])cpuSetIds.Clone();
                ProcessTuningState state = new ProcessTuningState {
                    SchemaVersion = 1, ProcessId = processId, CreationFileTime = creation, CpuPolicy = cpuPolicy,
                    HighQoSRequested = highQoS, OriginalCpuSetIds = original, AppliedCpuSetIds = applied,
                    CpuSetsChanged = !SameSets(original, applied), PowerThrottlingVersion = 1, Status = "Prepared"
                };
                if (highQoS)
                {
                    PowerThrottling power = ReadPower(handle);
                    state.PowerThrottlingVersion = power.Version;
                    state.OriginalPowerControlMask = power.ControlMask;
                    state.OriginalPowerStateMask = power.StateMask;
                    state.AppliedPowerControlMask = power.ControlMask | ExecutionSpeed;
                    state.AppliedPowerStateMask = power.StateMask & ~ExecutionSpeed;
                    state.PowerThrottlingChanged = !SamePower(power, state.AppliedPowerControlMask, state.AppliedPowerStateMask);
                }
                return state;
            }
        }

        private static void ValidateState(ProcessTuningState state)
        {
            if (state == null || state.SchemaVersion != 1 || state.ProcessId <= 0 || state.CreationFileTime <= 0 ||
                state.CreationFileTime > DateTime.MaxValue.ToFileTimeUtc() ||
                state.OriginalCpuSetIds == null || state.AppliedCpuSetIds == null || state.PowerThrottlingVersion != 1)
                throw new ArgumentException("Invalid or unsupported process tuning snapshot.");
            if (state.OriginalCpuSetIds.Length > 1048576 || state.AppliedCpuSetIds.Length > 1048576 ||
                state.OriginalCpuSetIds.Distinct().Count() != state.OriginalCpuSetIds.Length ||
                state.AppliedCpuSetIds.Distinct().Count() != state.AppliedCpuSetIds.Length)
                throw new ArgumentException("Invalid or duplicated CPU Set IDs in snapshot.");
            if (state.CpuPolicy != "Default" && state.CpuPolicy != "Performance" && state.CpuPolicy != "Custom")
                throw new ArgumentException("Invalid CPU policy in snapshot.");
            if (state.CpuPolicy == "Default" && state.CpuSetsChanged) throw new ArgumentException("Default policy cannot change CPU Sets.");
            if (state.CpuSetsChanged != !SameSets(state.OriginalCpuSetIds, state.AppliedCpuSetIds))
                throw new ArgumentException("CPU Set snapshot does not match its change flag.");
            if (state.HighQoSRequested)
            {
                if (state.AppliedPowerControlMask != (state.OriginalPowerControlMask | ExecutionSpeed) ||
                    state.AppliedPowerStateMask != (state.OriginalPowerStateMask & ~ExecutionSpeed))
                    throw new ArgumentException("HighQoS snapshot has invalid applied settings.");
                bool changed = state.OriginalPowerControlMask != state.AppliedPowerControlMask || state.OriginalPowerStateMask != state.AppliedPowerStateMask;
                if (state.PowerThrottlingChanged != changed) throw new ArgumentException("Power snapshot does not match its change flag.");
            }
            else if (state.PowerThrottlingChanged) throw new ArgumentException("Unrequested power throttling change in snapshot.");
        }

        private static uint WriteAccess(ProcessTuningState state)
        {
            return QueryLimitedInformation | (state.CpuSetsChanged ? SetLimitedInformation : 0) | (state.PowerThrottlingChanged ? SetInformation : 0);
        }

        public static ProcessTuningState Apply(ProcessTuningState state)
        {
            ValidateState(state);
            using (ProcessHandle handle = Open(state.ProcessId, WriteAccess(state)))
            {
                RequireSameProcess(handle, state);
                if (state.CpuSetsChanged && !SameSets(ReadCpuSets(handle), state.OriginalCpuSetIds))
                    throw new InvalidOperationException("CPU Sets changed since the snapshot; no settings were applied.");
                if (state.PowerThrottlingChanged && !SamePower(ReadPower(handle), state.OriginalPowerControlMask, state.OriginalPowerStateMask))
                    throw new InvalidOperationException("Power throttling changed since the snapshot; no settings were applied.");
                // Validate all requested CPU Sets immediately before the first mutation.
                if (state.CpuSetsChanged)
                {
                    uint[] available = ReadTopology(handle).CpuSets.Where(x => !x.Allocated || x.AllocatedToTargetProcess).Select(x => x.Id).ToArray();
                    if (state.AppliedCpuSetIds.Any(x => !available.Contains(x))) throw new InvalidOperationException("A requested CPU Set is no longer available.");
                }
                try
                {
                    if (state.CpuSetsChanged)
                    {
                        WriteCpuSets(handle, state.AppliedCpuSetIds);
                        if (!SameSets(ReadCpuSets(handle), state.AppliedCpuSetIds)) throw new InvalidOperationException("Windows did not retain the requested CPU Sets.");
                    }
                    if (state.PowerThrottlingChanged)
                    {
                        WritePower(handle, new PowerThrottling { Version = state.PowerThrottlingVersion, ControlMask = state.AppliedPowerControlMask, StateMask = state.AppliedPowerStateMask });
                        if (!SamePower(ReadPower(handle), state.AppliedPowerControlMask, state.AppliedPowerStateMask))
                            throw new InvalidOperationException("Windows did not retain the requested HighQoS settings.");
                    }
                    state.Status = state.CpuSetsChanged || state.PowerThrottlingChanged ? "Applied" : "Already configured";
                    return state;
                }
                catch (Exception error)
                {
                    RestoreResult rollback = RestoreWithHandle(handle, state);
                    state.Status = "Apply failed";
                    string details = rollback.Succeeded ? "Changed settings were rolled back or preserved if changed externally." : "Rollback requires attention: " + string.Join("; ", rollback.Errors);
                    throw new TuningApplyException("Process tuning failed: " + error.Message + " " + details, error, state, rollback);
                }
            }
        }

        private static RestoreResult NewRestoreResult(ProcessTuningState state)
        {
            return new RestoreResult { ProcessId = state.ProcessId, CpuSetsStatus = "Unchanged", PowerThrottlingStatus = "Unchanged", Errors = new string[0] };
        }

        private static RestoreResult RestoreWithHandle(ProcessHandle handle, ProcessTuningState state)
        {
            RestoreResult result = NewRestoreResult(state);
            List<string> errors = new List<string>();
            bool alive;
            long creation = Identity(handle, out alive);
            if (creation != state.CreationFileTime || !alive)
            {
                result.Status = creation != state.CreationFileTime ? "Process identity changed" : "Process exited";
                result.CpuSetsStatus = result.PowerThrottlingStatus = "Original process exited";
                state.Status = result.Status;
                return result;
            }
            if (state.PowerThrottlingChanged)
            {
                try
                {
                    PowerThrottling current = ReadPower(handle);
                    if (SamePower(current, state.OriginalPowerControlMask, state.OriginalPowerStateMask)) result.PowerThrottlingStatus = "Already restored";
                    else if (!SamePower(current, state.AppliedPowerControlMask, state.AppliedPowerStateMask)) result.PowerThrottlingStatus = "Preserved external change";
                    else
                    {
                        WritePower(handle, new PowerThrottling { Version = state.PowerThrottlingVersion, ControlMask = state.OriginalPowerControlMask, StateMask = state.OriginalPowerStateMask });
                        if (!SamePower(ReadPower(handle), state.OriginalPowerControlMask, state.OriginalPowerStateMask)) throw new InvalidOperationException("Power throttling restoration could not be verified.");
                        result.PowerThrottlingStatus = "Restored";
                    }
                }
                catch (Exception error) { result.PowerThrottlingStatus = "Restore failed"; errors.Add(error.Message); }
            }
            if (state.CpuSetsChanged)
            {
                try
                {
                    uint[] current = ReadCpuSets(handle);
                    if (SameSets(current, state.OriginalCpuSetIds)) result.CpuSetsStatus = "Already restored";
                    else if (!SameSets(current, state.AppliedCpuSetIds)) result.CpuSetsStatus = "Preserved external change";
                    else
                    {
                        WriteCpuSets(handle, state.OriginalCpuSetIds);
                        if (!SameSets(ReadCpuSets(handle), state.OriginalCpuSetIds)) throw new InvalidOperationException("CPU Set restoration could not be verified.");
                        result.CpuSetsStatus = "Restored";
                    }
                }
                catch (Exception error) { result.CpuSetsStatus = "Restore failed"; errors.Add(error.Message); }
            }
            result.Errors = errors.ToArray();
            result.Status = errors.Count > 0 ? "Restore failed" :
                (result.CpuSetsStatus == "Preserved external change" || result.PowerThrottlingStatus == "Preserved external change" ? "External changes preserved" : "Restored");
            state.Status = result.Status;
            return result;
        }

        public static RestoreResult Restore(ProcessTuningState state)
        {
            ValidateState(state);
            try
            {
                using (ProcessHandle handle = Open(state.ProcessId, WriteAccess(state))) { return RestoreWithHandle(handle, state); }
            }
            catch (Win32Exception error)
            {
                RestoreResult result = NewRestoreResult(state);
                if (error.NativeErrorCode == 87 || error.NativeErrorCode == 1168)
                {
                    result.Status = "Process exited";
                    result.CpuSetsStatus = result.PowerThrottlingStatus = "Original process exited";
                }
                else { result.Status = "Restore failed"; result.Errors = new string[] { error.Message }; }
                state.Status = result.Status;
                return result;
            }
        }

        public static TuningStatus GetStatus(ProcessTuningState state)
        {
            ValidateState(state);
            TuningStatus result = new TuningStatus { ProcessId = state.ProcessId, CurrentCpuSetIds = new uint[0], CpuSetsStatus = "Unchanged", PowerThrottlingStatus = "Unchanged" };
            try
            {
                using (ProcessHandle handle = Open(state.ProcessId, QueryLimitedInformation))
                {
                    bool alive;
                    result.SameProcess = Identity(handle, out alive) == state.CreationFileTime;
                    result.ProcessAlive = alive && result.SameProcess;
                    if (!result.ProcessAlive) return result;
                    result.CurrentCpuSetIds = ReadCpuSets(handle);
                    if (state.CpuSetsChanged) result.CpuSetsStatus = SameSets(result.CurrentCpuSetIds, state.AppliedCpuSetIds) ? "Applied" : SameSets(result.CurrentCpuSetIds, state.OriginalCpuSetIds) ? "Original" : "Changed externally";
                    if (state.HighQoSRequested)
                    {
                        PowerThrottling power = ReadPower(handle);
                        result.CurrentPowerControlMask = power.ControlMask;
                        result.CurrentPowerStateMask = power.StateMask;
                        result.PowerThrottlingStatus = SamePower(power, state.AppliedPowerControlMask, state.AppliedPowerStateMask) ? "Applied" : SamePower(power, state.OriginalPowerControlMask, state.OriginalPowerStateMask) ? "Original" : "Changed externally";
                    }
                    return result;
                }
            }
            catch (Win32Exception error) { if (error.NativeErrorCode == 87 || error.NativeErrorCode == 1168) return result; throw; }
        }
    }
}
