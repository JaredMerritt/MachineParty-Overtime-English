# 自己编译 Overtime

从零编译出与 Release 里那个 `overtime_install.exe` 等价的安装器。全程在 Windows 上跑。

## 为什么需要这一步

本仓库公开的是**差异补丁**（`patches/*.patch`），不是完整脚本 ——
完整脚本里绝大部分是游戏自己的反编译源码，我们不分发它（见 README 的红线一节）。

所以构建的第一步是：**你用自己那份正版游戏解包出原版脚本**，补丁再打在它上面。
打完的结果与作者本机**逐字节相同**（作者出包时每次都会自动验证这一点）。

## 前置

| 需要 | 说明 |
| --- | --- |
| 正版 Machine Party **v2.1.2**（Steam）| 版本必须对得上，否则补丁打不上 |
| `git` | 用 `git apply` 打补丁 |
| GDRE Tools（gdsdecomp）**v2.6.4** Windows 版 | 解包与编译 GDScript 字节码。去它的 GitHub Releases 页下载，解压到 `tools\gdre\`，确保有 `tools\gdre\gdre_tools.exe` |
| PowerShell 5.1 | Win10/11 自带 |
| .NET Framework 4 的 `csc.exe` | Win10/11 自带（`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`），**不需要装 SDK** |

> ⚠️ **gdre 版本必须是 v2.6.4。** 不同版本的反编译结果会有出入，行号一对不上，
> 补丁就打不上了。

## 步骤

### 1. 解包出原版脚本

游戏目录 = Steam 里右键游戏 → 管理 → 浏览本地文件。

```powershell
tools\gdre\gdre_tools.exe --headless --recover="<游戏目录>\Machine Party.pck" --output="src"
```

跑完 `src\` 下应该有 `modules\multiplayer\network_manager.gd` 之类的文件。

> `src\` 与 `patch\` 都在 `.gitignore` 里 —— 它们含游戏源码，**不要提交**。

### 2. 打补丁

```powershell
powershell -ExecutionPolicy Bypass -File tools\apply_patches.ps1
```

51 个全部成功才算过。有失败的话脚本会告诉你是「游戏版本不对」还是「gdre 版本不对」。

### 3. 编译成字节码

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -CompileOnly
```

产物落在 `patch_gdc\`。`-CompileOnly` 表示只编译、不去动任何 PCK
（出安装器只需要字节码，不需要那 605 MB 的数据包）。

### 4. 出安装器

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
```

