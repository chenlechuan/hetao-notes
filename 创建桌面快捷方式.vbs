' 核桃便签 · 创建桌面快捷方式
' 双击本文件：自动识别所在文件夹，在桌面创建「核桃便签」快捷方式（指向 Launch.vbs 启动器）。
Option Explicit

Dim fso, sh, base, desktop, lnkPath, target, iconPath, shortcut, ie4u

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

' 1) 识别所在目录
base = fso.GetParentFolderName(WScript.ScriptFullName)

' 2) 校验启动文件存在
target = base & "\Launch.vbs"
If Not fso.FileExists(target) Then
  MsgBox "没找到启动文件 Launch.vbs。" & vbCrLf & vbCrLf & _
         "请把本文件（创建桌面快捷方式.vbs）和「核桃便签」整个文件夹放在一起，再双击运行。", _
         16, "核桃便签"
  WScript.Quit 1
End If

' 3) 取桌面路径（用户桌面）
desktop = sh.SpecialFolders("Desktop")
If desktop = "" Then desktop = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\Desktop"

' 4) 删除旧快捷方式，确保图标全新生效
lnkPath = desktop & "\核桃便签.lnk"
If fso.FileExists(lnkPath) Then fso.DeleteFile lnkPath, True

' 5) 创建快捷方式：用系统 wscript 运行 Launch.vbs
Set shortcut = sh.CreateShortcut(lnkPath)
shortcut.TargetPath = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\wscript.exe"
shortcut.Arguments = """" & target & """"
shortcut.WorkingDirectory = base
shortcut.Description = "核桃便签"
iconPath = base & "\assets\icon.ico"
If fso.FileExists(iconPath) Then shortcut.IconLocation = iconPath

On Error Resume Next
shortcut.Save
If Err.Number <> 0 Then
  MsgBox "创建快捷方式失败：" & Err.Description, 16, "核桃便签"
  WScript.Quit 1
End If
On Error GoTo 0

' 6) 清空并刷新图标缓存，让新图标立即显示
On Error Resume Next
ie4u = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\ie4uinit.exe"
sh.Run """" & ie4u & """ -ClearIconCache", 0, True
sh.Run """" & ie4u & """ -show", 0, True
On Error GoTo 0

MsgBox "已在桌面创建「核桃便签」快捷方式。" & vbCrLf & vbCrLf & _
       "以后双击桌面的「核桃便签」就能直接打开。" & vbCrLf & vbCrLf & _
       "如果桌面图标暂时还是旧的，注销或重启电脑一次即可彻底刷新。" & vbCrLf & vbCrLf & _
       "注意：请不要移动或删除这个文件夹，否则桌面快捷方式会失效。", 64, "核桃便签"
