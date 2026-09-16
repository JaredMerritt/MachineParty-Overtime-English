// Machine Party 8-player mod — installer / launcher
//
// The same source builds two exes (see tools\build_installer.ps1)
//   mp8_install.exe    console version, with the full set of command-line arguments
//   mp8_launcher.exe   windowed version (/define:GUI /target:winexe), just double-click to use
// All patch bytecode is **embedded**, so neither one needs any runtime installed or any other tool downloaded.
//
// It doesn't contain or distribute any original game assets. The only embedded files are the .gdc files the mod itself changed.
//
// ── How restoring only needs to store a few KB ───────────────────────────────────────
// Patching works by "appending the new content to the end of the PCK + pointing that index entry at it",
// so **not a single byte of the original file is overwritten**, and it all still sits there in the middle of the pack.
// That means restoring doesn't need a 605 MB backup of the whole pack. It just writes those few index fields back
// and truncates the file back to its original length — which is why the backup file is only a few KB,
// and after restoring, a SHA256 can be computed and compared with the vanilla fingerprint, **proving it's byte-for-byte exact**.
// (The old-style 605 MB whole-pack backup is still recognised, see the legacy backup branches in Install and Uninstall.)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
#if GUI
using System.Drawing;
using System.Threading;
using System.Windows.Forms;
#endif

// ═════════════════════════════════════════════════════════════════════════
// Bilingual text
// ═════════════════════════════════════════════════════════════════════════
static class L
{
    public static bool Zh = true;

    public static void Auto()
    {
        try { Zh = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh"; }
        catch { Zh = true; }
    }

    // Chinese and English are written side by side at the call site with no key table — so a text change can't miss the other language
    public static string T(string zh, string en) { return Zh ? zh : en; }
}

// ═════════════════════════════════════════════════════════════════════════
// Core logic (shared by the console and windowed versions)
// ═════════════════════════════════════════════════════════════════════════
static class Core
{
    // ── Game version this mod supports (fingerprint of the vanilla PCK) ────────────────────────
    // Switching game versions means updating these three lines together, or a new version's pack gets broken by the old patches.
    public const string GameVersion = "v2.1.2";
    public const string VanillaSha  = "326CC3988D3AC554D1F288BED89B1F89D450F78EC9D4470F88558975753DFA8E";
    public const long   VanillaSize = 634798100L;

    // ── The installer's own release number (a separate thing from the mod version) ────────────────────────
    // ModTag() (from MP8_VERSION_TAG in network_manager.gd) = the mod version built into the pck.
    //   It decides who can play online with whom, and changing it means everyone has to reinstall.
    // ReleaseNum = this exe's own release number. It doesn't go into the pck or the multiplayer handshake string, it's only a label.
    // 1.3.1 was an "installer-only fix" release. The mod was still overtime-1.3 and not a single pck byte changed,
    // so people with 1.3 installed didn't need to do anything, and 1.3 and 1.3.1 players can still share a lobby.
    // It also decides the output folder name under dist\ and the release package name (see tools\build_installer.ps1),
    // so a rebuild doesn't overwrite the already-released dist\overtime-1.3\ along with its zip.
    public const string ReleaseNum = "1.7-en";

    public const string AppId   = "4108000";
    public const string GameRel = @"steamapps\common\party project\Machine Party_Windows";
    public const string PckName = "Machine Party.pck";
    public const string BakName = "Machine Party.pck.vanilla";   // Old-style whole-pack backup (still supported)
    public const string ResName    = "overtime_restore.dat";           // Small restore data
    // Before 0.9 it was called mp8_restore.dat. Machines that installed an old version still have that name,
    // so reading accepts both names, but writing only uses the new one.
    public const string OldResName = "mp8_restore.dat";

    // Where the existing restore data is (new name first). Returns an empty string if there isn't any.
    public static string FindRes(string gameDir)
    {
        string a = Path.Combine(gameDir, ResName);
        if (File.Exists(a)) return a;
        string b = Path.Combine(gameDir, OldResName);
        if (File.Exists(b)) return b;
        return "";
    }

    const uint  ResMagic  = 0x3852504Du;   // "MP8R"
    const uint  ResFormat = 1u;

    // ── Log ───────────────────────────────────────────────────────────
    static readonly List<string> logBuf = new List<string>();
    public static string LogPath
    {
        get { return Path.Combine(Path.GetTempPath(), "overtime_install.log"); }
    }

    public static void Log(string s)
    {
        logBuf.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + s);
    }

