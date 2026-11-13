' 核桃便签 · 启动器
' 作用：环境自检 + 隐藏窗口启动 HetaoNotes.ps1
Option Explicit

Dim fso, sh, base, rc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)

' 1) 文件完整性：主脚本和界面文件必须与启动器同目录
If Not fso.FileExists(base & "\HetaoNotes.ps1") Or Not fso.FileExists(base & "\ui.xaml") Then
  MsgBox "启动失败：找不到 HetaoNotes.ps1 或 ui.xaml。" & vbCrLf & vbCrLf & _
         "这两个文件必须和 Launch.vbs 放在同一个文件夹里。" & vbCrLf & _
         "请先把压缩包完整解压（不要在压缩软件里直接双击运行），再双击 Launch.vbs。", _
         16, "核桃便签"
  WScript.Quit 1
End If

' 2) 系统要求：Windows PowerShell 5.1（Win10 / Win11 自带）
On Error Resume Next
rc = sh.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""exit [int]([version]$PSVersionTable.PSVersion -lt [version]'5.1')""", 0, True)
If Err.Number <> 0 Then rc = 1
On Error GoTo 0

If rc <> 0 Then
  MsgBox "启动失败：这台电脑的 Windows PowerShell 版本低于 5.1。" & vbCrLf & vbCrLf & _
         "Windows 10 / Windows 11 自带 5.1，可直接运行。" & vbCrLf & _
         "Windows 7 / 8.1 请先安装 Windows Management Framework 5.1（微软官网免费下载）后重试。", _
         16, "核桃便签"
  WScript.Quit 1
End If

' 3) 正常启动：无控制台窗口
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\HetaoNotes.ps1""", 0, False
