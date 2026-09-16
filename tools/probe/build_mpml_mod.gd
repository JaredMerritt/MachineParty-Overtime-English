extends SceneTree

# [MP8] Builds the MPML alternative install package (2026-09-03)
#
# Output goes to dist\mpml\overtime\{mod.json, main.gd, vanilla_md5.json, overtime_overlay.zip}
# Players just drop this whole overtime folder into mods\ in the game folder.
#
# It does three things
#   1. Computes the md5 of each of "the 54 files we're going to overwrite", one by one, from the **vanilla** .pck
#      — these are what the version gate in main.gd checks against. As soon as the game updates, all of these hashes change,
#      and the mod refuses to mount instead of covering a new game with old scripts.
#   2. Packs the 54 .gdc files in patch_gdc\ into overtime_overlay.zip
#   3. Copies mod.json and main.gd from mpml\overtime\ over to the output
#
# Usage (normally called by tools\build_mpml_mod.ps1)
#   godot.windows.opt.tools.64.exe --headless --path tools/probe --script build_mpml_mod.gd

# The repo root is derived from res:// rather than a hardcoded absolute path — this file ships with the public repo,
# so it has to work on whatever drive someone clones it to. (Godot is started with --path tools/probe, so res:// is tools/probe/.)
# The trailing "/" can't be dropped. Everything below joins paths directly as ROOT + "xxx/", and simplify_path would strip it.
var ROOT: String = ProjectSettings.globalize_path("res://").path_join("../..").simplify_path() + "/"
var ORIG: String = ROOT + "game_test/Machine Party.pck.orig"
var SRC_MOD: String = ROOT + "mpml/overtime/"
var OUT_DIR: String = ROOT + "dist/mpml/overtime/"

var lines: PackedStringArray = []
func say(s: String) -> void:
	lines.append(s); print(s)


# Relative path under patch\ -> [flat file name in patch_gdc, .gdc path in res://]
# patch_gdc is flattened by base name (gdre's --output doesn't keep the folder structure, see build.ps1),
# and the 54 base names have been verified to have no duplicates.
func manifest() -> Array:
	var out: Array = []
	var stack: Array = [""]
	while not stack.is_empty():
		var rel: String = stack.pop_back()
		var d := DirAccess.open(ROOT + "patch/" + rel)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".gd"):
				out.append([
					f.trim_suffix(".gd") + ".gdc",
					"res://" + rel + f.trim_suffix(".gd") + ".gdc",
				])
		for sub in d.get_directories():
			stack.append(rel + sub + "/")
	out.sort_custom(func(a, b): return a[1] < b[1])
	return out


func _init() -> void:

	var man := manifest()
	say("[1/4] Patch list: %d files" % man.size())

	# ---- Vanilla md5 (what the version gate checks against) ----
	if not ProjectSettings.load_resource_pack(ORIG, false):
		say("!! Can't mount the vanilla pack " + ORIG); quit(1); return

	var ver := "%d.%d.%d" % [
		int(Engine.get_version_info()["major"]),
		int(Engine.get_version_info()["minor"]),
		int(Engine.get_version_info()["patch"]),
	]
	var files := {}
	var missing := 0
	for e in man:
		var res_path: String = e[1]
		if not FileAccess.file_exists(res_path):
			say("   !! Not in the vanilla pack " + res_path)
			missing += 1
			continue
		files[res_path] = FileAccess.get_md5(res_path)
	if missing > 0:
		say("!! %d paths can't be found in the vanilla pack — game version mismatch? Stopping" % missing)
		quit(1); return
	say("[2/4] Vanilla md5: %d entries" % files.size())

	# ---- Assemble the output folder ----
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# The game version comes from the patch's MP8_VERSION_TAG (the authoritative marker of "which version this batch of .gdc files was compiled for")
	var tag := "?"
	var nm_src := FileAccess.get_file_as_string(ROOT + "patch/modules/multiplayer/network_manager.gd")
	for ln in nm_src.split("\n"):
		if ln.begins_with("const MP8_VERSION_TAG"):
			tag = ln.get_slice("\"", 1)
			break

	var mf := {
		"built_for_note": "These are the md5s of the **vanilla** files. The mod checks each one before mounting; a mismatch means the game isn't this version, and it refuses to mount.",
		"game_version": tag,
		"godot": ver,
		"files": files,
	}
	# ---- Overlay pack ----
	var z := ZIPPacker.new()
	if z.open(OUT_DIR + "overtime_overlay.zip") != OK:
		say("!! Packing failed"); quit(1); return
	for e in man:
		var src: String = ROOT + "patch_gdc/" + e[0]
		if not FileAccess.file_exists(src):
			say("!! patch_gdc is missing " + e[0] + " — run tools\\build.ps1 first")
			z.close(); quit(1); return
		z.start_file(String(e[1]).trim_prefix("res://"))
		z.write_file(FileAccess.get_file_as_bytes(src))
		z.close_file()
	z.close()

	# The manifest is written after the zip so it can record the zip's SHA256. main.gd refuses to mount an overlay
	# that doesn't match, which catches a corrupted, half-updated or swapped zip.
	mf["overlay_sha256"] = FileAccess.get_sha256(OUT_DIR + "overtime_overlay.zip")
	var f := FileAccess.open(OUT_DIR + "vanilla_md5.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(mf, "  "))
	f.close()
	say("[3/4] Wrote vanilla_md5.json (game_version=%s, overlay sha256 %s)" % [tag, mf["overlay_sha256"]])

	# ---- Copy mod.json / main.gd ----
	for n in ["mod.json", "main.gd"]:
		var b := FileAccess.get_file_as_bytes(SRC_MOD + n)
		if b.is_empty():
			say("!! Can't read " + SRC_MOD + n); quit(1); return
		var o := FileAccess.open(OUT_DIR + n, FileAccess.WRITE)
		o.store_buffer(b); o.close()

	say("[4/4] Done -> %s" % OUT_DIR)
	for n in ["mod.json", "main.gd", "vanilla_md5.json", "overtime_overlay.zip"]:
		say("      %-24s %d bytes" % [n, FileAccess.get_file_as_bytes(OUT_DIR + n).size()])
	quit(0)