    public static void FlushLog()
    {
        // Don't write if the buffer is empty. Otherwise every press of "Install log" inserts an empty section header into the file
        if (logBuf.Count == 0) return;
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine("──── " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                          "  mod " + ModTag() + "  installer " + ReleaseNum +
                          "  game " + GameVersion + " ────");
            foreach (string s in logBuf) sb.AppendLine(s);
            File.AppendAllText(LogPath, sb.ToString(), Encoding.UTF8);
            // Clear it once written out. 1.3 was missing this line. The "Install log" button flushed once, closing the window
            // flushed again, and the same batch of lines got written to the file twice — players saw a whole screen of
            // identical lines and assumed their log was broken.
            logBuf.Clear();
        }
        catch { }
    }

    // ── Finding the game. The registry gives the Steam root → libraryfolders.vdf gives every library drive ──
    // Returns **every** matching copy. Some people have several installs (multiple library drives, family sharing),
    // and just taking the first one would patch the wrong pack, so the caller asks the user.
    public static List<string> FindGameDirs()
    {
        var roots = new List<string>();
        foreach (var pair in new[] {
            new[] { @"Software\Valve\Steam", "SteamPath" },
            new[] { @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath" } })
        {
            foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            {
                try
                {
                    using (var k = hive.OpenSubKey(pair[0]))
                    {
                        if (k == null) continue;
                        var v = k.GetValue(pair[1]) as string;
                        if (!string.IsNullOrEmpty(v)) roots.Add(v.Replace('/', '\\'));
                    }
                }
                catch { }
            }
        }

        var dirs = new List<string>(roots);
        foreach (string r in roots)
        {
            string vdf = Path.Combine(r, @"steamapps\libraryfolders.vdf");
            if (!File.Exists(vdf)) continue;
            try
            {
                foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                    dirs.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
            }
            catch { }
        }

        var found = new List<string>();
        foreach (string d in dirs)
        {
            try
            {
                string cand = Path.Combine(d, GameRel);
                if (!File.Exists(Path.Combine(cand, PckName))) continue;
                string full = Path.GetFullPath(cand);
                bool dup = false;
                foreach (string f in found)
                    if (string.Equals(f, full, StringComparison.OrdinalIgnoreCase)) dup = true;
                if (!dup) found.Add(full);
            }
            catch { }
        }
        return found;
    }

    // ── "Can we touch this pack right now" ───────────────────────────────────────────
    //
    // Before 1.3 this only asked one thing, whether the process list had a process named "Machine Party".
    // That test was wrong because it only compared the name — it ignored the path and whether it was the currently selected game folder.
    // It really went wrong in the wild. One player's machine had a same-named process that never went away (a zombie that didn't exit cleanly, one held by
    // WerFault after a crash, or some other same-named exe elsewhere), so they were permanently locked out. Rebooting the PC
    // and reinstalling the game were both useless — neither of those changes "what the process is named" —
    // and the popup gave no clue at all.
    //
    // It's now split into two tests, each covering its own part
    //   ① Can the pck be opened exclusively with FileShare.None — authoritative. It asks the file system directly
    //      "is anyone holding this file", no matter what the process is called.
    //   ② A same-named process **and** its exe path is inside this game folder — this covers the gap in ①.
    //      Godot's FileAccessPack "opens a handle each time it reads a resource", so a game idling on the main menu
    //      may not hold a single pck handle, and ① can't detect it then.
    // Same-named processes whose path can't be read, or whose path is somewhere else, are **never blocked**, only logged —
    // that's exactly the branch where 1.3 locked players out.

    public sealed class Holder
    {
        public int    Pid;
        public string ExePath = "";   // Empty string if it can't be read (permissions / bitness mismatch)
        public bool   InGameDir;      // Path confirmed to be inside the current game folder
    }

    // List of same-named processes. Only used to explain "why you're blocked", never used as a test on its own.
    public static List<Holder> FindGameProcesses(string gameDir)
    {
        var list = new List<Holder>();
        string root = "";
        try { root = Path.GetFullPath(gameDir).TrimEnd('\\') + "\\"; }
        catch { }

        Process[] ps;
        try { ps = Process.GetProcessesByName("Machine Party"); }
        catch { return list; }

        foreach (var p in ps)
        {
            var h = new Holder();
            try { h.Pid = p.Id; } catch { h.Pid = -1; }
            // MainModule throws on permission or 32/64-bit mismatch. If it throws, treat the path as unknown,
            // and an unknown path **doesn't block anyone** (see the section above).
            try { h.ExePath = p.MainModule.FileName; } catch { h.ExePath = ""; }
            h.InGameDir = root.Length > 0 && h.ExePath.Length > 0 &&
                          h.ExePath.StartsWith(root, StringComparison.OrdinalIgnoreCase);
            list.Add(h);
            try { p.Dispose(); } catch { }
        }
        return list;
    }

    // OK to touch → returns null. Not OK → returns the reason to show the player as-is.
    public static string BusyReason(string gameDir)
    {
        // ② Check processes first. When this one hits, its message is far more useful than ①'s (it can name the exact PID and path)
        var mine = new List<Holder>();
        foreach (var h in FindGameProcesses(gameDir))
        {
            if (h.InGameDir) mine.Add(h);
            else Log(string.Format("Same-named process, not blocking (path {0}): PID {1}  {2}",
                                   h.ExePath.Length == 0 ? "unreadable" : "not in this folder",
                                   h.Pid, h.ExePath.Length == 0 ? "-" : h.ExePath));
        }
        if (mine.Count > 0)
        {
            var sb = new StringBuilder();
            sb.Append(L.T("The game is running, fully exit it first.\n\nProcesses holding it:\n",
                          "The game is running. Fully exit it first.\n\nProcesses:\n"));
            foreach (var h in mine)
            {
                sb.AppendLine("    PID " + h.Pid + "    " + h.ExePath);
                Log("Blocked: PID " + h.Pid + "  " + h.ExePath);
            }
            sb.Append(L.T("\nIf you still get this after the window is closed, the process didn't exit cleanly:\n" +
                          "Task Manager → 'Details' → find the PID above → End task.",
                          "\nIf the window is already closed, the process did not exit:\n" +
                          "Task Manager -> Details -> find that PID -> End task."));
            return sb.ToString();
        }

        // ① Then ask the file system. Antivirus scans and Steam verification hold it briefly, so retry a few times before giving up.
        string pck = Path.Combine(gameDir, PckName);
        if (!File.Exists(pck)) return null;      // The pack isn't even there, so let the later steps report that error
        for (int i = 0; i < 5; i++)
        {
            try
            {
                using (new FileStream(pck, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                // A permission problem isn't a lock, so leave it to PreflightWritable to report — its message is more accurate
                return null;
            }
            catch (IOException) { }
            // using System.Threading is only in the GUI branch and the console version doesn't compile it in, so the full name is written here
            if (i < 4) System.Threading.Thread.Sleep(200);
        }
        Log("Exclusive pck open failed: " + pck);
        return L.T(
            "The PCK is in use and can't be changed right now.\n\n" +
            "Common causes: the game didn't exit cleanly; Steam is updating or verifying this game; antivirus is scanning it.\n" +
            "What to do: fully exit the game and Steam, wait a few seconds and try again. If that still doesn't work, restart your PC once and try again.",
            "The PCK is locked by another process.\n\n" +
            "Usual causes: the game did not exit cleanly; Steam is updating or verifying it; " +
            "an antivirus is scanning it.\n" +
            "Fix: fully exit the game and Steam, wait a few seconds, then retry; reboot if it persists.");
    }

    public static string ModTag()
    {
        try
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("mp8.version"))
                if (s != null) using (var r = new StreamReader(s)) return r.ReadToEnd().Trim();
        }
        catch { }
        return "mp8";
    }

    public static string Sha256(string path)
    {
        using (var sha = SHA256.Create())
        using (var fs = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // PCK structure
    // ═══════════════════════════════════════════════════════════════════
    //
    // Godot 4.5 PCK (format version 3) layout — measured from a stock pack, not copied from the docs
    //
    //   +0   "GDPC"
    //   +4   format version = 3
    //   +8   +12  +16   engine version 4 / 5 / 2
    //   +20  pack_flags (bit 0 = encrypted directory, bit 1 = offsets relative to file_base)
    //   +24  file_base (u64) = 128 ← file data starts here
    //   +32  dir_offset(u64)       ← **the index is at the end of the file** (changed in Godot 4.4+, it's not at the start)
    //   …    reserved area, up to 128
    //   128  file data…
    //   dir_offset   u32 file count, then for each entry
    //                u32 path length (zero-padded for alignment) + path + u64 offset + u64 size + md5[16] + u32 flags

    public class PckEntry
    {
        public long   FieldPos;   // Absolute position of the "offset" field in the index, with the other three fields right after it
        public ulong  Offset;
        public ulong  Size;
        public byte[] Md5;
    }

    public class PckIndex
    {
        public ulong FileBase;
        public bool  RelBase;
        public Dictionary<string, PckEntry> Entries = new Dictionary<string, PckEntry>();
    }

    public static PckIndex ReadIndex(FileStream fs)
    {
        var br = new BinaryReader(fs);
        fs.Position = 0;

        if (br.ReadUInt32() != 0x43504447u)
            throw new Exception(L.T("Not a PCK file (missing the GDPC marker)", "Not a PCK file (missing GDPC magic)"));
        uint ver = br.ReadUInt32();
        if (ver != 3)
            throw new Exception(L.T("PCK format version is " + ver + ", this program only accepts 3 (Godot 4.4+)",
                                    "PCK format version is " + ver + ", this tool only supports 3 (Godot 4.4+)"));
        br.ReadUInt32(); br.ReadUInt32(); br.ReadUInt32();
        uint packFlags = br.ReadUInt32();
        if ((packFlags & 1) != 0)
            throw new Exception(L.T("This PCK's directory is encrypted and can't be modified", "This PCK has an encrypted directory"));

        var idx = new PckIndex();
        idx.FileBase = br.ReadUInt64();
        ulong dirOffset = br.ReadUInt64();
        idx.RelBase = (packFlags & 2) != 0;

        fs.Position = (long)dirOffset;
        uint count = br.ReadUInt32();
        for (uint i = 0; i < count; i++)
        {
            uint plen = br.ReadUInt32();
            string path = Encoding.UTF8.GetString(br.ReadBytes((int)plen)).TrimEnd('\0');
            var e = new PckEntry();
            e.FieldPos = fs.Position;
            e.Offset = br.ReadUInt64();
            e.Size   = br.ReadUInt64();
            e.Md5    = br.ReadBytes(16);
            br.ReadUInt32();                       // flags
            idx.Entries[path] = e;
        }
        return idx;
    }

    // Embedded resources. mp8.manifest has one line per file, "<index>|<res:// path>", and the content is in mp8.<index>
    public static SortedDictionary<string, byte[]> LoadEmbedded()
    {
        var asm = Assembly.GetExecutingAssembly();
        // ⚠️ Use SortedDictionary, not Dictionary. The write order decides the append order,
        //    which in turn decides the output bytes. Only a fixed order gives "the same input produces the same pack".
        var map = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);

        string manifest;
        using (var s = asm.GetManifestResourceStream("mp8.manifest"))
        {
            if (s == null)
                throw new Exception(L.T("This exe has no embedded patches (they were left out when packaging)",
                                        "This exe has no embedded patches (packaging error)"));
            using (var r = new StreamReader(s, Encoding.UTF8)) manifest = r.ReadToEnd();
        }

        foreach (string raw in manifest.Split('\n'))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            int bar = line.IndexOf('|');
            if (bar < 0) throw new Exception("bad manifest line: " + line);
            string id = line.Substring(0, bar);
            string path = line.Substring(bar + 1).Trim();
            if (path.StartsWith("res://")) path = path.Substring(6);   // PCK index entries don't include res://

            using (var s = asm.GetManifestResourceStream("mp8." + id))
            {
                if (s == null) throw new Exception("missing embedded patch: mp8." + id);
                var buf = new byte[s.Length];
                int off = 0;
                while (off < buf.Length) off += s.Read(buf, off, buf.Length - off);
                map[path] = buf;
            }
        }
        return map;
    }

    static byte[] Md5Of(byte[] data)
    {
        using (var md5 = MD5.Create()) return md5.ComputeHash(data);
    }

    static bool SameBytes(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Current state
    // ═══════════════════════════════════════════════════════════════════
    public enum Kind { Missing, Vanilla, OursInstalled, OldVersion, Unknown }

    public class State
    {
        public string GameDir;
        public string PckPath;
        public Kind   Kind = Kind.Missing;
        public long   Length;
        public bool   HasRestore;
        public bool   HasLegacy;
        public string InstalledTag = "";   // The mod version recorded in the restore data
        public string Note = "";

        public bool CanUninstall { get { return HasRestore || HasLegacy; } }
    }

    public static State Detect(string gameDir)
    {
        var st = new State();
        st.GameDir = gameDir;
        st.PckPath = Path.Combine(gameDir, PckName);
        if (!File.Exists(st.PckPath)) return st;

        st.Length     = new FileInfo(st.PckPath).Length;
        string resPath = FindRes(gameDir);
        st.HasRestore = (resPath.Length > 0);
        st.HasLegacy  = File.Exists(Path.Combine(gameDir, BakName));

        if (st.HasRestore)
        {
            try { st.InstalledTag = ReadRestore(resPath).ModTag; }
            catch { }
        }

        try
        {
            var patches = LoadEmbedded();
            using (var fs = new FileStream(st.PckPath, FileMode.Open, FileAccess.Read))
            {
                var idx = ReadIndex(fs);

                // Deciding "is our version the one installed" doesn't hash the whole pack (635 MB takes over ten seconds).
                // It only compares the md5 recorded in the index with the embedded patches' md5 — if they match, we wrote it.
                int hit = 0, total = 0;
                bool allPresent = true;
                foreach (var kv in patches)
                {
                    total++;
                    PckEntry e;
                    if (!idx.Entries.TryGetValue(kv.Key, out e)) { allPresent = false; continue; }
                    if (SameBytes(e.Md5, Md5Of(kv.Value))) hit++;
                }

                if (!allPresent)
                {
                    st.Kind = Kind.Unknown;
                    st.Note = L.T("Can't find the files this mod changes in this pack — the game version is most likely not " + GameVersion,
                                  "Files this mod patches are absent — the game is probably not " + GameVersion);
                }
                else if (hit == total)   st.Kind = Kind.OursInstalled;
                else if (st.InstalledTag.Length > 0 && st.InstalledTag != ModTag())
                {
                    // 🩸 A **different version** of MP8 is installed. Without this check it would fall into the branch below,
                    //    "only N/47 patches in place, the last install may have failed" — both alarming and wrong,
                    //    and upgrading is exactly the most common path (every new release sends all existing users through here).
                    st.Kind = Kind.OldVersion;
                    st.Note = L.T("Overtime " + st.InstalledTag + " is installed, and this program is " + ModTag() + ". Just install to upgrade.",
                                  "Overtime " + st.InstalledTag + " is installed; this program is " + ModTag() + ". Installing upgrades it.");
                }
                else if (hit > 0)
                {
                    st.Kind = Kind.Unknown;
                    st.Note = L.T("Only " + hit + "/" + total + " patches are in place — the last install may have failed partway through",
                                  "Only " + hit + "/" + total + " patches present — a previous install may have failed");
                }
                else if (st.Length == VanillaSize) st.Kind = Kind.Vanilla;
                else
                {
                    st.Kind = Kind.Unknown;
                    st.Note = L.T("Neither vanilla nor this mod (installed another mod? game updated?)",
                                  "Neither vanilla nor this mod (another mod? game updated?)");
                }
            }
        }
        catch (Exception ex)
        {
            st.Kind = Kind.Unknown;
            st.Note = ex.Message;
        }
        return st;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Restore data (a few KB)
    // ═══════════════════════════════════════════════════════════════════
    class RestoreData
    {
        public long   OrigLength;      // File length before patching
        public long   PatchedLength;   // File length after patching
        public string BaseSha;         // Fingerprint of the pack before patching. Empty if it wasn't verified
        public string GameVer;
        public string ModTag;
        public Dictionary<string, PckEntry> Orig = new Dictionary<string, PckEntry>();
        // The values we wrote. Before restoring, compare them with what's on disk to confirm "this pack is exactly the one I modified".
        public Dictionary<string, PckEntry> Made = new Dictionary<string, PckEntry>();
    }

    static void WriteRestore(string path, RestoreData d)
    {
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        using (var bw = new BinaryWriter(fs, Encoding.UTF8))
        {
            bw.Write(ResMagic);
            bw.Write(ResFormat);
            bw.Write(d.OrigLength);
            bw.Write(d.PatchedLength);
            bw.Write(d.BaseSha == null ? "" : d.BaseSha);
            bw.Write(d.GameVer);
            bw.Write(d.ModTag);
            bw.Write(d.Orig.Count);
            foreach (var kv in d.Orig)
            {
                var made = d.Made[kv.Key];
                bw.Write(kv.Key);
                bw.Write(kv.Value.Offset); bw.Write(kv.Value.Size); bw.Write(kv.Value.Md5);
                bw.Write(made.Offset);     bw.Write(made.Size);     bw.Write(made.Md5);
            }
        }
    }

    static RestoreData ReadRestore(string path)
    {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read))
        using (var br = new BinaryReader(fs, Encoding.UTF8))
        {
            if (br.ReadUInt32() != ResMagic)
                throw new Exception(L.T("Restore data file is corrupt (wrong marker)", "Restore data corrupt (bad magic)"));
            uint fmt = br.ReadUInt32();
            if (fmt != ResFormat)
                throw new Exception(L.T("Restore data format version is " + fmt + ", which this program doesn't recognise",
                                        "Restore data format " + fmt + " is not supported"));
            var d = new RestoreData();
            d.OrigLength    = br.ReadInt64();
            d.PatchedLength = br.ReadInt64();
            d.BaseSha       = br.ReadString();
            d.GameVer       = br.ReadString();
            d.ModTag        = br.ReadString();
            int n = br.ReadInt32();
            for (int i = 0; i < n; i++)
            {
                string p = br.ReadString();
                var o = new PckEntry();
                o.Offset = br.ReadUInt64(); o.Size = br.ReadUInt64(); o.Md5 = br.ReadBytes(16);
                var m = new PckEntry();
                m.Offset = br.ReadUInt64(); m.Size = br.ReadUInt64(); m.Md5 = br.ReadBytes(16);
                d.Orig[p] = o;
                d.Made[p] = m;
            }
            return d;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Patching / restoring
    // ═══════════════════════════════════════════════════════════════════
    //
    // The method is **append + edit the index**, without rewriting the whole pack.
    //   1. Write the new content to the end of the file (after the index is fine too — the engine only seeks by the offsets in the index).
    //   2. Change that index entry's offset/size/md5 in place.
    // So only ~640 KB gets written into the 635 MB pack, and it's done in seconds.
    static int PatchPck(string pckPath, SortedDictionary<string, byte[]> patches, RestoreData rec)
    {
        int replaced = 0;
        using (var fs = new FileStream(pckPath, FileMode.Open, FileAccess.ReadWrite))
        {
            var idx = ReadIndex(fs);
            var bw = new BinaryWriter(fs);

            var missing = new List<string>();
            foreach (var kv in patches) if (!idx.Entries.ContainsKey(kv.Key)) missing.Add(kv.Key);
            if (missing.Count > 0)
                throw new Exception(L.T("These patches have no matching file in the game pack (wrong game version?):\n  ",
                                        "These patches have no counterpart in the game (wrong version?):\n  ")
                                    + string.Join("\n  ", missing.ToArray()));

            // First record the "index fields before the change" exactly as they are — that's everything restoring needs
            rec.OrigLength = fs.Length;
            foreach (var kv in patches)
            {
                var e = idx.Entries[kv.Key];
                var copy = new PckEntry();
                copy.Offset = e.Offset; copy.Size = e.Size; copy.Md5 = e.Md5;
                rec.Orig[kv.Key] = copy;
            }

            foreach (var kv in patches)      // SortedDictionary gives a fixed order, so the output is reproducible
            {
                byte[] data = kv.Value;
                fs.Position = fs.Length;
                long at = fs.Position;
                bw.Write(data);

                ulong stored = idx.RelBase ? (ulong)at - idx.FileBase : (ulong)at;
                byte[] md5 = Md5Of(data);
                fs.Position = idx.Entries[kv.Key].FieldPos;
                bw.Write(stored);
                bw.Write((ulong)data.Length);
                bw.Write(md5);

                var made = new PckEntry();
                made.Offset = stored; made.Size = (ulong)data.Length; made.Md5 = md5;
                rec.Made[kv.Key] = made;
                replaced++;
            }
            bw.Flush();
            rec.PatchedLength = fs.Length;
        }
        return replaced;
    }

    // "Is the pack right now exactly the one I modified back then?"
    //
    // 🩸 This gate can't be skipped. Restoring writes the recorded old values back into the index fields + truncates to the old length —
    //    once the file is no longer the original one (most commonly **Steam updated the game**, or the user clicked
    //    "Verify integrity of game files"), writing old offsets into the new pack's index **corrupts it on the spot**.
    //    So before restoring, every entry has to prove that what's on disk matches the record.
    static bool RestoreApplies(string pckPath, RestoreData d, out string why)
    {
        why = null;
        try
        {
            var fi = new FileInfo(pckPath);
            if (fi.Length != d.PatchedLength)
            {
                why = L.T("PCK length changed (recorded " + d.PatchedLength.ToString("N0") +
                          ", now " + fi.Length.ToString("N0") + ")",
                          "PCK length changed (recorded " + d.PatchedLength.ToString("N0") +
                          ", now " + fi.Length.ToString("N0") + ")");
                return false;
            }

            using (var fs = new FileStream(pckPath, FileMode.Open, FileAccess.Read))
            {
                var idx = ReadIndex(fs);
                foreach (var kv in d.Made)
                {
                    PckEntry cur;
                    if (!idx.Entries.TryGetValue(kv.Key, out cur))
                    {
                        why = L.T("The PCK no longer contains " + kv.Key, "The PCK no longer contains " + kv.Key);
                        return false;
                    }
                    if (cur.Offset != kv.Value.Offset || cur.Size != kv.Value.Size ||
                        !SameBytes(cur.Md5, kv.Value.Md5))
                    {
                        why = L.T("Index mismatch (" + kv.Key + ")", "Index mismatch (" + kv.Key + ")");
                        return false;
                    }
                }
            }
            return true;
        }
        catch (Exception ex) { why = ex.Message; return false; }
    }

    // After patching, read the index again and check that every entry's md5 is the one we just wrote.
    // A cheap safety net. If the power goes out halfway through writing or the disk fills up, it gets caught right here.
    static void VerifyPatched(string pckPath, SortedDictionary<string, byte[]> patches)
    {
        using (var fs = new FileStream(pckPath, FileMode.Open, FileAccess.Read))
        {
            var idx = ReadIndex(fs);
            var bad = new List<string>();
            foreach (var kv in patches)
            {
                PckEntry e;
                if (!idx.Entries.TryGetValue(kv.Key, out e)) { bad.Add(kv.Key); continue; }
                if (!SameBytes(e.Md5, Md5Of(kv.Value))) bad.Add(kv.Key);
                if (e.Size != (ulong)kv.Value.Length) bad.Add(kv.Key);
            }
            if (bad.Count > 0)
                throw new Exception(L.T("Post-write self-check failed (" + bad.Count + " entries don't match)",
                                        "Post-write verification failed (" + bad.Count + " entries)"));
        }
    }

    // Restoring means writing the index fields back + truncating the section we appended.
    // The original file's bytes were never overwritten, so this returns it **byte for byte** to how it was before patching.
    static void ApplyRestore(string pckPath, RestoreData d)
    {
        string why;
        if (!RestoreApplies(pckPath, d, out why))
            throw new Exception(L.T(
                "The restore data doesn't match the current game PCK, **your files were not touched**.\n  " + why + "\n" +
                "Most likely Steam updated the game, or you clicked 'Verify integrity of game files' —\n" +
                "in which case the game is already vanilla, just delete " + ResName + ".",
                "The restore data does not match the current PCK. Nothing was changed.\n  " + why + "\n" +
                "Most likely Steam updated the game, or you ran \"Verify integrity of game files\" —\n" +
                "in that case the game is already vanilla; just delete " + ResName + "."));

        using (var fs = new FileStream(pckPath, FileMode.Open, FileAccess.ReadWrite))
        {
            var idx = ReadIndex(fs);
            var bw = new BinaryWriter(fs);
            foreach (var kv in d.Orig)
            {
                var e = idx.Entries[kv.Key];       // RestoreApplies already guarantees it exists
                fs.Position = e.FieldPos;
                bw.Write(kv.Value.Offset);
                bw.Write(kv.Value.Size);
                bw.Write(kv.Value.Md5);
            }
            bw.Flush();
            fs.SetLength(d.OrigLength);      // Cut off the appended section
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Public actions
    // ═══════════════════════════════════════════════════════════════════
    public static void Install(string gameDir, bool force, Action<string> say)
    {
        string live = Path.Combine(gameDir, PckName);
        string res  = Path.Combine(gameDir, ResName);   // For writing, always use the new name
        string cur  = FindRes(gameDir);                 // For reading, whatever is on disk (may be the old name)
        string bak  = Path.Combine(gameDir, BakName);

        PreflightWritable(gameDir, live);

        // Already installed → first restore it exactly, then patch again from the clean pack.
        // Otherwise the patches would pile up layer on layer and the pack would keep growing.
        if (cur.Length > 0)
        {
            RestoreData old = null;
            string why = null;
            try { old = ReadRestore(cur); } catch (Exception ex) { why = ex.Message; }

            if (old != null && RestoreApplies(live, old, out why))
            {
                say(L.T("[1/4] Restoring the previous install first…", "[1/4] Reverting the previous install first..."));
                ApplyRestore(live, old);
                File.Delete(cur);
            }
            else
            {
                // What's on disk doesn't match the record (a Steam update, or the user clicked "Verify integrity of game files").
                // Using it to modify the pack would corrupt the file, so it's only ignored, never used.
                // Whether this pack can actually be installed is decided by the vanilla check below.
                say(L.T("[1/4] The previous restore data doesn't match the current PCK, ignored (" + why + ")",
                        "[1/4] Stale restore data ignored (" + why + ")"));
            }
        }
        else if (File.Exists(bak))
        {
            // Old-style 605 MB whole-pack backup. **Its hash must be verified**.
            // 🩸 Old installers only checked that it existed here, not its contents — reinstalling after a game update
            //    would put the old version's pack over the new game. This is the fix for that bug.
            say(L.T("[1/4] Found an old-style whole-pack backup, verifying (takes ten-plus seconds)…",
                    "[1/4] Found a legacy full backup, verifying (~15s)..."));
            string bs = Sha256(bak);
            if (bs != VanillaSha)
                throw new Exception(L.T(
                    "Old backup " + BakName + " isn't a vanilla build this mod recognises, **your files were not touched**.\n" +
                    "  Most likely the game was updated and that backup is still from the old version.\n" +
                    "  What to do: delete it, then use Steam's 'Verify integrity of game files' to get the current vanilla version back.",
                    "Legacy backup " + BakName + " is not the vanilla build this mod knows. Nothing was changed.\n" +
                    "  Most likely the game updated while that backup is from an older version.\n" +
                    "  Fix: delete it, then use Steam's \"Verify integrity of game files\"."));
            File.Copy(bak, live, true);
            say(L.T("      ✓ Restored to vanilla from the old backup", "      OK, restored to vanilla from the legacy backup"));
        }

        // The pack should be clean vanilla now, so verify it
        say(L.T("[2/4] Checking whether the current PCK is vanilla (takes ten-plus seconds)…",
                "[2/4] Verifying the current PCK is vanilla (~15s)..."));
        long sz = new FileInfo(live).Length;
        string sha = Sha256(live);
        bool verified = (sha == VanillaSha);

        if (!verified)
        {
            if (!force)
                throw new Exception(L.T(
                    "The current PCK doesn't match the vanilla build this mod recognises, **it was not touched**.\n" +
                    "  Expected: " + VanillaSha + " (" + GameVersion + ", " + VanillaSize.ToString("N0") + " bytes)\n" +
                    "  Actual:   " + sha + " (" + sz.ToString("N0") + " bytes)\n" +
                    "Common causes:\n" +
                    "  1. The game was updated — you need to wait for a mod release that supports the new version, forcing the install will break it;\n" +
                    "  2. Another mod is already installed.\n" +
                    "To fix it: Steam → right-click the game → Properties → Installed Files → Verify integrity of game files.\n" +
                    "If you're sure you want to continue, add --force.",
                    "The current PCK does not match the vanilla build this mod knows. Nothing was changed.\n" +
                    "  Expected: " + VanillaSha + " (" + GameVersion + ", " + VanillaSize.ToString("N0") + " bytes)\n" +
                    "  Actual:   " + sha + " (" + sz.ToString("N0") + " bytes)\n" +
                    "Common causes:\n" +
                    "  1. The game was updated — wait for a mod build that targets it;\n" +
                    "  2. Another mod is already installed.\n" +
                    "Fix: Steam -> right click the game -> Properties -> Installed Files -> Verify integrity.\n" +
                    "Use --force to proceed anyway."));
            say(L.T("      ⚠ Verification failed, but you passed --force, so continuing.",
                    "      WARNING: verification failed but --force was given, continuing."));
        }
        else say(L.T("      ✓ It's vanilla " + GameVersion, "      OK, vanilla " + GameVersion));

        var patches = LoadEmbedded();
        say(L.T("[3/4] Writing " + patches.Count + " patches…",
                "[3/4] Writing " + patches.Count + " patches..."));

        var rec = new RestoreData();
        rec.BaseSha = verified ? VanillaSha : null;   // If it wasn't verified, don't promise that restoring gives vanilla
        rec.GameVer = GameVersion;
        rec.ModTag  = ModTag();

        var sw = Stopwatch.StartNew();
        int n = PatchPck(live, patches, rec);
        sw.Stop();

        // The restore data is written to disk after patching, so a failed install never leaves half-written restore data.
        // If patching is interrupted partway (power loss, crash), the PCK is left partly patched with no restore data.
        // Running again then fails the vanilla SHA256 check, and Steam's "Verify integrity of game files" brings back the original.
        WriteRestore(res, rec);

        say(L.T("[4/4] Self-checking what was written…", "[4/4] Verifying what was written..."));
        VerifyPatched(live, patches);

        say("");
        say(L.T("✓ Installed: " + n + " files replaced, took " + sw.Elapsed.TotalSeconds.ToString("0.0") + " seconds",
                "Done: " + n + " files replaced in " + sw.Elapsed.TotalSeconds.ToString("0.0") + "s"));

        if (File.Exists(bak))
            say(L.T("Tip: restoring now only needs " + ResName + " (a few KB), so the 605 MB " + BakName + " can be deleted.",
                    "Note: reverting now only needs " + ResName + " (a few KB); the 605 MB " + BakName + " can be deleted."));
    }

    public static void Uninstall(string gameDir, Action<string> say)
    {
        string live = Path.Combine(gameDir, PckName);
        string res  = FindRes(gameDir);                // May be the old name mp8_restore.dat
        string bak  = Path.Combine(gameDir, BakName);

        PreflightWritable(gameDir, live);

        string stale = null;
        if (res.Length > 0)
        {
            RestoreData d = null;
            try { d = ReadRestore(res); } catch (Exception ex) { stale = ex.Message; }

            // If it doesn't match, don't force it — there's still the whole-pack backup route below, and failing that, let Steam repair it
            if (d != null && !RestoreApplies(live, d, out stale)) d = null;

            if (d != null)
            {
                say(L.T("Restoring vanilla…", "Restoring vanilla..."));
                ApplyRestore(live, d);

                if (!string.IsNullOrEmpty(d.BaseSha))
                {
                    say(L.T("Verifying the restore result (takes ten-plus seconds)…", "Verifying the restored file (~15s)..."));
                    string sha = Sha256(live);
                    if (sha != d.BaseSha)
                        throw new Exception(L.T(
                            "The restored PCK doesn't match the vanilla fingerprint:\n  expected " + d.BaseSha + "\n  actual " + sha +
                            "\nUse Steam's 'Verify integrity of game files' to get vanilla back.",
                            "The restored PCK does not match the vanilla fingerprint:\n  expected " + d.BaseSha +
                            "\n  actual   " + sha + "\nUse Steam's \"Verify integrity of game files\" to recover."));
                    say(L.T("      ✓ Byte-for-byte identical to vanilla " + GameVersion,
                            "      OK, byte-for-byte identical to vanilla " + GameVersion));
                }
                File.Delete(res);
                say("");
                say(L.T("✓ Restored to vanilla, you can now play with friends who don't have the mod.",
                        "Reverted to vanilla. You can play with unmodded friends now."));
                return;
            }
        }

        if (File.Exists(bak))
        {
            say(L.T("Restoring from the old-style whole-pack backup, verifying first (takes ten-plus seconds)…",
                    "Restoring from the legacy full backup, verifying first (~15s)..."));
            if (Sha256(bak) != VanillaSha)
                throw new Exception(L.T(
                    "The old backup isn't a vanilla build this mod recognises, **your files were not touched**.\n" +
                    "Use Steam's 'Verify integrity of game files' to get vanilla back.",
                    "The legacy backup is not the vanilla build this mod knows. Nothing was changed.\n" +
                    "Use Steam's \"Verify integrity of game files\"."));
            File.Copy(bak, live, true);
            say("");
            say(L.T("✓ Restored to vanilla.", "Reverted to vanilla."));
            return;
        }

        // Reaching here means there's no usable way to restore. First check whether a restore is even needed —
        // this is the state right after the user clicks Steam's "Verify integrity of game files". The pack is already vanilla,
        // with just an unusable mp8_restore.dat left over. That case deserves good news, not an error.
        var now = Detect(gameDir);
        if (now.Kind == Kind.Vanilla)
        {
            if (res.Length > 0) { try { File.Delete(res); } catch { } }
            say(L.T("✓ It's already vanilla, no restore needed (cleared out the unusable restore data while at it).",
                    "Already vanilla, nothing to revert (removed the stale restore data)."));
            return;
        }

        throw new Exception(L.T(
            "No usable way to restore — it can't be restored automatically.\n" +
            (stale != null ? "  Restore data can't be used: " + stale + "\n" : "  Can't find restore data (" + ResName + "), and there's no old backup either.\n") +
            "To fix it: Steam → right-click the game → Properties → Installed Files → Verify integrity of game files,\n" +
            "and Steam will download vanilla again (about 600 MB).",
            "No usable way to revert.\n" +
            (stale != null ? "  Restore data unusable: " + stale + "\n" : "  No restore data (" + ResName + ") and no legacy backup.\n") +
            "Fix: Steam -> right click the game -> Properties -> Installed Files -> Verify integrity of game files."));
    }

    // Can we write to it, and is there enough space — ask up front instead of blowing up halfway through writing
    static void PreflightWritable(string gameDir, string live)
    {
        try
        {
            using (var fs = new FileStream(live, FileMode.Open, FileAccess.ReadWrite)) { }
        }
        catch (UnauthorizedAccessException)
        {
            throw new Exception(L.T(
                "No write permission: " + gameDir + "\n" +
                "The game is installed in a protected folder (such as Program Files).\n" +
                "What to do: right-click this program → 'Run as administrator'.",
                "No write permission: " + gameDir + "\n" +
                "The game lives in a protected folder (e.g. Program Files).\n" +
                "Fix: right click this program -> Run as administrator."));
        }
        catch (IOException)
        {
            throw new Exception(L.T(
                "The PCK is in use and can't be changed.\n" +
                "What to do: fully exit the game. If Steam is updating or verifying this game, wait for it to finish. Exit Steam if necessary.",
                "The PCK is locked by another process.\n" +
                "Fix: fully exit the game; if Steam is updating or validating it, wait; exit Steam if needed."));
        }

        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(gameDir)));
            // The append is ~1 MB, so a 200 MB margin is plenty. Only the old whole-pack backup route needs 605 MB
            if (drive.AvailableFreeSpace < 200L * 1024 * 1024)
                throw new Exception(L.T(
                    "Low disk space, less than 200 MB free (" + drive.Name + "), free up some space and try again.",
                    "Less than 200 MB free on " + drive.Name + ". Free up some space first."));
        }
        catch (Exception ex)
        {
            if (ex.Message.StartsWith("Low disk space") || ex.Message.StartsWith("Less than")) throw;
            // If the drive info can't be read, never mind. Don't block the install just because free space can't be checked
        }
    }

    // Free-of-charge notice. It lives in Core so the console and windowed versions match word for word.
    // The reason is that someone in the community was selling a similar mod as closed source for money, and this mod is the free alternative.
    public static string FreeNotice()
    {
        return L.T("This mod is completely free. If you paid for it, you've been scammed.",
                   "This mod is completely FREE. If you paid for it, you were scammed.");
    }

    public static void OpenSteamValidate()
    {
        try { Process.Start("steam://validate/" + AppId); } catch { }
    }

    // ── The game's own log folder (written by Godot, not the one this installer writes) ────────────────
    //
    // This is the one needed to track down mod bugs. The T45 Spine Breaker black screen investigation got stuck because we couldn't get the host machine's
    // godot.log — letting every player open their own log folder in two clicks is meant to close that gap.
    //
    // ⚠️⚠️ This **deliberately only opens the folder. No copying, no packaging, no uploading**. Don't change that.
    //   This exe is unsigned, and "read files in the user folder → package them → send them out" is exactly an infostealer's
    //   behaviour signature. Only calling explorer to open a folder leaves the antivirus profile completely unchanged.
    //   **To date this file makes zero network calls (grep finds no System.Net / HttpClient / Socket),
    //   so don't add the first one here.** Users can drag the file out themselves.
    //
    // /select also highlights godot.log. The folder also holds several rotated godot<date>.log files,
    // and without pointing to it users won't know which one to grab (and godot.log is the current session's).
    // If the file isn't there, fall back to just opening the folder. If the folder isn't there either (game never launched), return false and let the UI say so.
    public static string GameLogDir
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"Godot\app_userdata\Machine Party\logs");
        }
    }

    public static bool OpenGameLogFolder()
    {
        try
        {
            string dir = GameLogDir;
            string cur = Path.Combine(dir, "godot.log");

            if (File.Exists(cur))
            {
                Process.Start("explorer.exe", "/select,\"" + cur + "\"");
                return true;
            }
            if (Directory.Exists(dir))
            {
                Process.Start("explorer.exe", "\"" + dir + "\"");
                return true;
            }
            return false;
        }
        catch { return false; }
    }

    public static void LaunchGame()
    {
        try { Process.Start("steam://rungameid/" + AppId); } catch { }
    }
}

