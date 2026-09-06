extends SceneTree

# [MP8] 生成 MPML 备选安装包（2026-09-03）
#
# 产物：dist\mpml\overtime\{mod.json, main.gd, vanilla_md5.json, overtime_overlay.zip}
# 玩家把这个 overtime 文件夹整个丢进游戏目录的 mods\ 里就行。
#
# 三件事：
#   1. 从**原版** .pck 里逐个算出「我们将要覆盖的那 54 个文件」的 md5
#      —— 这是 main.gd 版本闸门的判据。游戏一更新这些哈希就全变，
#      mod 会拒绝挂载而不是拿旧脚本盖新游戏。
#   2. 把 patch_gdc\ 的 54 个 .gdc 打成 overtime_overlay.zip
#   3. 抄 mpml\overtime\ 下的 mod.json 与 main.gd 过去
#
# 用法（一般由 tools\build_mpml_mod.ps1 调）：
#   godot.windows.opt.tools.64.exe --headless --path tools/probe --script build_mpml_mod.gd

# 仓库根从 res:// 反推，不写死绝对路径 —— 本文件随公开仓发出去，
# 别人克隆到哪个盘都得能跑。（Godot 用 --path tools/probe 起，res:// 就是 tools/probe/。）
# 末尾那个 "/" 不能省：下面全是 ROOT + "xxx/" 直接拼，simplify_path 会把它吃掉。
var ROOT: String = ProjectSettings.globalize_path("res://").path_join("../..").simplify_path() + "/"
var ORIG: String = ROOT + "game_test/Machine Party.pck.orig"
var SRC_MOD: String = ROOT + "mpml/overtime/"
var OUT_DIR: String = ROOT + "dist/mpml/overtime/"

var lines: PackedStringArray = []
func say(s: String) -> void:
	lines.append(s); print(s)


# patch\ 下的相对路径 -> [patch_gdc 里的平铺文件名, res:// 里的 .gdc 路径]
# patch_gdc 是按基名平铺的（gdre 的 --output 不保留层级，见 build.ps1），
# 54 个基名已核实无重名。
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
	say("[1/4] 补丁清单：%d 个文件" % man.size())

	# ---- 原版 md5（版本闸门的判据）----
	if not ProjectSettings.load_resource_pack(ORIG, false):
		say("!! 挂不上原版包 " + ORIG); quit(1); return

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
			say("   !! 原版包里没有 " + res_path)
			missing += 1
			continue
		files[res_path] = FileAccess.get_md5(res_path)
	if missing > 0:
		say("!! 有 %d 个路径在原版包里找不到 —— 游戏版本对不上？停手" % missing)
		quit(1); return
	say("[2/4] 原版 md5：%d 条" % files.size())

	# ---- 组装输出目录 ----
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# 游戏版本从 patch 的 MP8_VERSION_TAG 取（那是"这批 .gdc 是给谁编的"的权威标识）
	var tag := "?"
	var nm_src := FileAccess.get_file_as_string(ROOT + "patch/modules/multiplayer/network_manager.gd")
	for ln in nm_src.split("\n"):
		if ln.begins_with("const MP8_VERSION_TAG"):
			tag = ln.get_slice("\"", 1)
			break

	var mf := {
		"built_for_note": "这些是**原版**文件的 md5。mod 挂载前逐条核对；对不上说明游戏不是这一版，拒绝挂载。",
		"game_version": tag,
		"godot": ver,
		"files": files,
	}
	var f := FileAccess.open(OUT_DIR + "vanilla_md5.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(mf, "  "))
	f.close()
	say("[3/4] 写出 vanilla_md5.json（game_version=%s）" % tag)

	# ---- 覆盖包 ----
	var z := ZIPPacker.new()
	if z.open(OUT_DIR + "overtime_overlay.zip") != OK:
		say("!! 打包失败"); quit(1); return
	for e in man:
		var src: String = ROOT + "patch_gdc/" + e[0]
		if not FileAccess.file_exists(src):
			say("!! patch_gdc 里缺 " + e[0] + " —— 先跑 tools\\build.ps1")
			z.close(); quit(1); return
		z.start_file(String(e[1]).trim_prefix("res://"))
		z.write_file(FileAccess.get_file_as_bytes(src))
		z.close_file()
	z.close()

	# ---- 抄 mod.json / main.gd ----
	for n in ["mod.json", "main.gd"]:
		var b := FileAccess.get_file_as_bytes(SRC_MOD + n)
		if b.is_empty():
			say("!! 读不到 " + SRC_MOD + n); quit(1); return
		var o := FileAccess.open(OUT_DIR + n, FileAccess.WRITE)
		o.store_buffer(b); o.close()

	say("[4/4] 完成 -> %s" % OUT_DIR)
	for n in ["mod.json", "main.gd", "vanilla_md5.json", "overtime_overlay.zip"]:
		say("      %-24s %d 字节" % [n, FileAccess.get_file_as_bytes(OUT_DIR + n).size()])
	quit(0)
