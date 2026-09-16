extends Node

# =====================================================================
#  Machine Party - Overtime  ·  MachinePartyModLoader adapter layer
# ---------------------------------------------------------------------
#  This is the **alternative install method**. overtime_launcher.exe is still the recommended one.
#  This route exists for one reason only. Players who go the exe route can't install MPML, so they can't use
#  the whole MachineParty+ / first-person / offline bots package. If you want them to coexist, take this route.
#
#  The whole mod does just one thing. In the _init() window of MPML's first autoload,
#  it overlays 54 compiled .gdc files onto res://.
#
#  Why not use extends?
#    Most of Overtime's patches "insert code into the middle of a vanilla method body". Expressing that with extends
#    would mean copying that decompiled vanilla code into the mod and redistributing it — that crosses a red line.
#    The overlay pack replaces whole files and doesn't need to reference a single line of vanilla.
#
#  Why the timing is safe (tested in practice, not just reasoned out)
#    The engine runs autoloads in two passes — all _init first, then all _ready. MPML makes itself
#    the first autoload and runs each mod's _mod_init() inside its _init().
#    At that moment none of the game's scripts have been loaded yet (tested, ResourceLoader.has_cached
#    is false for all of them), so the overlay arrives in time. priority = -1000 makes sure we run before other mods.
# =====================================================================

const MOD_ID := "overtime"
const PACK := "overtime_overlay.zip"
const MANIFEST := "vanilla_md5.json"

# Self-check sentinels. If any of these got into the ResourceCache before us, the overlay no longer works for them.
# Silent failure is the only dangerous failure mode of this mechanism, so it has to speak up.
const SENTINELS := [
	"res://modules/multiplayer/network_manager.gd",
	"res://scripts/scenes/game/game.gd",
	"res://scenes/lobby/scripts/lobby_scene.gd",
]

# Did mounting succeed? When _mod_init didn't make it to the end, the cross-check in _mod_ready must be skipped —
# otherwise it would follow a correct failure reason with another line saying "the files were only half replaced",
# a cause that doesn't exist (all three failure branches would hit it), and point the player in the wrong direction.
var _mounted: bool = false