产物在 `dist\overtime-<版本>\`，两个 exe 各约 645 KB，补丁字节码全部内嵌：

| 文件 | csc 参数 | 进发布包吗 |
| --- | --- | --- |
| `overtime_launcher.exe` | `/target:winexe /define:GUI`（窗口版）| ✅ **发布包里只有它** |
| `overtime_install.exe` | `/target:exe`（控制台版，同一份源码的另一个 `Main`）| ❌ 自己排查/脚本化安装用 |

同时还会打出 `Machine-Party-Overtime-<版本>.zip` —— 里面就是启动器 + README，
**那个 zip 才是发给玩家的东西**。控制台版留在目录里供开发使用，别放进发布。

脚本带两道自检：产物目录里只允许 `.exe` / `.md`，且任一 exe 超过 5 MB 直接报错停下
—— 那是「混进了游戏资产」的信号。

> 编译带 `/codepage:65001`：源码是无 BOM 的 UTF-8，中文字面量全靠它。
> 本机的 csc 能自己认出来，但换台机器未必。

### 5.（可选）出 MPML 备选安装包

只有想走 **MachinePartyModLoader 备选装法**（跟 MachineParty+、第一人称等共存那条路，
见 README 的「跟 mod loader 的关系」）才需要这一步。主推的 `.exe` 路线到第 4 步就完了。

**额外前置**：Godot 4 编辑器版可执行文件（本项目用 4.7.2）。这一步用它跑一段脚本，
不用它打开工程。

```powershell
# 默认找 Steam 版 Godot；装在别处就用 -Godot 指过去，或设 $env:GODOT
powershell -ExecutionPolicy Bypass -File tools\build_mpml_mod.ps1 -Godot "D:\Godot\godot.exe"
```

产物在 `dist\mpml\`：

| 文件 | 是什么 |
| --- | --- |
| `overtime\mod.json` | 加载器读的清单（id / 版本 / 入口） |
| `overtime\main.gd` | **适配层，本仓库里可以逐行读的那个文件**。它不 `extends` 任何原版脚本，只在加载器的 `_init()` 窗口里把覆盖包挂进 `res://` |
| `overtime\vanilla_md5.json` | 54 个**原版**文件的 md5。挂载前逐条核对，游戏一更新就拒绝挂载 |
| `overtime\overtime_overlay.zip` | 第 3 步编出来的 54 个 `.gdc`，打成资源包 |
| `Machine-Party-Overtime-<版本>-MPML.zip` | 上面整个 `overtime\` 文件夹，即 Release 里那个附件 |

玩家侧：先自己装 MachinePartyModLoader，再把 zip 里的 `overtime` 文件夹放进游戏的
`mods` 目录。**我们不打包加载器本身** —— 它的仓库没有 LICENSE，未经作者许可无权再分发。

> ⚠️ **这一步不是确定性构建，别拿哈希对。**
> `overtime_overlay.zip` 和外层那个 zip 都会把**打包时间**写进 zip 头，
> 所以同一份输入连打两次，两个 zip 的 SHA256 就不一样 ——
> 实测两次构建：zip 逐字节不同，但**里面 94 个条目的内容逐条相同**。
> 要核对就解开来比内容，或者比 `overtime_overlay.zip` 里那 54 个 `.gdc`
> 与你第 3 步自己编出来的 `patch_gdc\` 是否一致。
> （`.exe` 那条路同理：csc 每次编出来的二进制也带时间戳。
> README 里那几行 SHA256 是给**校验你下载到的那一份**用的，
> 不是"自己编一遍应该得到同一个哈希"的意思。）

## 可选：本地测试台

想在不动自己 Steam 安装的前提下试跑，把游戏目录整个拷贝一份到 `game_test\`，
再把原版数据包留一份副本叫 `Machine Party.pck.orig`，然后**不带** `-CompileOnly` 跑：

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1
```

它会从 `.orig` 打出一个新 PCK 换上去。**永远从 `.orig` 打，不要在已经打过的包上叠。**

## 常见报错

**`apply_patches.ps1` 说「在 src\ 里找不到」**
游戏版本不是 v2.1.2。等 mod 出适配版本，或按 [`UPDATING.md`](UPDATING.md) 自己迁。

**`apply_patches.ps1` 说「补丁打不上」**
多半是 gdre 不是 v2.6.4。

**打出来的文件每行都多一个字节 / 与作者的产物哈希对不上**
是 git 的 `core.autocrlf` 把 LF 换成了 CRLF。`apply_patches.ps1` 已经用
`-c core.autocrlf=false -c core.eol=lf` 强制关掉了；如果你是手动 `git apply` 的，
记得自己带上这两个参数。

**`build.ps1` 说「patch\ 下有同名脚本」**
gdre 的 `--output` 只认目录、不保留层级，两个不同目录下的同名 `.gd` 会互相覆盖。
正常情况下不会遇到（现有 51 个文件基名互不冲突）；你自己加文件时才可能撞上。

**`build_mpml_mod.ps1` 说「缺少：…godot…exe」**
找不到 Godot。用 `-Godot "<你的 godot.exe>"` 指过去，或先设 `$env:GODOT`。

**`build_installer.ps1` 说找不到 `csc.exe`**
路径写死在脚本第 18 行。极老的系统或裁剪过的镜像可能没有 .NET Framework 4。
