// Copyright (c) ZeroStutter contributors. MIT license; see LICENSE.
// C# 5 / Windows .NET Framework. The desktop is a client of the audited session engine.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("ZeroStutter")]
[assembly: AssemblyProduct("ZeroStutter")]
[assembly: AssemblyDescription("Reversible Windows game sessions and frame-pacing measurements")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Amirtheshwaran and contributors")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]
[assembly: AssemblyInformationalVersion("0.1.0-beta.1")]

namespace ZeroStutter.Desktop
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--self-test") return Helpers.SelfTest();
            bool held = false;
            using (Mutex instance = new Mutex(false, @"Local\ZeroStutter.Desktop.v1"))
            {
                try { held = instance.WaitOne(0); }
                catch (AbandonedMutexException) { held = true; }
                if (!held)
                {
                    MessageBox.Show("ZeroStutter is already open in this Windows session.", "ZeroStutter", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 1;
                }
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new MainWindow());
                    return 0;
                }
                finally { instance.ReleaseMutex(); }
            }
        }
    }

    internal static class Helpers
    {
        internal static string Literal(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0) throw new ArgumentException("Invalid argument.");
            return "'" + value.Replace("'", "''") + "'";
        }

        internal static string EncodedCommand(string script, IList<string> arguments)
        {
            string command = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; try { & " + Literal(script);
            foreach (string argument in arguments) command += " " + argument;
            // EncodedCommand otherwise sends PowerShell information/warning records as CLIXML
            // on stderr. Route records to readable lines and retain real errors as failures.
            command += " *>&1 | ForEach-Object { if ($_ -is [Management.Automation.WarningRecord]) { [Console]::WriteLine('WARNING: ' + $_.Message) } else { [Console]::WriteLine([string]$_) } }; if (-not $?) { exit 1 } } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }";
            return Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        }

        internal static ProcessStartInfo WorkerStartInfo(string script, IList<string> arguments)
        {
            return new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + EncodedCommand(script, arguments),
                WorkingDirectory = Path.GetDirectoryName(script),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
        }

        internal static Process RetainProcess(int id, long creationTime)
        {
            Process process = Process.GetProcessById(id);
            try
            {
                // Keep a handle to the process object across asynchronous worker startup.
                // This prevents its PID from being reused while the worker targets it.
                IntPtr handle = process.Handle;
                if (process.HasExited || process.StartTime.ToUniversalTime().ToFileTimeUtc() != creationTime)
                    throw new InvalidOperationException("The selected process exited or changed. Refresh games and select it again.");
                return process;
            }
            catch { process.Dispose(); throw; }
        }

        internal static bool SameProcess(int id, long creationTime)
        {
            try
            {
                using (Process process = RetainProcess(id, creationTime)) return true;
            }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }

        internal static int SelfTest()
        {
            try
            {
                if (Literal("a'b $() `\"; x") != "'a''b $() `\"; x'") return 2;
                string encoded = EncodedCommand(@"C:\space dir\it's.ps1", new string[] { "-ProcessId", "42" });
                string decoded = Encoding.Unicode.GetString(Convert.FromBase64String(encoded));
                if (!decoded.Contains("& 'C:\\space dir\\it''s.ps1' -ProcessId 42")) return 3;
                using (Process self = Process.GetCurrentProcess())
                {
                    long stamp = self.StartTime.ToUniversalTime().ToFileTimeUtc();
                    if (!SameProcess(self.Id, stamp) || SameProcess(self.Id, stamp + 1)) return 4;
                    using (Process held = RetainProcess(self.Id, stamp)) if (held.Id != self.Id || held.HasExited) return 6;
                }
                try { Literal("bad\0arg"); return 5; } catch (ArgumentException) { }
                return CheckWorkerProtocol();
            }
            catch { return 10; }
        }

        private static int CheckWorkerProtocol()
        {
            string fixture = Path.Combine(Path.GetTempPath(), "ZeroStutter-self-test-'" + Guid.NewGuid().ToString("N") + ".ps1");
            try
            {
                using (FileStream file = new FileStream(fixture, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (StreamWriter writer = new StreamWriter(file, Encoding.UTF8))
                    writer.Write("param([string]$Value, [switch]$Fail)\r\nif ($Fail) { throw 'Expected worker failure' }\r\nWrite-Host ('Ready: ' + $Value)\r\nWrite-Warning 'Protocol warning'\r\n[pscustomobject]@{Status='Restored'} | Format-List | Out-Host\r\n");
                string stdout; string stderr;
                string argument = "a'b $() `\"; x";
                int code = RunProtocolWorker(fixture, new string[] { "-Value", Literal(argument) }, out stdout, out stderr);
                if (code != 0 || !stdout.Contains("Ready: " + argument) || !stdout.Contains("WARNING: Protocol warning") || !stdout.Contains("Restored") || stdout.Contains("CLIXML") || !String.IsNullOrWhiteSpace(stderr)) return 7;
                code = RunProtocolWorker(fixture, new string[] { "-Fail" }, out stdout, out stderr);
                if (code != 1 || !stderr.Contains("Expected worker failure") || stderr.Contains("CLIXML")) return 8;
                return 0;
            }
            finally { if (File.Exists(fixture)) File.Delete(fixture); }
        }

        private static int RunProtocolWorker(string script, IList<string> arguments, out string stdout, out string stderr)
        {
            stdout = ""; stderr = "";
            using (Process worker = new Process { StartInfo = WorkerStartInfo(script, arguments) })
            {
                worker.Start();
                var output = worker.StandardOutput.ReadToEndAsync();
                var errors = worker.StandardError.ReadToEndAsync();
                if (!worker.WaitForExit(5000))
                {
                    worker.Kill(); worker.WaitForExit(1000);
                    return 99;
                }
                stdout = output.GetAwaiter().GetResult(); stderr = errors.GetAwaiter().GetResult();
                return worker.ExitCode;
            }
        }
    }

    internal sealed class Target
    {
        internal int Id;
        internal long Created;
        internal string Name;
        internal string Title;
        internal string Priority;
    }

    internal sealed class MainWindow : Form
    {
        private readonly Color background = Color.FromArgb(12, 19, 33);
        private readonly Color panelColor = Color.FromArgb(21, 32, 50);
        private readonly Color ink = Color.FromArgb(231, 239, 248);
        private readonly Color muted = Color.FromArgb(157, 176, 198);
        private readonly Color accent = Color.FromArgb(61, 217, 210);
        private readonly string appRoot = AppDomain.CurrentDomain.BaseDirectory;
        private readonly string dataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZeroStutter", "DesktopSessions");
        private readonly ListView games = new ListView();
        private readonly TextBox filter = new TextBox();
        private readonly CheckBox showBackground = new CheckBox();
        private readonly Button refresh = new Button();
        private readonly Label targetDetails = new Label();
        private readonly ComboBox priority = new ComboBox();
        private readonly ComboBox cpuPolicy = new ComboBox();
        private readonly CheckBox highQoS = new CheckBox();
        private readonly CheckBox unpark = new CheckBox();
        private readonly Button start = new Button();
        private readonly Button stop = new Button();
        private readonly Button recover = new Button();
        private readonly Label status = new Label();
        private readonly Label activity = new Label();
        private readonly TextBox log = new TextBox();
        private readonly TextBox presentMon = new TextBox();
        private readonly TextBox outputDirectory = new TextBox();
        private readonly NumericUpDown seconds = new NumericUpDown();
        private readonly NumericUpDown delay = new NumericUpDown();
        private readonly ComboBox metric = new ComboBox();
        private readonly TextBox streamPid = new TextBox();
        private readonly TextBox streamAddress = new TextBox();
        private readonly Button capture = new Button();
        private readonly Button analyze = new Button();
        private readonly Button compare = new Button();
        private readonly Button browsePresentMon = new Button();
        private readonly Button browseOutput = new Button();
        private readonly System.Windows.Forms.Timer progress = new System.Windows.Forms.Timer();
        private List<Target> available = new List<Target>();
        private Process session;
        private Process operation;
        private Process sessionTarget;
        private Process captureTarget;
        private string stopSignal;
        private string sessionReport;
        private bool sessionActive;
        private bool stopping;
        private bool closeRequested;
        private bool closeAllowed;
        private bool refreshing;
        private DateTime operationStarted;
        private string operationName;
        private int captureDuration;
        private int captureDelay;
        private bool capturing;

        internal MainWindow()
        {
            Text = "ZeroStutter | Game sessions & frame pacing";
            Icon = SystemIcons.Application;
            MinimumSize = new Size(900, 680);
            Size = new Size(1120, 850);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10F);
            BackColor = background;
            ForeColor = ink;
            AutoScaleMode = AutoScaleMode.Dpi;
            BuildLayout();
            progress.Interval = 500;
            progress.Tick += delegate { UpdateProgress(); };
            progress.Start();
            Shown += delegate { Append("Ready. Start your game, select its process, then start a reversible session."); RefreshGames(); CheckBackend(); };
            FormClosing += OnClosing;
            FormClosed += delegate { progress.Stop(); progress.Dispose(); };
        }

        private Label LabelOf(string text, float size, Color color)
        {
            return new Label { Text = text, UseMnemonic = false, ForeColor = color, Font = new Font("Segoe UI", size), AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(0, 2, 6, 2) };
        }

        private void StyleButton(Button button, string text, bool primaryButton)
        {
            button.Text = text;
            button.UseMnemonic = false;
            button.AutoSize = true;
            button.MinimumSize = new Size(115, 35);
            button.Padding = new Padding(9, 2, 9, 2);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = primaryButton ? accent : Color.FromArgb(61, 82, 107);
            button.BackColor = primaryButton ? accent : panelColor;
            button.ForeColor = primaryButton ? background : ink;
            button.Cursor = Cursors.Hand;
            button.Margin = new Padding(0, 4, 10, 4);
        }

        private void StyleText(TextBox text)
        {
            text.BackColor = panelColor;
            text.ForeColor = ink;
            text.BorderStyle = BorderStyle.FixedSingle;
            text.Dock = DockStyle.Fill;
            text.Margin = new Padding(0, 7, 10, 5);
        }

        private void StyleChoice(ComboBox choice, string[] values)
        {
            choice.DropDownStyle = ComboBoxStyle.DropDownList;
            choice.Items.AddRange(values);
            choice.SelectedIndex = 0;
            choice.BackColor = panelColor;
            choice.ForeColor = ink;
            choice.FlatStyle = FlatStyle.Flat;
            choice.Width = 165;
        }

        private void BuildLayout()
        {
            TableLayoutPanel root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22, 14, 22, 12), ColumnCount = 1, RowCount = 5 };
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 70));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 165));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
            Controls.Add(root);
            TableLayoutPanel heading = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2 };
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
            heading.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
            heading.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            heading.Controls.Add(LabelOf("ZeroStutter", 23, ink), 0, 0);
            heading.Controls.Add(LabelOf("Reversible game sessions. Measure what changes.", 10, muted), 0, 1);
            LinkLabel help = new LinkLabel { Text = "Source & docs", UseMnemonic = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight, LinkColor = accent, ActiveLinkColor = ink };
            help.LinkClicked += delegate { OpenLink("https://github.com/Amirtheshwaran/ZeroStutter"); };
            heading.Controls.Add(help, 1, 0);
            root.Controls.Add(heading, 0, 0);
            status.Text = "IDLE  |  Select a running game";
            status.Dock = DockStyle.Fill;
            status.Padding = new Padding(12, 0, 0, 0);
            status.TextAlign = ContentAlignment.MiddleLeft;
            status.BackColor = panelColor;
            status.ForeColor = accent;
            root.Controls.Add(status, 0, 1);
            TabControl tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 7), Margin = new Padding(0, 12, 0, 8), DrawMode = TabDrawMode.OwnerDrawFixed };
            tabs.DrawItem += delegate(object sender, DrawItemEventArgs e)
            {
                bool selected = e.Index == tabs.SelectedIndex;
                using (SolidBrush fill = new SolidBrush(selected ? panelColor : background)) e.Graphics.FillRectangle(fill, e.Bounds);
                TextRenderer.DrawText(e.Graphics, tabs.TabPages[e.Index].Text, Font, e.Bounds, selected ? accent : muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            };
            TabPage sessions = new TabPage("Game session") { BackColor = background, Padding = new Padding(10) };
            TabPage measurements = new TabPage("Measure & compare") { BackColor = background, Padding = new Padding(10), AutoScroll = true };
            tabs.TabPages.Add(sessions); tabs.TabPages.Add(measurements);
            BuildSession(sessions); BuildMeasurement(measurements);
            root.Controls.Add(tabs, 0, 2);
            TableLayoutPanel logs = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = new Padding(0) };
            logs.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            logs.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            activity.Text = "Activity"; activity.Dock = DockStyle.Fill; activity.ForeColor = muted;
            logs.Controls.Add(activity, 0, 0);
            log.Multiline = true; log.ReadOnly = true; log.WordWrap = false; log.ScrollBars = ScrollBars.Both;
            log.Font = new Font("Consolas", 9F); StyleText(log); log.Margin = new Padding(0);
            logs.Controls.Add(log, 0, 1); root.Controls.Add(logs, 0, 3);
            root.Controls.Add(LabelOf("Experimental • Effects vary by game and PC. No guaranteed FPS gain or stutter fix.", 9, muted), 0, 4);
            UpdateControls();
        }

        private void BuildSession(TabPage page)
        {
            // Preserve a usable process picker on small screens instead of shrinking it to zero.
            page.AutoScroll = true;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Top, Height = 380, ColumnCount = 1, RowCount = 6 };
            page.Resize += delegate { layout.Height = Math.Max(380, page.ClientSize.Height - page.Padding.Vertical); };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 108));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            TableLayoutPanel picker = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 1 };
            picker.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
            picker.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            picker.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 210));
            picker.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
            StyleText(filter); filter.AccessibleName = "Filter running games by process or window title";
            filter.TextChanged += delegate { PopulateGames(); };
            picker.Controls.Add(LabelOf("Find a game", 9, muted), 0, 0);
            picker.Controls.Add(filter, 1, 0);
            showBackground.Text = "Include background apps"; showBackground.AutoSize = true; showBackground.Margin = new Padding(0, 9, 5, 0);
            showBackground.CheckedChanged += delegate { RefreshGames(); };
            picker.Controls.Add(showBackground, 2, 0);
            StyleButton(refresh, "Refresh games", false); refresh.Click += delegate { RefreshGames(); };
            picker.Controls.Add(refresh, 3, 0); layout.Controls.Add(picker, 0, 0);
            games.Dock = DockStyle.Fill; games.View = View.Details; games.FullRowSelect = true; games.MultiSelect = false;
            games.HideSelection = false; games.BackColor = panelColor; games.ForeColor = ink; games.BorderStyle = BorderStyle.FixedSingle;
            games.Columns.Add("Running process", 220); games.Columns.Add("PID", 85); games.Columns.Add("Window", 590);
            games.SelectedIndexChanged += delegate { UpdateSelection(); };
            games.Resize += delegate { if (games.Columns.Count == 3) games.Columns[2].Width = Math.Max(160, games.ClientSize.Width - 310); };
            layout.Controls.Add(games, 0, 1);
            targetDetails.Text = "Select the game executable, not its launcher. Use the filter above to find it.";
            targetDetails.Dock = DockStyle.Fill; targetDetails.ForeColor = muted; targetDetails.TextAlign = ContentAlignment.MiddleLeft;
            layout.Controls.Add(targetDetails, 0, 2);
            TableLayoutPanel options = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 3 };
            for (int i = 0; i < 4; ++i) options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25));
            options.RowStyles.Add(new RowStyle(SizeType.Absolute, 25)); options.RowStyles.Add(new RowStyle(SizeType.Absolute, 35)); options.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            options.Controls.Add(LabelOf("Process priority", 9, muted), 0, 0);
            options.Controls.Add(LabelOf("CPU placement", 9, muted), 1, 0);
            options.Controls.Add(LabelOf("Power preference", 9, muted), 2, 0);
            options.Controls.Add(LabelOf("Optional system setting", 9, muted), 3, 0);
            StyleChoice(priority, new string[] { "AboveNormal", "Observe" }); priority.Dock = DockStyle.Fill;
            StyleChoice(cpuPolicy, new string[] { "Default", "Performance" }); cpuPolicy.Dock = DockStyle.Fill;
            highQoS.Text = "Request High QoS"; highQoS.Checked = true; highQoS.AutoSize = true;
            unpark.Text = "Unpark cores (AC)"; unpark.AutoSize = true;
            options.Controls.Add(priority, 0, 1); options.Controls.Add(cpuPolicy, 1, 1); options.Controls.Add(highQoS, 2, 1); options.Controls.Add(unpark, 3, 1);
            options.Controls.Add(LabelOf("Observe leaves priority alone.", 8.5F, muted), 0, 2);
            options.Controls.Add(LabelOf("Performance needs distinct CPU classes.", 8.5F, muted), 1, 2);
            options.Controls.Add(LabelOf("Requests full execution speed.", 8.5F, muted), 2, 2);
            options.Controls.Add(LabelOf("Temporary power plan; may use more power.", 8.5F, muted), 3, 2);
            layout.Controls.Add(options, 0, 3);
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            StyleButton(start, "Start session", true); start.Click += delegate { StartSession(); };
            StyleButton(stop, "Stop & restore", false); stop.Click += delegate { RequestStop(); };
            StyleButton(recover, "Recover previous session", false); recover.Click += delegate { Recover(); };
            buttons.Controls.Add(start); buttons.Controls.Add(stop); buttons.Controls.Add(recover); layout.Controls.Add(buttons, 0, 4);
            layout.Controls.Add(LabelOf("For an untuned baseline, leave the session stopped. A session restores its changes when stopped or when the game exits.", 9, muted), 0, 5);
            page.Controls.Add(layout);
        }

        private void BuildMeasurement(TabPage page)
        {
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3, RowCount = 9 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140));
            for (int i = 0; i < 9; ++i) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, i == 0 || i == 8 ? 52 : 42));
            Label introduction = LabelOf("Capture the selected game during regular play, then compare repeated runs of the same route. Keep graphics, frame generation and background work identical.", 10, muted);
            layout.Controls.Add(introduction, 0, 0); layout.SetColumnSpan(introduction, 3);
            StyleText(presentMon); presentMon.AccessibleName = "Path to PresentMon console executable";
            StyleButton(browsePresentMon, "Browse .exe", false);
            browsePresentMon.Click += delegate { using (OpenFileDialog dialog = new OpenFileDialog { Filter = "PresentMon executable (*.exe)|*.exe", Title = "Choose the PresentMon console executable" }) if (dialog.ShowDialog(this) == DialogResult.OK) presentMon.Text = dialog.FileName; };
            layout.Controls.Add(LabelOf("PresentMon", 10, ink), 0, 1); layout.Controls.Add(presentMon, 1, 1); layout.Controls.Add(browsePresentMon, 2, 1);
            StyleText(outputDirectory); outputDirectory.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "ZeroStutter Captures");
            StyleButton(browseOutput, "Output folder", false);
            browseOutput.Click += delegate { using (FolderBrowserDialog dialog = new FolderBrowserDialog { Description = "Choose the folder for frame captures" }) if (dialog.ShowDialog(this) == DialogResult.OK) outputDirectory.Text = dialog.SelectedPath; };
            layout.Controls.Add(LabelOf("Save captures to", 10, ink), 0, 2); layout.Controls.Add(outputDirectory, 1, 2); layout.Controls.Add(browseOutput, 2, 2);
            FlowLayoutPanel timing = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            seconds.Minimum = 5; seconds.Maximum = 300; seconds.Value = 60; seconds.Width = 75;
            delay.Minimum = 5; delay.Maximum = 60; delay.Value = 10; delay.Width = 65;
            timing.Controls.Add(seconds); timing.Controls.Add(new Label { Text = "seconds    Start delay", AutoSize = true, Padding = new Padding(4, 4, 4, 0) }); timing.Controls.Add(delay); timing.Controls.Add(new Label { Text = "seconds", AutoSize = true, Padding = new Padding(4, 4, 0, 0) });
            layout.Controls.Add(LabelOf("Capture duration", 10, ink), 0, 3); layout.Controls.Add(timing, 1, 3);
            StyleButton(capture, "Arm capture", true); capture.Click += delegate { StartCapture(); }; layout.Controls.Add(capture, 2, 3);
            StyleChoice(metric, new string[] { "PresentToPresent", "Displayed" }); metric.Dock = DockStyle.Fill;
            layout.Controls.Add(LabelOf("Analysis metric", 10, ink), 0, 4); layout.Controls.Add(metric, 1, 4);
            LinkLabel download = new LinkLabel { Text = "Get PresentMon", LinkColor = accent, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
            download.LinkClicked += delegate { OpenLink("https://github.com/GameTechDev/PresentMon/releases"); }; layout.Controls.Add(download, 2, 4);
            FlowLayoutPanel streams = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            streamPid.Width = 95; streamPid.BackColor = panelColor; streamPid.ForeColor = ink; streamPid.AccessibleName = "Optional process ID for analysis";
            streamAddress.Width = 160; streamAddress.BackColor = panelColor; streamAddress.ForeColor = ink; streamAddress.AccessibleName = "Optional swap chain for analysis";
            streams.Controls.Add(new Label { Text = "PID", AutoSize = true, Padding = new Padding(0, 4, 4, 0) }); streams.Controls.Add(streamPid);
            streams.Controls.Add(new Label { Text = "Swap chain", AutoSize = true, Padding = new Padding(8, 4, 4, 0) }); streams.Controls.Add(streamAddress);
            layout.Controls.Add(LabelOf("Optional stream filter", 9, ink), 0, 5); layout.Controls.Add(streams, 1, 5); layout.SetColumnSpan(streams, 2);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            StyleButton(analyze, "Analyze a CSV", false); analyze.Click += delegate { Analyze(false); };
            StyleButton(compare, "Compare two CSVs", false); compare.Click += delegate { Analyze(true); };
            Button folder = new Button(); StyleButton(folder, "Open captures", false); folder.Click += delegate { OpenFolder(outputDirectory.Text); };
            actions.Controls.Add(analyze); actions.Controls.Add(compare); actions.Controls.Add(folder);
            layout.Controls.Add(actions, 0, 6); layout.SetColumnSpan(actions, 3);
            Label definitions = LabelOf("PresentToPresent measures game submission intervals. Displayed measures visible frame durations. Lower p99/p99.9 means fewer long intervals; one faster run does not prove a benefit.", 9, muted);
            layout.Controls.Add(definitions, 0, 7); layout.SetColumnSpan(definitions, 3);
            Label captureNote = LabelOf("Return to the game during the start delay. Menus, loading, Alt-Tab and captures of different routes make comparisons unreliable. Optional filters apply to both comparison files. PresentMon runs only from the executable you select.", 9, muted);
            layout.Controls.Add(captureNote, 0, 8); layout.SetColumnSpan(captureNote, 3); page.Controls.Add(layout);
        }

        private void Ui(Action action)
        {
            if (IsDisposed || Disposing || !IsHandleCreated) return;
            try { BeginInvoke((MethodInvoker)delegate { if (!IsDisposed) action(); }); }
            catch (InvalidOperationException) { }
        }

        private void Append(string message)
        {
            if (String.IsNullOrEmpty(message)) return;
            if (log.TextLength > 160000) log.Text = log.Text.Substring(log.TextLength - 100000);
            log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "] " + message + Environment.NewLine);
        }

        private bool CheckBackend()
        {
            string[] required = { "Start-ZeroStutterSession.ps1", "Restore-ZeroStutterSession.ps1", "Measure-ZeroStutter.ps1", @"src\ZeroStutter.Core.psm1", @"src\ZeroStutter.Tuning.psm1", @"src\ZeroStutter.Recovery.psm1", @"src\ZeroStutter.Power.psm1", @"src\ZeroStutter.Measurement.psm1", @"src\ZeroStutter.Native.cs" };
            foreach (string file in required)
                if (!File.Exists(Path.Combine(appRoot, file)))
                {
                    Append("Missing backend file: " + file + ". Extract the complete ZeroStutter package and run ZeroStutter.exe from that folder.");
                    status.Text = "PACKAGE INCOMPLETE  |  Extract the complete download";
                    return false;
                }
            return true;
        }

        private Target SelectedTarget()
        {
            return games.SelectedItems.Count == 1 ? (Target)games.SelectedItems[0].Tag : null;
        }

        private void RefreshGames()
        {
            if (refreshing || session != null || operation != null) return;
            refreshing = true; UpdateControls();
            bool includeBackground = showBackground.Checked;
            ThreadPool.QueueUserWorkItem(delegate
            {
                List<Target> found = new List<Target>();
                try
                {
                    int myId; int mySession;
                    using (Process self = Process.GetCurrentProcess()) { myId = self.Id; mySession = self.SessionId; }
                    foreach (Process process in Process.GetProcesses())
                    {
                        using (process)
                        {
                            try
                            {
                                if (process.Id == myId || process.SessionId != mySession || process.SessionId == 0) continue;
                                string title = process.MainWindowTitle;
                                if (!includeBackground && String.IsNullOrWhiteSpace(title)) continue;
                                found.Add(new Target { Id = process.Id, Created = process.StartTime.ToUniversalTime().ToFileTimeUtc(), Name = process.ProcessName + ".exe", Title = title, Priority = process.PriorityClass.ToString() });
                            }
                            catch (InvalidOperationException) { }
                            catch (System.ComponentModel.Win32Exception) { }
                        }
                    }
                    found = found.OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ToList();
                    Ui(delegate { available = found; refreshing = false; PopulateGames(); UpdateControls(); });
                }
                catch (Exception error) { Ui(delegate { refreshing = false; Append("Could not refresh applications: " + error.Message); UpdateControls(); }); }
            });
        }

        private void PopulateGames()
        {
            Target previous = SelectedTarget();
            string query = filter.Text.Trim();
            games.BeginUpdate(); games.Items.Clear();
            foreach (Target target in available)
            {
                if (query.Length > 0 && target.Name.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0 && target.Title.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
                ListViewItem item = new ListViewItem(new string[] { target.Name, target.Id.ToString(CultureInfo.InvariantCulture), target.Title }); item.Tag = target;
                games.Items.Add(item);
                if (previous != null && target.Id == previous.Id && target.Created == previous.Created) item.Selected = true;
            }
            games.EndUpdate(); UpdateSelection();
        }

        private void UpdateSelection()
        {
            Target selected = SelectedTarget();
            targetDetails.Text = selected == null ? "Select the game executable, not its launcher. Type in the filter above to find it." : selected.Name + "  •  PID " + selected.Id + "  •  Priority at refresh: " + selected.Priority;
            UpdateControls();
        }

        private void UpdateControls()
        {
            bool idle = session == null && operation == null && !closeRequested;
            bool target = SelectedTarget() != null;
            games.Enabled = idle; filter.Enabled = idle; showBackground.Enabled = idle; refresh.Enabled = idle && !refreshing;
            priority.Enabled = idle; cpuPolicy.Enabled = idle; highQoS.Enabled = idle; unpark.Enabled = idle;
            start.Enabled = idle && target && !refreshing;
            stop.Enabled = session != null && !stopping && !closeRequested;
            recover.Enabled = idle && !refreshing;
            bool canMeasure = operation == null && !stopping && !closeRequested && (session == null || sessionActive);
            capture.Enabled = canMeasure && target;
            analyze.Enabled = canMeasure; compare.Enabled = canMeasure;
            presentMon.Enabled = canMeasure; outputDirectory.Enabled = canMeasure; browsePresentMon.Enabled = canMeasure; browseOutput.Enabled = canMeasure;
            seconds.Enabled = canMeasure; delay.Enabled = canMeasure; metric.Enabled = canMeasure; streamPid.Enabled = canMeasure; streamAddress.Enabled = canMeasure;
        }

        private string NewRunDirectory()
        {
            string path = Path.Combine(dataRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            return path;
        }

        private Process Launch(string scriptName, IList<string> arguments, Action<string> output, Action<int> finished)
        {
            Process process = new Process();
            process.StartInfo = Helpers.WorkerStartInfo(Path.Combine(appRoot, scriptName), arguments);
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Ui(delegate { output(e.Data); }); };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Ui(delegate { output("Error: " + e.Data); }); };
            try { process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); }
            catch { process.Dispose(); throw; }
            ThreadPool.QueueUserWorkItem(delegate
            {
                int code = -1;
                try { process.WaitForExit(); code = process.ExitCode; }
                catch (Exception error) { Ui(delegate { Append("Could not read worker result: " + error.Message); }); }
                int finalCode = code;
                Ui(delegate { finished(finalCode); process.Dispose(); });
            });
            return process;
        }

        private void StartSession()
        {
            Target target = SelectedTarget();
            if (target == null || session != null || operation != null || !CheckBackend()) return;
            if (!Helpers.SameProcess(target.Id, target.Created)) { Append("The selected process exited or changed. Refresh games and select it again."); RefreshGames(); return; }
            try
            {
                sessionTarget = Helpers.RetainProcess(target.Id, target.Created);
                string run = NewRunDirectory(); stopSignal = Path.Combine(run, "stop.signal"); sessionReport = Path.Combine(run, "session.json");
                int ownerId; long ownerCreated;
                using (Process self = Process.GetCurrentProcess()) { ownerId = self.Id; ownerCreated = self.StartTime.ToUniversalTime().ToFileTimeUtc(); }
                List<string> arguments = new List<string> { "-ProcessId", target.Id.ToString(CultureInfo.InvariantCulture), "-Priority", Helpers.Literal(priority.SelectedItem.ToString()), "-CpuPolicy", Helpers.Literal(cpuPolicy.SelectedItem.ToString()), "-Headless", "-StopSignalPath", Helpers.Literal(stopSignal), "-OwnerProcessId", ownerId.ToString(CultureInfo.InvariantCulture), "-OwnerCreationFileTime", ownerCreated.ToString(CultureInfo.InvariantCulture), "-ReportPath", Helpers.Literal(sessionReport) };
                if (!highQoS.Checked) arguments.Add("-DisableHighQoS");
                if (unpark.Checked) arguments.Add("-UnparkCores");
                sessionActive = false; stopping = false;
                Append("Starting session for " + target.Name + " (PID " + target.Id + "). Waiting for the engine to confirm setup.");
                session = Launch("Start-ZeroStutterSession.ps1", arguments, delegate(string line)
                {
                    Append(line);
                    if (line.StartsWith("ZeroStutter session:", StringComparison.Ordinal))
                    {
                        sessionActive = true;
                        if (!stopping) status.Text = "ACTIVE  |  " + target.Name + "  •  Changes will be restored when stopped";
                        UpdateControls();
                    }
                }, SessionFinished);
                status.Text = "STARTING  |  Preparing recovery and applying the selected settings"; UpdateControls();
            }
            catch (Exception error) { session = null; ReleaseSessionTarget(); Append("Session could not start: " + error.Message); status.Text = "SESSION ERROR  |  See activity below"; UpdateControls(); }
        }

        private void RequestStop()
        {
            if (session == null || stopping) return;
            try
            {
                File.WriteAllText(stopSignal, "Stop requested by ZeroStutter desktop.", Encoding.UTF8);
                stopping = true; status.Text = "RESTORING  |  Waiting for the session engine to restore settings";
                if (capturing) Append("WARNING: Stop was requested during capture. This recording mixes tuning states and should not be used for a baseline/session comparison.");
                Append("Stop requested. The engine will restore its owned changes before exiting."); UpdateControls();
            }
            catch (Exception error)
            {
                closeRequested = false;
                Append("Could not signal the session to stop: " + error.Message + ". The session remains running.");
                MessageBox.Show(this, "Could not write the stop request. The session is still running. See Activity for details.", "ZeroStutter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                UpdateControls();
            }
        }

        private void SessionFinished(int code)
        {
            session = null; sessionActive = false; stopping = false;
            ReleaseSessionTarget();
            if (capturing) Append("WARNING: The tuning session ended during capture. Do not use this as a consistently tuned run; repeat it with a session active for the entire capture.");
            Append("Session report: " + sessionReport);
            if (code == 0) { status.Text = "IDLE  |  Session ended; restoration completed"; Append("Session ended successfully. See restore messages for any externally changed settings preserved by the engine."); }
            else
            {
                status.Text = "SESSION ERROR  |  Review activity; recover previous session if restoration failed";
                Append("Session worker exited with code " + code + ". Do not assume restoration succeeded; review the log and use Recover previous session.");
                closeRequested = false;
            }
            UpdateControls(); MaybeClose();
        }

        private void ReleaseSessionTarget()
        {
            if (sessionTarget == null) return;
            sessionTarget.Dispose(); sessionTarget = null;
        }

        private void ReleaseCaptureTarget()
        {
            if (captureTarget == null) return;
            captureTarget.Dispose(); captureTarget = null;
        }

        private void Recover()
        {
            if (session != null || operation != null || !CheckBackend()) return;
            StartOperation("Recovery", "Restore-ZeroStutterSession.ps1", new List<string>(), null);
        }

        private void StartCapture()
        {
            Target target = SelectedTarget();
            if (target == null || operation != null || !CheckBackend()) return;
            if (!Helpers.SameProcess(target.Id, target.Created)) { Append("The selected game exited or changed. Refresh and select it again."); return; }
            try
            {
                string tool = Path.GetFullPath(presentMon.Text.Trim());
                if (!File.Exists(tool) || !String.Equals(Path.GetExtension(tool), ".exe", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Choose the local PresentMon console .exe first.");
                string directory = Path.GetFullPath(outputDirectory.Text.Trim()); Directory.CreateDirectory(directory);
                captureTarget = Helpers.RetainProcess(target.Id, target.Created);
                string filename = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + (sessionActive ? "session" : "baseline") + "-" + target.Id + "-" + Guid.NewGuid().ToString("N").Substring(0, 6) + ".csv";
                string destination = Path.Combine(directory, filename);
                List<string> arguments = new List<string> { "-Capture", "-PresentMonPath", Helpers.Literal(tool), "-ProcessId", target.Id.ToString(CultureInfo.InvariantCulture), "-OutputPath", Helpers.Literal(destination), "-Seconds", seconds.Value.ToString(CultureInfo.InvariantCulture), "-DelaySeconds", delay.Value.ToString(CultureInfo.InvariantCulture) };
                captureDuration = (int)seconds.Value; captureDelay = (int)delay.Value; capturing = true;
                Append("Capture armed for " + target.Name + ". Return to the game now. Session state: " + (sessionActive ? "active" : "untuned") + ".");
                StartOperation("Capture", "Measure-ZeroStutter.ps1", arguments, delegate(int code)
                {
                    if (code == 0) Append("Capture saved: " + destination + ". Analyze this CSV, then repeat the same route with the other session state.");
                });
            }
            catch (Exception error) { capturing = false; ReleaseCaptureTarget(); Append("Capture could not start: " + error.Message); UpdateControls(); }
        }

        private string PickCsv(string title)
        {
            using (OpenFileDialog dialog = new OpenFileDialog { Title = title, Filter = "Frame capture (*.csv)|*.csv", CheckFileExists = true })
            {
                if (Directory.Exists(outputDirectory.Text)) dialog.InitialDirectory = outputDirectory.Text;
                return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null;
            }
        }

        private void Analyze(bool comparison)
        {
            if (operation != null || !CheckBackend()) return;
            string first = PickCsv(comparison ? "Choose BASELINE capture (session stopped)" : "Choose a frame capture");
            if (first == null) return;
            string second = comparison ? PickCsv("Choose CANDIDATE capture (session active)") : null;
            if (comparison && second == null) return;
            try
            {
                List<string> arguments = new List<string>();
                if (comparison) { arguments.Add("-BaselinePath"); arguments.Add(Helpers.Literal(first)); arguments.Add("-CandidatePath"); arguments.Add(Helpers.Literal(second)); }
                else { arguments.Add("-CsvPath"); arguments.Add(Helpers.Literal(first)); }
                if (!String.IsNullOrWhiteSpace(streamPid.Text))
                {
                    int id;
                    if (!Int32.TryParse(streamPid.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out id) || id < 1) throw new ArgumentException("Optional analysis PID must be a positive integer, or blank for automatic stream selection.");
                    arguments.Add(comparison ? "-BaselineProcessId" : "-ProcessId"); arguments.Add(id.ToString(CultureInfo.InvariantCulture));
                    if (comparison) { arguments.Add("-CandidateProcessId"); arguments.Add(id.ToString(CultureInfo.InvariantCulture)); }
                }
                if (!String.IsNullOrWhiteSpace(streamAddress.Text))
                {
                    arguments.Add(comparison ? "-BaselineSwapChain" : "-SwapChainAddress"); arguments.Add(Helpers.Literal(streamAddress.Text.Trim()));
                    if (comparison) { arguments.Add("-CandidateSwapChain"); arguments.Add(Helpers.Literal(streamAddress.Text.Trim())); }
                }
                string report = Path.Combine(NewRunDirectory(), comparison ? "comparison.json" : "analysis.json");
                arguments.Add("-Metric"); arguments.Add(Helpers.Literal(metric.SelectedItem.ToString())); arguments.Add("-JsonPath"); arguments.Add(Helpers.Literal(report));
                StartOperation(comparison ? "Comparison" : "Analysis", "Measure-ZeroStutter.ps1", arguments, delegate(int code) { if (code == 0) ShowReport(report, comparison); });
            }
            catch (Exception error) { Append("Could not analyze capture: " + error.Message); }
        }

        private void ShowReport(string path, bool comparison)
        {
            Append("Full JSON report: " + path);
            try
            {
                Dictionary<string, object> report = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                object warnings;
                if (report.TryGetValue("Warnings", out warnings))
                {
                    System.Collections.IEnumerable items = warnings as System.Collections.IEnumerable;
                    if (items != null && !(warnings is string))
                        foreach (object warning in items) Append("WARNING: " + Convert.ToString(warning, CultureInfo.InvariantCulture));
                }
                if (comparison)
                {
                    Dictionary<string, object> changes = report["Changes"] as Dictionary<string, object>;
                    foreach (string name in new string[] { "MeanMs", "P99Ms", "P999Ms", "MaximumMs", "SlowFramePercent" })
                    {
                        Dictionary<string, object> change = changes[name] as Dictionary<string, object>;
                        string suffix = name == "SlowFramePercent" ? "% of intervals" : "ms";
                        Append(String.Format(CultureInfo.InvariantCulture, "{0}: baseline {1:0.000} → session {2:0.000} {3}", name, change["Baseline"], change["Candidate"], suffix));
                    }
                    Append("Comparison complete. Lower interval values are better; repeat matched runs before attributing a benefit to ZeroStutter."); return;
                }
                Append(String.Format(CultureInfo.InvariantCulture, "Summary: {0} intervals | mean {1:0.000} ms | p99 {2:0.000} ms | p99.9 {3:0.000} ms | slow intervals {4:0.00}%", report["FrameCount"], report["MeanMs"], report["P99Ms"], report["P999Ms"], report["SlowFramePercent"]));
            }
            catch (Exception error) { Append("See the detailed report above. Could not display summary: " + error.Message); }
        }

        private void StartOperation(string name, string script, IList<string> arguments, Action<int> after)
        {
            try
            {
                operationName = name; operationStarted = DateTime.UtcNow;
                operation = Launch(script, arguments, Append, delegate(int code)
                {
                    operation = null; capturing = false; ReleaseCaptureTarget();
                    Append(name + (code == 0 ? " completed." : " failed (exit " + code + "). Review the details above."));
                    if (after != null) after(code);
                    if (name == "Recovery") status.Text = code == 0 ? "IDLE  |  Recovery completed" : "RECOVERY ERROR  |  Review activity below";
                    if (name == "Recovery" && code != 0) closeRequested = false;
                    if (closeRequested && session != null) RequestStop();
                    UpdateControls(); MaybeClose();
                });
                UpdateControls();
            }
            catch (Exception error) { operation = null; capturing = false; ReleaseCaptureTarget(); Append(name + " could not start: " + error.Message); UpdateControls(); }
        }

        private void UpdateProgress()
        {
            if (operation != null)
            {
                int elapsed = (int)(DateTime.UtcNow - operationStarted).TotalSeconds;
                if (capturing)
                {
                    // Engine startup adds a small amount of time; these are guidance, not capture timestamps.
                    activity.Text = elapsed < captureDelay ? "Capture armed • return to your game • delay approximately " + (captureDelay - elapsed) + "s" : "Capture in progress • " + Math.Max(0, captureDelay + captureDuration - elapsed) + "s approximately remaining; then validating data";
                }
                else activity.Text = operationName + " in progress • " + elapsed + "s";
            }
            else activity.Text = closeRequested ? "Closing after restoration completes…" : "Activity";
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (closeAllowed || (session == null && operation == null)) return;
            e.Cancel = true; closeRequested = true;
            if (operation != null)
            {
                status.Text = "CLOSING  |  Waiting for the current capture or analysis, then restoring settings";
                Append("Close requested. Waiting for the current operation to finish safely before restoring and closing.");
            }
            else RequestStop();
            UpdateControls();
        }

        private void MaybeClose()
        {
            if (!closeRequested || session != null || operation != null) return;
            closeAllowed = true; Close();
        }

        private void OpenLink(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception error) { Append("Could not open documentation: " + error.Message); }
        }

        private void OpenFolder(string path)
        {
            try
            {
                string resolved = Path.GetFullPath(path);
                if (!Directory.Exists(resolved)) { Append("Capture folder does not exist yet. It will be created by the first capture."); return; }
                Process.Start(new ProcessStartInfo { FileName = resolved, UseShellExecute = true });
            }
            catch (Exception error) { Append("Could not open capture folder: " + error.Message); }
        }
    }
}