func _mod_init(loader) -> void:

	# ---- 1. Loader version ----
	# Besides dir_of, API 1 has nothing else we need, but when the version is too old we should report one readable line
	# rather than silently not working.
	if loader.has_method("has_api") and not loader.call("has_api", 2):
		_fail(loader, "This Machine Party Mod Loader is too old (API 2 or newer is required). Please update the loader: https://github.com/Krunk-theduck/MachinePartyModLoader/releases")
		return

	var dir: String = loader.dir_of(MOD_ID)
	if dir.is_empty():
		_fail(loader, "Can't get the mod folder — the id in mod.json must be \"%s\"" % MOD_ID)
		return

	# ---- 2. Sentinels. Did we arrive too late? ----
	var late: Array = []
	for p in SENTINELS:
		if ResourceLoader.has_cached(p):
			late.append(p)
	if not late.is_empty():
		_fail(loader, "Another mod loaded game scripts before Overtime, so the overlay won't take effect: %s. Please make sure this mod's priority is -1000." % str(late))
		return

	# ---- 3. Version gate ----
	#
	# ⚠️ This step can't be skipped. The .gdc files in the overlay pack are compiled **for one specific game version**.
	# When the game updates, Steam replaces the whole pack but leaves the mods folder untouched — if we
	# mounted blindly at that point, we'd cover the new scripts with old ones, almost certainly crash, and the player would see no reason why.
	#
	# The exe route has a SHA gate that blocks this case (the installer refuses non-vanilla packs),
	# but the overlay route has **nothing**, so the gate has to live right here.
	#
	# The test is to check, one by one, the vanilla md5 of the files we're **about to overwrite**.
	# A mismatch = the current game isn't the version we compiled against.
	var manifest_path: String = dir.path_join(MANIFEST)
	if not FileAccess.file_exists(manifest_path):
		_fail(loader, "%s is missing — this mod package is incomplete, please download it again" % MANIFEST)
		return

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail(loader, "%s is not valid JSON — this mod package is incomplete, please download it again" % MANIFEST)
		return

	var expect: Dictionary = parsed.get("files", {})
	var built_for: String = str(parsed.get("game_version", "?"))
	if expect.is_empty():
		_fail(loader, "%s has no file list — this mod package is incomplete, please download it again" % MANIFEST)
		return

	var bad: Array = []
	for res_path in expect.keys():
		var want: String = str(expect[res_path])
		if not FileAccess.file_exists(res_path):
			bad.append("%s (does not exist)" % res_path)
		elif FileAccess.get_md5(res_path) != want:
			bad.append(res_path)
		if bad.size() >= 3:
			break            # The first three are enough to diagnose it without flooding the log

	if not bad.is_empty():
		_fail(loader, ("Game version mismatch — this mod was compiled for %s, and the current game isn't that version. "
			+ "Please download the Overtime that matches your current game version, or wait for a compatible release. "
			+ "(First mismatches: %s)") % [built_for, ", ".join(PackedStringArray(bad))])
		return

	# ---- 4. Mount ----
	var pack: String = dir.path_join(PACK)
	if not FileAccess.file_exists(pack):
		_fail(loader, "%s is missing — this mod package is incomplete, please download it again" % PACK)
		return

	# The overlay holds compiled scripts that run with full engine access, so it must match the SHA256 recorded
	# when the package was built. This catches a corrupted, half-updated or swapped zip. Someone replacing both
	# files together isn't caught, so only use packages you built or got from a source you trust.
	var want_overlay: String = str(parsed.get("overlay_sha256", ""))
	if want_overlay.is_empty() or FileAccess.get_sha256(pack) != want_overlay:
		_fail(loader, "%s doesn't match the checksum in %s — this mod package is damaged or was modified, please download it again" % [PACK, MANIFEST])
		return

	var ok := ProjectSettings.load_resource_pack(pack, true)
	if not ok:
		_fail(loader, "Failed to mount the overlay pack: %s" % pack)
		return

	_mounted = true
	loader.note("overtime: mounted (compiled for %s, checked %d vanilla files)" % [built_for, expect.size()])


func _mod_ready(loader) -> void:

	# If mounting didn't succeed, say nothing. _mod_init has already reported one accurate failure reason.
	if not _mounted:
		return

	# Cross-check. The version the overlay pack claims must match the MP8_VERSION_TAG in the network_manager.gd
	# it actually put in place. A mismatch means the zip in the mods folder and
	# mod.json aren't from the same batch (most commonly, only half the files were replaced), which leads to
	# "handshake strings match but behaviour is from different versions" — players can join the same lobby but don't sync, the hardest kind of bug to track down.
	var declared: String = "?"
	var mj: String = loader.dir_of(MOD_ID).path_join("mod.json")
	if FileAccess.file_exists(mj):
		var m = JSON.parse_string(FileAccess.get_file_as_string(mj))
		if typeof(m) == TYPE_DICTIONARY:
			declared = str(m.get("version", "?"))

	var actual: String = "?"
	var nm = get_tree().root.get_node_or_null("NetworkManager")
	if nm != null:
		actual = str(nm.get("MP8_VERSION_TAG"))

	# mod.json says "1.7.0-en" and MP8_VERSION_TAG says "overtime-1.7-en" — so drop the ".0" and compare the suffix
	if actual != "?" and declared != "?" and not actual.ends_with(declared.replace(".0-", "-").trim_suffix(".0")):
		loader.note("overtime: ⚠️ version mismatch — mod.json says %s, but what's actually running is %s. The files in the mods folder may have only been half replaced." % [declared, actual])
		printerr("[MP8] ⚠️ Overtime version mismatch: mod.json=%s actual=%s" % [declared, actual])
	else:
		loader.note("overtime: ready (%s)" % actual)


func _fail(loader, msg: String) -> void:
	loader.note("overtime: ❌ " + msg)
	printerr("[MP8] Overtime is not enabled: " + msg)