#if !GUI
// ═════════════════════════════════════════════════════════════════════════
// Console version
// ═════════════════════════════════════════════════════════════════════════
static class Installer
{
    static bool pause = true;

    static int Main(string[] args)
    {
        L.Auto();

        bool uninstall = false, force = false, status = false, validate = false;
        string gameDir = null;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            if (a == "--uninstall" || a == "-u") uninstall = true;
            else if (a == "--status" || a == "-s") status = true;
            else if (a == "--force") force = true;
            else if (a == "--validate") validate = true;
            else if (a == "--no-pause") pause = false;
            else if (a == "--lang" && i + 1 < args.Length) L.Zh = (args[++i].ToLowerInvariant() == "zh");
            else if ((a == "--game" || a == "-g") && i + 1 < args.Length) gameDir = args[++i];
            else if (a == "--help" || a == "-h" || a == "/?") { Usage(); return 0; }
            else { Console.WriteLine("unknown argument: " + args[i]); Usage(); return Done(2); }
        }

        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        Line(L.T("Machine Party-Overtime (8-player online + full rebalance)",
                 "Machine Party-Overtime - 8 players & rebalance"), ConsoleColor.Green);
        Console.WriteLine(L.T("Supported game version: ", "Target game version: ") + Core.GameVersion +
                          L.T("        mod version: ", "        mod version: ") + Core.ModTag() +
                          L.T("        installer: ", "        installer: ") + Core.ReleaseNum);
        Console.WriteLine();

