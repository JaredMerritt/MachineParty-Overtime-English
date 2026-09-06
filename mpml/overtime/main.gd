extends Node

# =====================================================================
#  Machine Party - Overtime  ·  MachinePartyModLoader 适配层
# ---------------------------------------------------------------------
#  这是**备选安装方式**。主推的仍然是 overtime_launcher.exe。
#  这条路线存在的理由只有一个：走 exe 的玩家装不了 MPML，也就用不了
#  MachineParty+ / 第一人称 / 离线机器人那一整套。想要共存就走这条。
#
#  整个 mod 的逻辑就一件事：在 MPML 第一个 autoload 的 _init() 窗口里，
#  把 54 个已编译的 .gdc 覆盖进 res://。
#
#  为什么不用 extends：
#    Overtime 的补丁大量是「往原版方法体中间插代码」。用 extends 表达
#    就必须把原版那段反编译代码抄进 mod 里再分发 —— 撞红线。
#    覆盖包是整份替换，不需要引用原版任何一行。
#
#  为什么时机是安全的（实测，不是推演）：
#    引擎的 autoload 是两趟 —— 先全部 _init，再全部 _ready。MPML 把自己
#    设成第一个 autoload，并在 _init() 里跑各 mod 的 _mod_init()。
#    那一刻游戏的任何脚本都还没被加载过（实测 ResourceLoader.has_cached
#    全是 false），所以覆盖来得及。priority = -1000 保证我们跑在别的 mod 前面。
# =====================================================================

const MOD_ID := "overtime"
const PACK := "overtime_overlay.zip"
const MANIFEST := "vanilla_md5.json"

# 自检哨兵：这几条一旦在我们之前就进了 ResourceCache，覆盖对它们就已经失效。
# 静默失效是这套机制唯一的危险失败模式，所以必须出声。
const SENTINELS := [
	"res://modules/multiplayer/network_manager.gd",
	"res://scripts/scenes/game/game.gd",
	"res://scenes/lobby/scripts/lobby_scene.gd",
]

# 挂载成功了吗。_mod_init 没走到底时，_mod_ready 的交叉校验必须跳过 ——
# 否则它会在一句对的失败原因后面再追一句「文件只换了一半」，
# 而那个原因并不存在（三个失败分支全中），把玩家往错方向引。
var _mounted: bool = false


func _mod_init(loader) -> void:

	# ---- 1. 加载器版本 ----
	# API 1 没有 dir_of 之外我们要的东西，但版本太老时要报一行看得懂的话，
	# 而不是静默不工作。
	if loader.has_method("has_api") and not loader.call("has_api", 2):
		_fail(loader, "这个 Machine Party Mod Loader 太旧了（需要 API 2 或更新）。请更新加载器：https://github.com/Krunk-theduck/MachinePartyModLoader/releases")
		return

	var dir: String = loader.dir_of(MOD_ID)
	if dir.is_empty():
		_fail(loader, "拿不到 mod 目录 —— mod.json 里的 id 必须是 \"%s\"" % MOD_ID)
		return

	# ---- 2. 哨兵：我们来晚了吗 ----
	var late: Array = []
	for p in SENTINELS:
		if ResourceLoader.has_cached(p):
			late.append(p)
	if not late.is_empty():
		_fail(loader, "有别的 mod 抢在 Overtime 之前加载了游戏脚本，覆盖不会生效：%s。请确认本 mod 的 priority 是 -1000。" % str(late))
		return

	# ---- 3. 版本闸门 ----
	#
	# ⚠️ 这一步不能省。覆盖包里的 .gdc 是**针对某一个游戏版本**编译的。
	# 游戏一更新，Steam 会换掉整包，而 mods 文件夹原封不动 —— 如果这时候
	# 无脑挂载，我们就会拿旧版脚本盖掉新版，几乎必崩，而且玩家看不到任何原因。
	#
	# exe 那条路有 SHA 闸门挡着这种情况（安装器会拒绝非原版包），
	# 覆盖包这条路**什么都没有**，所以闸门必须自己长在这里。
	#
	# 判据：逐个核对我们**将要覆盖**的那些文件的原版 md5。
	# 对不上 = 当前游戏不是我们编译时那一版。
	var manifest_path: String = dir.path_join(MANIFEST)
	if not FileAccess.file_exists(manifest_path):
		_fail(loader, "缺少 %s —— 这个 mod 包不完整，请重新下载" % MANIFEST)
		return

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail(loader, "%s 不是合法 JSON —— 这个 mod 包不完整，请重新下载" % MANIFEST)
		return

	var expect: Dictionary = parsed.get("files", {})
	var built_for: String = str(parsed.get("game_version", "?"))
	if expect.is_empty():
		_fail(loader, "%s 里没有文件清单 —— 这个 mod 包不完整，请重新下载" % MANIFEST)
		return

	var bad: Array = []
	for res_path in expect.keys():
		var want: String = str(expect[res_path])
		if not FileAccess.file_exists(res_path):
			bad.append("%s（不存在）" % res_path)
		elif FileAccess.get_md5(res_path) != want:
			bad.append(res_path)
		if bad.size() >= 3:
			break            # 报前三个就够诊断了，不刷屏

	if not bad.is_empty():
		_fail(loader, ("游戏版本对不上 —— 本 mod 是给 %s 编译的，当前游戏不是那一版。"
			+ "请下载与当前游戏版本匹配的 Overtime，或等适配版本发布。"
			+ "（首批对不上的：%s）") % [built_for, ", ".join(PackedStringArray(bad))])
		return

	# ---- 4. 挂载 ----
	var pack: String = dir.path_join(PACK)
	if not FileAccess.file_exists(pack):
		_fail(loader, "缺少 %s —— 这个 mod 包不完整，请重新下载" % PACK)
		return

	var ok := ProjectSettings.load_resource_pack(pack, true)
	if not ok:
		_fail(loader, "覆盖包挂载失败：%s" % pack)
		return

	_mounted = true
	loader.note("overtime: 已挂载（为 %s 编译，核对了 %d 个原版文件）" % [built_for, expect.size()])


func _mod_ready(loader) -> void:

	# 没挂载成功就什么都别说。失败原因 _mod_init 里已经报过一句准的了。
	if not _mounted:
		return

	# 交叉校验：覆盖包声称的版本，必须与它实际盖进去的 network_manager.gd
	# 里那个 MP8_VERSION_TAG 一致。不一致说明 mods 文件夹里的 zip 与
	# mod.json 不是同一批（最常见：只换了一半文件），那会导致
	# 「握手串对得上、行为却不同版」—— 能进同一个房但不同步，最难查的一类。
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

	# mod.json 写 "1.6.0"，MP8_VERSION_TAG 写 "overtime-1.6" —— 比后缀
	if actual != "?" and declared != "?" and not actual.ends_with(declared.trim_suffix(".0")):
		loader.note("overtime: ⚠️ 版本不一致 —— mod.json 说 %s，实际跑起来的是 %s。mods 文件夹里的文件可能只换了一半。" % [declared, actual])
		printerr("[MP8] ⚠️ Overtime 版本不一致：mod.json=%s 实际=%s" % [declared, actual])
	else:
		loader.note("overtime: 就绪（%s）" % actual)


func _fail(loader, msg: String) -> void:
	loader.note("overtime: ❌ " + msg)
	printerr("[MP8] Overtime 没有启用：" + msg)