        try
        {
            if (validate) { Core.OpenSteamValidate(); Console.WriteLine(L.T("Requested a Steam verification of the game files.", "Asked Steam to verify game files.")); return Done(0); }

            if (gameDir == null) gameDir = PickGameDir();
            if (gameDir == null || !File.Exists(Path.Combine(gameDir, Core.PckName)))
                return Fail(L.T(
                    "Couldn't find the Machine Party install folder.\nUse --game to specify it manually, for example:\n" +
                    "  mp8_install.exe --game \"D:\\Steam\\" + Core.GameRel + "\"\n" +
                    "(In Steam, right-click the game → Manage → Browse local files, and the folder that opens is the one)",
                    "Could not find the Machine Party install folder.\nSpecify it with --game, e.g.\n" +
                    "  mp8_install.exe --game \"D:\\Steam\\" + Core.GameRel + "\"\n" +
                    "(In Steam: right click the game -> Manage -> Browse local files.)"));

            Console.WriteLine(L.T("Game folder: ", "Game folder: ") + gameDir);
            Core.Log("gameDir=" + gameDir);
            Console.WriteLine();

            if (status) { PrintStatus(gameDir); return Done(0); }

            string busy = Core.BusyReason(gameDir);
            if (busy != null) return Fail(busy);

            if (uninstall) Core.Uninstall(gameDir, Say);
            else           Core.Install(gameDir, force, Say);

            if (!uninstall)
            {
                Console.WriteLine();
                Warn(L.T("Next steps:", "Next:"));
                Console.WriteLine(L.T(
                    "  · Launch the game from Steam as usual. If the version number in the bottom right of the main menu has +" + Core.ModTag() + ", it's installed.",
                    "  - Launch the game from Steam; the version in the bottom right of the main menu ends with +" + Core.ModTag() + "."));
                Console.WriteLine(L.T(
                    "  · **Everyone playing together must install the same version**. With a version mismatch the host rejects them from the lobby outright.",
                    "  - EVERYONE in the lobby must install the SAME version, or the host will refuse them."));
                Console.WriteLine(L.T(
                    "  · To go back to vanilla, run this program again with the --uninstall argument.",
                    "  - To revert: run this program again with --uninstall."));
                Console.WriteLine();
                Warn(L.T("⚠ A Steam game update, or clicking 'Verify integrity of game files', will wipe the mod. Just run this program again.",
                         "Steam updating the game (or verifying its files) removes the mod; just run this again."));

                // The free notice goes on the very last line — that's where the eye rests after installing
                Console.WriteLine();
                Line(Core.FreeNotice(), ConsoleColor.Red);
            }
            return Done(0);
        }
        catch (Exception ex)
        {
            Core.Log("ERROR " + ex);
            return Fail(ex.Message + L.T(
                "\n\n(Full log: " + Core.LogPath + ")",
                "\n\n(Full log: " + Core.LogPath + ")"));
        }
    }

    // If several copies are found, let the user choose instead of silently using the first one
    static string PickGameDir()
    {
        var dirs = Core.FindGameDirs();
        if (dirs.Count == 0) return null;
        if (dirs.Count == 1) return dirs[0];

        Warn(L.T("Found " + dirs.Count + " game installs, pick one:",
                 "Found " + dirs.Count + " installs, pick one:"));
        for (int i = 0; i < dirs.Count; i++) Console.WriteLine("  " + (i + 1) + ") " + dirs[i]);
        Console.Write(L.T("Enter the number: ", "Number: "));
        string s = Console.ReadLine();
        int n;
        if (int.TryParse(s == null ? "" : s.Trim(), out n) && n >= 1 && n <= dirs.Count) return dirs[n - 1];
        return null;
    }

    static void PrintStatus(string gameDir)
    {
        var st = Core.Detect(gameDir);
        Console.WriteLine(L.T("PCK:      ", "PCK:      ") + st.PckPath);
        Console.WriteLine(L.T("Size:     ", "Size:     ") + st.Length.ToString("N0"));
        switch (st.Kind)
        {
            case Core.Kind.Vanilla:
                Line(L.T("State:    vanilla (no mod installed)", "State:    vanilla (mod not installed)"), ConsoleColor.Gray); break;
            case Core.Kind.OursInstalled:
                Line(L.T("State:    Overtime installed " + Core.ModTag(), "State:    Overtime " + Core.ModTag() + " installed"), ConsoleColor.Green); break;
            case Core.Kind.OldVersion:
                Line(L.T("State:    Overtime installed " + st.InstalledTag + " (old version, this program is " + Core.ModTag() + ")",
                         "State:    Overtime " + st.InstalledTag + " installed (this program is " + Core.ModTag() + ")"), ConsoleColor.Yellow);
                Console.WriteLine(L.T("        Just run this program to upgrade.", "        Just run this program to upgrade."));
                break;
            case Core.Kind.Missing:
                Line(L.T("State:    can't find the PCK", "State:    PCK not found"), ConsoleColor.Red); break;
            default:
                Line(L.T("State:    can't recognise it", "State:    unrecognised"), ConsoleColor.Yellow);
                if (st.Note.Length > 0) Console.WriteLine("        " + st.Note);
                break;
        }
        Console.WriteLine(L.T("Restore data: ", "Restore:  ") + (st.HasRestore ? Path.GetFileName(Core.FindRes(gameDir)) : "-"));
        Console.WriteLine(L.T("Old backup: ", "Legacy:   ") + (st.HasLegacy ? Core.BakName + " (605 MB)" : "-"));
        Console.WriteLine(L.T("Log:      ", "Log:      ") + Core.LogPath);
    }

    static void Say(string s) { Console.WriteLine(s); Core.Log(s); }

    static void Line(string s, ConsoleColor c)
    {
        var old = Console.ForegroundColor; Console.ForegroundColor = c;
        Console.WriteLine(s); Console.ForegroundColor = old;
        Core.Log(s);
    }
    static void Warn(string s) { Line(s, ConsoleColor.Yellow); }

    static int Fail(string msg)
    {
        Console.WriteLine();
        Line("X " + msg, ConsoleColor.Red);
        return Done(1);
    }

    // When run by double-clicking the window flashes past, so pause to let people see the result
    static int Done(int code)
    {
        Core.FlushLog();
        if (pause && !Console.IsOutputRedirected)
        {
            Console.WriteLine();
            Console.WriteLine(L.T("(press any key to close)", "(press any key to close)"));
            try { Console.ReadKey(true); } catch { }
        }
        return code;
    }

    static void Usage()
    {
        Console.WriteLine();
        Console.WriteLine(L.T("Usage:", "Usage:"));
        Console.WriteLine(L.T("  mp8_install.exe                 install (automatically finds the game in Steam)",
                              "  mp8_install.exe                 install (auto-detects the game)"));
        Console.WriteLine(L.T("  mp8_install.exe --uninstall     restore to vanilla",
                              "  mp8_install.exe --uninstall     revert to vanilla"));
        Console.WriteLine(L.T("  mp8_install.exe --status        only show the current state, don't change anything",
                              "  mp8_install.exe --status        show current state, change nothing"));
        Console.WriteLine(L.T("  mp8_install.exe --game \"<folder>\"  specify the game folder manually",
                              "  mp8_install.exe --game \"<dir>\"   set the game folder manually"));
        Console.WriteLine(L.T("  mp8_install.exe --validate      have Steam verify the game files (gets vanilla back)",
                              "  mp8_install.exe --validate      ask Steam to verify game files"));
        Console.WriteLine(L.T("  mp8_install.exe --lang en|zh    interface language",
                              "  mp8_install.exe --lang en|zh    interface language"));
        Console.WriteLine(L.T("  mp8_install.exe --force         skip the vanilla check (at your own risk)",
                              "  mp8_install.exe --force         skip the vanilla check (at your own risk)"));
    }
}
#endif

#if GUI
// ═════════════════════════════════════════════════════════════════════════
// Windowed version, a single switch that toggles between "vanilla ⇄ MP8"
//
// Why it's worth doing. This mod's biggest cost to the experience is "once it's installed you can't play with friends who don't have it"
// (the version handshake is deliberately designed that way). Since restoring only writes a few KB, switching should take one second and one button.
//
// The UI deliberately uses a fixed light colour scheme and doesn't follow system dark mode — WinForms has no native dark mode support,
// and following it halfway would only produce black text on a black background.
// ═════════════════════════════════════════════════════════════════════════
static class Launcher
{
    [STAThread]
    static void Main()
    {
        L.Auto();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}

class MainForm : Form
{
    // ── Colours ────────────────────────────────────────────────────────────
    static readonly Color Ink      = Color.FromArgb( 24,  26,  33);
    static readonly Color InkSub   = Color.FromArgb(150, 156, 168);
    static readonly Color Muted    = Color.FromArgb(110, 118, 132);
    static readonly Color CardBg   = Color.FromArgb(246, 247, 249);
    static readonly Color CardLine = Color.FromArgb(226, 229, 234);
    static readonly Color Amber    = Color.FromArgb(202, 138,   4);
    static readonly Color AmberHot = Color.FromArgb(170, 116,   3);
    static readonly Color Slate    = Color.FromArgb( 71,  85, 105);
    static readonly Color SlateHot = Color.FromArgb( 51,  65,  85);
    static readonly Color Ghost    = Color.FromArgb(238, 240, 244);
    static readonly Color GhostHot = Color.FromArgb(226, 229, 234);
    static readonly Color Good     = Color.FromArgb( 22, 143,  74);
    static readonly Color Bad      = Color.FromArgb(185,  28,  28);
    static readonly Color Caution  = Color.FromArgb(180,  83,   9);
    static readonly Color FreeBg   = Color.FromArgb(254, 237, 237);
    static readonly Color FreeLine = Color.FromArgb(246, 203, 203);

    ComboBox dirBox;
    Label    stateLabel, noteLabel;
    Panel    accentBar;
    Button   toggleBtn, launchBtn, validateBtn, logBtn, gameLogBtn;
    Core.State st;
    bool busy;

    static Font F(float size, FontStyle style)
    {
        // Segoe UI is always present on Win10/11, and Chinese text automatically falls back to Microsoft YaHei
        return new Font("Segoe UI", size, style);
    }

    static Button FlatBtn(string text, Color bg, Color hover, Color fg, float size, FontStyle fs)
    {
        var b = new Button();
        b.Text = text;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = hover;
        b.FlatAppearance.MouseDownBackColor = hover;
        b.BackColor = bg;
        b.ForeColor = fg;
        b.Font = F(size, fs);
        b.Cursor = Cursors.Hand;
        b.UseVisualStyleBackColor = false;
        return b;
    }

    public MainForm()
    {
        Text = "Machine Party-Overtime";   // Brand name, the same in both languages
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(580, 430);
        BackColor = Color.White;
        Font = F(9f, FontStyle.Regular);

        // ── Header bar ───────────────────────────────────────────────────────
        var header = new Panel();
        header.SetBounds(0, 0, 580, 78);
        header.BackColor = Ink;
        Controls.Add(header);

        var title = new Label();
        title.Text = "Overtime";
        title.Font = F(15f, FontStyle.Bold);
        title.ForeColor = Color.White;
        title.AutoSize = false;
        title.SetBounds(24, 14, 320, 30);
        header.Controls.Add(title);

        var sub = new Label();
        sub.Text = L.T("Machine Party  ·  player cap 4 → 8", "Machine Party  ·  8 players & rebalance");
        sub.Font = F(8.5f, FontStyle.Regular);
        sub.ForeColor = InkSub;
        sub.AutoSize = false;
        sub.SetBounds(26, 46, 340, 20);
        header.Controls.Add(sub);

        var ver = new Label();
        // Three lines, mod version / installer release number / game version. The installer line is for troubleshooting —
        // an installer-only release (such as 1.3.1) doesn't change ModTag(), and without this line there's no telling whether a player has
        // the fixed build or the broken one, when often all we can get is a single screenshot.
        ver.Text = Core.ModTag() + "\n"
                 + L.T("installer ", "installer ") + Core.ReleaseNum + "\n"
                 + L.T("game ", "game ") + Core.GameVersion;
        ver.Font = F(8.5f, FontStyle.Regular);
        ver.ForeColor = InkSub;
        ver.TextAlign = ContentAlignment.MiddleRight;
        ver.AutoSize = false;
        ver.SetBounds(370, 14, 186, 52);   // Three lines. The header bar is 78 tall, so ending at 66 still leaves some margin
        header.Controls.Add(ver);

        // ── Game folder ───────────────────────────────────────────────────
        var dirLab = new Label();
        dirLab.Text = L.T("Game folder", "Game folder");
        dirLab.ForeColor = Muted;
        dirLab.AutoSize = false;
        dirLab.SetBounds(26, 94, 300, 18);
        Controls.Add(dirLab);

        dirBox = new ComboBox();
        dirBox.DropDownStyle = ComboBoxStyle.DropDownList;
        dirBox.FlatStyle = FlatStyle.Flat;
        dirBox.SetBounds(26, 114, 428, 24);
        dirBox.SelectedIndexChanged += delegate { Refresh2(); };
        Controls.Add(dirBox);

        var browse = FlatBtn(L.T("Browse…", "Browse"), Ghost, GhostHot, Ink, 9f, FontStyle.Regular);
        browse.SetBounds(462, 113, 92, 26);
        browse.Click += delegate { Browse(); };
        Controls.Add(browse);

        // ── Status card ───────────────────────────────────────────────────
        var card = new Panel();
        card.SetBounds(26, 152, 528, 92);
        card.BackColor = CardBg;
        card.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(card);

        accentBar = new Panel();
        accentBar.Dock = DockStyle.Left;
        accentBar.Width = 4;
        accentBar.BackColor = CardLine;
        card.Controls.Add(accentBar);

        stateLabel = new Label();
        stateLabel.Font = F(12f, FontStyle.Bold);
        stateLabel.AutoSize = false;
        stateLabel.SetBounds(20, 13, 490, 26);
        card.Controls.Add(stateLabel);

        noteLabel = new Label();
        noteLabel.ForeColor = Muted;
        noteLabel.Font = F(8.5f, FontStyle.Regular);
        noteLabel.AutoSize = false;
        noteLabel.SetBounds(22, 42, 492, 44);
        card.Controls.Add(noteLabel);

        // ── Action buttons ───────────────────────────────────────────────────
        toggleBtn = FlatBtn("", Amber, AmberHot, Color.White, 11f, FontStyle.Bold);
        toggleBtn.SetBounds(26, 260, 268, 48);
        toggleBtn.Click += delegate { Toggle(); };
        Controls.Add(toggleBtn);

        // One shade darker than the main button. Main button (amber/slate) → Launch game (near black) → Steam repair (light grey),
        // a three-step colour scale that makes "which one to click this time" obvious at a glance. The same colour kills the hierarchy (the first version did that).
        launchBtn = FlatBtn(L.T("Launch game", "Play"), Ink, Color.FromArgb(44, 47, 58), Color.White, 10f, FontStyle.Regular);
        launchBtn.SetBounds(306, 260, 122, 48);
        launchBtn.Click += delegate { Core.LaunchGame(); };
        Controls.Add(launchBtn);

        validateBtn = FlatBtn(L.T("Steam repair", "Steam repair"), Ghost, GhostHot, Ink, 9f, FontStyle.Regular);
        validateBtn.SetBounds(440, 260, 114, 48);
        validateBtn.Click += delegate { Core.OpenSteamValidate(); };
        Controls.Add(validateBtn);

        // Two log entry points, one for the installer itself and one for the game — the labels have to be clearly distinct.
        // There used to be just one, called "Open log". Once the second was added that name became ambiguous, so it was renamed as well.
        logBtn = FlatBtn(L.T("Install log", "Install log"), Color.White, Ghost, Muted, 8.5f, FontStyle.Regular);
        logBtn.SetBounds(24, 318, 100, 24);
        logBtn.Click += delegate {
            try { Core.FlushLog(); Process.Start("notepad.exe", Core.LogPath); } catch { }
        };
        Controls.Add(logBtn);

        // This is the one to hand in when reporting a bug. See the notes above Core.OpenGameLogFolder()
        // — it only opens the folder, with no copying and no uploading.
        gameLogBtn = FlatBtn(L.T("Game log", "Game log"), Color.White, Ghost, Muted, 8.5f, FontStyle.Regular);
        gameLogBtn.SetBounds(132, 318, 116, 24);
        gameLogBtn.Click += delegate {
            if (Core.OpenGameLogFolder()) return;
            MessageBox.Show(this,
                L.T("No game log yet — the game has to have been launched at least once.\n\nFolder:\n",
                    "No game logs yet — launch the game at least once.\n\nFolder:\n")
                + Core.GameLogDir,
                "Machine Party-Overtime",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        };
        Controls.Add(gameLogBtn);

        // ── Free notice (red, always visible) ──────────────────────────────────────
        // Someone in the community sells a similar mod as closed source for money, so this has to be seen at a glance.
        var freeBand = new Panel();
        freeBand.SetBounds(0, 354, 580, 76);
        freeBand.BackColor = FreeBg;
        Controls.Add(freeBand);

        var freeLine = new Panel();
        freeLine.Dock = DockStyle.Top;
        freeLine.Height = 1;
        freeLine.BackColor = FreeLine;
        freeBand.Controls.Add(freeLine);

        var free = new Label();
        free.Text = Core.FreeNotice();
        free.Font = F(10.5f, FontStyle.Bold);
        free.ForeColor = Bad;
        free.TextAlign = ContentAlignment.MiddleCenter;
        free.AutoSize = false;
        free.SetBounds(16, 10, 548, 56);
        freeBand.Controls.Add(free);

        // If the window is closed after only detecting and doing nothing, the buffered log still has to be written out by someone
        FormClosed += delegate { Core.FlushLog(); };

        foreach (string d in Core.FindGameDirs()) dirBox.Items.Add(d);
        // Assigning SelectedIndex triggers SelectedIndexChanged → Refresh2(),
        // so it only needs calling manually when "no folder was found at all". 1.3 called it in both places,
        // so every time the launcher opened, the log got two identical detect lines.
        if (dirBox.Items.Count > 0) dirBox.SelectedIndex = 0;
        else Refresh2();

        // Don't let focus land on the dropdown at startup. Once a DropDownList gets focus, the selected item is painted across the whole row in
        // the system highlight blue, and that blue bar grabs the first glance. Focus goes to the main button instead, and Enter runs it too.
        ActiveControl = toggleBtn;
    }

    string Dir { get { return dirBox.SelectedItem == null ? null : dirBox.SelectedItem.ToString(); } }

    void Browse()
    {
        var fd = new FolderBrowserDialog();
        fd.Description = L.T("Select the Machine Party_Windows folder (it contains Machine Party.pck)",
                             "Pick the Machine Party_Windows folder (it contains Machine Party.pck)");
        if (fd.ShowDialog() != DialogResult.OK) return;
        if (!File.Exists(Path.Combine(fd.SelectedPath, Core.PckName)))
        {
            MessageBox.Show(L.T("There's no " + Core.PckName + " in this folder.", "No " + Core.PckName + " in that folder."),
                            Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        int i = dirBox.Items.Add(fd.SelectedPath);
        dirBox.SelectedIndex = i;
    }

    void SetState(string text, Color color, string note)
    {
        stateLabel.Text = text;
        stateLabel.ForeColor = color;
        accentBar.BackColor = color;
        noteLabel.Text = note;
    }

    void Refresh2()
    {
        if (busy) return;
        if (Dir == null)
        {
            SetState(L.T("Game not found", "Game not found"), Bad,
                     L.T("Use 'Browse…' to pick the game folder manually (in Steam, right-click the game → Manage → Browse local files).",
                         "Use Browse to pick the game folder (Steam: right click the game -> Manage -> Browse local files)."));
            toggleBtn.Enabled = false;
            toggleBtn.Text = L.T("Enable Overtime", "Enable Overtime");
            toggleBtn.BackColor = Ghost;
            toggleBtn.ForeColor = Muted;
            return;
        }

        st = Core.Detect(Dir);
        // The console version isn't given to players anymore, so the log is the only diagnostic channel —
        // log one line on every detect, so "Open log" has something to show even before anything is installed.
        Core.Log(string.Format("detect: {0} | tag={1} | len={2} | restore={3} | legacy={4} | {5}",
            st.Kind, (st.InstalledTag.Length > 0 ? st.InstalledTag : "-"),
            st.Length, st.HasRestore, st.HasLegacy, Dir));
        toggleBtn.Enabled = true;
        toggleBtn.ForeColor = Color.White;

        switch (st.Kind)
        {
            case Core.Kind.OursInstalled:
                SetState(L.T("Overtime enabled", "Overtime enabled"), Good,
                         L.T("The version number in the bottom right of the main menu will have +" + Core.ModTag() + ".\n" +
                             "Everyone playing together must install the same version, or the host will refuse to let them into the lobby.",
                             "The main menu version ends with +" + Core.ModTag() + ".\n" +
                             "Everyone in the lobby needs this same version, or the host will refuse them."));
                toggleBtn.Text = L.T("Switch back to vanilla", "Switch to vanilla");
                toggleBtn.BackColor = Slate;
                toggleBtn.FlatAppearance.MouseOverBackColor = SlateHot;
                break;

            case Core.Kind.OldVersion:
                SetState(L.T("Overtime installed " + st.InstalledTag + " (old version)", "Overtime " + st.InstalledTag + " installed (outdated)"), Caution,
                         L.T("This program is " + Core.ModTag() + ". Click the button below to upgrade (it restores first, then installs the new version). "
                             + "Everyone playing together has to upgrade to the same version, or you can't join each other's lobbies.",
                             "This program is " + Core.ModTag() + ". The button below upgrades it "
                             + "(revert, then install). Everyone you play with needs the same version."));
                toggleBtn.Text = L.T("Upgrade to " + Core.ModTag(), "Upgrade to " + Core.ModTag());
                toggleBtn.BackColor = Amber;
                toggleBtn.FlatAppearance.MouseOverBackColor = AmberHot;
                break;

            case Core.Kind.Vanilla:
                SetState(L.T("Currently vanilla", "Currently vanilla"), Slate,
                         L.T("Click the button below to enable Overtime. You can switch back any time.",
                             "Press the button below to enable Overtime. You can switch back at any time."));
                toggleBtn.Text = L.T("Enable Overtime", "Enable Overtime");
                toggleBtn.BackColor = Amber;
                toggleBtn.FlatAppearance.MouseOverBackColor = AmberHot;
                break;

            case Core.Kind.Missing:
                SetState(L.T("Can't find the PCK", "PCK not found"), Bad, st.Note);
                toggleBtn.Enabled = false;
                toggleBtn.BackColor = Ghost;
                toggleBtn.ForeColor = Muted;
                break;

            default:
                SetState(L.T("Can't recognise the current game data", "Unrecognised game data"), Caution,
                         st.Note.Length > 0 ? st.Note
                                            : L.T("It's neither vanilla nor this mod.", "Neither vanilla nor this mod."));
                if (st.CanUninstall)
                {
                    toggleBtn.Text = L.T("Switch back to vanilla", "Switch to vanilla");
                    toggleBtn.BackColor = Slate;
                    toggleBtn.FlatAppearance.MouseOverBackColor = SlateHot;
                }
                else
                {
                    toggleBtn.Text = L.T("Enable Overtime", "Enable Overtime");
                    toggleBtn.BackColor = Amber;
                    toggleBtn.FlatAppearance.MouseOverBackColor = AmberHot;
                }
                break;
        }
    }

    void Toggle()
    {
        if (Dir == null) return;
        // Don't call it busy. MainForm already has a bool busy field (the "working" flag),
        // and a local with the same name would shadow it, so the later busy = true wouldn't even compile.
        string blocked = Core.BusyReason(Dir);
        if (blocked != null)
        {
            // The block reason (PID / path) was just written to the buffer, so flush it to disk right away — when the player clicks "Install log"
            // they need to be able to see it, otherwise it's yet another log with only detect lines that explains nothing.
            Core.FlushLog();
            MessageBox.Show(blocked, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // OldVersion goes through install (Install first uses the restore data to go back to vanilla, then applies the new patches), not uninstall
        bool remove = (st.Kind == Core.Kind.OursInstalled) || (st.Kind == Core.Kind.Unknown && st.CanUninstall);
        string dir = Dir;

        busy = true;
        toggleBtn.Enabled = false; launchBtn.Enabled = false; dirBox.Enabled = false;
        SetState(L.T("Working…", "Working..."), Caution, "");

        // Verifying the hash takes over ten seconds, so it mustn't freeze the UI
        var th = new Thread(delegate ()
        {
            string err = null;
            try
            {
                Action<string> say = delegate (string s)
                {
                    Core.Log(s);
                    try { BeginInvoke((Action)delegate { noteLabel.Text = s; }); } catch { }
                };
                if (remove) Core.Uninstall(dir, say);
                else        Core.Install(dir, false, say);
            }
            catch (Exception ex) { Core.Log("ERROR " + ex); err = ex.Message; }

            Core.FlushLog();
            try
            {
                BeginInvoke((Action)delegate
                {
                    busy = false;
                    launchBtn.Enabled = true;
                    dirBox.Enabled = true;
                    Refresh2();
                    if (err != null)
                        MessageBox.Show(err, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                });
            }
            catch { }
        });
        th.IsBackground = true;
        th.Start();
    }
}
#endif
