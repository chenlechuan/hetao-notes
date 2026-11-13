#requires -Version 5.1
<#
   核桃便签 v1.01 (HetaoNotes)
   单次 / 循环任务 + 历史记录 + 6 套主题 + 透明度调节 +
   托盘 / 全局快捷键 / 搜索 / 拖动排序 / 导出备份
   纯 Windows 原生 WPF，无需安装任何环境。
#>
param(
  [switch]$ResetData,
  [switch]$SmokeTest,
  # 仅配合 -SmokeTest 截图用：指定截图使用的主题（如 noteyellow）
  [string]$Theme = ''
)

# 版本号：全项目唯一的版本来源（设置面板副标题由它渲染，README 的版本记录要与它一致）。
# 口径为「主.次」，允许补一个修订号（如 1.0.1）：1.0 为首个正式发布版，小数点后两位表示小版本迭代。
$script:AppVersion = '1.01'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Namespace GN -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
'@

# ---------- 高 DPI ----------
try { [void][GN.Native]::SetProcessDpiAwareness(2) } catch {
  try { [void][GN.Native]::SetProcessDPIAware() } catch { }
}

# ---------- 单实例：找到已有窗口（含托盘隐藏的窗口）并唤醒 ----------
function Find-AppWindow {
  $script:ExistingWindow = [System.IntPtr]::Zero
  try {
    $enumCallback = [GN.Native+EnumWindowsProc]{
      param([System.IntPtr]$hWnd, [System.IntPtr]$lParam)
      try {
        $length = [GN.Native]::GetWindowTextLength($hWnd)
        if ($length -gt 0) {
          $buffer = [System.Text.StringBuilder]::new($length + 2)
          [void][GN.Native]::GetWindowText($hWnd, $buffer, $buffer.Capacity)
          if ($buffer.ToString() -eq '核桃便签') {
            $script:ExistingWindow = $hWnd
            return $false
          }
        }
      } catch { }
      return $true
    }
    [void][GN.Native]::EnumWindows($enumCallback, [System.IntPtr]::Zero)
  } catch { }
  return $script:ExistingWindow
}

$script:Mutex = [System.Threading.Mutex]::new($false, 'HetaoNotes_SingleInstance_2026')
$script:IsFirstInstance = $false
try { $script:IsFirstInstance = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $script:IsFirstInstance = $true }
if (-not $script:IsFirstInstance -and -not $SmokeTest) {
  # 存在另一个实例（互斥体被占）。它可能刚好在「已拿到互斥体但窗口还没建出来」或「窗口已销毁、
  # 进程正在退出」的瞬间，此时立刻 exit 会出现「双击了却没反应」。所以在 3 秒内轮询唤醒，
  # 若始终找不到窗口，再尝试补抢互斥体：抢到了说明对方确实已经退出，本进程直接接管。
  $woke = $false
  for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $existing = Find-AppWindow
    if ($existing -ne [System.IntPtr]::Zero) {
      try {
        [void][GN.Native]::ShowWindow($existing, 9)
        [void][GN.Native]::SetForegroundWindow($existing)
      } catch { }
      $woke = $true
      break
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not $woke) {
    # 用轮询而不是一次性 WaitOne(2000)：对方退出往往就落在这几秒的边界上，
    # 单次等待容易刚好错过释放时刻（实测就差了 30 毫秒）。这里最多再等 4 秒。
    for ($tick = 0; $tick -lt 16; $tick++) {
      try {
        if ($script:Mutex.WaitOne(250)) { $script:IsFirstInstance = $true; break }
      } catch [System.Threading.AbandonedMutexException] { $script:IsFirstInstance = $true; break } catch { }
      if ($script:IsFirstInstance) { break }
    }
  }
  if (-not $script:IsFirstInstance) { exit 0 }
}

# ---------- 路径与数据 ----------
$script:AppDir = if ([string]::IsNullOrEmpty($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$script:AssetDir = Join-Path $script:AppDir 'assets'
$script:UiFile = Join-Path $script:AppDir 'ui.xaml'
$script:DataDir = Join-Path $script:AppDir 'data'
try {
  New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
  $probeFile = Join-Path $script:DataDir '.write-test'
  [System.IO.File]::WriteAllText($probeFile, 'ok')
  Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
} catch {
  $script:DataDir = Join-Path $env:APPDATA 'HetaoNotes'
  try { New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null } catch { }
}
if ($SmokeTest) {
  # 自检模式：用临时数据目录，绝不碰真实数据
  $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ('HetaoNotes_Smoke_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}
$script:DataFile = Join-Path $script:DataDir 'notes.json'
$script:BakFile = Join-Path $script:DataDir 'notes.bak.json'
$script:RecoveredFromBackup = $false
$script:ErrorLog = Join-Path $script:DataDir 'error.log'
$script:ExportDir = Join-Path $script:DataDir 'exports'
$script:Culture = [System.Globalization.CultureInfo]::GetCultureInfo('zh-CN')
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- 界面语言（中文 / English） ----------
# 只翻译界面文案，便签内容与用户输入一律原样保留。语言设置存 settings.language：auto / zh / en。
$script:LangCode = 'zh'
$script:FmtDateLong = 'yyyy年M月d日 dddd'
$script:FmtDateShort = 'M月d日 HH:mm'
$script:FmtDayShort = 'M月d日 dddd'

# 中文原文 -> 英文。key 用界面上出现的中文原样，便于对照维护；没收录的条目会原样保留中文。
$script:I18nEn = @{
  '拖动移动窗口' = 'Drag to move';
  '你好' = 'Hello';
  '今天要做什么？' = 'What is on today?';
  '窗口置顶' = 'Always on top';
  '半透明玻璃' = 'Glass effect';
  '锁定页面（禁止拖动与编辑）' = 'Lock (no drag, no edit)';
  '专注模式（小窗）' = 'Focus mode';
  '设置' = 'Settings';
  '最小化' = 'Minimize';
  '关闭' = 'Close';
  '待办' = 'To-do';
  '历史' = 'History';
  '回收站' = 'Recycle bin';
  '组织管理（标签）' = 'Tags';
  '搜索（Ctrl+F）' = 'Search (Ctrl+F)';
  '搜索便签或历史…' = 'Search notes or history…';
  '全部标签 ▾' = 'All tags ▾';
  '按标签筛选' = 'Filter by tag';
  '清除搜索' = 'Clear search';
  '还没有便签' = 'No notes yet';
  '在下方输入一条，按 Enter 保存' = 'Add one below, press Enter to save';
  '添加一条便签，Enter 保存，Shift + Enter 换行…' = 'Add a note. Enter to save, Shift + Enter for a new line…';
  '单次 ▾' = 'One-time ▾';
  '选择任务类型' = 'Choose task type';
  '添加便签' = 'Add note';
  '左键开始 / 暂停，右键切换时长' = 'Left click to start or pause, right click to change length';
  '退出专注模式（Esc）' = 'Exit focus mode (Esc)';
  '拖动调整窗口大小' = 'Drag to resize';
  '到点提醒' = 'Reminder';
  '收起提醒' = 'Collapse';
  '设置提醒时间' = 'Set reminder';
  '格式：2026-10-31 09:00，也可以只写 10-31 09:00' = 'Format: 2026-10-31 09:00, or 10-31 09:00';
  '确定' = 'OK';
  '取消' = 'Cancel';
  '自定义番茄钟时长' = 'Custom pomodoro length';
  '输入分钟数，如 30' = 'Minutes, e.g. 30';
  '核桃便签' = 'Hetao Notes';
  '关闭设置' = 'Close settings';
  '跟随系统' = 'System';
  '外观' = 'Appearance';
  '主题' = 'Theme';
  '玻璃效果' = 'Glass effect';
  '背景透明度' = 'Background opacity';
  '清透 55%' = 'Clear 55%';
  '标准 86%' = 'Standard 86%';
  '沉稳 92%' = 'Deep 92%';
  '时钟' = 'Clock';
  '24 小时制' = '24-hour clock';
  '显示秒' = 'Show seconds';
  '本周日历' = 'Week calendar';
  '主页时间下方显示周一到周日，今天高亮' = 'Show Mon-Sun under the clock, today highlighted';
  '提醒' = 'Reminders';
  '提示音' = 'Sound';
  '完成音效' = 'Completion sound';
  '勾掉一条便签时轻响一声' = 'Play a soft sound when a note is checked off';
  '番茄钟' = 'Pomodoro';
  '专注模式下显示倒计时' = 'Show countdown in focus mode';
  '提前提醒：准时' = 'Remind ahead: on time';
  '准时' = 'On time';
  '提前 5 分' = '5 min early';
  '提前 15 分' = '15 min early';
  '提前 30 分' = '30 min early';
  '关机错过的提醒：24 小时内补弹' = 'Missed while off: within 24h';
  '24 小时' = '24 hours';
  '3 天' = '3 days';
  '7 天' = '7 days';
  '永久' = 'Forever';
  '有 0 条提醒已错过' = '0 reminders missed';
  '查看' = 'View';
  '在便签右侧点小铃铛可以为单条便签设置提醒时间。' = 'Click the bell on a note to set a reminder.';
  '任务与历史' = 'Tasks and history';
  '单次任务未完成会自动顺延；完成后次日归档到历史。循环任务按周期自动出现，未完成也会在新周期再新增一条。' = 'Unfinished one-time tasks roll over each day; completed ones are archived the next day. Recurring tasks reappear every period, and an unfinished one is added again in the new period.';
  '导出 Markdown' = 'Export Markdown';
  '导出 CSV' = 'Export CSV';
  '清空历史' = 'Clear history';
  '桌面集成' = 'Desktop integration';
  '系统托盘图标' = 'Tray icon';
  '关闭时隐藏到托盘' = 'Hide to tray on close';
  '全局快捷键' = 'Global hotkey';
  'Ctrl + Alt + N 显示 / 隐藏窗口' = 'Ctrl + Alt + N to show or hide';
  '开机自启' = 'Start with Windows';
  '数据' = 'Data';
  '备份全部数据' = 'Back up all data';
  '恢复最近备份' = 'Restore latest backup';
  '从文件恢复…' = 'Restore from file…';
  '打开数据文件夹' = 'Open data folder';
  '所有数据都保存在本地，不联网。数据文件：HetaoNotes\data\notes.json' = 'Everything stays local, no network. Data file: HetaoNotes\data\notes.json';
  '组织管理' = 'Tags';
  '新建标签，把条目归档到标签，可按标签筛选' = 'Create tags, file notes under them, filter by tag';
  '关闭组织管理' = 'Close tags';
  '新标签名称…' = 'New tag name…';
  '新建' = 'Create';
  '清除筛选' = 'Clear filter';
  '每天' = 'Daily';
  '每周' = 'Weekly';
  '每月' = 'Monthly';
  '循环' = 'recurring';
  '单次' = 'One-time';
  '笔记' = 'Note';
  '完成于 ' = 'Completed ';
  '逾期，仍未完成' = 'Overdue';
  '新的一天：' = 'A new day: ';
  '点一下文字就能编辑，修改会自动保存 ✍' = 'Click the text to edit, changes save automatically';
  '每天喝一杯水，开始今天' = 'Drink a glass of water and start the day';
  '点击右上角「设置」可以换主题、调透明度' = 'Open Settings (top right) to change the theme and opacity';
  '夜深了' = 'Late night';
  '早上好' = 'Good morning';
  '上午好' = 'Good morning';
  '中午好' = 'Good noon';
  '下午好' = 'Good afternoon';
  '晚上好' = 'Good evening';
  '没有找到匹配的便签' = 'No matching notes';
  '换个关键词试试' = 'Try another keyword';
  '复制内容' = 'Copy text';
  '已复制到剪贴板' = 'Copied to clipboard';
  '复制失败，剪贴板可能被别的程序占用' = 'Copy failed, the clipboard may be in use';
  '按住拖动排序，拖到窗口外可把笔记变成独立小窗' = 'Drag to reorder. Drag a note out of the window to open it separately';
  '拖动排序' = 'Drag to reorder';
  '取消完成' = 'Mark as not done';
  '标记完成' = 'Mark as done';
  '点击转为待办条目' = 'Click to convert to a to-do';
  '点击修改循环周期' = 'Click to change the repeat period';
  '点击设置为循环任务或转为笔记' = 'Click to make it recurring or convert to a note';
  '点击管理这条的标签' = 'Manage tags for this note';
  '便签内容' = 'Note text';
  'Shift + Enter 换行，Enter 回到输入框' = 'Shift + Enter for a new line, Enter to go back';
  '修改标签归档' = 'Change tags';
  '归档到标签' = 'Tags';
  '修改 / 取消提醒' = 'Edit or remove reminder';
  '设置提醒' = 'Set reminder';
  '置顶这条便签' = 'Pin this note';
  '删除本次（循环仍会继续）' = 'Delete this one (the series continues)';
  '删除便签' = 'Delete note';
  '重新加入待办' = 'Add back to the list';
  '从历史中删除' = 'Delete from history';
  '删除历史记录' = 'Delete history record';
  '没有找到匹配的历史记录' = 'No matching history';
  '还没有完成记录，完成任务后次日会归档到这里' = 'No completed records yet. Finished tasks are archived here the next day.';
  '未知' = 'Unknown';
  '删除于 ' = 'Deleted ';
  '未知时间' = 'Unknown time';
  '未知日期' = 'Unknown date';
  ' · 来自历史' = ' · from history';
  ' · 笔记' = ' · note';
  '还原' = 'Restore';
  '彻底删除（不可恢复）' = 'Delete permanently';
  '彻底删除' = 'Delete permanently';
  '回收站是空的，删除的条目会先放到这里' = 'The recycle bin is empty. Deleted items land here first.';
  '清空回收站' = 'Empty recycle bin';
  '已隐藏到托盘，Ctrl + Alt + N 可以呼出' = 'Hidden to tray. Press Ctrl + Alt + N to bring it back';
  '显示 / 隐藏' = 'Show / hide';
  '打开设置' = 'Open settings';
  '退出核桃便签' = 'Quit Hetao Notes';
  '已移入回收站，可随时还原' = 'Moved to the recycle bin';
  '这条已经在待办里了' = 'This one is already in the list';
  '已重新加入待办' = 'Added back to the list';
  '已设为' = 'Set to ';
  '已停止循环，保留当前任务' = 'Stopped repeating, the current task is kept';
  '已还原到历史记录' = 'Restored to history';
  '已还原到列表' = 'Restored to the list';
  '回收站已经是空的' = 'The recycle bin is already empty';
  '回收站已清空' = 'Recycle bin emptied';
  '已转为笔记（没有勾选框，不参与完成率）' = 'Converted to a note (no checkbox, not counted in progress)';
  '已转为待办' = 'Converted to a to-do';
  '已经有同名标签了' = 'A tag with this name already exists';
  '已删除标签「' = 'Deleted tag "';
  '」，条目本身保留' = '". The notes are kept';
  '还没有标签。在上面输入名称（比如「工作」「读书」）再点「新建」。' = 'No tags yet. Type a name above (for example "Work" or "Reading") and click Create.';
  '直接改字即可重命名' = 'Edit the text to rename';
  '标签名称' = 'Tag name';
  '取消该标签筛选' = 'Clear this tag filter';
  '只看这个标签' = 'Show only this tag';
  '按该标签筛选' = 'Filter by this tag';
  '删除标签（条目会保留）' = 'Delete tag (notes are kept)';
  '删除标签' = 'Delete tag';
  '还没有标签' = 'No tags yet';
  '清空这条的标签' = 'Clear tags on this note';
  '新建标签…' = 'New tag…';
  '笔记 · 拖动可移动' = 'Note · drag to move';
  '半透明' = 'Translucent';
  '置顶显示' = 'Always on top';
  '锁定（禁止拖动和缩放）' = 'Lock (no drag, no resize)';
  '关闭这个小窗（笔记本身仍保留在完整模式）' = 'Close this window (the note stays in the main window)';
  '关闭笔记小窗' = 'Close note window';
  '拖动调整大小' = 'Drag to resize';
  '笔记 · 已锁定' = 'Note · locked';
  '今天 ' = 'Today ';
  '明天 ' = 'Tomorrow ';
  '后天 ' = 'In 2 days ';
  '昨天 ' = 'Yesterday ';
  '已取消提醒' = 'Reminder removed';
  '已设置提醒：' = 'Reminder set: ';
  '（随循环延续）' = ' (repeats with the series)';
  '已错过 ' = 'Missed ';
  '提醒时间 ' = 'Reminder ';
  '稍后 5 分' = 'Snooze 5 min';
  '完成' = 'Done';
  '已错过 · ' = 'Missed · ';
  '原定 ' = 'Originally ';
  '原定时间未知' = 'Original time unknown';
  '重新提醒' = 'Remind again';
  '忽略' = 'Dismiss';
  '提前 5 分钟' = '5 min early';
  '提前 15 分钟' = '15 min early';
  '提前 30 分钟' = '30 min early';
  '提前提醒：' = 'Remind ahead: ';
  '不限时间，全部补弹' = 'No limit, show all';
  '3 天内补弹' = 'Within 3 days';
  '7 天内补弹' = 'Within 7 days';
  '24 小时内补弹' = 'Within 24 hours';
  '关机错过的提醒：' = 'Missed while off: ';
  '已设为：' = 'Set to: ';
  '为「' = 'Set a reminder for "';
  '」设置提醒' = '';
  '取消窗口置顶' = 'Disable always on top';
  '已锁定，点一下解锁' = 'Locked, click to unlock';
  '已锁定：拖动与编辑已禁用' = 'Locked: dragging and editing disabled';
  '已解锁' = 'Unlocked';
  '专注' = 'Focus';
  '左键暂停 · 右键换时长' = 'Left click to pause, right click to change length';
  '休息' = 'Break';
  '休息结束，回来继续' = 'Break is over, back to it';
  '专注结束，歇 5 分钟' = 'Focus session done, take 5';
  '退出专注模式即可添加新便签' = 'Exit focus mode to add notes';
  '退出专注模式' = 'Exit focus mode';
  '状态,内容,创建时间,提醒时间,循环情况,完成时间' = 'Status,Text,Created,Reminder,Repeat,Completed';
  '已完成' = 'Completed';
  '已归档' = 'Archived';
  '历史记录已导出为 Markdown' = 'History exported as Markdown';
  '全部便签与历史已导出为 CSV' = 'All notes and history exported as CSV';
  '数据已备份' = 'Data backed up';
  '备份版本过旧，无法恢复' = 'This backup is too old to restore';
  '数据已从备份恢复' = 'Data restored from backup';
  '还没有备份文件' = 'No backup file yet';
  '还没有可恢复的备份' = 'No backup available';
  '恢复备份' = 'Restore backup';
  '将用以下备份覆盖当前数据：' = 'This backup will replace the current data:';
  '会先自动备份当前数据，继续？' = 'The current data is backed up first. Continue?';
  '记一条笔记（没有勾选框），Enter 保存，Shift + Enter 换行…' = 'Write a note (no checkbox). Enter to save, Shift + Enter for a new line…';
  '转为待办（显示复选框）' = 'Convert to to-do (with checkbox)';
  '转为笔记（无勾选框）' = 'Convert to note (no checkbox)';
  '改为' = 'Change to ';
  '改为每天循环' = 'Repeat daily';
  '改为每周循环' = 'Repeat weekly';
  '改为每月循环' = 'Repeat monthly';
  '停止循环' = 'Stop repeating';
  '1 小时后' = 'In 1 hour';
  '今天 20:00' = 'Today 20:00';
  '明天 09:00' = 'Tomorrow 09:00';
  '下周一 09:00' = 'Next Monday 09:00';
  '自定义时间…' = 'Custom time…';
  '取消提醒' = 'Remove reminder';
  '5 分钟后再提醒' = 'Snooze 5 min';
  '已重新提醒：' = 'Reminded again: ';
  '已忽略这条提醒' = 'This reminder was dismissed';
  '时间格式无法识别，试试 2026-10-31 09:00 或 10-31 09:00' = 'Unrecognized format. Try 2026-10-31 09:00 or 10-31 09:00';
  '已把这条笔记拖成独立小窗（原条目仍在）' = 'Opened this note in its own window (the original stays)';
  '单次待办' = 'One-time to-do';
  '每天循环' = 'Daily';
  '每周循环' = 'Weekly';
  '每月循环' = 'Monthly';
  '笔记（无勾选框）' = 'Note (no checkbox)';
  '全部标签' = 'All tags';
  '组织管理…' = 'Manage tags…';
  '已新建标签「' = 'Created tag "';
  '已清除标签筛选' = 'Tag filter cleared';
  '专注 25 分钟' = 'Focus 25 min';
  '休息 5 分钟' = 'Break 5 min';
  '自定义…' = 'Custom…';
  '准时提醒' = 'On time';
  '请输入 1 到 480 之间的分钟数' = 'Enter a number between 1 and 480';
  '托盘图标已开启' = 'Tray icon on';
  '托盘图标已关闭' = 'Tray icon off';
  '快捷键注册失败（可能被其他程序占用）' = 'Hotkey registration failed (another app may be using it)';
  '已开启全局快捷键 Ctrl + Alt + N' = 'Global hotkey enabled: Ctrl + Alt + N';
  '设置开机自启失败，请检查权限' = 'Could not enable start with Windows, check permissions';
  '已设置开机自启' = 'Start with Windows enabled';
  '取消开机自启失败，请检查权限' = 'Could not disable start with Windows, check permissions';
  '确定清空全部历史记录吗？此操作不可撤销（建议先导出或备份）。' = 'Clear all history? This cannot be undone (export or back up first).';
  '历史记录已清空' = 'History cleared';
  '选择备份文件' = 'Choose backup file';
  'JSON 备份' = 'JSON backup';
  '所有文件' = 'All files';
  '将用该备份覆盖当前数据，继续？' = 'This backup will overwrite the current data. Continue?';
  '打开备份文件失败' = 'Could not open the backup file';
  '无法打开数据文件夹' = 'Could not open the data folder';
  '数据文件损坏，已用备份 notes.bak.json 恢复' = 'Data file was damaged and restored from notes.bak.json';
  '青柠绿' = 'Lime';
  '森林绿' = 'Forest';
  '海盐蓝' = 'Sea salt';
  '樱花粉' = 'Sakura';
  '暖阳橙' = 'Sunset';
  '极夜黑' = 'Polar night';
  '便签黄' = 'Sticky yellow';
  '便签白' = 'Sticky white';
  '便签粉' = 'Sticky pink';
  '置顶' = 'Pinned';
  '继续？' = 'Continue?';
  '已错过' = 'Missed';
  '刚刚错过' = 'Just missed';
  '原定' = 'Was due';
  '提醒时间' = 'Reminds at';
  '已删除' = 'Deleted';
  '回收站是空的' = 'The recycle bin is empty';
  '导出失败：' = 'Export failed: ';
  '已导出：' = 'Exported: ';
  '已备份：' = 'Backed up: ';
  '已恢复：' = 'Restored: ';
  '备份失败：' = 'Backup failed: ';
  '恢复失败：' = 'Restore failed: ';
  '语言' = 'Language';
  ' 小时' = ' hours';
  '全部完成 · 共 {0} 项' = 'All done · {0} items';
  '待办 {0} · 今日完成 {1}' = '{0} to do · {1} done today';
}
# 子串替换时按长度从长到短，避免「每天」先把「每天循环」拆坏
$script:I18nKeys = @($script:I18nEn.Keys | Sort-Object { $_.Length } -Descending)

function T([string]$zh) {
  if ([string]::IsNullOrEmpty($zh)) { return $zh }
  if ($script:LangCode -ne 'en') { return $zh }
  if ($script:I18nEn.ContainsKey($zh)) { return $script:I18nEn[$zh] }
  return $zh
}

# 带数量的句子：中文模板 + 英文单数 + 英文复数三份并列，避免出现 "1 items" 这类硬伤。
# key 用含 {0} 的中文模板；中文直接格式化，英文按数量挑单数或复数。
$script:I18nCount = @{
  '{0} 项' = @('{0} item', '{0} items')
  '已删除 · {0} 项，还原后回到列表' = @('Deleted · {0} item · restore to bring it back', 'Deleted · {0} items · restore them to bring them back')
  '将彻底删除回收站里的 {0} 项，且不可恢复。' = @('Permanently delete {0} item from the recycle bin? This cannot be undone.', 'Permanently delete {0} items from the recycle bin? This cannot be undone.')
  '全部完成 · 共 {0} 项' = @('All done · {0} item', 'All done · {0} items')
  '已错过 {0} 天' = @('missed {0} day', 'missed {0} days')
  '已错过 {0} 小时' = @('missed {0} hour', 'missed {0} hours')
  '{0} 天前创建' = @('{0} day ago', '{0} days ago')
  '已错过 · {0} 条' = @('Missed · {0} reminder', 'Missed · {0} reminders')
  '有 {0} 条提醒已错过（到点时程序没在运行）' = @('{0} reminder was missed (the app was not running)', '{0} reminders were missed (the app was not running)')
  '到点提醒 · {0} 条' = @('Due now · {0} reminder', 'Due now · {0} reminders')
}
# 提醒浮层标题：中文带「条」，英文用 "2 due · 1 missed" 这类不带名词的句式，天然没有单复数问题
function Format-RemindTitle([int]$due, [int]$missed) {
  if ($script:LangCode -eq 'en') {
    if ($due -gt 0 -and $missed -gt 0) { return ('{0} due · {1} missed' -f $due, $missed) }
    if ($due -gt 0) { return ('{0} due now' -f $due) }
    return ('{0} missed' -f $missed)
  }
  if ($due -gt 0 -and $missed -gt 0) { return "到点提醒 · $due 条（已错过 $missed 条）" }
  if ($due -eq 1 -and $missed -eq 0) { return '到点提醒' }
  if ($due -gt 0) { return "到点提醒 · $due 条" }
  return "已错过的提醒 · $missed 条"
}
function TCount([string]$zhFmt, $n) {
  $num = [int]$n
  if ($script:LangCode -ne 'en') { return ($zhFmt -f $num) }
  $pair = $script:I18nCount[$zhFmt]
  if ($null -eq $pair) { return ($zhFmt -f $num) }
  $fmt = $pair[1]
  if ($num -eq 1) { $fmt = $pair[0] }
  return ($fmt -f $num)
}

# 拼接文本用：先精确匹配，再按词段替换。只处理界面字符串，绝不用于用户内容。
function Convert-LangText([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return $text }
  if ($script:LangCode -ne 'en') { return $text }
  if ($script:I18nEn.ContainsKey($text)) { return $script:I18nEn[$text] }
  $out = $text
  foreach ($k in $script:I18nKeys) {
    if ($out.IndexOf($k, [System.StringComparison]::Ordinal) -lt 0) { continue }
    $out = $out.Replace($k, $script:I18nEn[$k])
  }
  return $out
}

# 静态界面文案：遍历视觉树时按元素备份中文原文，切换语言只改 Text / Content / ToolTip。
# 用户自己写的内容（便签正文、标签名、搜索词）一律带 Tag=user，遍历时跳过，避免把便签也翻译了。
# 这些元素的文字由代码按语言现算（时钟、问候、进度、提示条），遍历时跳过，
# 否则会被切换前的旧中文覆盖
$script:LangLiveNames = @('ClockText','SecondsText','AmPmText','DateText','GreetingText','ProgressText','StatusPill','ToastText','MissedText','SettingsStatus','TagFilterButton','TagStatus')
$script:I18nOrigin = @{}
function Update-LangNode([System.Windows.DependencyObject]$node) {
  if ($null -eq $node) { return }
  if ($node -is [System.Windows.FrameworkElement] -and [string]$node.Tag -eq 'user') { return }
  # Tag 被业务占用的控件（标签徽标、筛选按钮）用 HelpText 打同一个标记
  if ($node -is [System.Windows.FrameworkElement]) {
    $help = ''
    try { $help = [string][System.Windows.Automation.AutomationProperties]::GetHelpText($node) } catch { }
    if ($help -eq 'user') { return }
  }
  if ($node -is [System.Windows.FrameworkElement] -and ($script:LangLiveNames -contains [string]$node.Name)) { return }
  $isText = $node -is [System.Windows.Controls.TextBlock]
  $isContent = ($node -is [System.Windows.Controls.ContentControl]) -and ($node.Content -is [string])
  $hasTip = ($node -is [System.Windows.FrameworkElement]) -and ($node.ToolTip -is [string])
  if ($isText -or $isContent -or $hasTip) {
    $rec = $script:I18nOrigin[$node]
    if ($null -eq $rec) {
      $rec = @{}
      if ($isText) { $rec.Text = [string]$node.Text }
      if ($isContent) { $rec.Content = [string]$node.Content }
      if ($hasTip) { $rec.ToolTip = [string]$node.ToolTip }
      $script:I18nOrigin[$node] = $rec
    }
    if ($isText) { $node.Text = Convert-LangText ([string]$rec.Text) }
    if ($isContent) { $node.Content = Convert-LangText ([string]$rec.Content) }
    if ($hasTip) { $node.ToolTip = Convert-LangText ([string]$rec.ToolTip) }
  }
  $n = 0
  try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node) } catch { $n = 0 }
  for ($i = 0; $i -lt $n; $i++) {
    Update-LangNode ([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
  }
}

function Update-LangUi {
  try { Update-LangNode $script:Win } catch { }
}

# auto：中文系统用中文，其余一律英文（目前只提供中英两种）
function Resolve-LangCode([string]$setting) {
  if ($setting -eq 'zh' -or $setting -eq 'en') { return $setting }
  try {
    $ui = [System.Globalization.CultureInfo]::CurrentUICulture
    if ($null -ne $ui -and $ui.Name -like 'zh*') { return 'zh' }
  } catch { }
  return 'en'
}

function Set-AppLanguage([string]$setting) {
  $script:LangCode = Resolve-LangCode $setting
  # 旧语言的提示条不要留在屏幕上
  try { Hide-Toast } catch { }
  if ($script:LangCode -eq 'en') {
    $script:Culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $script:FmtDateLong = 'dddd, MMM d, yyyy'
    $script:FmtDateShort = 'MMM d, HH:mm'
    $script:FmtDayShort = 'MMM d, dddd'
  } else {
    $script:Culture = [System.Globalization.CultureInfo]::GetCultureInfo('zh-CN')
    $script:FmtDateLong = 'yyyy年M月d日 dddd'
    $script:FmtDateShort = 'M月d日 HH:mm'
    $script:FmtDayShort = 'M月d日 dddd'
  }
  # 托盘菜单不在视觉树里，界面语言换了要单独刷新（启动时托盘还没建，$null 直接跳过）
  try { if ($null -ne $script:TrayIcon) { Update-TrayMenu } } catch { }
}

# 上次若在「写临时文件成功、原子换名失败」的窗口里被强杀（比如杀毒软件正锁着 notes.json），
# 会留下半截 .tmp。这里的文件从不会被读取，但留在数据目录里容易让人误解，启动时顺手清掉。
try { Get-ChildItem -LiteralPath $script:DataDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }

# ---------- 抗损坏写入 ----------
# 断电 / 强杀进程时，直接覆盖原文件会出现「已截断」或「写了一半」的文件，整个便签库就废了。
# 所以一律：写同目录的临时文件 → 刷盘 → 用 File.Replace 原子换名（旧文件自动留成 notes.bak.json）。
# Replace 是 NTFS 的 ReplaceFile 语义，要么是新文件、要么是旧文件，不会出现中间态；
# 万一所在文件系统不支持（U 盘 exFAT 等），退回到「删除 + 改名」，至少还有 .bak 兜底。
function Write-FileAtomic {
  param([string]$Path, [string]$Content, [string]$Backup = '')
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
  $tmp = $Path + '.tmp'
  $stream = $null
  try {
    $stream = [System.IO.FileStream]::new($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)   # 真正落盘，不做这一步断电仍可能丢内容
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  if ([System.IO.File]::Exists($Path)) {
    try {
      # 注意：这里不能写成 $(if (...) { $null } else { $Backup })。
      # PowerShell 把 $null 传给 [string] 类型参数时会转成空字符串 ""，File.Replace 收到
      # 空的备份路径会抛「路径的形式不合法」，导致每次无备份写入（draft.json）都退化成
      # 「先删原文件再改名」，等于又回到非原子路径。必须显式传 [NullString]::Value。
      if ([string]::IsNullOrEmpty($Backup)) {
        [System.IO.File]::Replace($tmp, $Path, [NullString]::Value, $true)
      } else {
        [System.IO.File]::Replace($tmp, $Path, $Backup, $true)
      }
      return
    } catch { Write-ErrorLog "atomic replace failed, falling back to delete+rename: $($_.Exception.Message)" }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch { }
  }
  [System.IO.File]::Move($tmp, $Path)
}

function Write-ErrorLog([string]$message) {
  try { [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}  {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message)) } catch { }
}
function Write-ToastLog([string]$message) {
  try { [System.IO.File]::AppendAllText((Join-Path $script:DataDir 'run.log'), ("{0}  {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $message)) } catch { }
}

if ($ResetData) { Remove-Item -LiteralPath $script:DataFile -Force -ErrorAction SilentlyContinue }

# ---------- 运行状态 ----------
$script:Win = $null
$script:Ui = @{}
$script:Tasks = [System.Collections.ArrayList]@()
$script:Series = [System.Collections.ArrayList]@()
$script:History = [System.Collections.ArrayList]@()
$script:Tags = [System.Collections.ArrayList]@()
$script:Trash = [System.Collections.ArrayList]@()
$script:ActiveMenu = $null
$script:Settings = @{
  theme = 'lime'; glass = $true; glassOpacity = 0.86; topmost = $true
  tray = $true; closeToTray = $true; hotkey = $true; autostart = $true
  composerKind = 'once'; lastRollDate = ''; view = 'tasks'
  locked = $false; focusMode = $false
  clock24 = $true; clockSeconds = $true; clockCalendar = $true
  focusWidth = 320; focusHeight = 420; snapEdge = $true
  remindSound = $true; doneSound = $true; remindLead = 0; pomodoro = $true; layoutVersion = 2
  # 错过多久之后不再自动弹窗（小时）。0 = 永久保留，关机再久也会补弹。
  remindExpire = 24
  # 界面语言：auto 跟随系统，zh 中文，en 英文
  language = 'auto'
}
$script:Bounds = @{ left = $null; top = $null; width = 800; height = 600 }
# 窗口尺寸下限：完整模式不得小于设置面板所需尺寸（340 面板 + 36 内边距 + 52 阴影边距 => 428，取 440）
$script:FullMinWidth = 440
$script:FullMinHeight = 540
$script:FullDefaultWidth = 800
$script:FullDefaultHeight = 600
$script:FocusMinWidth = 200
$script:FocusMinHeight = 160
$script:CurrentView = 'tasks'
$script:SearchOpen = $false
$script:SearchQuery = ''
$script:ForceExit = $false
$script:SyncingUi = $false
$script:TrayIcon = $null
$script:TrayBalloonShown = $false
$script:HotkeyRegistered = $false
$script:Hwnd = [IntPtr]::Zero
$script:Source = $null
$script:Hook = $null
$script:SourceInitialized = $false
$script:RolloverSummary = @{ archived = 0; spawned = 0 }
$script:TaskTextElements = @{}
$script:SyncingText = $false
$script:RestoreSize = $null
$script:RemindItems = @()
# 「已错过」列表是否展开：默认不展开，只有点过提示 / 设置里的「查看」才显示，
# 避免每次开机都被一堆陈年提醒糊一脸；但数据（task.expiredAt）保留，随时可查。
$script:ShowMissed = $false
$script:ToastAction = $null
$script:RemindEditTaskId = $null
$script:WeekStripKey = ''
$script:FocusResizing = $false
$script:FocusResizeStart = $null
$script:TagFilter = ''
$script:TagPendingTaskId = $null
$script:TagColors = @('#FF5FB88A', '#FF5A9BD8', '#FFD08A4A', '#FFC86A8E', '#FF8E7BD6', '#FFB0A24E')
$script:DraftFile = Join-Path $script:DataDir 'draft.json'
$script:NoteWindows = @()
$script:DragTaskId = $null
$script:DragStartPoint = $null
$script:DragActive = $false
$script:DragGhost = $null
$script:DragSourceCard = $null
$script:DragGrabDx = 0
$script:DragGrabDy = 0
$script:DragTargetCard = $null
$script:DragSourceOpacity = 1.0
$script:DragFadeGhost = $null
$script:DragLastPos = $null

# ---------- 主题色板 ----------
$script:Themes = [ordered]@{
  lime   = @{ name = '青柠绿'; solidTop = '#FF0C241A'; solidMid = '#FF0A1F17'; solidBottom = '#FF071A11'
    glassTop = '#FF0E2A1E'; glassMid = '#FF0A2117'; glassBottom = '#FF071A11'
    accent = '#FF7BE495'; accentSoft = '#FFC9F9C8'; accentDeep = '#FF35D07F'; accentText = '#FFA5EDB9'
    textSecondary = '#FFB8D6C6'; textMuted = '#FF95B9A6'; glowTop = '#3DA8F0A0'; glowBottom = '#3335D07F'
    cardBorder = '#2BFFFFFF'; settingsBg = '#FF0A2118' }
  forest = @{ name = '森林绿'; solidTop = '#FF101F10'; solidMid = '#FF0B190C'; solidBottom = '#FF061006'
    glassTop = '#FF142616'; glassMid = '#FF0D1F10'; glassBottom = '#FF081408'
    accent = '#FFB6D96A'; accentSoft = '#FFE2F2B5'; accentDeep = '#FF7FA33F'; accentText = '#FFD2E6A2'
    textSecondary = '#FFC8D8B8'; textMuted = '#FF9BB08A'; glowTop = '#3DB8D96A'; glowBottom = '#337FA33F'
    cardBorder = '#2BFFFFFF'; settingsBg = '#FF0B190C' }
  ocean  = @{ name = '海盐蓝'; solidTop = '#FF0A1B24'; solidMid = '#FF07141D'; solidBottom = '#FF051018'
    glassTop = '#FF0C2430'; glassMid = '#FF081A25'; glassBottom = '#FF06121C'
    accent = '#FF7CCFF0'; accentSoft = '#FFC4EDF9'; accentDeep = '#FF38A9D6'; accentText = '#FFA7DEF5'
    textSecondary = '#FFB7D3E0'; textMuted = '#FF8AAEBE'; glowTop = '#3D5FD0E0'; glowBottom = '#33408AB8'
    cardBorder = '#2BFFFFFF'; settingsBg = '#FF071620' }
  sakura = @{ name = '樱花粉'; solidTop = '#FF1E1018'; solidMid = '#FF160B12'; solidBottom = '#FF0F070C'
    glassTop = '#FF261520'; glassMid = '#FF1C0E17'; glassBottom = '#FF120A10'
    accent = '#FFF2A7C3'; accentSoft = '#FFFBD3E2'; accentDeep = '#FFD05E8C'; accentText = '#FFF5C3D6'
    textSecondary = '#FFE8C9D6'; textMuted = '#FFC09EAC'; glowTop = '#3DE8A0C0'; glowBottom = '#33C06A8E'
    cardBorder = '#30FFFFFF'; settingsBg = '#FF150A10' }
  amber  = @{ name = '暖阳橙'; solidTop = '#FF20160C'; solidMid = '#FF181006'; solidBottom = '#FF110B05'
    glassTop = '#FF2A1D10'; glassMid = '#FF1F150A'; glassBottom = '#FF150E07'
    accent = '#FFF2B05E'; accentSoft = '#FFFBE0B8'; accentDeep = '#FFD0802F'; accentText = '#FFF5CD98'
    textSecondary = '#FFE6D2B8'; textMuted = '#FFBFA888'; glowTop = '#3DE8B060'; glowBottom = '#33C08030'
    cardBorder = '#30FFFFFF'; settingsBg = '#FF170F06' }
  midnight = @{ name = '极夜黑'; solidTop = '#FF080B0A'; solidMid = '#FF050807'; solidBottom = '#FF030505'
    glassTop = '#FF0C1210'; glassMid = '#FF070C0A'; glassBottom = '#FF040706'
    accent = '#FF8FF0C0'; accentSoft = '#FFC9FBE0'; accentDeep = '#FF3ED99A'; accentText = '#FFB6F5D4'
    textSecondary = '#FFC9D8D0'; textMuted = '#FF8EA89C'; glowTop = '#3D6FE0B0'; glowBottom = '#3333A078'
    cardBorder = '#2BFFFFFF'; settingsBg = '#FF050807' }
  # ---------- 传统便签配色（亮色，dark = $false 时启用浅色文字反转） ----------
  noteyellow = @{ name = '便签黄'; dark = $false
    solidTop = '#FFFFF6D2'; solidMid = '#FFFFF0C2'; solidBottom = '#FFFCE8AC'
    glassTop = '#FFFFF8DE'; glassMid = '#FFFFF2C8'; glassBottom = '#FFFCEAB6'
    accent = '#FFE9B93F'; accentSoft = '#FFF8DE9A'; accentDeep = '#FFC68C1C'; accentText = '#FF8F6612'
    textPrimary = '#FF3B3320'; textSecondary = '#FF5F5028'; textMuted = '#FF8A7745'
    glowTop = '#40F2C869'; glowBottom = '#2ED8A63C'
    cardBorder = '#33A98428'; settingsBg = '#FFFEF8DE'
    cardBg = '#40E9C455'; cardHoverBg = '#55F0D06E'; composerBg = '#66FFFFFF'
    composerBorder = '#3DC9A64A'; pillBg = '#33D9B44A'; pillBorder = '#33C9A64A'; trackBg = '#26A98428'
    iconFg = '#FF6E551A'; iconHoverBg = '#1FA98428'; iconPressedBg = '#33A98428'
    checkBoxBg = '#4DFFFFFF'; checkBoxBorder = '#4DA98428'; dangerFg = '#FFB2402F'
    switchTrackOff = '#38000000'; switchTrackHover = '#5C000000'; switchTrackDrag = '#80000000'
    switchKnobBorder = '#33000000' }
  notewhite = @{ name = '便签白'; dark = $false
    solidTop = '#FFFDFDFA'; solidMid = '#FFF8F8F4'; solidBottom = '#FFF2F2EC'
    glassTop = '#FFFFFFFF'; glassMid = '#FFFBFBF7'; glassBottom = '#FFF4F4EE'
    accent = '#FF7FA97A'; accentSoft = '#FFC4DCC0'; accentDeep = '#FF4C7A4F'; accentText = '#FF47684A'
    textPrimary = '#FF2E322C'; textSecondary = '#FF4F574D'; textMuted = '#FF767F74'
    glowTop = '#33A8C4A0'; glowBottom = '#2E88A88C'
    cardBorder = '#33A8B0A0'; settingsBg = '#FFFFFFFF'
    cardBg = '#3DFFFFFF'; cardHoverBg = '#59FFFFFF'; composerBg = '#73FFFFFF'
    composerBorder = '#40A8B0A0'; pillBg = '#3DFFFFFF'; pillBorder = '#40A8B0A0'; trackBg = '#2EA8B0A0'
    iconFg = '#FF4A5247'; iconHoverBg = '#1F8E968A'; iconPressedBg = '#338E968A'
    checkBoxBg = '#59FFFFFF'; checkBoxBorder = '#4D8E968A'; dangerFg = '#FFB0453C'
    switchTrackOff = '#38000000'; switchTrackHover = '#5C000000'; switchTrackDrag = '#80000000'
    switchKnobBorder = '#33000000' }
  notepink = @{ name = '便签粉'; dark = $false
    solidTop = '#FFFFF1F3'; solidMid = '#FFFFE8EB'; solidBottom = '#FFFADDE2'
    glassTop = '#FFFFF6F7'; glassMid = '#FFFFEEF0'; glassBottom = '#FFFADFE4'
    accent = '#FFE58BA0'; accentSoft = '#FFF8C4CE'; accentDeep = '#FFC9617C'; accentText = '#FF9A4358'
    textPrimary = '#FF3C2B30'; textSecondary = '#FF64464D'; textMuted = '#FF8F6C74'
    glowTop = '#40F0A0B4'; glowBottom = '#33D8788F'
    cardBorder = '#33C98CA0'; settingsBg = '#FFFFF5F7'
    cardBg = '#33E58BA0'; cardHoverBg = '#45EFA6B8'; composerBg = '#66FFFFFF'
    composerBorder = '#3DC9617C'; pillBg = '#33E58BA0'; pillBorder = '#33C9617C'; trackBg = '#26C9617C'
    iconFg = '#FF6B4650'; iconHoverBg = '#1FC98CA0'; iconPressedBg = '#33C98CA0'
    checkBoxBg = '#4DFFFFFF'; checkBoxBorder = '#4DC9617C'; dangerFg = '#FFB0453C'
    switchTrackOff = '#38000000'; switchTrackHover = '#5C000000'; switchTrackDrag = '#80000000'
    switchKnobBorder = '#33000000' }
}

# 深色主题的默认画刷（主题未覆写时沿用）
$script:ThemeBrushDefaults = @{
  textPrimary = '#FFF4FBF7'
  cardBg = '#16FFFFFF'; cardHoverBg = '#22FFFFFF'; cardBorder = '#2BFFFFFF'
  iconHoverBg = '#1FFFFFFF'; iconPressedBg = '#30FFFFFF'
  checkBoxBg = '#12FFFFFF'; checkBoxBorder = '#4DFFFFFF'
  composerBg = '#12FFFFFF'; composerBorder = '#1FFFFFFF'
  pillBg = '#14FFFFFF'; pillBorder = '#1FFFFFFF'; trackBg = '#26FFFFFF'
  dangerFg = '#FFFF9C9C'; dangerHoverBg = '#26FF6B6B'; dangerPressedBg = '#40FF6B6B'
  # 开关轨道 / 滚动条滑块：深色主题叠白，浅色主题在各自定义里改成叠黑
  switchTrackOff = '#2EFFFFFF'; switchTrackHover = '#55FFFFFF'; switchTrackDrag = '#77FFFFFF'
  switchKnobBorder = '#00000000'
}
function Get-ThemeBrushHex($theme, [string]$key) {
  if ($theme.ContainsKey($key) -and $theme[$key]) { return [string]$theme[$key] }
  if ($script:ThemeBrushDefaults.ContainsKey($key)) { return [string]$script:ThemeBrushDefaults[$key] }
  return '#00000000'
}
function Test-ThemeIsLight($theme) {
  if ($theme.ContainsKey('dark')) { return (-not [bool]$theme.dark) }
  return $false
}

function Get-Color([string]$hex) {
  return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}
function New-Brush([string]$hex) {
  return [System.Windows.Media.SolidColorBrush]::new((Get-Color $hex))
}
function New-LinearBrush([string]$a, [string]$b, [string]$c) {
  $brush = [System.Windows.Media.LinearGradientBrush]::new()
  $brush.StartPoint = [System.Windows.Point]::new(0, 0)
  $brush.EndPoint = [System.Windows.Point]::new(0.85, 1)
  $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $a), 0))
  if ($c) {
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $b), 0.55))
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $c), 1))
  } else {
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $b), 1))
  }
  return $brush
}
function New-RadialBrush([string]$colorHex) {
  $color = Get-Color $colorHex
  $transparent = [System.Windows.Media.Color]::FromArgb(0, $color.R, $color.G, $color.B)
  $brush = [System.Windows.Media.RadialGradientBrush]::new()
  $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($color, 0))
  $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($transparent, 0.72))
  return $brush
}
function Set-Brush([string]$key, $brush) {
  if ($script:Win) { $script:Win.Resources[$key] = $brush }
}
# 两个颜色按比例混合，返回不带 Alpha 的 6 位色值
function Get-BlendHex([string]$fromHex, [string]$toHex, [double]$ratio) {
  $a = Get-Color $fromHex
  $b = Get-Color $toHex
  $r = [int][math]::Round($a.R + ($b.R - $a.R) * $ratio)
  $g = [int][math]::Round($a.G + ($b.G - $a.G) * $ratio)
  $bl = [int][math]::Round($a.B + ($b.B - $a.B) * $ratio)
  return ('{0:X2}{1:X2}{2:X2}' -f $r, $g, $bl)
}
# 弹出菜单底色跟着主题走：面板色朝文字色轻推一档（深色变亮 / 浅色变暗），
# 这样亮色主题下不会出现「深底 + 深字」看不清的情况。
function Set-MenuSkin {
  $t = $script:Themes[$script:Settings.theme]
  if ($null -eq $t) { $t = $script:Themes['lime'] }
  $panel = [string]$t.settingsBg
  $text = [string](Get-ThemeBrushHex $t 'textPrimary')
  $accent = [string]$t.accent
  Set-Brush 'MenuBgBrush' (New-Brush ('#FF' + (Get-BlendHex $panel $text 0.07)))
  Set-Brush 'MenuBorderBrush' (New-Brush ('#3D' + (Get-BlendHex $panel $text 0.30)))
  Set-Brush 'MenuHoverBgBrush' (New-Brush ('#FF' + (Get-BlendHex $panel $accent 0.16)))
  Set-Brush 'MenuSeparatorBrush' (New-Brush ('#FF' + (Get-BlendHex $panel $text 0.20)))
}

# 头部 / 专注模式那几个图标按钮的 Foreground 是代码按状态直接赋值的（激活=强调色、未激活=图标色），
# 换主题时 DynamicResource 不会刷新这些已赋值的属性，必须主动重设一遍，否则要「点一下」才变新色。
function Sync-ChromeIcons {
  if (-not $script:Win) { return }
  $topmost = [bool]$script:Settings.topmost
  $locked = [bool]$script:Settings.locked
  $focus = [bool]$script:Settings.focusMode
  if ($ui['FocusPinToggle']) { $ui['FocusPinToggle'].Foreground = if ($topmost) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] } }
  if ($ui['FocusLockToggle']) { $ui['FocusLockToggle'].Foreground = if ($locked) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] } }
  if ($ui['LockToggle']) { $ui['LockToggle'].Foreground = if ($locked) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] } }
  if ($ui['FocusToggle']) { $ui['FocusToggle'].Foreground = if ($focus) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] } }
}

function Set-Theme([string]$themeId, [bool]$save = $true) {
  if (-not $script:Themes.Contains($themeId)) { $themeId = 'lime' }
  $t = $script:Themes[$themeId]
  $script:Settings.theme = $themeId

  Set-Brush 'BgSolidBrush' (New-LinearBrush $t.solidTop $t.solidMid $t.solidBottom)
  Set-Brush 'BgGlassBrush' (New-LinearBrush $t.glassTop $t.glassMid $t.glassBottom)
  Set-Brush 'GlowTopBrush' (New-RadialBrush $t.glowTop)
  Set-Brush 'GlowBottomBrush' (New-RadialBrush $t.glowBottom)
  Set-Brush 'ProgressBrush' (New-LinearBrush $t.accentDeep $t.accentSoft $null)
  Set-Brush 'AddButtonBrush' (New-LinearBrush $t.accentSoft $t.accentDeep $null)
  Set-Brush 'CheckedBrush' (New-LinearBrush $t.accentSoft $t.accentDeep $null)
  Set-Brush 'AccentBrush' (New-Brush $t.accent)
  Set-Brush 'AccentSoftBrush' (New-Brush $t.accentSoft)
  Set-Brush 'AccentDeepBrush' (New-Brush $t.accentDeep)
  Set-Brush 'AccentTextBrush' (New-Brush $t.accentText)
  Set-Brush 'TextSecondaryBrush' (New-Brush $t.textSecondary)
  Set-Brush 'TextMutedBrush' (New-Brush $t.textMuted)
  Set-Brush 'TextPrimaryBrush' (New-Brush (Get-ThemeBrushHex $t 'textPrimary'))
  Set-Brush 'CardBgBrush' (New-Brush (Get-ThemeBrushHex $t 'cardBg'))
  Set-Brush 'CardHoverBgBrush' (New-Brush (Get-ThemeBrushHex $t 'cardHoverBg'))
  Set-Brush 'CheckBoxBgBrush' (New-Brush (Get-ThemeBrushHex $t 'checkBoxBg'))
  Set-Brush 'CheckBoxBorderBrush' (New-Brush (Get-ThemeBrushHex $t 'checkBoxBorder'))
  Set-Brush 'ComposerBgBrush' (New-Brush (Get-ThemeBrushHex $t 'composerBg'))
  Set-Brush 'ComposerBorderBrush' (New-Brush (Get-ThemeBrushHex $t 'composerBorder'))
  Set-Brush 'PillBgBrush' (New-Brush (Get-ThemeBrushHex $t 'pillBg'))
  Set-Brush 'PillBorderBrush' (New-Brush (Get-ThemeBrushHex $t 'pillBorder'))
  Set-Brush 'TrackBgBrush' (New-Brush (Get-ThemeBrushHex $t 'trackBg'))
  Set-Brush 'SwitchTrackOffBrush' (New-Brush (Get-ThemeBrushHex $t 'switchTrackOff'))
  Set-Brush 'SwitchTrackHoverBrush' (New-Brush (Get-ThemeBrushHex $t 'switchTrackHover'))
  Set-Brush 'SwitchTrackDragBrush' (New-Brush (Get-ThemeBrushHex $t 'switchTrackDrag'))
  Set-Brush 'SwitchKnobBorderBrush' (New-Brush (Get-ThemeBrushHex $t 'switchKnobBorder'))
  Set-Brush 'DangerFgBrush' (New-Brush (Get-ThemeBrushHex $t 'dangerFg'))
  Set-Brush 'DangerHoverBgBrush' (New-Brush (Get-ThemeBrushHex $t 'dangerHoverBg'))
  Set-Brush 'DangerPressedBgBrush' (New-Brush (Get-ThemeBrushHex $t 'dangerPressedBg'))
  Set-Brush 'IconHoverBgBrush' (New-Brush (Get-ThemeBrushHex $t 'iconHoverBg'))
  Set-Brush 'IconPressedBgBrush' (New-Brush (Get-ThemeBrushHex $t 'iconPressedBg'))
  Set-Brush 'CardBorderBrush' (New-Brush $t.cardBorder)
  Set-Brush 'CardHoverBorderBrush' (New-Brush ('#4D' + $t.accent.Substring(3)))
  if ($t.ContainsKey('iconFg')) { Set-Brush 'IconFgBrush' (New-Brush ([string]$t.iconFg)) }
  else { Set-Brush 'IconFgBrush' (New-Brush $t.textSecondary) }
  Set-Brush 'SettingsBgBrush' (New-Brush $t.settingsBg)
  $accentColor = Get-Color $t.accent
  Set-Brush 'SelectionBrush' ([System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(102, $accentColor.R, $accentColor.G, $accentColor.B)))
  $deepColor = Get-Color $t.accentDeep
  Set-Brush 'ToggleCheckedBgBrush' ([System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x29, $deepColor.R, $deepColor.G, $deepColor.B)))
  Set-Brush 'ToggleCheckedHoverBgBrush' ([System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x3D, $deepColor.R, $deepColor.G, $deepColor.B)))
  $glyphR = [math]::Min(40, [int]($deepColor.R * 0.12) + 6)
  $glyphG = [math]::Min(40, [int]($deepColor.G * 0.16) + 8)
  $glyphB = [math]::Min(40, [int]($deepColor.B * 0.12) + 6)
  Set-Brush 'CheckGlyphFgBrush' ([System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(255, $glyphR, $glyphG, $glyphB)))
  Set-MenuSkin
  if ($script:Win -and $script:Ui['GlassCard']) {
    $script:Ui['GlassCard'].BorderBrush = New-Brush $t.cardBorder
    Update-ThemeSelection
    Rebuild-All
  }
  if ($script:Win) { $script:WeekStripKey = ''; Update-WeekStrip }
  if ($script:Win) {
    Sync-ChromeIcons
    Update-ComposerTypeButton
    Update-TagFilterButton
    # 已打开的笔记小窗是独立 Window，需重新灌入主题 brush 才会跟着换色
    if ($script:NoteWindows) {
      foreach ($entry in $script:NoteWindows) { Sync-NoteWindowResources $entry.win }
    }
  }
  if ($save) { Save-State }
}

# ---------- 数据工具 ----------
function Get-DateKey([datetime]$date) { return $date.ToString('yyyy-MM-dd') }
function Get-IsoNow { return (Get-Date).ToString('o') }
function Get-NextOrder {
  $max = 0
  foreach ($task in $script:Tasks) { if ([int]$task.order -gt $max) { $max = [int]$task.order } }
  return ($max + 1)
}
function New-TaskObject([string]$text, [string]$mode = 'todo') {
  if ($mode -ne 'note') { $mode = 'todo' }
  return @{
    id = [guid]::NewGuid().ToString('N'); text = $text; kind = 'once'; seriesId = $null; unit = $null
    mode = $mode; tags = @()
    done = $false; pinned = $false; order = (Get-NextOrder); created = (Get-IsoNow); doneAt = $null; cycleKey = $null
    remindAt = $null; reminded = $false; snoozeAt = $null; expiredAt = $null
  }
}
function Test-IsNote($task) {
  if ($null -eq $task) { return $false }
  return ([string]$task.mode -eq 'note')
}
function Get-NextDate([datetime]$from, [string]$unit, [int]$interval) {
  switch ($unit) {
    'day' { return $from.AddDays($interval) }
    'week' { return $from.AddDays(7 * $interval) }
    'month' { return $from.AddMonths($interval) }
    default { return $from.AddDays($interval) }
  }
}
function Get-UnitLabel([string]$unit) {
  switch ($unit) { 'day' { return '每天' } 'week' { return '每周' } 'month' { return '每月' } default { return '循环' } }
}
function Find-Task([string]$id) {
  foreach ($task in $script:Tasks) { if ([string]$task.id -eq $id) { return $task } }
  return $null
}
function Find-Series([string]$id) {
  foreach ($series in $script:Series) { if ([string]$series.id -eq $id) { return $series } }
  return $null
}
# 从任务当前的提醒时间里取出「几点几分」（HH:mm），用于让循环链记住提醒时刻。
# 必须定义在 Normalize-LoadedState 之前：读档回填时就要用到它。
function Get-RemindClockOf($task) {
  if ($null -eq $task -or $null -eq $task.remindAt) { return $null }
  $raw = [string]$task.remindAt
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return ([datetime]::Parse($raw, $script:Invariant)).ToString('HH:mm') } catch { return $null }
}
function Find-Tag([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id)) { return $null }
  foreach ($tag in $script:Tags) { if ([string]$tag.id -eq $id) { return $tag } }
  return $null
}
function Find-TagByName([string]$name) {
  foreach ($tag in $script:Tags) { if ([string]$tag.name -eq $name) { return $tag } }
  return $null
}
function Get-TaskTagIds($task) {
  if ($null -eq $task) { return @() }
  $raw = $task.tags
  if ($null -eq $raw) { return @() }
  return @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}
function New-RepeatTask([string]$text, [string]$unit) {
  $now = Get-Date
  $seriesId = [guid]::NewGuid().ToString('N')
  $next = Get-NextDate $now.Date $unit 1
  [void]$script:Series.Add(@{
      id = $seriesId; text = $text; unit = $unit; interval = 1; anchor = $now.Date.ToString('o')
      nextAt = (Get-DateKey $next); created = (Get-IsoNow); remindClock = $null
    })
  [void]$script:Tasks.Add(@{
      id = [guid]::NewGuid().ToString('N'); text = $text; kind = 'repeat'; seriesId = $seriesId; unit = $unit
      mode = 'todo'; tags = @()
      done = $false; pinned = $false; order = (Get-NextOrder); created = (Get-IsoNow); doneAt = $null
      cycleKey = (Get-DateKey $now.Date); remindAt = $null; reminded = $false; snoozeAt = $null; expiredAt = $null
    })
}

# ---------- 加载 / 迁移 ----------
function Normalize-LoadedState($obj) {
  [void]$script:Tasks.Clear(); [void]$script:Series.Clear(); [void]$script:History.Clear()
  [void]$script:Tags.Clear(); [void]$script:Trash.Clear()
  # 旧存档没有 layoutVersion：窗口尺寸按新默认 800×600 重置一次
  $layoutVersion = 0
  if ($obj.settings -and $null -ne $obj.settings.layoutVersion) { $layoutVersion = [int]$obj.settings.layoutVersion }
  if ($obj.settings) {
    foreach ($key in @('theme', 'glass', 'glassOpacity', 'topmost', 'tray', 'closeToTray', 'hotkey', 'autostart', 'composerKind', 'lastRollDate',
        'view', 'focusMode', 'clock24', 'clockSeconds', 'clockCalendar', 'remindSound', 'doneSound', 'remindLead', 'pomodoro',
        'remindExpire', 'language',
        'focusWidth', 'focusHeight', 'snapEdge')) {
      $value = $obj.settings.$key
      if ($null -ne $value) { $script:Settings[$key] = $value }
    }
  }
  # 错过提醒的保留时长只认 0（永久）/ 24 / 72 / 168 小时；存档被手改坏时退回 24，别让提醒整体失效
  $expireHours = 24
  try { $expireHours = [int]$script:Settings.remindExpire } catch { $expireHours = 24 }
  if (@(0, 24, 72, 168) -notcontains $expireHours) { $expireHours = 24 }
  $script:Settings.remindExpire = $expireHours
  # 语言只认 auto / zh / en，存档被手改坏时退回跟随系统
  $lang = [string]$script:Settings.language
  if (@('auto', 'zh', 'en') -notcontains $lang) { $lang = 'auto' }
  $script:Settings.language = $lang
  # 锁定状态不跟随上次关闭：无论存档里写的是什么，启动一律从未锁定开始（其余状态照常恢复）
  $script:Settings.locked = $false
  if ($null -ne $obj.window) {
    foreach ($key in @('left', 'top', 'width', 'height')) {
      if ($null -ne $obj.window.$key) { $script:Bounds[$key] = [double]$obj.window.$key }
    }
    # v2.1 及更早的默认窗口是 400×640，升级后改用新的 800×600 默认尺寸
    if ([math]::Abs([double]$script:Bounds.width - 400) -lt 1 -and [math]::Abs([double]$script:Bounds.height - 640) -lt 1) {
      $script:Bounds.width = $script:FullDefaultWidth
      $script:Bounds.height = $script:FullDefaultHeight
    }
  }
  if ($layoutVersion -lt 2) {
    $script:Bounds.width = $script:FullDefaultWidth
    $script:Bounds.height = $script:FullDefaultHeight
  }
  $script:Settings.layoutVersion = 2
  foreach ($s in @($obj.series)) {
    if ($null -eq $s) { continue }
    [void]$script:Series.Add(@{ id = [string]$s.id; text = [string]$s.text; unit = [string]$s.unit; interval = [int]$s.interval
        anchor = [string]$s.anchor; nextAt = [string]$s.nextAt; created = [string]$s.created
        remindClock = $(if ($s.remindClock) { [string]$s.remindClock } else { $null }) })
  }
  foreach ($t in @($obj.tasks)) {
    if ($null -eq $t) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$t.text)) { continue }
    $tagIds = @()
    foreach ($tg in @($t.tags)) { if (-not [string]::IsNullOrWhiteSpace([string]$tg)) { $tagIds += [string]$tg } }
    [void]$script:Tasks.Add(@{
        id = [string]$t.id; text = [string]$t.text; kind = [string]$t.kind
        mode = $(if ([string]$t.mode -eq 'note') { 'note' } else { 'todo' }); tags = $tagIds
        seriesId = $(if ($t.seriesId) { [string]$t.seriesId } else { $null }); unit = $(if ($t.unit) { [string]$t.unit } else { $null })
        done = [bool]$t.done; pinned = [bool]$t.pinned; order = [int]$t.order; created = [string]$t.created
        doneAt = $(if ($t.doneAt) { [string]$t.doneAt } else { $null }); cycleKey = $(if ($t.cycleKey) { [string]$t.cycleKey } else { $null })
        remindAt = $(if ($t.remindAt) { [string]$t.remindAt } else { $null }); reminded = [bool]$t.reminded
        snoozeAt = $(if ($t.snoozeAt) { [string]$t.snoozeAt } else { $null })
        expiredAt = $(if ($t.expiredAt) { [string]$t.expiredAt } else { $null })
      })
  }
  foreach ($h in @($obj.history)) {
    if ($null -eq $h) { continue }
    [void]$script:History.Add(@{
        id = [string]$h.id; text = [string]$h.text; kind = [string]$h.kind
        mode = $(if ([string]$h.mode -eq 'note') { 'note' } else { 'todo' })
        seriesId = $(if ($h.seriesId) { [string]$h.seriesId } else { $null }); unit = $(if ($h.unit) { [string]$h.unit } else { $null })
        doneAt = [string]$h.doneAt; archivedAt = [string]$h.archivedAt; created = [string]$h.created
        remindAt = $(if ($h.remindAt) { [string]$h.remindAt } else { $null })
      })
  }
  $tagOrder = 0
  foreach ($tg in @($obj.tags)) {
    if ($null -eq $tg) { continue }
    $name = ([string]$tg.name).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $tagOrder++
    [void]$script:Tags.Add(@{
        id = $(if ($tg.id) { [string]$tg.id } else { [guid]::NewGuid().ToString('N') })
        name = $name
        color = $(if ($tg.color) { [string]$tg.color } else { $script:TagColors[($tagOrder - 1) % $script:TagColors.Count] })
        order = $(if ($null -ne $tg.order) { [int]$tg.order } else { $tagOrder })
        created = $(if ($tg.created) { [string]$tg.created } else { (Get-IsoNow) })
      })
  }
  # 丢掉指向已不存在标签的悬空引用
  foreach ($task in $script:Tasks) { $task.tags = @(Get-TaskTagIds $task | Where-Object { $null -ne (Find-Tag $_) }) }
  foreach ($item in @($obj.trash)) {
    if ($null -eq $item) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$item.text)) { continue }
    $trashTags = @()
    foreach ($tg in @($item.tags)) { if (-not [string]::IsNullOrWhiteSpace([string]$tg)) { $trashTags += [string]$tg } }
    [void]$script:Trash.Add(@{
        id = [string]$item.id; text = [string]$item.text; kind = [string]$item.kind
        mode = $(if ([string]$item.mode -eq 'note') { 'note' } else { 'todo' }); tags = $trashTags
        seriesId = $(if ($item.seriesId) { [string]$item.seriesId } else { $null }); unit = $(if ($item.unit) { [string]$item.unit } else { $null })
        pinned = [bool]$item.pinned; order = [int]$item.order; created = [string]$item.created
        doneAt = $(if ($item.doneAt) { [string]$item.doneAt } else { $null }); cycleKey = $(if ($item.cycleKey) { [string]$item.cycleKey } else { $null })
        remindAt = $(if ($item.remindAt) { [string]$item.remindAt } else { $null })
        source = $(if ([string]$item.source -eq 'history') { 'history' } else { 'task' })
        deletedAt = $(if ($item.deletedAt) { [string]$item.deletedAt } else { (Get-IsoNow) })
      })
  }
  # 旧存档升级：循环任务已经设了提醒、但 series 还没记住时刻 → 回填，让它从下一轮开始自动延续
  foreach ($task in $script:Tasks) {
    if ([string]$task.kind -ne 'repeat' -or -not $task.seriesId) { continue }
    $series = Find-Series ([string]$task.seriesId)
    if ($null -eq $series) { continue }
    if (-not [string]::IsNullOrWhiteSpace([string]$series.remindClock)) { continue }
    $clock = Get-RemindClockOf $task
    if ($clock) { $series.remindClock = $clock }
  }
}

function Load-State {
  if (-not (Test-Path -LiteralPath $script:DataFile)) { return $false }
  try {
    $raw = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($raw)) { throw '文件为空' }
    $obj = $raw | ConvertFrom-Json
    $version = 0
    if ($null -ne $obj.version) { $version = [int]$obj.version }
    if ($version -lt 2) {
      try { Copy-Item -LiteralPath $script:DataFile -Destination (Join-Path $script:DataDir 'notes.v1.backup.json') -Force } catch { }
      $script:Settings.theme = 'lime'
      $script:Settings.glassOpacity = 0.86
      $script:Settings.tray = $true
      $script:Settings.closeToTray = $true
      $script:Settings.hotkey = $true
      $script:Settings.composerKind = 'once'
      if ($obj.settings) {
        if ($null -ne $obj.settings.glass) { $script:Settings.glass = [bool]$obj.settings.glass }
        if ($null -ne $obj.settings.topmost) { $script:Settings.topmost = [bool]$obj.settings.topmost }
      }
      if ($obj.window) {
        foreach ($key in @('left', 'top', 'width', 'height')) {
          if ($null -ne $obj.window.$key) { $script:Bounds[$key] = [double]$obj.window.$key }
        }
      }
      $script:Bounds.width = [math]::Max($script:FullMinWidth, [double]$script:Bounds.width)
      $script:Bounds.height = [math]::Max($script:FullMinHeight, [double]$script:Bounds.height)
      [void]$script:Tasks.Clear()
      $order = 1
      foreach ($n in @($obj.notes)) {
        if ($null -eq $n) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$n.text)) { continue }
        [void]$script:Tasks.Add(@{
            id = $(if ($n.id) { [string]$n.id } else { [guid]::NewGuid().ToString('N') })
            text = [string]$n.text; kind = 'once'; seriesId = $null; unit = $null
            mode = 'todo'; tags = @()
            done = [bool]$n.done; pinned = $false; order = $order
            created = $(if ($n.created) { [string]$n.created } else { (Get-IsoNow) })
            doneAt = $(if ($n.doneAt) { [string]$n.doneAt } else { $null }); cycleKey = $null
          })
        $order++
      }
      $script:Settings.lastRollDate = ''
      Save-State
      return $true
    }
    Normalize-LoadedState $obj
    return $true
  } catch {
    Write-ErrorLog "load state failed: $($_.Exception.ToString())"
    try {
      $backup = Join-Path $script:DataDir ("notes.corrupt.{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
      Copy-Item -LiteralPath $script:DataFile -Destination $backup -Force -ErrorAction SilentlyContinue
    } catch { }
    # 主文件坏了先别急着当「空库」启动——上一版的 notes.bak.json 是完整可用的，
    # 用它救回来，用户最多丢最后一次改动，而不是丢掉整个便签库。
    try {
      if (Test-Path -LiteralPath $script:BakFile) {
        $rawBak = [System.IO.File]::ReadAllText($script:BakFile, [System.Text.UTF8Encoding]::new($false))
        if (-not [string]::IsNullOrWhiteSpace($rawBak)) {
          $objBak = $rawBak | ConvertFrom-Json
          if ($null -ne $objBak.version -and [int]$objBak.version -ge 2) {
            Normalize-LoadedState $objBak
            $script:RecoveredFromBackup = $true
            Write-ErrorLog "state recovered from notes.bak.json"
            Save-State
            return $true
          }
        }
      }
    } catch { Write-ErrorLog "recover from backup failed: $($_.Exception.ToString())" }
    return $false
  }
}

# ---------- 保存 ----------
$script:SaveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:SaveTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:SaveTimer.Add_Tick({ $script:SaveTimer.Stop(); Save-State })
function Request-Save { $script:SaveTimer.Stop(); $script:SaveTimer.Start() }

function Save-State {
  try {
    $payload = [ordered]@{
      version = 4
      settings = [ordered]@{
        theme = [string]$script:Settings.theme; glass = [bool]$script:Settings.glass
        glassOpacity = [math]::Round([double]$script:Settings.glassOpacity, 3); topmost = [bool]$script:Settings.topmost
        tray = [bool]$script:Settings.tray; closeToTray = [bool]$script:Settings.closeToTray
        hotkey = [bool]$script:Settings.hotkey; autostart = [bool]$script:Settings.autostart
        composerKind = [string]$script:Settings.composerKind; lastRollDate = [string]$script:Settings.lastRollDate
        view = [string]$script:Settings.view; locked = $false; focusMode = [bool]$script:Settings.focusMode
        clock24 = [bool]$script:Settings.clock24
        clockSeconds = [bool]$script:Settings.clockSeconds; clockCalendar = [bool]$script:Settings.clockCalendar
        focusWidth = [math]::Round([double]$script:Settings.focusWidth, 0)
        focusHeight = [math]::Round([double]$script:Settings.focusHeight, 0)
        snapEdge = [bool]$script:Settings.snapEdge
        remindSound = [bool]$script:Settings.remindSound; doneSound = [bool]$script:Settings.doneSound
        pomodoro = [bool]$script:Settings.pomodoro
        remindLead = [int]$script:Settings.remindLead
        remindExpire = [int]$script:Settings.remindExpire
        language = [string]$script:Settings.language
        layoutVersion = 2
      }
      window = [ordered]@{
        left = [math]::Round([double]$script:Bounds.left, 1); top = [math]::Round([double]$script:Bounds.top, 1)
        width = [math]::Round([double]$script:Bounds.width, 1); height = [math]::Round([double]$script:Bounds.height, 1)
      }
      tasks = @($script:Tasks | ForEach-Object {
          [ordered]@{ id = $_.id; text = $_.text; kind = $_.kind; seriesId = $_.seriesId; unit = $_.unit
            mode = [string]$_.mode; tags = @(Get-TaskTagIds $_)
            done = [bool]$_.done; pinned = [bool]$_.pinned; order = [int]$_.order
            created = $_.created; doneAt = $_.doneAt; cycleKey = $_.cycleKey
            remindAt = $_.remindAt; reminded = [bool]$_.reminded; snoozeAt = $_.snoozeAt; expiredAt = $_.expiredAt }
        })
      series = @($script:Series | ForEach-Object {
          [ordered]@{ id = $_.id; text = $_.text; unit = $_.unit; interval = [int]$_.interval
            anchor = $_.anchor; nextAt = $_.nextAt; created = $_.created; remindClock = $_.remindClock }
        })
      history = @($script:History | ForEach-Object {
          [ordered]@{ id = $_.id; text = $_.text; kind = $_.kind; seriesId = $_.seriesId; unit = $_.unit
            mode = [string]$_.mode; doneAt = $_.doneAt; archivedAt = $_.archivedAt; created = $_.created; remindAt = $_.remindAt }
        })
      tags = @($script:Tags | Sort-Object -Property @{ Expression = { [int]$_.order } } | ForEach-Object {
          [ordered]@{ id = $_.id; name = $_.name; color = $_.color; order = [int]$_.order; created = $_.created }
        })
      trash = @($script:Trash | ForEach-Object {
          [ordered]@{ id = $_.id; text = $_.text; kind = $_.kind; seriesId = $_.seriesId; unit = $_.unit
            mode = [string]$_.mode; tags = @(Get-TaskTagIds $_); pinned = [bool]$_.pinned; order = [int]$_.order
            created = $_.created; doneAt = $_.doneAt; cycleKey = $_.cycleKey; remindAt = $_.remindAt
            source = [string]$_.source; deletedAt = $_.deletedAt }
        })
    }
    $json = $payload | ConvertTo-Json -Depth 8
    Write-FileAtomic $script:DataFile $json $script:BakFile
  } catch { Write-ErrorLog "save state failed: $($_.Exception.ToString())" }
}

# ---------- 草稿实时保存（正在编写的文字永不丢） ----------
# 与 notes.json 分离成独立小文件：每次敲键都只写几百字节，代价极低，
# 所以可以做到「拔电源也只丢最后 200 毫秒」。窗口关闭 / 系统注销时再强制刷一次。
$script:DraftTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:DraftTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$script:DraftTimer.Add_Tick({ $script:DraftTimer.Stop(); Save-Draft })
function Request-DraftSave {
  if ($null -eq $script:DraftTimer) { return }
  $script:DraftTimer.Stop(); $script:DraftTimer.Start()
}
function Save-Draft {
  try {
    $box = $script:Ui['NoteInput']
    $text = if ($null -ne $box) { [string]$box.Text } else { '' }
    $json = ([ordered]@{ text = $text; kind = [string]$script:Settings.composerKind; updated = (Get-IsoNow) } | ConvertTo-Json -Compress)
    Write-FileAtomic $script:DraftFile $json
  } catch { }
}
function Reset-Draft {
  try { Remove-Item -LiteralPath $script:DraftFile -Force -ErrorAction SilentlyContinue } catch { }
}
function Read-Draft {
  try {
    if (-not (Test-Path -LiteralPath $script:DraftFile)) { return $null }
    $raw = [System.IO.File]::ReadAllText($script:DraftFile, [System.Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $obj = $raw | ConvertFrom-Json
    return @{ text = [string]$obj.text; kind = [string]$obj.kind }
  } catch { return $null }
}
function Restore-Draft {
  $draft = Read-Draft
  if ($null -eq $draft) { return $false }
  $text = [string]$draft.text
  if ([string]::IsNullOrEmpty($text)) { return $false }
  if ($draft.kind -in @('once', 'day', 'week', 'month', 'note')) { $script:Settings.composerKind = $draft.kind }
  $box = $script:Ui['NoteInput']
  if ($null -eq $box) { return $false }
  $box.Text = $text
  if ($script:Ui['Placeholder']) { $script:Ui['Placeholder'].Visibility = [System.Windows.Visibility]::Collapsed }
  Update-ComposerTypeButton
  return $true
}

# ---------- 跨天整理 ----------
function Invoke-DayRollover([bool]$silent = $true) {
  $today = (Get-Date).Date
  $todayKey = Get-DateKey $today
  $archived = 0
  $spawned = 0

  foreach ($task in @($script:Tasks)) {
    if (Test-IsNote $task) { continue }
    if (-not $task.done -or -not $task.doneAt) { continue }
    try { $doneDate = [datetime]::Parse([string]$task.doneAt, $script:Invariant).Date } catch { continue }
    if ($doneDate -lt $today) {
      $series = if ($task.seriesId) { Find-Series ([string]$task.seriesId) } else { $null }
      $unit = if ($task.unit) { [string]$task.unit } elseif ($series) { [string]$series.unit } else { $null }
      [void]$script:History.Add(@{
          id = [string]$task.id; text = [string]$task.text; kind = [string]$task.kind
          seriesId = $task.seriesId; unit = $unit; doneAt = [string]$task.doneAt
          archivedAt = (Get-IsoNow); created = [string]$task.created
          remindAt = $(if ($task.remindAt) { [string]$task.remindAt } else { $null })
        })
      [void]$script:Tasks.Remove($task)
      $archived++
    }
  }

  foreach ($series in @($script:Series)) {
    try { $next = [datetime]::Parse([string]$series.nextAt, $script:Invariant).Date } catch { continue }
    if ($next -le $today) {
      $existing = @($script:Tasks | Where-Object { $_.kind -eq 'repeat' -and $_.seriesId -eq $series.id -and -not $_.done -and $_.cycleKey -eq $todayKey })
      if ($existing.Count -eq 0) {
        # 提醒跟着循环走：series 记了时刻（HH:mm），就把它落到新任务的当天
        $remindAt = $null
        $clock = [string]$series.remindClock
        if (-not [string]::IsNullOrWhiteSpace($clock)) {
          try {
            $seg = $clock.Split(':')
            $hh = [int]$seg[0]; $mm = [int]$seg[1]
            if ($hh -ge 0 -and $hh -le 23 -and $mm -ge 0 -and $mm -le 59) {
              $remindAt = $today.AddHours($hh).AddMinutes($mm).ToString('o')
            }
          } catch { $remindAt = $null }
        }
        [void]$script:Tasks.Add(@{
            id = [guid]::NewGuid().ToString('N'); text = [string]$series.text; kind = 'repeat'; seriesId = [string]$series.id
            unit = [string]$series.unit; done = $false; pinned = $false; order = (Get-NextOrder)
            created = (Get-IsoNow); doneAt = $null; cycleKey = $todayKey
            remindAt = $remindAt; reminded = $false; snoozeAt = $null; expiredAt = $null
          })
        $spawned++
      }
      while ($next -le $today) { $next = Get-NextDate $next ([string]$series.unit) ([int]$series.interval) }
      $series.nextAt = Get-DateKey $next
    }
  }

  $dayChanged = ([string]$script:Settings.lastRollDate -ne $todayKey)
  $script:Settings.lastRollDate = $todayKey
  if ($archived -gt 0 -or $spawned -gt 0 -or $dayChanged) { Save-State }
  $script:RolloverSummary = @{ archived = $archived; spawned = $spawned }
  if (-not $silent -and ($archived -gt 0 -or $spawned -gt 0)) {
    $parts = @()
    if ($archived -gt 0) { $parts += "已归档 $archived 项完成记录" }
    if ($spawned -gt 0) { $parts += "新增 $spawned 项循环任务" }
    Show-Toast ('新的一天：' + ($parts -join '，'))
  }
  return $script:RolloverSummary
}

# ---------- XAML 加载 ----------
$loaded = Load-State
# 语言必须在界面渲染前定下来，否则窗口会先闪一下中文再切成英文。
# 自检一律按中文跑：断言里写的是中文文案，不能因为跑测试的机器是英文系统就全红。
Set-AppLanguage $(if ($SmokeTest) { 'zh' } else { [string]$script:Settings.language })
$reader = [System.Xml.XmlReader]::Create($script:UiFile)
try { $script:Win = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }

foreach ($name in 'RootGrid','GlassCard','SolidBg','GlassBg','GlowLayer','SheenLayer','NoiseLayer','MainGrid',
  'HeaderGrid','ClockText','SecondsText','AmPmText','DateText','GreetingText','StatusPill','ProgressText','ProgressTrack','ProgressFill',
  'WeekStrip','WeekStripHost',
  'PinToggle','GlassToggle','MinButton','CloseButton','ToolbarGrid','TabTasks','TabHistory','TabTrash','SearchButton','SettingsButton','TagsButton',
  'LockToggle','FocusToggle','FocusExitButton',
  'SearchBar','SearchPlaceholder','SearchInput','SearchClearButton','TagFilterButton','TasksScroller','TasksHost','HistoryScroller','HistoryHost',
  'TrashScroller','TrashHost','DragLayer',
  'TagOverlay','TagPanel','TagCloseButton','TagInput','TagInputPlaceholder','TagAddButton','TagScroller','TagListHost','TagStatus','TagClearFilterButton',
  'EmptyState','EmptyIcon','EmptyTitle','EmptySubtitle','ComposerGrid','ComposerBorder','Placeholder','NoteInput','RepeatButton','AddButton',
  'Toast','ToastText','SettingsOverlay','SettingsPanel','SettingsCloseButton','ThemeGrid','LangPanel','SettingsGlassToggle','OpacitySlider',
  'OpacityValueText','PresetClear','PresetStandard','PresetDeep','ExportMdButton','ExportCsvButton','ClearHistoryButton',
  'TrayToggle','CloseToTrayToggle','HotkeyToggle','AutostartToggle','BackupButton','RestoreLatestButton','RestoreFileButton',
  'OpenDataFolderButton','SettingsStatus','VersionText',
  'Clock24Toggle','ClockSecondsToggle','ClockCalendarToggle','RemindSoundToggle','DoneSoundToggle','PomodoroToggle',
  'RemindLead0','RemindLead5','RemindLead15','RemindLead30','RemindLeadText',
  'RemindExpireText','RemindExpire24','RemindExpire72','RemindExpire168','RemindExpire0',
  'MissedBanner','MissedText','MissedViewButton',
  'RemindOverlay','RemindHost','RemindScroller','RemindTitle','RemindCloseButton',
  'RemindEditor','RemindEditorText','RemindInput','RemindHint','RemindOkButton','RemindCancelButton','FocusDragBar',
  'PomodoroEditor','PomodoroEditorHint','PomodoroInput','PomodoroOkButton','PomodoroCancelButton',
  'FocusActions','FocusPinToggle','FocusLockToggle','PomodoroPanel','PomodoroDot','PomodoroText','ResizeGrip') {
  $script:Ui[$name] = $script:Win.FindName($name)
}
$ui = $script:Ui
# 版本号只在 AppVersion 一处维护，设置面板副标题由它渲染
if ($null -ne $ui['VersionText']) { $ui['VersionText'].Text = '核桃便签 v' + [string]$script:AppVersion }

# ---------- 图标 / 噪点 / 裁剪 ----------
$iconPath = Join-Path $script:AssetDir 'icon.png'
if (Test-Path -LiteralPath $iconPath) {
  try {
    $image = [System.Windows.Media.Imaging.BitmapImage]::new()
    $image.BeginInit(); $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = [Uri]::new($iconPath); $image.EndInit()
    $script:Win.Icon = $image
    if ($ui['EmptyIcon']) { $ui['EmptyIcon'].Source = $image }
  } catch { }
}
$noisePath = Join-Path $script:AssetDir 'noise.png'
if (Test-Path -LiteralPath $noisePath) {
  try {
    $noiseImage = [System.Windows.Media.Imaging.BitmapImage]::new()
    $noiseImage.BeginInit(); $noiseImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $noiseImage.UriSource = [Uri]::new($noisePath); $noiseImage.EndInit()
    $brush = [System.Windows.Media.ImageBrush]::new($noiseImage)
    $brush.TileMode = [System.Windows.Media.TileMode]::Tile
    $brush.Viewport = [System.Windows.Rect]::new(0, 0, 128, 128)
    $brush.ViewportUnits = [System.Windows.Media.BrushMappingMode]::Absolute
    $ui['NoiseLayer'].Background = $brush
  } catch { }
}
function Update-GlowClip {
  try {
    $w = $ui['GlowLayer'].ActualWidth; $h = $ui['GlowLayer'].ActualHeight
    if ($w -gt 0 -and $h -gt 0) {
      $rect = [System.Windows.Rect]::new(0, 0, $w, $h)
      $ui['GlowLayer'].Clip = [System.Windows.Media.RectangleGeometry]::new($rect, 22, 22)
    }
  } catch { }
}
$ui['GlowLayer'].Add_SizeChanged({ Update-GlowClip })

# ---------- 窗口几何 ----------
$workArea = [System.Windows.SystemParameters]::WorkArea
$winW = [math]::Max($script:FullMinWidth, [math]::Min(1600, [double]$script:Bounds.width))
$winH = [math]::Max($script:FullMinHeight, [math]::Min(1400, [double]$script:Bounds.height))
$winL = if ($null -ne $script:Bounds.left) { [double]$script:Bounds.left } else { $workArea.Right - $winW - 40 }
$winT = if ($null -ne $script:Bounds.top) { [double]$script:Bounds.top } else { $workArea.Top + 50 }
$virtualLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
$virtualTop = [System.Windows.SystemParameters]::VirtualScreenTop
$virtualRight = $virtualLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
$virtualBottom = $virtualTop + [System.Windows.SystemParameters]::VirtualScreenHeight
if ($winL -lt ($virtualLeft - 60) -or $winL -gt ($virtualRight - 160) -or $winT -lt ($virtualTop - 40) -or $winT -gt ($virtualBottom - 120)) {
  $winL = $workArea.Right - $winW - 40; $winT = $workArea.Top + 50
}
# 存档位置若让窗口伸出工作区（比如换了更小的显示器），启动时拉回可见范围
if ($winL + $winW -gt $workArea.Right) { $winL = [math]::Max($workArea.Left, $workArea.Right - $winW) }
if ($winT + $winH -gt $workArea.Bottom) { $winT = [math]::Max($workArea.Top, $workArea.Bottom - $winH) }
if ($winL -lt $workArea.Left) { $winL = $workArea.Left }
if ($winT -lt $workArea.Top) { $winT = $workArea.Top }
$script:Win.Width = $winW; $script:Win.Height = $winH
$script:Win.Left = $winL; $script:Win.Top = $winT
$script:Bounds.width = $winW; $script:Bounds.height = $winH
$script:Bounds.left = $winL; $script:Bounds.top = $winT

# ---------- 首次启动种子 ----------
if (-not $loaded) {
  [void]$script:Tasks.Add((New-TaskObject '点一下文字就能编辑，修改会自动保存 ✍'))
  New-RepeatTask '每天喝一杯水，开始今天' 'day'
  [void]$script:Tasks.Add((New-TaskObject '点击右上角「设置」可以换主题、调透明度'))
}

# ---------- 基础 UI ----------
function Update-Clock {
  $now = Get-Date
  $use24 = [bool]$script:Settings.clock24
  if ($use24) {
    $ui['ClockText'].Text = $now.ToString('HH:mm')
    $ui['AmPmText'].Text = ''
  } else {
    $hour12 = $now.Hour % 12
    if ($hour12 -eq 0) { $hour12 = 12 }
    $ui['ClockText'].Text = ('{0}:{1:00}' -f $hour12, $now.Minute)
    $ui['AmPmText'].Text = $(if ($now.Hour -lt 12) { 'AM' } else { 'PM' })
  }
  if ([bool]$script:Settings.clockSeconds) {
    $ui['SecondsText'].Text = $now.ToString(':ss')
    $ui['SecondsText'].Visibility = [System.Windows.Visibility]::Visible
  } else {
    $ui['SecondsText'].Visibility = [System.Windows.Visibility]::Collapsed
  }
  $ui['DateText'].Text = $now.ToString($script:FmtDateLong, $script:Culture)
  $hour = $now.Hour
  $greeting = if ($hour -lt 5) { '夜深了' } elseif ($hour -lt 9) { '早上好' } elseif ($hour -lt 12) { '上午好' }
    elseif ($hour -lt 14) { '中午好' } elseif ($hour -lt 18) { '下午好' } elseif ($hour -lt 23) { '晚上好' } else { '夜深了' }
  $ui['GreetingText'].Text = T $greeting
  Update-WeekStrip
}
$script:ToastTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:ToastTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:ToastTimer.Add_Tick({ Hide-Toast })
function Show-Toast([string]$text, $action = $null, [int]$seconds = 4) {
  try {
    $ui['ToastText'].Text = Convert-LangText $text
    # 带 $action 时提示条变成可点入口（「有 N 条提醒已错过，点这里查看」），否则保持纯展示、不吃鼠标
    $script:ToastAction = $action
    $ui['Toast'].IsHitTestVisible = ($null -ne $action)
    $ui['Toast'].Cursor = $(if ($null -ne $action) { [System.Windows.Input.Cursors]::Hand } else { [System.Windows.Input.Cursors]::Arrow })
    $ui['Toast'].Visibility = [System.Windows.Visibility]::Visible
    $script:ToastTimer.Interval = [TimeSpan]::FromSeconds([math]::Max(2, $seconds))
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
  } catch { }
}
function Hide-Toast {
  $script:ToastTimer.Stop()
  $script:ToastAction = $null
  try {
    $ui['Toast'].IsHitTestVisible = $false
    $ui['Toast'].Visibility = [System.Windows.Visibility]::Collapsed
  } catch { }
}
function Set-TopmostMode([bool]$enabled) {
  $script:Settings.topmost = $enabled
  $script:Win.Topmost = $enabled
  Sync-FocusChrome
}
function Set-GlassMode([bool]$enabled, [bool]$animate = $true) {
  $script:Settings.glass = $enabled
  $opacity = [double]$script:Settings.glassOpacity
  $solidTarget = if ($enabled) { 0.0 } else { 1.0 }
  $glassTarget = if ($enabled) { $opacity } else { 0.0 }
  if ($animate) {
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(240))
    $ease = [System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    foreach ($pair in @(@{ el = $ui['SolidBg']; to = $solidTarget }, @{ el = $ui['GlassBg']; to = $glassTarget })) {
      $anim = [System.Windows.Media.Animation.DoubleAnimation]::new([double]$pair.el.Opacity, [double]$pair.to, $duration)
      $anim.EasingFunction = $ease
      $pair.el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
    }
  } else {
    $ui['SolidBg'].Opacity = $solidTarget
    $ui['GlassBg'].Opacity = $glassTarget
  }
  $ui['OpacitySlider'].IsEnabled = $enabled
}
function Apply-GlassOpacity([double]$percent) {
  $script:Settings.glassOpacity = [math]::Round($percent / 100.0, 3)
  $ui['OpacityValueText'].Text = ('{0}%' -f [int]$percent)
  if ($script:Settings.glass) {
    $ui['GlassBg'].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ui['GlassBg'].Opacity = $script:Settings.glassOpacity
  }
  if ($null -ne $script:ClockBgLayer) { $script:ClockBgLayer.Opacity = $script:Settings.glassOpacity }
  Request-Save
}

# ---------- 空状态 ----------
function Update-EmptyState([bool]$searching, [int]$count) {
  if ($script:CurrentView -eq 'history') { $ui['EmptyState'].Visibility = [System.Windows.Visibility]::Collapsed; return }
  if ($searching) {
    $ui['EmptyTitle'].Text = '没有找到匹配的便签'; $ui['EmptySubtitle'].Text = '换个关键词试试'
  } else {
    $ui['EmptyTitle'].Text = '还没有便签'; $ui['EmptySubtitle'].Text = '在下方输入一条，按 Enter 保存'
  }
  $ui['EmptyState'].Visibility = if ($count -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

# ---------- 列表 ----------
function Get-TaskMeta([hashtable]$task) {
  if (Test-IsNote $task) { return '笔记' }
  if ($task.kind -eq 'repeat') { return ((Get-UnitLabel ([string]$task.unit)) + '循环') }
  return '单次'
}
function Get-TaskInfo([hashtable]$task) {
  # 笔记没有时间概念：不显示顺延 / 逾期，标签只留「笔记」
  if (Test-IsNote $task) { return '' }
  if ($task.done -and $task.doneAt) {
    try { return ('完成于 ' + ([datetime]::Parse([string]$task.doneAt, $script:Invariant)).ToString('HH:mm')) } catch { return '' }
  }
  $todayKey = Get-DateKey (Get-Date).Date
  if ($task.kind -eq 'repeat') {
    if ($task.cycleKey -and [string]$task.cycleKey -lt $todayKey) { return '逾期，仍未完成' }
    return ''
  }
  try {
    $created = [datetime]::Parse([string]$task.created, $script:Invariant).Date
    $days = ((Get-Date).Date - $created).Days
    # 未完成的任务只说「多久前建的」，不写「已延迟 N 天」——避免制造进度压力
    if ($days -ge 1) { return (TCount '{0} 天前创建' $days) }
  } catch { }
  return ''
}
function New-SectionLabel([string]$text, [bool]$topGap = $false) {
  $label = [System.Windows.Controls.TextBlock]::new()
  $label.Text = $text
  $label.Style = $script:Win.Resources['SectionLabelStyle']
  if ($topGap) { $label.Margin = [System.Windows.Thickness]::new(3, 12, 0, 8) }
  return $label
}
function Add-RowAnimation([System.Windows.FrameworkElement]$element, [int]$index) {
  try {
    $element.Opacity = 0
    $transform = [System.Windows.Media.TranslateTransform]::new(0, 6)
    $element.RenderTransform = $transform
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(190))
    $ease = [System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $delay = [TimeSpan]::FromMilliseconds([math]::Min($index * 18, 120))
    $a1 = [System.Windows.Media.Animation.DoubleAnimation]::new(0.0, 1.0, $duration); $a1.BeginTime = $delay; $a1.EasingFunction = $ease
    $a2 = [System.Windows.Media.Animation.DoubleAnimation]::new(6.0, 0.0, $duration); $a2.BeginTime = $delay; $a2.EasingFunction = $ease
    $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a1)
    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $a2)
  } catch { }
}

# ---------- 条目右键菜单：复制内容 ----------
# 作为 ContextMenu 属性挂在卡片上，WPF 会代为管理生命周期，不存在浮层被 GC 的坑；
# 但弹出层不在可视树里，拿不到 XAML 的隐式样式，所以样式要显式套一遍。
function New-CopyContextMenu([string]$text) {
  $menu = [System.Windows.Controls.ContextMenu]::new()
  if ($null -ne $script:Win.Resources['AppMenuStyle']) { $menu.Style = $script:Win.Resources['AppMenuStyle'] }
  $item = [System.Windows.Controls.MenuItem]::new()
  $item.Header = (T '复制内容')
  $item.Tag = $text
  if ($null -ne $script:Win.Resources['AppMenuItemStyle']) { $item.Style = $script:Win.Resources['AppMenuItemStyle'] }
  $item.Add_Click({
      param($s, $e)
      try {
        $value = [string]$s.Tag
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        [System.Windows.Clipboard]::SetText($value)
        Show-Toast '已复制到剪贴板'
      } catch {
        try { Show-Toast '复制失败，剪贴板可能被别的程序占用' } catch { }
        Write-ErrorLog ('copy to clipboard failed: ' + $_.Exception.ToString())
      }
    })
  [void]$menu.Items.Add($item)
  return $menu
}

function New-TaskRow([hashtable]$task) {
  $locked = [bool]$script:Settings.locked
  $focus = [bool]$script:Settings.focusMode
  $card = [System.Windows.Controls.Border]::new()
  $card.Style = $script:Win.Resources['NoteCardStyle']
  $card.Tag = [string]$task.id
  if ([bool]$task.done) { $card.Opacity = 0.78 }
  try {
    $createdAt = [datetime]::Parse([string]$task.created, $script:Invariant)
    $card.ToolTip = "创建于 $($createdAt.ToString($script:FmtDateShort, $script:Culture))"
  } catch { }

  $isNote = Test-IsNote $task
  $grid = [System.Windows.Controls.Grid]::new()
  # 0 拖动把手 / 1 勾选框 / 2 正文 / 3 归档标签 / 4 提醒 / 5 置顶 / 6 删除
  # 列宽必须大于控件本身：勾选框 22 + 左右留白，否则会被裁掉一截（这就是「复选框显示不全」）
  $handleCol = if ($focus) { 0 } else { 18 }
  $checkCol = if ($focus -and $isNote) { 0 } else { 30 }
  $actionCol = if ($focus) { 0 } else { 24 }
  $columnPx = @($handleCol, $checkCol, 0, $actionCol, $actionCol, $actionCol, $actionCol)
  foreach ($index in 0..6) {
    $col = [System.Windows.Controls.ColumnDefinition]::new()
    if ($index -eq 2) { $col.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
    else { $col.Width = [System.Windows.GridLength]::new([double]$columnPx[$index], [System.Windows.GridUnitType]::Pixel) }
    [void]$grid.ColumnDefinitions.Add($col)
  }

  # 把手用透明 Border 包一层：TextBlock 只有字形本身能命中，3px 宽的「⋮」几乎抓不住
  $handleBox = [System.Windows.Controls.Border]::new()
  $handleBox.Width = 18
  $handleBox.Background = [System.Windows.Media.Brushes]::Transparent
  $handleBox.Cursor = [System.Windows.Input.Cursors]::SizeAll
  $handleBox.ToolTip = '按住拖动排序，拖到窗口外可把笔记变成独立小窗'
  if ($locked -or $focus) { $handleBox.Visibility = [System.Windows.Visibility]::Collapsed }
  $handleBox.Tag = [string]$task.id
  [System.Windows.Automation.AutomationProperties]::SetName($handleBox, '拖动排序')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($handleBox, "drag-$($task.id)")

  $handle = [System.Windows.Controls.TextBlock]::new()
  $handle.Text = '⋮'
  $handle.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI Symbol')
  $handle.FontSize = 15
  $handle.Foreground = $script:Win.Resources['TextMutedBrush']
  $handle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $handle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $handle.IsHitTestVisible = $false
  $handleBox.Child = $handle

  $handleBox.Add_MouseLeftButtonDown($script:OnDragHandleDown)
  $handleBox.Add_MouseMove($script:OnDragHandleMove)
  $handleBox.Add_MouseLeftButtonUp($script:OnDragHandleUp)
  $handleBox.Add_LostMouseCapture({ param($s, $e) if ($script:DragActive) { End-TaskDrag $false } else { $script:DragTaskId = $null } })
  [void]$grid.Children.Add($handleBox)

  if (-not $isNote) {
    $check = [System.Windows.Controls.CheckBox]::new()
    $check.Style = $script:Win.Resources['NoteCheckStyle']
    $check.IsChecked = [bool]$task.done
    $check.Tag = [string]$task.id
    $check.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $check.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $check.Margin = [System.Windows.Thickness]::new(1, 0, 4, 0)
    $checkName = if ($task.done) { '取消完成' } else { '标记完成' }
    $check.ToolTip = $checkName
    [System.Windows.Automation.AutomationProperties]::SetName($check, $checkName)
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($check, "done-$($task.id)")
    $check.Add_Checked($script:OnTaskChecked)
    $check.Add_Unchecked($script:OnTaskChecked)
    if ($locked) { $check.IsEnabled = $false }
    [void]$grid.Children.Add($check)
    [System.Windows.Controls.Grid]::SetColumn($check, 1)
  }

  $content = [System.Windows.Controls.StackPanel]::new()
  $content.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $metaPanel = [System.Windows.Controls.StackPanel]::new()
  $metaPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $metaPanel.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)

  $badge = [System.Windows.Controls.TextBlock]::new()
  $badge.Text = (Get-TaskMeta $task)
  $badge.FontSize = 9.5
  $badgeColor = if ($task.kind -eq 'repeat') { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
  $badge.Foreground = $badgeColor
  $badge.Cursor = [System.Windows.Input.Cursors]::Hand
  if ($isNote) { $badge.ToolTip = '点击转为待办条目' }
  elseif ($task.kind -eq 'repeat') { $badge.ToolTip = '点击修改循环周期' }
  else { $badge.ToolTip = '点击设置为循环任务或转为笔记' }
  # 用「抬起」而不是「按下」触发：按下时弹菜单，紧接着的抬起事件会把菜单立刻关掉
  $badge.Tag = [string]$task.id
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($badge, "type-$($task.id)")
  $badge.Add_MouseLeftButtonUp($script:OnTypeBadgeClick)
  [void]$metaPanel.Children.Add($badge)

  $infoText = Get-TaskInfo $task
  if (-not [string]::IsNullOrWhiteSpace($infoText)) {
    $separator = [System.Windows.Controls.TextBlock]::new(); $separator.Text = ' · '; $separator.FontSize = 9.5
    $separator.Foreground = $script:Win.Resources['TextMutedBrush']; [void]$metaPanel.Children.Add($separator)
    $info = [System.Windows.Controls.TextBlock]::new(); $info.Text = $infoText; $info.FontSize = 9.5
    $info.Foreground = $script:Win.Resources['TextMutedBrush']
    [void]$metaPanel.Children.Add($info)
  }
  $remindAt = Get-TaskRemindAt $task
  if ($null -ne $remindAt -and -not [bool]$task.done) {
    $separator2 = [System.Windows.Controls.TextBlock]::new(); $separator2.Text = ' · '; $separator2.FontSize = 9.5
    $separator2.Foreground = $script:Win.Resources['TextMutedBrush']; [void]$metaPanel.Children.Add($separator2)
    $remindInfo = [System.Windows.Controls.TextBlock]::new()
    $remindInfo.Text = '提醒 ' + (Format-RemindLabel $remindAt)
    $remindInfo.FontSize = 9.5
    $remindInfo.Foreground = if ($remindAt -lt (Get-Date)) { $script:Win.Resources['TextMutedBrush'] } else { $script:Win.Resources['AccentTextBrush'] }
    [void]$metaPanel.Children.Add($remindInfo)
  }
  # 已归档到的标签：以 #标签 形式跟在元信息后面
  foreach ($tagId in @(Get-TaskTagIds $task)) {
    $tag = Find-Tag $tagId
    if ($null -eq $tag) { continue }
    $gap = [System.Windows.Controls.TextBlock]::new(); $gap.Text = '  '; $gap.FontSize = 9.5
    [void]$metaPanel.Children.Add($gap)
    $chip = [System.Windows.Controls.TextBlock]::new()
    $chip.Text = '#' + [string]$tag.name
    $chip.FontSize = 9.5
    $chip.Foreground = New-Brush ([string]$tag.color)
    $chip.ToolTip = '点击管理这条的标签'
    $chip.Tag = [string]$task.id
    # 标签名是用户写的，打标避免被当成界面文案翻译
    try { [System.Windows.Automation.AutomationProperties]::SetHelpText($chip, 'user') } catch { }
    $chip.Cursor = [System.Windows.Input.Cursors]::Hand
    # 同徽标：抬起再弹，否则菜单会被这次按下的抬起事件顶掉
    $chip.Add_MouseLeftButtonUp($script:OnTaskTagClick)
    [void]$metaPanel.Children.Add($chip)
  }
  [void]$content.Children.Add($metaPanel)

  if ([bool]$task.done -or $locked) {
    $textBlock = [System.Windows.Controls.TextBlock]::new()
    $textBlock.Text = [string]$task.text
    $textBlock.Tag = 'user'
    $textBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $textBlock.FontSize = 13.5
    if ([bool]$task.done) {
      $textBlock.Foreground = $script:Win.Resources['TextSecondaryBrush']
      $textBlock.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
      $textBlock.Add_MouseLeftButtonDown($script:OnDoneTextClick)
    } else {
      $textBlock.Foreground = $script:Win.Resources['TextPrimaryBrush']
    }
    $textBlock.Margin = [System.Windows.Thickness]::new(0, 1, 4, 1)
    $textBlock.Tag = [string]$task.id
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($textBlock, "text-$($task.id)")
    [System.Windows.Automation.AutomationProperties]::SetName($textBlock, '便签内容')
    [void]$content.Children.Insert(0, $textBlock)
  } else {
    $textBox = [System.Windows.Controls.TextBox]::new()
    $textBox.Style = $script:Win.Resources['NoteTextStyle']
    $textBox.Text = [string]$task.text
    $textBox.Tag = [string]$task.id
    $textBox.MinHeight = 21
    # 编辑已有条目也要能换行：NoteTextStyle 默认是单行，这里用本地值覆盖它
    # 不设 MaxHeight：卡片随行数自然变高，靠外层 TasksScroller 滚动，避免内容被裁
    $textBox.AcceptsReturn = $true
    $textBox.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $textBox.ToolTip = 'Shift + Enter 换行，Enter 回到输入框'
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($textBox, "text-$($task.id)")
    [System.Windows.Automation.AutomationProperties]::SetName($textBox, '便签内容')
    $script:TaskTextElements[[string]$task.id] = $textBox
    $textBox.Add_TextChanged($script:OnTaskTextChanged)
    $textBox.Add_PreviewKeyDown($script:OnTaskTextKeyDown)
    [void]$content.Children.Insert(0, $textBox)
  }
  [void]$grid.Children.Add($content)
  [System.Windows.Controls.Grid]::SetColumn($content, 2)

  $tagBtn = [System.Windows.Controls.Button]::new()
  $tagBtn.Style = $script:Win.Resources['NoteDeleteStyle']
  $tagBtn.Content = [string][char]0xE8EC
  $tagBtn.Tag = [string]$task.id
  $tagBtn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $hasTag = @(Get-TaskTagIds $task).Count -gt 0
  $tagBtn.ToolTip = if ($hasTag) { '修改标签归档' } else { '归档到标签' }
  $tagBtn.Foreground = if ($hasTag) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
  [System.Windows.Automation.AutomationProperties]::SetName($tagBtn, '归档到标签')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($tagBtn, "tag-$($task.id)")
  $tagBtn.Add_Click($script:OnTaskTagClick)
  if ([bool]$task.done -or $locked -or $focus) { $tagBtn.Visibility = [System.Windows.Visibility]::Hidden }
  [void]$grid.Children.Add($tagBtn)
  [System.Windows.Controls.Grid]::SetColumn($tagBtn, 3)

  $clock = [System.Windows.Controls.Button]::new()
  $clock.Style = $script:Win.Resources['NoteDeleteStyle']
  $clock.Content = if ($null -ne (Get-TaskRemindAt $task)) { [string][char]0xE823 } else { [string][char]0xE7ED }
  $clock.Tag = [string]$task.id
  $clock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $clock.ToolTip = if ($null -ne (Get-TaskRemindAt $task)) { '修改 / 取消提醒' } else { '设置提醒时间' }
  $clock.Foreground = if ($null -ne (Get-TaskRemindAt $task)) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
  [System.Windows.Automation.AutomationProperties]::SetName($clock, '设置提醒')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($clock, "remind-$($task.id)")
  $clock.Add_Click($script:OnTaskClockClick)
  if ([bool]$task.done -or $locked -or $focus) { $clock.Visibility = [System.Windows.Visibility]::Hidden }
  [void]$grid.Children.Add($clock)
  [System.Windows.Controls.Grid]::SetColumn($clock, 4)

  $pin = [System.Windows.Controls.Primitives.ToggleButton]::new()
  $pin.Style = $script:Win.Resources['PinToggleStyle']
  $pin.Content = [string][char]0xE718
  $pin.IsChecked = [bool]$task.pinned
  $pin.Tag = [string]$task.id
  $pin.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $pin.ToolTip = '置顶这条便签'
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($pin, "pin-$($task.id)")
  $pin.Add_Checked($script:OnTaskPinToggled)
  $pin.Add_Unchecked($script:OnTaskPinToggled)
  if ([bool]$task.done -or $locked -or $focus) { $pin.Visibility = [System.Windows.Visibility]::Hidden }
  [void]$grid.Children.Add($pin)
  [System.Windows.Controls.Grid]::SetColumn($pin, 5)

  $delete = [System.Windows.Controls.Button]::new()
  $delete.Style = $script:Win.Resources['NoteDeleteStyle']
  $delete.Content = [string][char]0xE74D
  $delete.Tag = [string]$task.id
  $delete.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $delete.ToolTip = if ($task.kind -eq 'repeat') { '删除本次（循环仍会继续）' } else { '删除便签' }
  [System.Windows.Automation.AutomationProperties]::SetName($delete, '删除便签')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($delete, "delete-$($task.id)")
  $delete.Add_Click($script:OnTaskDeleteClick)
  if ($locked -or $focus) { $delete.Visibility = [System.Windows.Visibility]::Hidden }
  [void]$grid.Children.Add($delete)
  [System.Windows.Controls.Grid]::SetColumn($delete, 6)

  $card.Child = $grid
  $card.ContextMenu = New-CopyContextMenu ([string]$task.text)
  return $card
}

function Get-FilteredTasks {
  $tasks = @($script:Tasks)
  if (-not [string]::IsNullOrWhiteSpace($script:SearchQuery)) {
    $q = $script:SearchQuery
    $tasks = @($tasks | Where-Object { ([string]$_.text).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$script:TagFilter)) {
    $fid = [string]$script:TagFilter
    $tasks = @($tasks | Where-Object { @(Get-TaskTagIds $_) -contains $fid })
  }
  return $tasks
}

function Rebuild-Tasks([bool]$animate = $true) {
  $hostPanel = $ui['TasksHost']
  $hostPanel.Children.Clear()
  $script:TaskTextElements.Clear()
  $tasks = @(Get-FilteredTasks)
  $active = @($tasks | Where-Object { -not $_.done })
  $pinned = @($active | Where-Object { $_.pinned } | Sort-Object -Property @{ Expression = { [int]$_.order } })
  $rest = @($active | Where-Object { -not $_.pinned })
  $normal = @($rest | Where-Object { -not (Test-IsNote $_) } | Sort-Object -Property @{ Expression = { [int]$_.order } })
  $notes = @($rest | Where-Object { Test-IsNote $_ } | Sort-Object -Property @{ Expression = { [int]$_.order } })
  $done = @($tasks | Where-Object { $_.done } | Sort-Object -Property @{ Expression = { [string]$_.doneAt }; Descending = $true })
  $index = 0
  $hasSection = $false
  if ($pinned.Count -gt 0) {
    [void]$hostPanel.Children.Add((New-SectionLabel "置顶 · $($pinned.Count)"))
    foreach ($task in $pinned) { $row = New-TaskRow $task; [void]$hostPanel.Children.Add($row); if ($animate) { Add-RowAnimation $row $index }; $index++ }
    $hasSection = $true
  }
  if ($normal.Count -gt 0) {
    [void]$hostPanel.Children.Add((New-SectionLabel "待办 · $($normal.Count)" $hasSection))
    foreach ($task in $normal) { $row = New-TaskRow $task; [void]$hostPanel.Children.Add($row); if ($animate) { Add-RowAnimation $row $index }; $index++ }
    $hasSection = $true
  }
  if ($notes.Count -gt 0) {
    [void]$hostPanel.Children.Add((New-SectionLabel "笔记 · $($notes.Count)" $hasSection))
    foreach ($task in $notes) { $row = New-TaskRow $task; [void]$hostPanel.Children.Add($row); if ($animate) { Add-RowAnimation $row $index }; $index++ }
    $hasSection = $true
  }
  if ($done.Count -gt 0 -and -not [bool]$script:Settings.focusMode) {
    [void]$hostPanel.Children.Add((New-SectionLabel "已完成 · $($done.Count)" $hasSection))
    foreach ($task in $done) { $row = New-TaskRow $task; [void]$hostPanel.Children.Add($row); if ($animate) { Add-RowAnimation $row $index }; $index++ }
  }
  $searching = (-not [string]::IsNullOrWhiteSpace($script:SearchQuery)) -or (-not [string]::IsNullOrWhiteSpace([string]$script:TagFilter))
  Update-EmptyState $searching $tasks.Count
  Update-Progress
  Sync-LangAfterRebuild
}

function Update-Progress {
  # 笔记不是待办，不参与完成率，否则进度条永远到不了 100%
  $all = @($script:Tasks | Where-Object { -not (Test-IsNote $_) })
  $total = $all.Count
  $done = @($all | Where-Object { $_.done }).Count
  $pending = $total - $done
  $todayKey = Get-DateKey (Get-Date).Date
  $todayDone = 0
  foreach ($task in $all) {
    if ($task.done -and $task.doneAt) {
      try { if ((Get-DateKey ([datetime]::Parse([string]$task.doneAt, $script:Invariant)).Date) -eq $todayKey) { $todayDone++ } } catch { }
    }
  }
  if ($total -eq 0) { $ui['ProgressText'].Text = T '今天要做什么？' }
  elseif ($pending -eq 0) { $ui['ProgressText'].Text = (TCount '全部完成 · 共 {0} 项' $done) }
  else { $ui['ProgressText'].Text = (T '待办 {0} · 今日完成 {1}') -f $pending, $todayDone }
  $ratio = if ($total -gt 0) { $done / $total } else { 0 }
  $target = [double]($ratio * 84.0)
  try {
    $current = if ($ui['ProgressFill'].ActualWidth -gt 0) { [double]$ui['ProgressFill'].ActualWidth } else { 0.0 }
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
    $anim = [System.Windows.Media.Animation.DoubleAnimation]::new($current, $target, $duration)
    $ease = [System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $anim.EasingFunction = $ease
    $ui['ProgressFill'].BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $anim)
  } catch { $ui['ProgressFill'].Width = $target }
}

# ---------- 历史 ----------
function Get-CompletionRecords {
  $records = @()
  foreach ($h in $script:History) { $records += @{ doneAt = [string]$h.doneAt; text = [string]$h.text; kind = [string]$h.kind; unit = [string]$h.unit; id = [string]$h.id } }
  foreach ($t in $script:Tasks) { if ($t.done -and $t.doneAt) { $records += @{ doneAt = [string]$t.doneAt; text = [string]$t.text; kind = [string]$t.kind; unit = [string]$t.unit; id = [string]$t.id } } }
  return $records
}
function New-HistoryRow([hashtable]$record) {
  $card = [System.Windows.Controls.Border]::new()
  $card.Style = $script:Win.Resources['NoteCardStyle']
  $card.Padding = [System.Windows.Thickness]::new(10, 8, 6, 8)
  $grid = [System.Windows.Controls.Grid]::new()
  $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $c3 = [System.Windows.Controls.ColumnDefinition]::new(); $c3.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2); [void]$grid.ColumnDefinitions.Add($c3)
  $glyph = [System.Windows.Controls.TextBlock]::new()
  $glyph.Text = [string][char]0xE73E; $glyph.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
  $glyph.FontSize = 10; $glyph.Foreground = $script:Win.Resources['AccentTextBrush']
  $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $glyph.Margin = [System.Windows.Thickness]::new(2, 0, 8, 0)
  [void]$grid.Children.Add($glyph)
  $panel = [System.Windows.Controls.StackPanel]::new()
  $panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $textBlock = [System.Windows.Controls.TextBlock]::new()
  $textBlock.Text = [string]$record.text; $textBlock.FontSize = 12.5
  $textBlock.Tag = 'user'
  $textBlock.Foreground = $script:Win.Resources['TextSecondaryBrush']; $textBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
  [void]$panel.Children.Add($textBlock)
  $metaText = ''
  try { $metaText = ([datetime]::Parse([string]$record.doneAt, $script:Invariant)).ToString('HH:mm') } catch { }
  if ($record.kind -eq 'repeat') { $metaText += ' · ' + (Get-UnitLabel ([string]$record.unit)) + '循环' } else { $metaText += ' · 单次' }
  $meta = [System.Windows.Controls.TextBlock]::new()
  $meta.Text = $metaText; $meta.FontSize = 9.5; $meta.Foreground = $script:Win.Resources['TextMutedBrush']
  $meta.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
  [void]$panel.Children.Add($meta)
  [void]$grid.Children.Add($panel)
  [System.Windows.Controls.Grid]::SetColumn($panel, 1)
  $actions = [System.Windows.Controls.StackPanel]::new()
  $actions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $actions.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $restore = [System.Windows.Controls.Button]::new()
  $restore.Style = $script:Win.Resources['NoteDeleteStyle']; $restore.Content = [string][char]0xE7A7
  $restore.Tag = [string]$record.id; $restore.ToolTip = '重新加入待办'
  [System.Windows.Automation.AutomationProperties]::SetName($restore, '重新加入待办')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($restore, "restore-$($record.id)")
  $restore.Add_Click($script:OnHistoryRestoreClick)
  $delete = [System.Windows.Controls.Button]::new()
  $delete.Style = $script:Win.Resources['NoteDeleteStyle']; $delete.Content = [string][char]0xE74D
  $delete.Tag = [string]$record.id; $delete.ToolTip = '从历史中删除'
  [System.Windows.Automation.AutomationProperties]::SetName($delete, '删除历史记录')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($delete, "hdelete-$($record.id)")
  $delete.Add_Click($script:OnHistoryDeleteClick)
  [void]$actions.Children.Add($restore); [void]$actions.Children.Add($delete)
  [void]$grid.Children.Add($actions)
  [System.Windows.Controls.Grid]::SetColumn($actions, 2)
  $card.Child = $grid
  $card.ContextMenu = New-CopyContextMenu ([string]$record.text)
  return $card
}
function Rebuild-History([bool]$animate = $true) {
  $hostPanel = $ui['HistoryHost']
  $hostPanel.Children.Clear()
  $records = @($script:History)
  if (-not [string]::IsNullOrWhiteSpace($script:SearchQuery)) {
    $q = $script:SearchQuery
    $records = @($records | Where-Object { ([string]$_.text).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
  }
  if ($records.Count -eq 0) {
    $searching = -not [string]::IsNullOrWhiteSpace($script:SearchQuery)
    $info = [System.Windows.Controls.TextBlock]::new()
    $info.Text = if ($searching) { '没有找到匹配的历史记录' } else { '还没有完成记录，完成任务后次日会归档到这里' }
    $info.FontSize = 11; $info.Foreground = $script:Win.Resources['TextMutedBrush']
    $info.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $info.Margin = [System.Windows.Thickness]::new(0, 26, 0, 0)
    [void]$hostPanel.Children.Add($info)
    return
  }
  $groups = $records | Group-Object { try { (Get-DateKey ([datetime]::Parse([string]$_.doneAt, $script:Invariant)).Date) } catch { '未知' } } |
    Sort-Object -Property @{ Expression = { $_.Name }; Descending = $true }
  $index = 0
  foreach ($group in $groups) {
    $dateLabel = $group.Name
    try { $dateLabel = ([datetime]::ParseExact($group.Name, 'yyyy-MM-dd', $script:Invariant)).ToString($script:FmtDayShort, $script:Culture) } catch { }
    [void]$hostPanel.Children.Add((New-SectionLabel ($dateLabel + ' · ' + (TCount '{0} 项' $group.Count)) ($index -gt 0)))
    foreach ($record in $group.Group) {
      $row = New-HistoryRow $record
      [void]$hostPanel.Children.Add($row)
      if ($animate) { Add-RowAnimation $row $index }
      $index++
    }
  }
  Sync-LangAfterRebuild
}
# 列表是代码现拼的，重建后要再跑一遍翻译，否则英文界面里会冒出中文行。
# 必须先 UpdateLayout：未布局的子树不在视觉树上，遍历会漏掉整页。
function Sync-LangAfterRebuild {
  if ($script:LangCode -ne 'en') { return }
  try { $script:Win.UpdateLayout() } catch { }
  Update-LangUi
}
function Rebuild-All([bool]$animate = $true) {
  # 顶部进度条是全量统计，跟当前在哪个标签页无关；在回收站/历史页做还原、彻底删除时
  # 也必须刷新，否则会出现「数据变了但角标还是旧数字」。
  Update-Progress
  if ($script:CurrentView -eq 'tasks') { Rebuild-Tasks $animate }
  elseif ($script:CurrentView -eq 'trash') { Rebuild-Trash $animate }
  else { Rebuild-History $animate; Rebuild-Tasks $false }
}

# ---------- 回收站 ----------
function New-TrashRow([hashtable]$item) {
  $card = [System.Windows.Controls.Border]::new()
  $card.Style = $script:Win.Resources['NoteCardStyle']
  $card.Padding = [System.Windows.Thickness]::new(10, 8, 6, 8)
  $grid = [System.Windows.Controls.Grid]::new()
  $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $c3 = [System.Windows.Controls.ColumnDefinition]::new(); $c3.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2); [void]$grid.ColumnDefinitions.Add($c3)

  $glyph = [System.Windows.Controls.TextBlock]::new()
  $glyph.Text = [string]([char]0xE74D); $glyph.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
  $glyph.FontSize = 10; $glyph.Foreground = $script:Win.Resources['TextMutedBrush']
  $glyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $glyph.Margin = [System.Windows.Thickness]::new(2, 0, 8, 0)
  [void]$grid.Children.Add($glyph)

  $panel = [System.Windows.Controls.StackPanel]::new()
  $panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $textBlock = [System.Windows.Controls.TextBlock]::new()
  $textBlock.Text = [string]$item.text; $textBlock.FontSize = 12.5
  $textBlock.Tag = 'user'
  $textBlock.Foreground = $script:Win.Resources['TextSecondaryBrush']
  $textBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
  [void]$panel.Children.Add($textBlock)
  $metaText = '删除于 '
  try { $metaText += ([datetime]::Parse([string]$item.deletedAt, $script:Invariant)).ToString($script:FmtDateShort, $script:Culture) } catch { $metaText += '未知时间' }
  if ([string]$item.source -eq 'history') { $metaText += ' · 来自历史' }
  elseif (Test-IsNote $item) { $metaText += ' · 笔记' }
  elseif ($item.kind -eq 'repeat') { $metaText += ' · ' + (Get-UnitLabel ([string]$item.unit)) + '循环' }
  $meta = [System.Windows.Controls.TextBlock]::new()
  $meta.Text = $metaText; $meta.FontSize = 9.5; $meta.Foreground = $script:Win.Resources['TextMutedBrush']
  $meta.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
  [void]$panel.Children.Add($meta)
  [void]$grid.Children.Add($panel)
  [System.Windows.Controls.Grid]::SetColumn($panel, 1)

  $actions = [System.Windows.Controls.StackPanel]::new()
  $actions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $actions.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $restore = [System.Windows.Controls.Button]::new()
  $restore.Style = $script:Win.Resources['NoteDeleteStyle']; $restore.Content = [string][char]0xE7A7
  $restore.Tag = [string]$item.id; $restore.ToolTip = '还原'
  [System.Windows.Automation.AutomationProperties]::SetName($restore, '还原')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($restore, "trash-restore-$($item.id)")
  $restore.Add_Click($script:OnTrashRestoreClick)
  $delete = [System.Windows.Controls.Button]::new()
  $delete.Style = $script:Win.Resources['NoteDeleteStyle']; $delete.Content = [string][char]0xE74D
  $delete.Tag = [string]$item.id; $delete.ToolTip = '彻底删除（不可恢复）'
  [System.Windows.Automation.AutomationProperties]::SetName($delete, '彻底删除')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($delete, "trash-purge-$($item.id)")
  $delete.Add_Click($script:OnTrashPurgeClick)
  [void]$actions.Children.Add($restore); [void]$actions.Children.Add($delete)
  [void]$grid.Children.Add($actions)
  [System.Windows.Controls.Grid]::SetColumn($actions, 2)
  $card.Child = $grid
  $card.ContextMenu = New-CopyContextMenu ([string]$item.text)
  return $card
}
function Rebuild-Trash([bool]$animate = $true) {
  $hostPanel = $ui['TrashHost']
  if ($null -eq $hostPanel) { return }
  $hostPanel.Children.Clear()
  $items = @($script:Trash | Sort-Object -Property @{ Expression = { [string]$_.deletedAt }; Descending = $true })
  if ($items.Count -eq 0) {
    $info = [System.Windows.Controls.TextBlock]::new()
    $info.Text = '回收站是空的，删除的条目会先放到这里'
    $info.FontSize = 11; $info.Foreground = $script:Win.Resources['TextMutedBrush']
    $info.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $info.Margin = [System.Windows.Thickness]::new(0, 26, 0, 0)
    [void]$hostPanel.Children.Add($info)
    return
  }
  [void]$hostPanel.Children.Add((New-SectionLabel (TCount '已删除 · {0} 项，还原后回到列表' $items.Count)))
  $index = 0
  foreach ($item in $items) {
    $row = New-TrashRow $item
    [void]$hostPanel.Children.Add($row)
    if ($animate) { Add-RowAnimation $row $index }
    $index++
  }
  $clear = [System.Windows.Controls.Button]::new()
  $clear.Style = $script:Win.Resources['DangerButtonStyle']
  $clear.Content = '清空回收站'
  $clear.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $clear.Margin = [System.Windows.Thickness]::new(3, 8, 0, 16)
  [System.Windows.Automation.AutomationProperties]::SetName($clear, '清空回收站')
  [System.Windows.Automation.AutomationProperties]::SetAutomationId($clear, 'TrashClearAll')
  $clear.Add_Click($script:OnTrashClearAll)
  [void]$hostPanel.Children.Add($clear)
  Sync-LangAfterRebuild
}

# ---------- 视图 / 搜索 ----------
function Update-TagFilterButton {
  if ($null -eq $ui['TagFilterButton']) { return }
  $tag = Find-Tag ([string]$script:TagFilter)
  if ($null -ne $tag) {
    $label = '#' + [string]$tag.name
    if ($label.Length -gt 12) { $label = $label.Substring(0, 11) + '…' }
    # label 里的标签名是用户内容，只给后缀加语言
    $ui['TagFilterButton'].Content = $label + ' ▾'
    $ui['TagFilterButton'].Foreground = $script:Win.Resources['AccentTextBrush']
    $ui['TagFilterButton'].BorderBrush = $script:Win.Resources['AccentDeepBrush']
  } else {
    $ui['TagFilterButton'].Content = (T '全部标签') + ' ▾'
    $ui['TagFilterButton'].Foreground = $script:Win.Resources['TextSecondaryBrush']
    $ui['TagFilterButton'].BorderBrush = $script:Win.Resources['PillBorderBrush']
  }
}
function Update-SearchBar {
  $show = $script:SearchOpen -or (-not [string]::IsNullOrWhiteSpace([string]$script:TagFilter))
  $ui['SearchBar'].Visibility = if ($show) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  Update-TagFilterButton
}
function Set-TagFilter([string]$tagId) {
  $script:TagFilter = if ([string]::IsNullOrWhiteSpace($tagId)) { '' } else { [string]$tagId }
  Update-SearchBar
  if ($script:CurrentView -eq 'tasks') { Rebuild-Tasks $true } else { Rebuild-All }
}
function Switch-View([string]$view) {
  if ($view -notin @('tasks', 'history', 'trash')) { $view = 'tasks' }
  $script:CurrentView = $view
  $script:Settings.view = $view
  Request-Save
  $script:SyncingUi = $true
  $ui['TabTasks'].IsChecked = ($view -eq 'tasks')
  $ui['TabHistory'].IsChecked = ($view -eq 'history')
  if ($ui['TabTrash']) { $ui['TabTrash'].IsChecked = ($view -eq 'trash') }
  $script:SyncingUi = $false
  $ui['TasksScroller'].Visibility = if ($view -eq 'tasks') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $ui['HistoryScroller'].Visibility = if ($view -eq 'history') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  if ($ui['TrashScroller']) { $ui['TrashScroller'].Visibility = if ($view -eq 'trash') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
  if ($view -eq 'tasks') { Rebuild-Tasks $true }
  elseif ($view -eq 'trash') { Rebuild-Trash $true }
  else { Rebuild-History $true }
  $count = if ($view -eq 'tasks') { @(Get-FilteredTasks).Count }
  elseif ($view -eq 'trash') { $script:Trash.Count } else { $script:History.Count }
  if ($view -ne 'trash') {
    Update-EmptyState ((-not [string]::IsNullOrWhiteSpace($script:SearchQuery)) -or (-not [string]::IsNullOrWhiteSpace([string]$script:TagFilter))) $count
  } else {
    $ui['EmptyState'].Visibility = [System.Windows.Visibility]::Collapsed
  }
}
function Open-Search {
  $script:SearchOpen = $true
  Update-SearchBar
  [void]$ui['SearchInput'].Focus()
}
function Close-Search {
  $script:SearchOpen = $false
  $ui['SearchInput'].Text = ''
  $script:SearchQuery = ''
  $script:TagFilter = ''
  Update-SearchBar
  if ($script:CurrentView -eq 'tasks') { Rebuild-Tasks $true } else { Rebuild-All }
}

# ---------- 设置 ----------
function Update-ThemeSelection {
  if (-not $ui['ThemeGrid']) { return }
  foreach ($child in $ui['ThemeGrid'].Children) {
    if ($child.Tag -and [string]$child.Tag -eq $script:Settings.theme) { $child.BorderBrush = $script:Win.Resources['AccentBrush'] }
    else { $child.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0x22, 255, 255, 255)) }
  }
}
function Build-ThemeCards {
  $grid = $ui['ThemeGrid']
  $grid.Children.Clear()
  foreach ($key in $script:Themes.Keys) {
    $theme = $script:Themes[$key]
    $card = [System.Windows.Controls.Button]::new()
    $card.Style = $script:Win.Resources['ThemeCardStyle']
    $card.Tag = $key
    $gradient = [System.Windows.Media.LinearGradientBrush]::new()
    $gradient.StartPoint = [System.Windows.Point]::new(0, 0); $gradient.EndPoint = [System.Windows.Point]::new(1, 1)
    $gradient.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $theme.solidTop), 0))
    $gradient.GradientStops.Add([System.Windows.Media.GradientStop]::new((Get-Color $theme.solidBottom), 1))
    $card.Background = $gradient
    [System.Windows.Automation.AutomationProperties]::SetName($card, "主题 $($theme.name)")
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($card, "theme-$key")
    $card.Add_Click($script:OnThemeCardClick)
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = [string]$theme.name; $label.FontSize = 10
    if (Test-ThemeIsLight $theme) {
      $label.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0xD9, 0x2E, 0x32, 0x2C))
    } else {
      $label.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(0xE6, 255, 255, 255))
    }
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $label.Margin = [System.Windows.Thickness]::new(8, 0, 8, 6)
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8; $dot.Height = 8; $dot.Fill = New-Brush $theme.accent
    $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $dot.Margin = [System.Windows.Thickness]::new(8, 8, 0, 0)
    $inner = [System.Windows.Controls.Grid]::new()
    [void]$inner.Children.Add($dot); [void]$inner.Children.Add($label)
    $card.Content = $inner
    [void]$grid.Children.Add($card)
  }
  Update-ThemeSelection
}
function Update-LangSelection {
  if ($null -eq $ui['LangPanel']) { return }
  foreach ($btn in $ui['LangPanel'].Children) {
    $on = [string]$btn.Tag -eq [string]$script:Settings.language
    try {
      $btn.BorderBrush = if ($on) { $script:Win.Resources['AccentBrush'] } else { $script:Win.Resources['PillBorderBrush'] }
      $btn.Foreground = if ($on) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextSecondaryBrush'] }
    } catch { }
  }
}

function Build-LangButtons {
  $panel = $ui['LangPanel']
  if ($null -eq $panel) { return }
  $panel.Children.Clear()
  foreach ($spec in @(@{ key = 'auto'; label = '跟随系统' }, @{ key = 'zh'; label = '中文' }, @{ key = 'en'; label = 'English' })) {
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Style = $script:Win.Resources['SmallButtonStyle']
    $btn.Content = [string]$spec.label
    $btn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
    $btn.BorderThickness = [System.Windows.Thickness]::new(1)
    $btn.Tag = [string]$spec.key
    [System.Windows.Automation.AutomationProperties]::SetName($btn, '界面语言 ' + [string]$spec.label)
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($btn, 'lang-' + [string]$spec.key)
    $btn.Add_Click($script:OnLangClick)
    [void]$panel.Children.Add($btn)
  }
  Update-LangSelection
}

$script:OnLangClick = {
  try {
    $key = [string]$sender.Tag
    if ([string]$script:Settings.language -eq $key) { return }
    $script:Settings.language = $key
    Set-AppLanguage $key
    Save-State
    # 先让各处按新语言重新生成文字，最后统一翻译静态控件，避免中英混排
    Update-Clock
    Rebuild-All $false
    Sync-SettingsUi
    Update-LangSelection
    Update-LangUi
  } catch { Write-ErrorLog ("apply language failed: " + $_.Exception.ToString()) }
}

function Sync-SettingsUi {
  $script:SyncingUi = $true
  $ui['SettingsGlassToggle'].IsChecked = [bool]$script:Settings.glass
  $ui['OpacitySlider'].Value = [double]$script:Settings.glassOpacity * 100
  $ui['OpacityValueText'].Text = ('{0}%' -f [int]([double]$script:Settings.glassOpacity * 100))
  $ui['OpacitySlider'].IsEnabled = [bool]$script:Settings.glass
  $ui['TrayToggle'].IsChecked = [bool]$script:Settings.tray
  $ui['CloseToTrayToggle'].IsChecked = [bool]$script:Settings.closeToTray
  $ui['CloseToTrayToggle'].IsEnabled = [bool]$script:Settings.tray
  $ui['HotkeyToggle'].IsChecked = [bool]$script:Settings.hotkey
  $ui['AutostartToggle'].IsChecked = [bool]$script:Settings.autostart
  $ui['Clock24Toggle'].IsChecked = [bool]$script:Settings.clock24
  $ui['ClockSecondsToggle'].IsChecked = [bool]$script:Settings.clockSeconds
  $ui['ClockCalendarToggle'].IsChecked = [bool]$script:Settings.clockCalendar
  $ui['RemindSoundToggle'].IsChecked = [bool]$script:Settings.remindSound
  $ui['DoneSoundToggle'].IsChecked = ([bool]$script:Settings.doneSound -ne $false)
  $ui['PomodoroToggle'].IsChecked = ([bool]$script:Settings.pomodoro -ne $false)
  $script:SyncingUi = $false
  Update-ThemeSelection
  Update-LangSelection
  Update-RemindLeadUi
  Update-RemindExpireUi
  Update-MissedUi
}
function Open-Settings {
  Sync-SettingsUi
  $ui['SettingsStatus'].Text = ''
  $ui['SettingsOverlay'].Visibility = [System.Windows.Visibility]::Visible
}
function Close-Settings { $ui['SettingsOverlay'].Visibility = [System.Windows.Visibility]::Collapsed }

# ---------- 托盘 / 热键 / 自启 ----------
function Toggle-WindowVisibility {
  if ($script:Win.IsVisible) { Hide-AppWindow } else { Show-AppWindow }
}
function Show-AppWindow {
  try {
    $script:Win.Show()
    if ($script:Win.WindowState -eq [System.Windows.WindowState]::Minimized) { $script:Win.WindowState = [System.Windows.WindowState]::Normal }
    [void]$script:Win.Activate()
    if ($script:Hwnd -ne [IntPtr]::Zero) { [void][GN.Native]::SetForegroundWindow($script:Hwnd) }
  } catch { }
}
function Hide-AppWindow {
  try {
    $script:Win.Hide()
    if ($script:TrayIcon -and $script:Settings.tray -and -not $script:TrayBalloonShown) {
      $script:TrayBalloonShown = $true
      try { $script:TrayIcon.ShowBalloonTip(1800, '核桃便签', '已隐藏到托盘，Ctrl + Alt + N 可以呼出', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
  } catch { }
}
function Initialize-Tray {
  if (-not $script:Settings.tray) { return }
  try {
    if ($null -eq $script:TrayIcon) {
      $icoPath = Join-Path $script:AssetDir 'icon.ico'
      $icon = if (Test-Path -LiteralPath $icoPath) { [System.Drawing.Icon]::new($icoPath) } else { [System.Drawing.SystemIcons]::Application }
      $script:TrayIcon = [System.Windows.Forms.NotifyIcon]::new()
      $script:TrayIcon.Icon = $icon
      $script:TrayIcon.Text = (T '核桃便签')
      $menu = [System.Windows.Forms.ContextMenuStrip]::new()
      $itemToggle = [System.Windows.Forms.ToolStripMenuItem]::new((T '显示 / 隐藏'))
      $itemToggle.Add_Click({ Toggle-WindowVisibility })
      $itemSettings = [System.Windows.Forms.ToolStripMenuItem]::new((T '打开设置'))
      $itemSettings.Add_Click({ Show-AppWindow; Open-Settings })
      $itemExit = [System.Windows.Forms.ToolStripMenuItem]::new((T '退出核桃便签'))
      $itemExit.Add_Click({ $script:ForceExit = $true; $script:Win.Close() })
      [void]$menu.Items.Add($itemToggle)
      [void]$menu.Items.Add($itemSettings)
      [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
      [void]$menu.Items.Add($itemExit)
      $script:TrayIcon.ContextMenuStrip = $menu
      $script:TrayIcon.Add_DoubleClick({ Toggle-WindowVisibility })
    }
    $script:TrayIcon.Visible = $true
  } catch { Write-ErrorLog "tray init failed: $($_.Exception.ToString())" }
}
# 托盘菜单是 WinForms 画的，既不在 WPF 视觉树里、也不会随界面语言刷新，
# 所以切换语言时得照着当前语言把条目文字重写一遍（菜单只建一次，只改文字最省事）。
function Update-TrayMenu {
  if ($null -eq $script:TrayIcon) { return }
  $strip = $script:TrayIcon.ContextMenuStrip
  if ($null -eq $strip) { return }
  # 顺序固定：显示/隐藏、打开设置、分隔线、退出
  if ($strip.Items.Count -lt 4) { return }
  $strip.Items[0].Text = (T '显示 / 隐藏')
  $strip.Items[1].Text = (T '打开设置')
  $strip.Items[3].Text = (T '退出核桃便签')
  $script:TrayIcon.Text = (T '核桃便签')
}
function Set-TrayEnabled([bool]$enabled) {
  $script:Settings.tray = $enabled
  if ($enabled) { Initialize-Tray }
  elseif ($script:TrayIcon) { try { $script:TrayIcon.Visible = $false } catch { } }
  Save-State
}
function Set-HotkeyEnabled([bool]$enabled) {
  if ($script:Hwnd -eq [IntPtr]::Zero) { $script:Settings.hotkey = $enabled; return $true }
  try {
    if ($enabled) {
      $ok = [GN.Native]::RegisterHotKey($script:Hwnd, 1, 0x3, 0x4E)
      if (-not $ok) { $script:Settings.hotkey = $false; return $false }
      $script:HotkeyRegistered = $true; $script:Settings.hotkey = $true
      return $true
    } else {
      if ($script:HotkeyRegistered) { [void][GN.Native]::UnregisterHotKey($script:Hwnd, 1); $script:HotkeyRegistered = $false }
      $script:Settings.hotkey = $false
      return $true
    }
  } catch { Write-ErrorLog "global hotkey setup failed: $($_.Exception.ToString())"; return $false }
}
function Test-Autostart {
  try {
    $value = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'HetaoNotes' -ErrorAction SilentlyContinue
    return ($null -ne $value)
  } catch { return $false }
}
function Set-Autostart([bool]$enabled) {
  try {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($enabled) {
      $command = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + (Join-Path $script:AppDir 'Launch.vbs') + '"'
      New-Item -Path $runKey -Force | Out-Null
      Set-ItemProperty -Path $runKey -Name 'HetaoNotes' -Value $command
      $script:Settings.autostart = $true
    } else {
      Remove-ItemProperty -Path $runKey -Name 'HetaoNotes' -ErrorAction SilentlyContinue
      $script:Settings.autostart = $false
    }
    Save-State
    return $true
  } catch { Write-ToastLog "autostart setup failed: $($_.Exception.ToString())"; return $false }
}

# ---------- 数据操作 ----------
function Add-TaskFromInput {
  $text = ([string]$ui['NoteInput'].Text).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $kind = [string]$script:Settings.composerKind
  $newTask = $null
  if ($kind -eq 'note') {
    $newTask = New-TaskObject $text 'note'
    [void]$script:Tasks.Add($newTask)
  } elseif ($kind -eq 'once') {
    $newTask = New-TaskObject $text 'todo'
    [void]$script:Tasks.Add($newTask)
  } else {
    New-RepeatTask $text $kind
    $newTask = @($script:Tasks)[$script:Tasks.Count - 1]
  }
  # 新建的条目若正在按标签筛选、且新条目不在该标签下，会「凭空消失」，所以顺手把标签带上
  if ($null -ne $newTask -and -not [string]::IsNullOrWhiteSpace([string]$script:TagFilter)) {
    $newTask.tags = @([string]$script:TagFilter)
  }
  $ui['NoteInput'].Text = ''
  Reset-Draft
  $script:Settings.lastRollDate = Get-DateKey (Get-Date).Date
  Save-State
  if ($script:CurrentView -ne 'tasks') { Switch-View 'tasks' } else { Rebuild-Tasks $true }
  $ui['TasksScroller'].ScrollToTop()
  [void]$ui['NoteInput'].Focus()
}
function Set-TaskDone([string]$taskId, [bool]$isDone) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  if ([bool]$task.done -eq $isDone) { return }
  $task.done = $isDone
  $task.doneAt = if ($isDone) { (Get-IsoNow) } else { $null }
  if ($isDone) { $task.expiredAt = $null }
  Save-State
  # 勾选 / 取消勾选只更新数据与样式，不重播整列表入场动画，避免无关条目跟着闪一下
  Rebuild-All $false
}
function Set-TaskText([string]$taskId, [string]$text) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  if ([string]$task.text -eq $text) { return }
  $task.text = $text
  if ($task.kind -eq 'repeat' -and $task.seriesId) {
    $series = Find-Series ([string]$task.seriesId)
    if ($series) { $series.text = $text }
    foreach ($other in $script:Tasks) {
      if ($other.id -eq $task.id) { continue }
      if ([string]$other.seriesId -ne [string]$task.seriesId) { continue }
      $other.text = $text
      $otherBox = $script:TaskTextElements[[string]$other.id]
      if ($otherBox -and [string]$otherBox.Text -ne $text) {
        $script:SyncingText = $true
        $otherBox.Text = $text
        $script:SyncingText = $false
      }
    }
  }
  Sync-NoteWindowsText
  Request-Save
}
function Set-TaskPinned([string]$taskId, [bool]$pinned) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $task.pinned = $pinned
  Save-State
  Rebuild-All
}
function Remove-Task([string]$taskId) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  Add-ToTrash $task 'task'
  Close-NoteWindowsFor $taskId
  [void]$script:Tasks.Remove($task)
  Save-State
  Rebuild-All
  Show-Toast '已移入回收站，可随时还原'
}
function Remove-History([string]$recordId) {
  for ($i = $script:History.Count - 1; $i -ge 0; $i--) {
    if ([string]$script:History[$i].id -eq $recordId) {
      Add-ToTrash $script:History[$i] 'history'
      $script:History.RemoveAt($i)
      break
    }
  }
  Save-State
  Rebuild-All
}
function Restore-History([string]$recordId) {
  $record = $null
  foreach ($h in $script:History) { if ([string]$h.id -eq $recordId) { $record = $h; break } }
  if ($null -eq $record) { return }
  $text = [string]$record.text
  foreach ($task in $script:Tasks) {
    if (-not [bool]$task.done -and [string]$task.text -eq $text) { Show-Toast '这条已经在待办里了'; return }
  }
  [void]$script:Tasks.Add((New-TaskObject $text))
  Save-State
  Rebuild-All
  Show-Toast '已重新加入待办'
}
function Set-TaskSeries([string]$taskId, [string]$unit) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $today = (Get-Date).Date
  if ($task.kind -ne 'repeat' -or -not $task.seriesId) {
    $seriesId = [guid]::NewGuid().ToString('N')
    [void]$script:Series.Add(@{
        id = $seriesId; text = [string]$task.text; unit = $unit; interval = 1; anchor = $today.ToString('o')
        nextAt = (Get-DateKey (Get-NextDate $today $unit 1)); created = (Get-IsoNow)
        remindClock = (Get-RemindClockOf $task)
      })
    $task.kind = 'repeat'; $task.seriesId = $seriesId; $task.unit = $unit; $task.cycleKey = (Get-DateKey $today)
  } else {
    $series = Find-Series ([string]$task.seriesId)
    if ($series) { $series.unit = $unit; $series.nextAt = Get-DateKey (Get-NextDate $today $unit 1) }
    $task.unit = $unit
    foreach ($other in $script:Tasks) { if ($other.seriesId -eq $task.seriesId) { $other.unit = $unit } }
  }
  Save-State
  Rebuild-All
  Show-Toast ('已设为' + (Get-UnitLabel $unit) + '循环')
}
function Stop-TaskSeries([string]$taskId) {
  $task = Find-Task $taskId
  if ($null -eq $task -or -not $task.seriesId) { return }
  $seriesId = [string]$task.seriesId
  for ($i = $script:Series.Count - 1; $i -ge 0; $i--) { if ([string]$script:Series[$i].id -eq $seriesId) { $script:Series.RemoveAt($i); break } }
  foreach ($other in $script:Tasks) {
    if ([string]$other.seriesId -eq $seriesId) { $other.kind = 'once'; $other.seriesId = $null; $other.unit = $null; $other.cycleKey = $null }
  }
  Save-State
  Rebuild-All
  Show-Toast '已停止循环，保留当前任务'
}
function Move-TaskOrder([string]$dragId, [string]$targetId, [bool]$after = $false) {
  if ($dragId -eq $targetId) { return }
  $pending = @($script:Tasks | Where-Object { -not $_.done } | Sort-Object -Property @{ Expression = { [int]$_.order } })
  $drag = $pending | Where-Object { [string]$_.id -eq $dragId } | Select-Object -First 1
  $target = $pending | Where-Object { [string]$_.id -eq $targetId } | Select-Object -First 1
  if ($null -eq $drag -or $null -eq $target) { return }
  $list = [System.Collections.ArrayList]@($pending)
  [void]$list.Remove($drag)
  $targetIndex = $list.IndexOf($target)
  if ($targetIndex -lt 0) { $targetIndex = 0 }
  # 光标落在目标下半区时插到它后面，否则插到它前面——按直觉落位
  if ($after) { $targetIndex = [math]::Min($targetIndex + 1, $list.Count) }
  $list.Insert($targetIndex, $drag)
  for ($i = 0; $i -lt $list.Count; $i++) { $list[$i].order = $i + 1 }
  Save-State
  Rebuild-All
}

# ---------- 回收站 ----------
function Add-ToTrash($item, [string]$source) {
  if ($null -eq $item) { return }
  [void]$script:Trash.Add(@{
      id = [string]$item.id; text = [string]$item.text; kind = [string]$item.kind
      mode = $(if ([string]$item.mode -eq 'note') { 'note' } else { 'todo' })
      tags = @(Get-TaskTagIds $item)
      seriesId = $(if ($item.seriesId) { [string]$item.seriesId } else { $null })
      unit = $(if ($item.unit) { [string]$item.unit } else { $null })
      pinned = [bool]$item.pinned
      order = $(if ($null -ne $item.order) { [int]$item.order } else { 0 })
      created = $(if ($item.created) { [string]$item.created } else { (Get-IsoNow) })
      doneAt = $(if ($item.doneAt) { [string]$item.doneAt } else { $null })
      cycleKey = $(if ($item.cycleKey) { [string]$item.cycleKey } else { $null })
      remindAt = $(if ($item.remindAt) { [string]$item.remindAt } else { $null })
      source = $source; deletedAt = (Get-IsoNow)
    })
}
function Find-TrashItem([string]$id) {
  foreach ($item in $script:Trash) { if ([string]$item.id -eq $id) { return $item } }
  return $null
}
function Restore-Trash([string]$id) {
  $item = Find-TrashItem $id
  if ($null -eq $item) { return }
  if ([string]$item.source -eq 'history') {
    $historyId = [string]$item.id
    foreach ($h in $script:History) { if ([string]$h.id -eq $historyId) { $historyId = [guid]::NewGuid().ToString('N'); break } }
    [void]$script:History.Add(@{
        id = $historyId
        text = [string]$item.text; kind = [string]$item.kind
        mode = $(if ([string]$item.mode -eq 'note') { 'note' } else { 'todo' })
        seriesId = $item.seriesId; unit = $item.unit
        doneAt = $(if ($item.doneAt) { [string]$item.doneAt } else { (Get-IsoNow) })
        archivedAt = (Get-IsoNow); created = [string]$item.created; remindAt = $item.remindAt
      })
    Show-Toast '已还原到历史记录'
  } else {
    $newId = [string]$item.id
    if ($null -ne (Find-Task $newId)) { $newId = [guid]::NewGuid().ToString('N') }
    [void]$script:Tasks.Add(@{
        id = $newId; text = [string]$item.text; kind = [string]$item.kind
        mode = $(if ([string]$item.mode -eq 'note') { 'note' } else { 'todo' })
        tags = @(Get-TaskTagIds $item)
        seriesId = $(if ($item.seriesId -and (Find-Series ([string]$item.seriesId))) { [string]$item.seriesId } else { $null })
        unit = $item.unit
        done = $false; pinned = [bool]$item.pinned; order = (Get-NextOrder); created = [string]$item.created
        doneAt = $null; cycleKey = $item.cycleKey; remindAt = $item.remindAt; reminded = $false; snoozeAt = $null; expiredAt = $null
      })
    Show-Toast '已还原到列表'
  }
  [void]$script:Trash.Remove($item)
  Save-State
  Rebuild-All
}
function Purge-Trash([string]$id) {
  $item = Find-TrashItem $id
  if ($null -eq $item) { return }
  [void]$script:Trash.Remove($item)
  Save-State
  Rebuild-All
}
function Clear-Trash {
  if ($script:Trash.Count -eq 0) { Show-Toast '回收站已经是空的'; return }
  $askBody = (TCount '将彻底删除回收站里的 {0} 项，且不可恢复。' $script:Trash.Count) + "`n`n" + (T '继续？')
  $answer = [System.Windows.MessageBox]::Show($askBody, (T '清空回收站'), 'YesNo', 'Warning')
  if ($answer -ne 'Yes') { return }
  $script:Trash.Clear()
  Save-State
  Rebuild-All
  Show-Toast '回收站已清空'
}
function Set-TaskMode([string]$taskId, [string]$mode) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  if ([string]$task.mode -eq $mode) { return }
  if ($mode -eq 'note') {
    if ($task.kind -eq 'repeat' -and $task.seriesId) {
      $seriesId = [string]$task.seriesId
      for ($i = $script:Series.Count - 1; $i -ge 0; $i--) { if ([string]$script:Series[$i].id -eq $seriesId) { $script:Series.RemoveAt($i); break } }
      foreach ($other in $script:Tasks) {
        if ([string]$other.seriesId -eq $seriesId) { $other.kind = 'once'; $other.seriesId = $null; $other.unit = $null; $other.cycleKey = $null }
      }
    }
    $task.mode = 'note'; $task.done = $false; $task.doneAt = $null
    Show-Toast '已转为笔记（没有勾选框，不参与完成率）'
  } else {
    $task.mode = 'todo'
    Show-Toast '已转为待办'
  }
  Save-State
  Rebuild-All
}

# ---------- 标签（组织管理） ----------
function New-Tag([string]$name) {
  $name = ([string]$name).Trim()
  if ([string]::IsNullOrWhiteSpace($name)) { return $null }
  if ($name.Length -gt 16) { $name = $name.Substring(0, 16) }
  if ($null -ne (Find-TagByName $name)) { Show-Toast '已经有同名标签了'; return $null }
  $order = $script:Tags.Count + 1
  $tag = @{
    id = [guid]::NewGuid().ToString('N'); name = $name
    color = $script:TagColors[($order - 1) % $script:TagColors.Count]
    order = $order; created = (Get-IsoNow)
  }
  [void]$script:Tags.Add($tag)
  Save-State
  return $tag
}
function Remove-Tag([string]$id) {
  $tag = Find-Tag $id
  if ($null -eq $tag) { return }
  [void]$script:Tags.Remove($tag)
  foreach ($task in $script:Tasks) { $task.tags = @(Get-TaskTagIds $task | Where-Object { $_ -ne $id }) }
  foreach ($item in $script:Trash) { $item.tags = @(Get-TaskTagIds $item | Where-Object { $_ -ne $id }) }
  if ([string]$script:TagFilter -eq $id) { $script:TagFilter = ''; Update-SearchBar }
  Save-State
  Rebuild-All
  Show-Toast ('已删除标签「' + [string]$tag.name + '」，条目本身保留')
}
function Rename-Tag([string]$id, [string]$name) {
  $tag = Find-Tag $id
  if ($null -eq $tag) { return }
  $name = ([string]$name).Trim()
  if ([string]::IsNullOrWhiteSpace($name)) { return }
  if ($name.Length -gt 16) { $name = $name.Substring(0, 16) }
  if ([string]$tag.name -eq $name) { return }
  $other = Find-TagByName $name
  if ($null -ne $other -and [string]$other.id -ne $id) { Show-Toast '已经有同名标签了'; Rebuild-All; return }
  $tag.name = $name
  Save-State
  Rebuild-All
  Update-TagFilterButton
}
function Set-TaskTag([string]$taskId, [string]$tagId, [bool]$on) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $ids = @(Get-TaskTagIds $task)
  if ($on) {
    if ($ids -notcontains $tagId) { $ids += $tagId }
  } else {
    $ids = @($ids | Where-Object { $_ -ne $tagId })
  }
  $task.tags = $ids
  Save-State
  Rebuild-All
  if ($script:Ui['TagListHost']) { Refresh-TagList }
}
function Get-TagUsage([string]$tagId) {
  $count = 0
  foreach ($task in $script:Tasks) { if (@(Get-TaskTagIds $task) -contains $tagId) { $count++ } }
  return $count
}
function Refresh-TagList {
  $hostPanel = $script:Ui['TagListHost']
  if ($null -eq $hostPanel) { return }
  $hostPanel.Children.Clear()
  $tags = @($script:Tags | Sort-Object -Property @{ Expression = { [int]$_.order } })
  if ($tags.Count -eq 0) {
    $hint = [System.Windows.Controls.TextBlock]::new()
    $hint.Text = '还没有标签。在上面输入名称（比如「工作」「读书」）再点「新建」。'
    $hint.FontSize = 10.5
    $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $hint.Foreground = $script:Win.Resources['TextMutedBrush']
    $hint.Margin = [System.Windows.Thickness]::new(2, 10, 2, 0)
    [void]$hostPanel.Children.Add($hint)
    return
  }
  foreach ($tag in $tags) {
    $row = [System.Windows.Controls.Grid]::new()
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $cols = @('Auto', '*', 'Auto', 'Auto', 'Auto')
    foreach ($spec in $cols) {
      $col = [System.Windows.Controls.ColumnDefinition]::new()
      if ($spec -eq '*') { $col.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
      else { $col.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto) }
      [void]$row.ColumnDefinitions.Add($col)
    }
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8; $dot.Height = 8; $dot.Fill = New-Brush ([string]$tag.color)
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dot.Margin = [System.Windows.Thickness]::new(2, 0, 8, 0)
    [void]$row.Children.Add($dot)

    $nameBox = [System.Windows.Controls.TextBox]::new()
    $nameBox.Style = $script:Win.Resources['NoteTextStyle']
    $nameBox.Text = [string]$tag.name
    $nameBox.FontSize = 12
    $nameBox.MinHeight = 22
    $nameBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $nameBox.Tag = [string]$tag.id
    $nameBox.ToolTip = '直接改字即可重命名'
    [System.Windows.Automation.AutomationProperties]::SetName($nameBox, '标签名称')
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($nameBox, "tag-name-$($tag.id)")
    $nameBox.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
          $eventArgs.Handled = $true
          Rename-Tag ([string]$sender.Tag) ([string]$sender.Text)
          Refresh-TagList
        }
      })
    $nameBox.Add_LostKeyboardFocus({
        param($sender, $eventArgs)
        Rename-Tag ([string]$sender.Tag) ([string]$sender.Text)
      })
    [void]$row.Children.Add($nameBox)
    [System.Windows.Controls.Grid]::SetColumn($nameBox, 1)

    $countText = [System.Windows.Controls.TextBlock]::new()
    $countText.Text = ('{0} 条' -f (Get-TagUsage ([string]$tag.id)))
    $countText.FontSize = 9.5
    $active = ([string]$script:TagFilter -eq [string]$tag.id)
    $countText.Foreground = if ($active) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
    $countText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $countText.Margin = [System.Windows.Thickness]::new(6, 0, 6, 0)
    [void]$row.Children.Add($countText)
    [System.Windows.Controls.Grid]::SetColumn($countText, 2)

    $filterBtn = [System.Windows.Controls.Button]::new()
    $filterBtn.Style = $script:Win.Resources['NoteDeleteStyle']
    $filterBtn.Content = [string][char]0xE71C
    $filterBtn.Tag = [string]$tag.id
    $filterBtn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $filterBtn.ToolTip = if ($active) { '取消该标签筛选' } else { '只看这个标签' }
    $filterBtn.Foreground = if ($active) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
    [System.Windows.Automation.AutomationProperties]::SetName($filterBtn, '按该标签筛选')
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($filterBtn, "tag-filter-$($tag.id)")
    $filterBtn.Add_Click({
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        if ([string]$script:TagFilter -eq $id) { Set-TagFilter '' } else { Set-TagFilter $id }
        Refresh-TagList
      })
    [void]$row.Children.Add($filterBtn)
    [System.Windows.Controls.Grid]::SetColumn($filterBtn, 3)

    $delBtn = [System.Windows.Controls.Button]::new()
    $delBtn.Style = $script:Win.Resources['NoteDeleteStyle']
    $delBtn.Content = [string][char]0xE74D
    $delBtn.Tag = [string]$tag.id
    $delBtn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $delBtn.ToolTip = '删除标签（条目会保留）'
    [System.Windows.Automation.AutomationProperties]::SetName($delBtn, '删除标签')
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($delBtn, "tag-del-$($tag.id)")
    $delBtn.Add_Click({
        param($sender, $eventArgs)
        Remove-Tag ([string]$sender.Tag)
        Refresh-TagList
      })
    [void]$row.Children.Add($delBtn)
    [System.Windows.Controls.Grid]::SetColumn($delBtn, 4)

    [void]$hostPanel.Children.Add($row)
  }
}
function Open-TagPanel {
  if ($null -ne $script:Ui['TagOverlay']) {
    Refresh-TagList
    $script:Ui['TagOverlay'].Visibility = [System.Windows.Visibility]::Visible
    [void]$script:Ui['TagInput'].Focus()
  }
}
function Close-TagPanel {
  if ($null -ne $script:Ui['TagOverlay']) { $script:Ui['TagOverlay'].Visibility = [System.Windows.Visibility]::Collapsed }
  $script:TagPendingTaskId = $null
}
function Show-TaskTagMenu([object]$sender) {
  if ($null -eq $sender) { return }
  $taskId = [string]$sender.Tag
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $assigned = @(Get-TaskTagIds $task)
  $menu = [System.Windows.Controls.ContextMenu]::new()
  $script:TagMenuTaskId = $taskId
  if ($script:Tags.Count -eq 0) {
    $empty = [System.Windows.Controls.MenuItem]::new()
    $empty.Header = (T '还没有标签'); $empty.IsEnabled = $false
    [void]$menu.Items.Add($empty)
  } else {
    foreach ($tag in @($script:Tags | Sort-Object -Property @{ Expression = { [int]$_.order } })) {
      $mi = [System.Windows.Controls.MenuItem]::new()
      $isOn = $assigned -contains [string]$tag.id
      $mi.Header = New-MenuTagHeader ([string]$tag.name) ([string]$tag.color) $isOn
      $mi.Tag = @{ taskId = $taskId; tagId = [string]$tag.id; on = (-not $isOn) }
      $mi.Add_Click({
          param($s, $e)
          $info = $s.Tag
          Set-TaskTag ([string]$info.taskId) ([string]$info.tagId) ([bool]$info.on)
        })
      [void]$menu.Items.Add($mi)
    }
    if ($assigned.Count -gt 0) {
      [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
      $clear = [System.Windows.Controls.MenuItem]::new()
      $clear.Header = (T '清空这条的标签')
      $clear.Tag = $taskId
      $clear.Add_Click({
          param($s, $e)
          $t = Find-Task ([string]$s.Tag)
          if ($t) { $t.tags = @(); Save-State; Rebuild-All }
        })
      [void]$menu.Items.Add($clear)
    }
  }
  [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
  $newItem = [System.Windows.Controls.MenuItem]::new()
  $newItem.Header = (T '新建标签…')
  $newItem.Tag = $taskId
  $newItem.Add_Click({
      param($s, $e)
      $script:TagPendingTaskId = [string]$s.Tag
      Open-TagPanel
    })
  [void]$menu.Items.Add($newItem)
  Open-FloatingMenu $menu $sender
}
# 代码里现造的 ContextMenu 必须留一个强引用，否则弹层刚显示就可能被 GC 回收而“一闪就没”。
# 同时用 MousePoint 定位、低优先级投递打开，避免同一次鼠标抬起事件把菜单顶掉。
function Open-FloatingMenu([object]$menu, [object]$target) {
  if ($null -eq $menu) { return }
  if ($null -ne $target) { $menu.PlacementTarget = $target }
  $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
  Apply-MenuSkin $menu
  $script:ActiveMenu = $menu
  $menu.Add_Closed({
      param($s, $e)
      if ($null -ne $script:ActiveMenu -and [object]::ReferenceEquals($script:ActiveMenu, $s)) { $script:ActiveMenu = $null }
    })
  $menu.IsOpen = $true
}
# 代码现造的菜单拿不到 XAML 里的隐式样式（弹出层不在可视树里），所以显式套一层皮肤。
function Apply-MenuSkin([object]$menu) {
  if ($null -eq $menu) { return }
  $bg = $script:Win.Resources['AppMenuStyle']
  $itemStyle = $script:Win.Resources['AppMenuItemStyle']
  $sepStyle = $script:Win.Resources['AppMenuSeparatorStyle']
  if ($null -ne $bg) { $menu.Style = $bg }
  foreach ($item in $menu.Items) {
    if ($item -is [System.Windows.Controls.Separator]) {
      if ($null -ne $sepStyle) { $item.Style = $sepStyle }
    } elseif ($null -ne $itemStyle) {
      $item.Style = $itemStyle
    }
  }
}
# 菜单项前面挂一个标签色圆点，方便一眼分清同名/相近的标签
function New-MenuTagHeader([string]$name, [string]$color, [bool]$checked) {
  $panel = [System.Windows.Controls.StackPanel]::new()
  $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $dot = [System.Windows.Shapes.Ellipse]::new()
  $dot.Width = 8; $dot.Height = 8
  $dot.Margin = [System.Windows.Thickness]::new(0, 0, 7, 0)
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  try { $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color) }
  catch { $dot.Fill = $script:Win.Resources['AccentBrush'] }
  [void]$panel.Children.Add($dot)
  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = if ($checked) { [string][char]0x2713 + ' ' + $name } else { $name }
  $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  [void]$panel.Children.Add($tb)
  return $panel
}
# 菜单里的「名称（数量）」括号：中文全角、英文半角加空格。
# Popup 不在视觉树里、切语言时扫不到，所以只能在每次弹出时按当前语言现拼。
function Format-MenuCount([string]$text, $n) {
  if ($script:LangCode -eq 'en') { return ('{0} ({1})' -f $text, $n) }
  return ('{0}（{1}）' -f $text, $n)
}
# 标签筛选菜单的条目文字「#名称（3）」：名称是用户内容不翻译，只改括号与计数排版。
function Format-TagMenuLabel([string]$name, $n) {
  return (Format-MenuCount ('#' + $name) $n)
}
# 标签面板底部那行「已新建标签「工作」」：中文用全角引号，英文用半角冒号
function Format-TagCreatedText([string]$name) {
  if ($script:LangCode -eq 'en') { return ('Tag created: ' + $name) }
  return ('已新建标签「' + $name + '」')
}

# ---------- 笔记独立小窗（拖出主窗口） ----------
function Get-VisualDpiScale($visual) {
  try {
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($visual)
    if ($dpi.DpiScaleX -gt 0) { return [double]$dpi.DpiScaleX }
  } catch { }
  return (Get-DpiScale)
}
# 事件处理代码块是在 New-NoteWindow 函数里创建的，而函数返回后其局部作用域已销毁，
# 代码块里读函数局部变量只会得到 $null（已用最小复现确认）。所以小窗的所有状态
# 一律挂到 Window.Tag 上，处理函数再用 GetWindow($sender) 反查窗口来取，绝不依赖闭包。
function Get-NoteWindowOf($element) {
  if ($null -eq $element) { return $null }
  if ($element -is [System.Windows.Window]) { return $element }
  try { return [System.Windows.Window]::GetWindow($element) } catch { return $null }
}
# 纯几何计算，单独成函数便于冒烟测试直接校验（拖动时按鼠标位移重设窗口尺寸）
function Resize-NoteWindow($win, [double]$dx, [double]$dy) {
  if ($null -eq $win) { return }
  $st = $win.Tag
  if ($null -eq $st -or -not $st.resizing -or $st.locked) { return }
  $scale = if ([double]$st.scale -gt 0) { [double]$st.scale } else { 1.0 }
  $minW = if ([double]$win.MinWidth -gt 0) { [double]$win.MinWidth } else { 150 }
  $minH = if ([double]$win.MinHeight -gt 0) { [double]$win.MinHeight } else { 104 }
  $win.Width = [math]::Max($minW, [double]$st.w + $dx / $scale)
  $win.Height = [math]::Max($minH, [double]$st.h + $dy / $scale)
}
function Close-NoteWindowsFor([string]$taskId) {
  for ($i = $script:NoteWindows.Count - 1; $i -ge 0; $i--) {
    $entry = $script:NoteWindows[$i]
    if ([string]$entry.taskId -eq $taskId) {
      try { $entry.win.Close() } catch { }
      $script:NoteWindows.RemoveAt($i)
    }
  }
}
# 主面板改完文字后把内容推给已打开的小窗。
# 小窗创建时只读一次 task.text，不同步的话会一直停在旧文字上（改完看着像没生效）。
# 不传 taskId 就全量同步：循环任务改一次文字会连带同链的其他条目，那些窗口也要跟着变。
function Sync-NoteWindowsText([string]$taskId = '') {
  if (-not $script:NoteWindows) { return }
  foreach ($entry in @($script:NoteWindows)) {
    if ($taskId -and ([string]$entry.taskId -ne $taskId)) { continue }
    $task = Find-Task ([string]$entry.taskId)
    if ($null -eq $task) { continue }
    $st = $entry.win.Tag
    if ($null -eq $st) { continue }
    $text = [string]$task.text
    if ($null -ne $st.body -and [string]$st.body.Text -ne $text) { $st.body.Text = $text }
    try {
      $title = '便签 · ' + $text
      if ([string]$entry.win.Title -ne $title) { $entry.win.Title = $title }
    } catch { }
  }
}
function Get-NoteWindowThemeKeys {
  @('SettingsBgBrush', 'CardBorderBrush', 'TextMutedBrush', 'TextPrimaryBrush', 'IconFgBrush',
    'IconHoverBgBrush', 'ToggleCheckedBgBrush', 'ToggleCheckedHoverBgBrush', 'AccentTextBrush',
    'DangerFgBrush', 'DangerHoverBgBrush', 'DangerPressedBgBrush')
}
# 小窗是独立 Window，资源查找链里没有主窗口 Resources；给它补一份 brush 引用，
# 切主题时再同步一次，元素上的 DynamicResource 才能解析并跟着刷新。
function Sync-NoteWindowResources($win) {
  if ($null -eq $win) { return }
  foreach ($k in (Get-NoteWindowThemeKeys)) {
    if ($script:Win.Resources.Contains($k)) { $win.Resources[$k] = $script:Win.Resources[$k] }
  }
}
function New-NoteWindow([hashtable]$task) {
  if ($null -eq $task) { return $null }
  foreach ($entry in $script:NoteWindows) {
    if ([string]$entry.taskId -eq [string]$task.id) {
      try { [void]$entry.win.Activate() } catch { }
      return $entry.win
    }
  }
  $w = [System.Windows.Window]::new()
  $w.WindowStyle = [System.Windows.WindowStyle]::None
  $w.AllowsTransparency = $true
  $w.Background = [System.Windows.Media.Brushes]::Transparent
  $w.ShowInTaskbar = $false
  $w.Topmost = $true
  $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $w.Width = 250; $w.Height = 176
  # 最小尺寸要容得下标题 + 右侧 4 个按钮，太小会把按钮挤到看不见
  $w.MinWidth = 176; $w.MinHeight = 112
  $w.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')
  $w.Title = '便签 · ' + [string]$task.text
  # 补齐主题 brush，独立窗口里的 Style / DynamicResource 才解析得到
  Sync-NoteWindowResources $w

  $outer = [System.Windows.Controls.Grid]::new()
  $outer.Margin = [System.Windows.Thickness]::new(14)
  $card = [System.Windows.Controls.Border]::new()
  $card.CornerRadius = [System.Windows.CornerRadius]::new(14)
  $card.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'SettingsBgBrush')
  $card.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'CardBorderBrush')
  $card.BorderThickness = [System.Windows.Thickness]::new(1)
  $shadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
  $shadow.BlurRadius = 18; $shadow.ShadowDepth = 5; $shadow.Opacity = 0.45
  $shadow.Direction = 270; $shadow.Color = [System.Windows.Media.Color]::FromArgb(255, 0, 0, 0)
  $card.Effect = $shadow

  $inner = [System.Windows.Controls.Grid]::new()
  $r1 = [System.Windows.Controls.RowDefinition]::new(); $r1.Height = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $r2 = [System.Windows.Controls.RowDefinition]::new(); $r2.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  [void]$inner.RowDefinitions.Add($r1); [void]$inner.RowDefinitions.Add($r2)

  # 标题栏：左标题（占满剩余宽度、超长省略），右侧「半透明 / 置顶 / 锁定 / 关闭」
  # 分两列而不是叠在同一格：窗口拖窄时按钮不会再压到标题上、也不会被挤出去
  $header = [System.Windows.Controls.Grid]::new()
  $header.Margin = [System.Windows.Thickness]::new(14, 8, 8, 0)
  $hc0 = [System.Windows.Controls.ColumnDefinition]::new()
  $hc0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $hc1 = [System.Windows.Controls.ColumnDefinition]::new()
  $hc1.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  [void]$header.ColumnDefinitions.Add($hc0); [void]$header.ColumnDefinitions.Add($hc1)

  $caption = [System.Windows.Controls.TextBlock]::new()
  $caption.Text = '笔记 · 拖动可移动'
  $caption.FontSize = 9
  $caption.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $caption.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $caption.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)
  $caption.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextMutedBrush')
  [void]$header.Children.Add($caption)

  $btnPanel = [System.Windows.Controls.StackPanel]::new()
  $btnPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $btnPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $btnPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  [System.Windows.Controls.Grid]::SetColumn($btnPanel, 1)
  [void]$header.Children.Add($btnPanel)

  $noteBtnSize = 20
  $mkNoteToggle = {
    param([string]$glyph, [string]$tip)
    $b = [System.Windows.Controls.Primitives.ToggleButton]::new()
    if ($null -ne $script:Win.Resources['ChromeToggleStyle']) { $b.Style = $script:Win.Resources['ChromeToggleStyle'] }
    $b.Width = $noteBtnSize; $b.Height = $noteBtnSize
    $b.FontSize = 9
    $b.Content = $glyph
    $b.ToolTip = $tip
    $b.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
    return $b
  }

  $transBtn = & $mkNoteToggle ([string][char]0xE890) '半透明'
  $pinBtn = & $mkNoteToggle ([string][char]0xE718) '置顶显示'
  $lockBtn = & $mkNoteToggle ([string][char]0xE72E) '锁定（禁止拖动和缩放）'
  $pinBtn.IsChecked = $true

  $closeBtn = [System.Windows.Controls.Button]::new()
  $closeBtn.Style = $script:Win.Resources['NoteDeleteStyle']
  $closeBtn.Content = [string][char]0xE711
  $closeBtn.Width = $noteBtnSize; $closeBtn.Height = $noteBtnSize
  $closeBtn.FontSize = 9
  $closeBtn.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
  $closeBtn.ToolTip = '关闭这个小窗（笔记本身仍保留在完整模式）'
  [System.Windows.Automation.AutomationProperties]::SetName($closeBtn, '关闭笔记小窗')
  $closeBtn.Add_Click({ param($s, $e) try { $s.Tag.Close() } catch { } })
  $closeBtn.Tag = $w

  [void]$btnPanel.Children.Add($transBtn)
  [void]$btnPanel.Children.Add($pinBtn)
  [void]$btnPanel.Children.Add($lockBtn)
  [void]$btnPanel.Children.Add($closeBtn)
  [void]$inner.Children.Add($header)

  $body = [System.Windows.Controls.TextBlock]::new()
  $body.Text = [string]$task.text
  $body.Tag = 'user'
  $body.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $body.FontSize = 13
  $body.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextPrimaryBrush')
  $body.Margin = [System.Windows.Thickness]::new(14, 6, 14, 18)
  [void]$inner.Children.Add($body)
  [System.Windows.Controls.Grid]::SetRow($body, 1)

  $grip = [System.Windows.Controls.Border]::new()
  $grip.Width = 26; $grip.Height = 18
  $grip.Background = [System.Windows.Media.Brushes]::Transparent
  $grip.Cursor = [System.Windows.Input.Cursors]::SizeNWSE
  $grip.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $grip.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
  $grip.ToolTip = '拖动调整大小'
  [System.Windows.Controls.Grid]::SetRow($grip, 1)
  $gripPath = [System.Windows.Shapes.Path]::new()
  $gripPath.SetResourceReference([System.Windows.Shapes.Path]::StrokeProperty, 'TextMutedBrush')
  $gripPath.StrokeThickness = 1.1
  $gripPath.Opacity = 0.55
  $gripPath.Data = [System.Windows.Media.Geometry]::Parse('M 6,12 L 12,6 M 10,12 L 12,10')
  $grip.Child = $gripPath
  [void]$inner.Children.Add($grip)

  $card.Child = $inner
  [void]$outer.Children.Add($card)
  $w.Content = $outer

  # 每个小窗独立状态，挂在 Window.Tag 上（不能存函数局部变量，见 Get-NoteWindowOf 注释）
  $w.Tag = @{
    taskId = [string]$task.id
    locked = $false; translucent = $false; resizing = $false
    sx = 0.0; sy = 0.0; w = 0.0; h = 0.0; scale = 1.0
    caption = $caption; grip = $grip; body = $body
    transBtn = $transBtn; pinBtn = $pinBtn; lockBtn = $lockBtn
  }

  # 拖动：卡片空白处可拖，按钮自己会吃掉按下事件，不会误触
  $card.Add_MouseLeftButtonDown({
      param($sender, $eventArgs)
      $win = Get-NoteWindowOf $sender
      if ($null -eq $win) { return }
      $st = $win.Tag
      if ($null -eq $st -or $st.locked) { return }
      try { $eventArgs.Handled = $true; $win.DragMove() } catch { }
    })

  # 缩放：grip 按下启动；移动挂窗口级、鼠标按 grip 捕获，即使偶尔丢捕获也不会中途失灵
  $grip.Add_MouseLeftButtonDown({
      param($sender, $eventArgs)
      $win = Get-NoteWindowOf $sender
      if ($null -eq $win) { return }
      $st = $win.Tag
      if ($null -eq $st -or $st.locked) { return }
      $st.resizing = $true
      $st.sx = [double][System.Windows.Forms.Cursor]::Position.X
      $st.sy = [double][System.Windows.Forms.Cursor]::Position.Y
      $st.w = [double]$win.ActualWidth
      $st.h = [double]$win.ActualHeight
      $st.scale = Get-VisualDpiScale $win
      try { [void]$sender.CaptureMouse() } catch { }
      $eventArgs.Handled = $true
    })
  $w.Add_MouseMove({
      param($sender, $eventArgs)
      $st = $sender.Tag
      if ($null -eq $st -or -not $st.resizing) { return }
      $dx = [double][System.Windows.Forms.Cursor]::Position.X - [double]$st.sx
      $dy = [double][System.Windows.Forms.Cursor]::Position.Y - [double]$st.sy
      try { Resize-NoteWindow $sender $dx $dy } catch { }
    })
  $w.Add_MouseLeftButtonUp({
      param($sender, $eventArgs)
      $st = $sender.Tag
      if ($null -eq $st) { return }
      if (-not $st.resizing) { return }
      $st.resizing = $false
      try { [void][System.Windows.Input.Mouse]::Capture($null) } catch { }
    })
  $w.Add_LostMouseCapture({
      param($sender, $eventArgs)
      $st = $sender.Tag
      if ($null -ne $st) { $st.resizing = $false }
    })

  # 工具栏开关
  $transBtn.Add_Click({
      param($sender, $eventArgs)
      $win = Get-NoteWindowOf $sender
      if ($null -eq $win) { return }
      $on = [bool]$sender.IsChecked
      $st = $win.Tag
      $st.translucent = $on
      try { $win.Opacity = if ($on) { 0.56 } else { 1.0 } } catch { }
    })
  $pinBtn.Add_Click({
      param($sender, $eventArgs)
      $win = Get-NoteWindowOf $sender
      if ($null -eq $win) { return }
      try { $win.Topmost = [bool]$sender.IsChecked } catch { }
    })
  $lockBtn.Add_Click({
      param($sender, $eventArgs)
      $win = Get-NoteWindowOf $sender
      if ($null -eq $win) { return }
      $on = [bool]$sender.IsChecked
      $st = $win.Tag
      $st.locked = $on
      # 锁定要有可见反馈，否则用户以为没生效：标题文字 + 缩放角标变淡
      try {
        if ($null -ne $st.caption) { $st.caption.Text = if ($on) { '笔记 · 已锁定' } else { '笔记 · 拖动可移动' } }
        if ($null -ne $st.grip) { $st.grip.Opacity = if ($on) { 0.18 } else { 1.0 } }
      } catch { }
    })

  # 出现在光标附近，并保证不越出工作区
  try {
    $scale = Get-VisualDpiScale $w
    if ($scale -le 0) { $scale = 1.0 }
    $cursor = [System.Windows.Forms.Cursor]::Position
    $area = Get-WindowWorkArea
    $left = $cursor.X / $scale + 18
    $top = $cursor.Y / $scale + 10
    $left = [math]::Min([math]::Max($area.left, $left), [math]::Max($area.left, $area.right - $w.Width - 8))
    $top = [math]::Min([math]::Max($area.top, $top), [math]::Max($area.top, $area.bottom - $w.Height - 8))
    $w.Left = $left; $w.Top = $top
  } catch { }

  $entry = @{ taskId = [string]$task.id; win = $w }
  $script:NoteWindows += $entry
  $w.Add_Closed({
      param($sender, $eventArgs)
      $keep = @()
      foreach ($item in $script:NoteWindows) { if (-not [object]::ReferenceEquals($item.win, $sender)) { $keep += $item } }
      $script:NoteWindows = $keep
    })
  try { $w.Show(); [void]$w.Activate() } catch { Write-ErrorLog ("note window create failed: " + $_.Exception.ToString()) }
  return $w
}

# ---------- 提醒 ----------
function Get-TaskRemindAt($task) {
  if ($null -eq $task -or $null -eq $task.remindAt) { return $null }
  $raw = [string]$task.remindAt
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return [datetime]::Parse($raw, $script:Invariant) } catch { return $null }
}
function Format-RemindLabel([datetime]$when) {
  $today = (Get-Date).Date
  if ($when.Date -eq $today) { return ('今天 ' + $when.ToString('HH:mm')) }
  if ($when.Date -eq $today.AddDays(1)) { return ('明天 ' + $when.ToString('HH:mm')) }
  if ($when.Date -eq $today.AddDays(2)) { return ('后天 ' + $when.ToString('HH:mm')) }
  if ($when.Date -eq $today.AddDays(-1)) { return ('昨天 ' + $when.ToString('HH:mm')) }
  return $when.ToString($script:FmtDateShort, $script:Culture)
}
function Set-TaskRemind([string]$taskId, $when) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $series = if ([string]$task.kind -eq 'repeat' -and $task.seriesId) { Find-Series ([string]$task.seriesId) } else { $null }
  if ($null -eq $when) {
    $task.remindAt = $null; $task.reminded = $false; $task.snoozeAt = $null; $task.expiredAt = $null
    if ($series) { $series.remindClock = $null }
    Save-State
    Rebuild-All
    Show-Toast '已取消提醒'
    return
  }
  $dt = [datetime]$when
  $task.remindAt = $dt.ToString('o')
  $task.reminded = $false
  $task.snoozeAt = $null
  $task.expiredAt = $null
  if ($series) { $series.remindClock = $dt.ToString('HH:mm') }
  Save-State
  Rebuild-All
  Show-Toast (('已设置提醒：' + (Format-RemindLabel $dt)) + $(if ($series) { '（随循环延续）' } else { '' }))
}
function Get-RemindTriggerAt($task) {
  if ([bool]$task.done) { return $null }
  if ($task.snoozeAt) {
    try { return [datetime]::Parse([string]$task.snoozeAt, $script:Invariant) } catch { }
  }
  if ([bool]$task.reminded) { return $null }
  $at = Get-TaskRemindAt $task
  if ($null -eq $at) { return $null }
  $lead = [int]$script:Settings.remindLead
  if ($lead -gt 0) { return $at.AddMinutes(-1 * $lead) }
  return $at
}
# 「提醒时间已过、但到点时程序没在运行」的条目：以 task.expiredAt 落盘，重启后仍能补看。
# 只取未完成的条目（笔记也能设提醒，同样算数）；完成 / 重设提醒 / 忽略时会清掉 expiredAt。
function Get-MissedReminders {
  $list = @()
  foreach ($task in @($script:Tasks)) {
    if ($null -eq $task) { continue }
    if ([bool]$task.done) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$task.expiredAt)) { continue }
    $list += $task
  }
  return $list
}
function Format-MissedAgo($task) {
  # 用「原定提醒时间」算过了多久（不是发现它过期的时间），重启多少次结果都一样
  $from = Get-TaskRemindAt $task
  if ($null -eq $from) {
    if ([string]::IsNullOrWhiteSpace([string]$task.expiredAt)) { return '已错过' }
    try { $from = [datetime]::Parse([string]$task.expiredAt, $script:Invariant) } catch { return '已错过' }
  }
  $hours = [int][math]::Floor(((Get-Date) - $from).TotalHours)
  if ($hours -ge 48) { return (TCount '已错过 {0} 天' ([int][math]::Floor($hours / 24))) }
  if ($hours -ge 1) { return (TCount '已错过 {0} 小时' $hours) }
  return '刚刚错过'
}
function New-RemindRow($task, [object[]]$actions, [string]$metaText) {
  $row = [System.Windows.Controls.Grid]::new()
  $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
  $colText = [System.Windows.Controls.ColumnDefinition]::new(); $colText.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $colBtn = [System.Windows.Controls.ColumnDefinition]::new(); $colBtn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  [void]$row.ColumnDefinitions.Add($colText)
  [void]$row.ColumnDefinitions.Add($colBtn)

  $info = [System.Windows.Controls.StackPanel]::new()
  $info.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $text = [System.Windows.Controls.TextBlock]::new()
  $text.Text = [string]$task.text
  $text.Tag = 'user'
  $text.FontSize = 12.5
  $text.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $text.Foreground = $script:Win.Resources['TextPrimaryBrush']
  [void]$info.Children.Add($text)
  if (-not [string]::IsNullOrWhiteSpace($metaText)) {
    $meta = [System.Windows.Controls.TextBlock]::new()
    $meta.Text = $metaText
    $meta.FontSize = 9.5
    $meta.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $meta.Foreground = $script:Win.Resources['TextMutedBrush']
    $meta.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$info.Children.Add($meta)
  }
  [void]$row.Children.Add($info)

  $btnPanel = [System.Windows.Controls.StackPanel]::new()
  $btnPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $btnPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  foreach ($spec in $actions) {
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Style = $script:Win.Resources['SmallButtonStyle']
    $btn.Content = [string]$spec.label
    $btn.FontSize = 10
    $btn.Padding = [System.Windows.Thickness]::new(7, 2, 7, 2)
    $btn.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
    $btn.Tag = @{ action = [string]$spec.action; taskId = [string]$task.id }
    $btn.Add_Click($script:OnRemindAction)
    [void]$btnPanel.Children.Add($btn)
  }
  [void]$row.Children.Add($btnPanel)
  [System.Windows.Controls.Grid]::SetColumn($btnPanel, 1)
  return $row
}
function Update-RemindOverlay {
  $panel = $ui['RemindHost']
  if ($null -eq $panel) { return }
  $panel.Children.Clear()
  $alive = @()
  foreach ($id in @($script:RemindItems)) {
    $task = Find-Task ([string]$id)
    if ($null -eq $task) { continue }
    $alive += [string]$id
    $at = Get-TaskRemindAt $task
    $metaText = ''
    if ($null -ne $at) { $metaText = '提醒时间 ' + $at.ToString($script:FmtDateShort, $script:Culture) }
    [void]$panel.Children.Add((New-RemindRow $task @(@{ label = '稍后 5 分'; action = 'snooze' }, @{ label = '完成'; action = 'done' }) $metaText))
  }
  $script:RemindItems = $alive

  # 「已错过」分组只在用户主动查看时展开，平时不打扰；数据本身一直在，随时能补看
  $missed = @()
  if ($script:ShowMissed) { $missed = @(Get-MissedReminders) }
  if ($missed.Count -gt 0) {
    if ($alive.Count -gt 0) {
      $sep = [System.Windows.Controls.TextBlock]::new()
      $sep.Text = (TCount '已错过 · {0} 条' $missed.Count)
      $sep.FontSize = 9.5
      $sep.Margin = [System.Windows.Thickness]::new(0, 4, 0, 5)
      $sep.Foreground = $script:Win.Resources['TextMutedBrush']
      [void]$panel.Children.Add($sep)
    }
    foreach ($task in $missed) {
      $at = Get-TaskRemindAt $task
      $whenText = if ($null -ne $at) { '原定 ' + (Format-RemindLabel $at) } else { '原定时间未知' }
      [void]$panel.Children.Add((New-RemindRow $task @(@{ label = '重新提醒'; action = 'resnooze' }, @{ label = '忽略'; action = 'ignore' }) ($whenText + ' · ' + (Format-MissedAgo $task))))
    }
  }

  $total = $alive.Count + $missed.Count
  if ($total -eq 0) {
    $ui['RemindOverlay'].Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $ui['RemindTitle'].Text = Format-RemindTitle $alive.Count $missed.Count
    $ui['RemindOverlay'].Visibility = [System.Windows.Visibility]::Visible
  }
}
function Show-MissedReminders {
  $script:ShowMissed = $true
  try {
    if ($ui['SettingsOverlay'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings }
  } catch { }
  Update-RemindOverlay
  if (-not $script:Win.IsVisible) { Show-AppWindow }
}
function Show-RemindOverlay([object[]]$tasks) {
  $ids = @()
  foreach ($t in $tasks) { if ($null -ne $t -and $t.id) { $ids += [string]$t.id } }
  if ($ids.Count -eq 0) { return }
  foreach ($id in $ids) { if ($script:RemindItems -notcontains $id) { $script:RemindItems += $id } }
  Update-RemindOverlay
  if (-not $script:Win.IsVisible) { Show-AppWindow }
  if ([bool]$script:Settings.remindSound) {
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
  }
  if ([bool]$script:Settings.tray -and $script:TrayIcon) {
    try {
      $names = @()
      foreach ($t in $tasks) { $names += [string]$t.text }
      $line = ($names -join '；')
      if ($line.Length -gt 60) { $line = $line.Substring(0, 60) + '…' }
      $script:TrayIcon.ShowBalloonTip(3000, '核桃便签 · 到点提醒', $line, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
  }
}
function Invoke-ReminderCheck {
  $now = Get-Date
  $due = @()
  $expired = @()
  $expireHours = 24
  try { $expireHours = [int]$script:Settings.remindExpire } catch { $expireHours = 24 }
  foreach ($task in @($script:Tasks)) {
    $trigger = Get-RemindTriggerAt $task
    if ($null -eq $trigger) { continue }
    if ($now -lt $trigger) { continue }
    # 超过保留时长的陈年提醒不再弹窗，避免关机几天后开机被一堆过期提醒淹没。
    # 但绝不静默丢弃：打上 expiredAt 记进「已错过」，并弹一条可点击的汇总提示，
    # 用户随时能补看、重新提醒或忽略（阈值可在设置里调，0 表示永不放弃）。
    if ($expireHours -gt 0 -and ($now - $trigger).TotalHours -gt $expireHours) {
      $isNew = [string]::IsNullOrWhiteSpace([string]$task.expiredAt)
      $task.reminded = $true
      $task.snoozeAt = $null
      if ($isNew) {
        $task.expiredAt = (Get-IsoNow)
        $expired += $task
      }
      continue
    }
    $due += $task
  }
  if ($due.Count -eq 0 -and $expired.Count -eq 0) { return }
  foreach ($task in $due) { $task.reminded = $true; $task.snoozeAt = $null }
  Save-State
  if ($due.Count -gt 0) {
    Show-RemindOverlay $due
    Rebuild-Tasks $false
  }
  if ($expired.Count -gt 0) {
    Update-MissedUi
    # 提示条在窗口里，藏在托盘时得先把窗口叫出来，否则等于没提示
    if (-not $script:Win.IsVisible) { Show-AppWindow }
    $line = if ($expired.Count -gt 1) { "有 $($expired.Count) 条提醒已错过（到点时程序没在运行），点这里查看" } else { '有 1 条提醒已错过（到点时程序没在运行），点这里查看' }
    Show-Toast $line { Show-MissedReminders } 12
  }
}
function Update-RemindLeadUi {
  $lead = [int]$script:Settings.remindLead
  $label = switch ($lead) { 5 { '提前 5 分钟' } 15 { '提前 15 分钟' } 30 { '提前 30 分钟' } default { '准时' } }
  if ($ui['RemindLeadText']) { $ui['RemindLeadText'].Text = '提前提醒：' + $label }
  foreach ($pair in @(@{ name = 'RemindLead0'; value = 0 }, @{ name = 'RemindLead5'; value = 5 },
      @{ name = 'RemindLead15'; value = 15 }, @{ name = 'RemindLead30'; value = 30 })) {
    $btn = $ui[$pair.name]
    if ($null -eq $btn) { continue }
    if ($lead -eq $pair.value) {
      $btn.Foreground = $script:Win.Resources['AccentTextBrush']
      $btn.BorderBrush = $script:Win.Resources['AccentDeepBrush']
    } else {
      $btn.Foreground = $script:Win.Resources['TextSecondaryBrush']
      $btn.BorderBrush = $script:Win.Resources['CardBorderBrush']
    }
  }
}
function Get-RemindExpireLabel([int]$hours) {
  switch ($hours) {
    0 { '不限时间，全部补弹' }
    72 { '3 天内补弹' }
    168 { '7 天内补弹' }
    default { '24 小时内补弹' }
  }
}
function Update-RemindExpireUi {
  $hours = 24
  try { $hours = [int]$script:Settings.remindExpire } catch { $hours = 24 }
  if ($ui['RemindExpireText']) { $ui['RemindExpireText'].Text = '关机错过的提醒：' + (Get-RemindExpireLabel $hours) }
  foreach ($pair in @(@{ name = 'RemindExpire24'; value = 24 }, @{ name = 'RemindExpire72'; value = 72 },
      @{ name = 'RemindExpire168'; value = 168 }, @{ name = 'RemindExpire0'; value = 0 })) {
    $btn = $ui[$pair.name]
    if ($null -eq $btn) { continue }
    if ($hours -eq [int]$pair.value) {
      $btn.Foreground = $script:Win.Resources['AccentTextBrush']
      $btn.BorderBrush = $script:Win.Resources['AccentDeepBrush']
    } else {
      $btn.Foreground = $script:Win.Resources['TextSecondaryBrush']
      $btn.BorderBrush = $script:Win.Resources['CardBorderBrush']
    }
  }
}
function Set-RemindExpire([int]$hours) {
  if (@(0, 24, 72, 168) -notcontains $hours) { return }
  $script:Settings.remindExpire = $hours
  Update-RemindExpireUi
  Save-State
  Show-Toast ('已设为：' + (Get-RemindExpireLabel $hours))
}
# 设置面板里的「已错过」入口：数字来自数据本身，重启后依然在，随时可以补看
function Update-MissedUi {
  $count = @(Get-MissedReminders).Count
  if ($ui['MissedBanner']) {
    $ui['MissedBanner'].Visibility = if ($count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  }
  if ($ui['MissedText'] -and $count -gt 0) {
    $ui['MissedText'].Text = (TCount '有 {0} 条提醒已错过（到点时程序没在运行）' $count)
  }
}
function Open-RemindEditor([string]$taskId) {
  $task = Find-Task $taskId
  if ($null -eq $task) { return }
  $script:RemindEditTaskId = $taskId
  $ui['RemindEditorText'].Text = '为「' + [string]$task.text + '」设置提醒'
  $existing = Get-TaskRemindAt $task
  $default = if ($null -ne $existing) { $existing } else { (Get-Date).Date.AddDays(1).AddHours(9) }
  $ui['RemindInput'].Text = $default.ToString('yyyy-MM-dd HH:mm', $script:Invariant)
  $ui['RemindEditor'].Visibility = [System.Windows.Visibility]::Visible
  [void]$ui['RemindInput'].Focus()
  $ui['RemindInput'].SelectAll()
}
function Close-RemindEditor {
  $ui['RemindEditor'].Visibility = [System.Windows.Visibility]::Collapsed
  $script:RemindEditTaskId = $null
}
function ConvertTo-RemindDate([string]$text) {
  $raw = ([string]$text).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $formats = @('yyyy-MM-dd HH:mm', 'yyyy-M-d H:mm', 'yyyy/MM/dd HH:mm', 'yyyy/M/d H:mm',
    'MM-dd HH:mm', 'M-d H:mm', 'MM/dd HH:mm', 'M/d H:mm', 'yyyy-MM-dd', 'yyyy-M-d')
  foreach ($fmt in $formats) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($raw, $fmt, $script:Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
      if ($fmt -notmatch 'H') { $parsed = $parsed.Date.AddHours(9) }
      # 省略年份时若已过期，顺延到明年（12 月输入 01-05 不该变成去年的 1 月）
      if ($fmt -notmatch 'y' -and $parsed -lt (Get-Date).Date) { $parsed = $parsed.AddYears(1) }
      return $parsed
    }
  }
  $loose = [datetime]::MinValue
  if ([datetime]::TryParse($raw, $script:Culture, [System.Globalization.DateTimeStyles]::None, [ref]$loose)) { return $loose }
  return $null
}

# ---------- 专注模式顶部按钮（置顶 / 锁定 / 退出） ----------
function Sync-FocusChrome {
  if (-not $script:Win) { return }
  $topmost = [bool]$script:Settings.topmost
  $locked = [bool]$script:Settings.locked
  $script:SyncingUi = $true
  if ($ui['FocusPinToggle']) { $ui['FocusPinToggle'].IsChecked = $topmost }
  if ($ui['FocusLockToggle']) { $ui['FocusLockToggle'].IsChecked = $locked }
  $script:SyncingUi = $false
  if ($ui['FocusPinToggle']) {
    $ui['FocusPinToggle'].ToolTip = if ($topmost) { '取消窗口置顶' } else { '窗口置顶' }
    $ui['FocusPinToggle'].Foreground = if ($topmost) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] }
  }
  if ($ui['FocusLockToggle']) {
    $ui['FocusLockToggle'].Content = if ($locked) { [string][char]0xE785 } else { [string][char]0xE72E }
    $ui['FocusLockToggle'].ToolTip = if ($locked) { '已锁定，点一下解锁' } else { '锁定页面（禁止拖动与编辑）' }
    $ui['FocusLockToggle'].Foreground = if ($locked) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] }
  }
  # 锁定状态下不可缩放窗口
  if ($ui['ResizeGrip']) {
    $ui['ResizeGrip'].Visibility = if ($locked) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
  }
}

# ---------- 页面锁定 ----------
function Set-Locked([bool]$enabled, [bool]$hint = $true) {
  $script:Settings.locked = $enabled
  $script:SyncingUi = $true
  if ($ui['LockToggle']) { $ui['LockToggle'].IsChecked = $enabled }
  $script:SyncingUi = $false
  if ($ui['LockToggle']) {
    $ui['LockToggle'].Content = if ($enabled) { [string][char]0xE785 } else { [string][char]0xE72E }
    $ui['LockToggle'].ToolTip = if ($enabled) { '已锁定，点一下解锁' } else { '锁定页面（禁止拖动与编辑）' }
    $ui['LockToggle'].Foreground = if ($enabled) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] }
  }
  foreach ($name in @('ComposerGrid', 'SearchButton', 'SettingsButton', 'TagsButton')) {
    if ($ui[$name]) { $ui[$name].IsEnabled = -not $enabled }
  }
  if ($ui['ComposerGrid']) { $ui['ComposerGrid'].Opacity = if ($enabled) { 0.45 } else { 1.0 } }
  Sync-FocusChrome
  Save-State
  Rebuild-All
  if ($hint) { Show-Toast $(if ($enabled) { '已锁定：拖动与编辑已禁用' } else { '已解锁' }) }
}
# ---------- 专注模式 ----------
# ---------- 专注模式：番茄钟 ----------
# 只在专注小窗出现；纯运行时状态，不落盘（关掉应用就重置）
$script:Pomodoro = @{ running = $false; remain = 1500; total = 1500; label = '专注' }

function Format-PomodoroTime([int]$seconds) {
  if ($seconds -lt 0) { $seconds = 0 }
  return ('{0:00}:{1:00}' -f [math]::Floor($seconds / 60), ($seconds % 60))
}

function Update-PomodoroUi {
  if (-not $script:Ui['PomodoroText']) { return }
  $script:Ui['PomodoroText'].Text = Format-PomodoroTime ([int]$script:Pomodoro.remain)
  $dot = $script:Ui['PomodoroDot']
  if ($dot) {
    $dot.Fill = if ($script:Pomodoro.running) { $script:Win.Resources['AccentDeepBrush'] } else { $script:Win.Resources['TextMutedBrush'] }
  }
  $panel = $script:Ui['PomodoroPanel']
  if ($panel) {
    $mins = [int][math]::Floor(([int]$script:Pomodoro.total) / 60)
    $panel.ToolTip = if ($script:Pomodoro.running) { '左键暂停 · 右键换时长' } else { "左键开始$($script:Pomodoro.label) $mins 分钟 · 右键换时长" }
  }
}

function Show-PomodoroDone {
  $line = if ([string]$script:Pomodoro.label -eq '休息') { '休息结束，回来继续' } else { '专注结束，歇 5 分钟' }
  try { Show-Toast $line } catch { }
  if ($script:Settings.remindSound -ne $false) {
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
  }
  if ($script:TrayIcon) {
    try { $script:TrayIcon.ShowBalloonTip(3200, '核桃便签 · 番茄钟', $line, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
  }
}

function Set-PomodoroMode([int]$minutes) {
  if ($minutes -le 0) { $minutes = 25 }
  $script:Pomodoro.total = $minutes * 60
  $script:Pomodoro.remain = $script:Pomodoro.total
  $script:Pomodoro.label = if ($minutes -eq 5) { '休息' } else { '专注' }
  $script:Pomodoro.running = $false
  $script:PomodoroTimer.Stop()
  Update-PomodoroUi
}
function Open-PomodoroEditor {
  if (-not $ui['PomodoroInput']) { return }
  $ui['PomodoroInput'].Text = ([string][int][math]::Floor(([int]$script:Pomodoro.total) / 60))
  $ui['PomodoroEditor'].Visibility = [System.Windows.Visibility]::Visible
  [void]$ui['PomodoroInput'].Focus()
  $ui['PomodoroInput'].SelectAll()
}
function Close-PomodoroEditor {
  if ($ui['PomodoroEditor']) { $ui['PomodoroEditor'].Visibility = [System.Windows.Visibility]::Collapsed }
}

$script:PomodoroTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:PomodoroTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:PomodoroTimer.Add_Tick({
    if (-not $script:Pomodoro.running) { return }
    $script:Pomodoro.remain = ([int]$script:Pomodoro.remain) - 1
    if ([int]$script:Pomodoro.remain -le 0) {
      $script:Pomodoro.remain = 0
      $script:Pomodoro.running = $false
      $script:PomodoroTimer.Stop()
      Update-PomodoroUi
      Show-PomodoroDone
      return
    }
    Update-PomodoroUi
  })

function Set-FocusMode([bool]$enabled) {
  $script:Settings.focusMode = $enabled
  if ($enabled) {
    # 进小窗前把完整模式尺寸存成快照，退出时按它还原（不依赖 Bounds 的事件时序）
    $snapW = [double]$script:Win.ActualWidth
    $snapH = [double]$script:Win.ActualHeight
    if ($snapW -le 0) { $snapW = [double]$script:Win.Width }
    if ($snapH -le 0) { $snapH = [double]$script:Win.Height }
    if ($snapW -ge $script:FullMinWidth -and $snapH -ge $script:FullMinHeight) {
      $script:RestoreSize = @{ w = $snapW; h = $snapH }
    }
    foreach ($name in @('HeaderGrid', 'ToolbarGrid', 'ComposerGrid')) {
      if ($ui[$name]) { $ui[$name].Visibility = [System.Windows.Visibility]::Collapsed }
    }
    if ($script:SearchOpen) { Close-Search }
    Close-Settings
    if ($ui['FocusActions']) { $ui['FocusActions'].Visibility = [System.Windows.Visibility]::Visible }
    if ($ui['PomodoroPanel']) {
      if ([bool]$script:Settings.pomodoro) { $ui['PomodoroPanel'].Visibility = [System.Windows.Visibility]::Visible; Update-PomodoroUi }
      else { $ui['PomodoroPanel'].Visibility = [System.Windows.Visibility]::Collapsed; $script:Pomodoro.running = $false; $script:PomodoroTimer.Stop() }
    }
    $ui['FocusExitButton'].Visibility = [System.Windows.Visibility]::Visible
    if ($ui['FocusDragBar']) { $ui['FocusDragBar'].Visibility = [System.Windows.Visibility]::Visible }
    Sync-FocusChrome
    if ($ui['EmptySubtitle']) { $ui['EmptySubtitle'].Text = '退出专注模式即可添加新便签' }
    # 番茄钟显示时给列表顶部留出它的高度（大字号居中占位），否则只避开右上角按钮
    $focusListTop = if ([bool]$script:Settings.pomodoro) { 104.0 } else { 34.0 }
    $ui['TasksScroller'].Margin = [System.Windows.Thickness]::new(10, $focusListTop, 10, 12)
    $ui['HistoryScroller'].Margin = [System.Windows.Thickness]::new(10, $focusListTop, 10, 12)
    $area = Get-WindowWorkArea
    $maxW = [math]::Max(220, $area.right - $area.left - 12)
    $maxH = [math]::Max(180, $area.bottom - $area.top - 12)
    $script:Win.MinWidth = $script:FocusMinWidth
    $script:Win.MinHeight = $script:FocusMinHeight
    $targetW = if ([double]$script:Settings.focusWidth -ge $script:FocusMinWidth) { [double]$script:Settings.focusWidth } else { 320 }
    $targetH = if ([double]$script:Settings.focusHeight -ge $script:FocusMinHeight) { [double]$script:Settings.focusHeight } else { 420 }
    $script:Win.Width = [math]::Min($targetW, $maxW)
    $script:Win.Height = [math]::Min($targetH, $maxH)
    Clamp-WindowToWorkArea
    Update-RemindLayout
    Rebuild-All
  } else {
    foreach ($name in @('HeaderGrid', 'ToolbarGrid', 'ComposerGrid')) {
      if ($ui[$name]) { $ui[$name].Visibility = [System.Windows.Visibility]::Visible }
    }
    if ($ui['FocusActions']) { $ui['FocusActions'].Visibility = [System.Windows.Visibility]::Collapsed }
    # 退出专注先暂停番茄钟，剩余时间留着，下次进小窗接着用
    if ($ui['PomodoroPanel']) { $ui['PomodoroPanel'].Visibility = [System.Windows.Visibility]::Collapsed }
    if ($script:Pomodoro.running) { $script:Pomodoro.running = $false; $script:PomodoroTimer.Stop() }
    Close-PomodoroEditor
    $ui['FocusExitButton'].Visibility = [System.Windows.Visibility]::Collapsed
    if ($ui['FocusDragBar']) { $ui['FocusDragBar'].Visibility = [System.Windows.Visibility]::Collapsed }
    if ($ui['EmptySubtitle']) { $ui['EmptySubtitle'].Text = '在下方输入一条，按 Enter 保存' }
    $ui['TasksScroller'].Margin = [System.Windows.Thickness]::new(22, 8, 14, 0)
    $ui['HistoryScroller'].Margin = [System.Windows.Thickness]::new(22, 8, 14, 0)
    $script:Win.MinWidth = $script:FullMinWidth
    $script:Win.MinHeight = $script:FullMinHeight
    # 退出专注：还原进小窗前的完整模式尺寸（最小 440×540）
    $restoreW = if ($null -ne $script:RestoreSize -and [double]$script:RestoreSize.w -ge $script:FullMinWidth) { [double]$script:RestoreSize.w } else { [double]$script:Bounds.width }
    $restoreH = if ($null -ne $script:RestoreSize -and [double]$script:RestoreSize.h -ge $script:FullMinHeight) { [double]$script:RestoreSize.h } else { [double]$script:Bounds.height }
    $restoreW = [math]::Max($script:FullMinWidth, $restoreW)
    $restoreH = [math]::Max($script:FullMinHeight, $restoreH)
    $script:Win.Width = $restoreW
    $script:Win.Height = $restoreH
    Clamp-WindowToWorkArea
    Update-RemindLayout
    Rebuild-All
  }
  $script:SyncingUi = $true
  if ($ui['FocusToggle']) { $ui['FocusToggle'].IsChecked = $enabled }
  $script:SyncingUi = $false
  if ($ui['FocusToggle']) {
    $ui['FocusToggle'].Content = if ($enabled) { [string][char]0xE73F } else { [string][char]0xE740 }
    $ui['FocusToggle'].ToolTip = if ($enabled) { '退出专注模式' } else { '专注模式（小窗）' }
    $ui['FocusToggle'].Foreground = if ($enabled) { $script:Win.Resources['AccentTextBrush'] } else { $script:Win.Resources['IconFgBrush'] }
  }
  Save-State
}

# ---------- 屏幕工作区 / 吸附 / 尺寸钳制 ----------
function Update-RemindLayout {
  # 提醒浮层贴在顶部按钮行以下，不能盖住置顶/锁定/专注/设置这些按钮，否则提醒一来就点不动了
  if (-not $ui['RemindOverlay']) { return }
  $focus = [bool]$script:Settings.focusMode
  $topGap = if ($focus) { 30.0 } else { 78.0 }
  $ui['RemindOverlay'].Margin = [System.Windows.Thickness]::new(16, $topGap, 16, 0)
  if (-not $ui['RemindScroller']) { return }
  $h = [double]$script:Win.ActualHeight
  if ($h -le 0) { return }
  $ui['RemindScroller'].MaxHeight = [math]::Max(90, [math]::Min(260, ($h - $topGap) * 0.55))
}
function Get-DpiScale {
  try {
    $src = [System.Windows.PresentationSource]::FromVisual($script:Win)
    if ($src -and $src.CompositionTarget) {
      $m = $src.CompositionTarget.TransformToDevice
      if ($m.M11 -gt 0) { return [double]$m.M11 }
    }
  } catch { }
  return 1.0
}
function Get-WindowWorkArea {
  try {
    if ($script:Hwnd -ne [System.IntPtr]::Zero) {
      $screen = [System.Windows.Forms.Screen]::FromHandle($script:Hwnd)
      if ($null -ne $screen) {
        $wa = $screen.WorkingArea
        $scale = Get-DpiScale
        return @{
          left   = [double]$wa.Left / $scale
          top    = [double]$wa.Top / $scale
          right  = [double]$wa.Right / $scale
          bottom = [double]$wa.Bottom / $scale
        }
      }
    }
  } catch { }
  $wa2 = [System.Windows.SystemParameters]::WorkArea
  return @{ left = [double]$wa2.Left; top = [double]$wa2.Top; right = [double]$wa2.Right; bottom = [double]$wa2.Bottom }
}
function Clamp-WindowToWorkArea {
  if ($null -eq $script:Win) { return }
  if ($script:Win.WindowState -ne [System.Windows.WindowState]::Normal) { return }
  $area = Get-WindowWorkArea
  $w = [double]$script:Win.ActualWidth; $h = [double]$script:Win.ActualHeight
  if ($w -le 0 -or $h -le 0) { return }
  $left = [double]$script:Win.Left; $top = [double]$script:Win.Top
  $maxLeft = [math]::Max($area.left, $area.right - $w)
  $maxTop = [math]::Max($area.top, $area.bottom - $h)
  $newLeft = [math]::Min([math]::Max($left, $area.left), $maxLeft)
  $newTop = [math]::Min([math]::Max($top, $area.top), $maxTop)
  if ($newLeft -ne $left -or $newTop -ne $top) {
    try { $script:Win.Left = $newLeft; $script:Win.Top = $newTop } catch { }
  }
}
function Snap-WindowToEdge {
  # 仅专注模式（小窗）吸附；贴边但不自动收起
  if (-not [bool]$script:Settings.snapEdge) { return $false }
  if (-not [bool]$script:Settings.focusMode) { return $false }
  if ($null -eq $script:Win) { return $false }
  if ($script:Win.WindowState -ne [System.Windows.WindowState]::Normal) { return $false }
  $area = Get-WindowWorkArea
  $snap = 18.0
  $left = [double]$script:Win.Left; $top = [double]$script:Win.Top
  $w = [double]$script:Win.ActualWidth; $h = [double]$script:Win.ActualHeight
  if ($w -le 0 -or $h -le 0) { return $false }
  $right = $left + $w; $bottom = $top + $h
  $newLeft = $left; $newTop = $top
  if ([math]::Abs($left - $area.left) -le $snap) { $newLeft = $area.left }
  elseif ([math]::Abs($right - $area.right) -le $snap) { $newLeft = $area.right - $w }
  if ([math]::Abs($top - $area.top) -le $snap) { $newTop = $area.top }
  elseif ([math]::Abs($bottom - $area.bottom) -le $snap) { $newTop = $area.bottom - $h }
  if ([math]::Abs($newLeft - $left) -lt 0.5 -and [math]::Abs($newTop - $top) -lt 0.5) { return $false }
  try { $script:Win.Left = $newLeft; $script:Win.Top = $newTop } catch { return $false }
  Update-Bounds
  Request-Save
  return $true
}

# ---------- 本周日历（主页时间模块） ----------
function Update-WeekStrip {
  if (-not $script:Win) { return }
  $strip = $ui['WeekStrip']
  $host_ = $ui['WeekStripHost']
  if ($null -eq $strip -or $null -eq $host_) { return }
  if (-not [bool]$script:Settings.clockCalendar) {
    $strip.Visibility = [System.Windows.Visibility]::Collapsed
    $script:WeekStripKey = ''
    return
  }
  $strip.Visibility = [System.Windows.Visibility]::Visible
  $today = (Get-Date).Date
  $key = $today.ToString('yyyy-MM-dd') + '|' + [string]$script:Settings.theme + '|' + $script:LangCode
  if ($script:WeekStripKey -eq $key -and $host_.Children.Count -gt 0) { return }
  $script:WeekStripKey = $key

  $t = $script:Themes[[string]$script:Settings.theme]
  if ($null -eq $t) { $t = $script:Themes['lime'] }
  $mutedBrush = New-Brush $t.textMuted
  $weekendBrush = New-Brush $t.textSecondary
  $primaryBrush = New-Brush '#FFF7FBF9'
  $todayBg = New-Brush ('#5A' + $t.accent.Substring(3))

  $host_.Children.Clear()
  $host_.RowDefinitions.Clear()
  $host_.ColumnDefinitions.Clear()
  for ($i = 0; $i -lt 7; $i++) {
    $col = [System.Windows.Controls.ColumnDefinition]::new()
    $col.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$host_.ColumnDefinitions.Add($col)
  }
  $names = if ($script:LangCode -eq 'en') { @('M', 'T', 'W', 'T', 'F', 'S', 'S') } else { @('一', '二', '三', '四', '五', '六', '日') }
  $offset = (([int]$today.DayOfWeek) + 6) % 7
  $monday = $today.AddDays(-$offset)
  for ($i = 0; $i -lt 7; $i++) {
    $day = $monday.AddDays($i)
    $isToday = ($day -eq $today)
    $cell = [System.Windows.Controls.StackPanel]::new()
    $cell.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch

    $weekday = [System.Windows.Controls.TextBlock]::new()
    $weekday.Text = $names[$i]
    $weekday.FontSize = 8.5
    $weekday.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    if ($isToday) { $weekday.Foreground = New-Brush $t.accentText }
    elseif ($i -ge 5) { $weekday.Foreground = $weekendBrush }
    else { $weekday.Foreground = $mutedBrush }

    $circle = [System.Windows.Controls.Border]::new()
    $circle.Width = 24; $circle.Height = 24
    $circle.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $circle.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $circle.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    if ($isToday) { $circle.Background = $todayBg }
    $num = [System.Windows.Controls.TextBlock]::new()
    $num.Text = [string]$day.Day
    $num.FontSize = 10.5
    $num.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $num.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    if ($isToday) {
      $num.Foreground = $primaryBrush
      $num.FontWeight = [System.Windows.FontWeights]::SemiBold
    } elseif ($i -ge 5) {
      $num.Foreground = $weekendBrush
    } else {
      $num.Foreground = $mutedBrush
    }
    $circle.Child = $num
    [void]$cell.Children.Add($weekday)
    [void]$cell.Children.Add($circle)
    [void]$host_.Children.Add($cell)
    [System.Windows.Controls.Grid]::SetColumn($cell, $i)
  }
}


# ---------- 导出 / 备份 ----------
function Get-ExportDir {
  if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Force -Path $script:ExportDir | Out-Null }
  return $script:ExportDir
}
function Export-HistoryMarkdown {
  try {
    $dir = Get-ExportDir
    $path = Join-Path $dir ("历史_{0}.md" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $records = @(Get-CompletionRecords) | Sort-Object { [string]$_.doneAt } -Descending
    $lines = @('# 核桃便签历史记录', '', ('导出时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm')), '')
    $lastDate = ''
    foreach ($record in $records) {
      $dateLabel = '未知日期'
      try { $dateLabel = ([datetime]::Parse([string]$record.doneAt, $script:Invariant)).ToString($script:FmtDateLong, $script:Culture) } catch { }
      if ($dateLabel -ne $lastDate) { $lines += ''; $lines += "## $dateLabel"; $lines += ''; $lastDate = $dateLabel }
      $time = ''
      try { $time = ([datetime]::Parse([string]$record.doneAt, $script:Invariant)).ToString('HH:mm') } catch { }
      $kind = if ($record.kind -eq 'repeat') { (Get-UnitLabel ([string]$record.unit)) + '循环' } else { '单次' }
      $lines += "- [x] $($record.text)  （$time · $kind）"
    }
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
    $ui['SettingsStatus'].Text = (T '已导出：') + $path
    Show-Toast '历史记录已导出为 Markdown'
  } catch { $ui['SettingsStatus'].Text = (T '导出失败：') + $_.Exception.Message; Write-ErrorLog "export markdown failed: $($_.Exception.ToString())" }
}
function Format-CsvTime($value) {
  if ($null -eq $value) { return '' }
  $raw = [string]$value
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
  try { return ([datetime]::Parse($raw, $script:Invariant)).ToString('yyyy-MM-dd HH:mm') } catch { return '' }
}
function ConvertTo-CsvField([string]$text) {
  return '"' + ([string]$text).Replace('"', '""') + '"'
}
function Get-TaskKindLabel($item) {
  if ($item.kind -eq 'repeat') { return ((Get-UnitLabel ([string]$item.unit)) + '循环') }
  return '单次'
}
function Export-RecordsCsv {
  try {
    $dir = Get-ExportDir
    $path = Join-Path $dir ("便签记录_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $lines = @('状态,内容,创建时间,提醒时间,循环情况,完成时间')
    foreach ($task in @($script:Tasks | Sort-Object -Property @{ Expression = { [int]$_.order } })) {
      $state = if ([bool]$task.done) { '已完成' } else { '待办' }
      $fields = @($state, [string]$task.text, (Format-CsvTime $task.created), (Format-CsvTime $task.remindAt),
        (Get-TaskKindLabel $task), (Format-CsvTime $task.doneAt))
      $lines += (($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
    }
    foreach ($record in @($script:History | Sort-Object -Property @{ Expression = { [string]$_.doneAt }; Descending = $true })) {
      $fields = @('已归档', [string]$record.text, (Format-CsvTime $record.created), (Format-CsvTime $record.remindAt),
        (Get-TaskKindLabel $record), (Format-CsvTime $record.doneAt))
      $lines += (($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
    }
    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($true))
    $ui['SettingsStatus'].Text = (T '已导出：') + $path
    Show-Toast '全部便签与历史已导出为 CSV'
  } catch { $ui['SettingsStatus'].Text = (T '导出失败：') + $_.Exception.Message; Write-ErrorLog "export csv failed: $($_.Exception.ToString())" }
}
function New-Backup {
  try {
    $dir = Get-ExportDir
    Save-State
    $path = Join-Path $dir ("backup_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item -LiteralPath $script:DataFile -Destination $path -Force
    $ui['SettingsStatus'].Text = (T '已备份：') + $path
    Show-Toast '数据已备份'
    return $path
  } catch { $ui['SettingsStatus'].Text = (T '备份失败：') + $_.Exception.Message; Write-ErrorLog "backup failed: $($_.Exception.ToString())"; return $null }
}
function Import-StateFile([string]$path) {
  try {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj.version -or [int]$obj.version -lt 2) { throw '备份版本过旧，无法恢复' }
    Save-State
    $safety = Join-Path $script:DataDir ("notes.before-restore.{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item -LiteralPath $script:DataFile -Destination $safety -Force -ErrorAction SilentlyContinue
    Normalize-LoadedState $obj
    Save-State
    Apply-AllSettingsUi
    Rebuild-All
    $ui['SettingsStatus'].Text = (T '已恢复：') + $path
    Show-Toast '数据已从备份恢复'
    return $true
  } catch { $ui['SettingsStatus'].Text = (T '恢复失败：') + $_.Exception.Message; Write-ErrorLog "restore from backup failed: $($_.Exception.ToString())"; return $false }
}
function Restore-LatestBackup {
  $dir = Get-ExportDir
  $latest = Get-ChildItem -LiteralPath $dir -Filter 'backup_*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $latest) { $ui['SettingsStatus'].Text = (T '还没有备份文件'); Show-Toast '还没有可恢复的备份'; return }
  $askBody = (T '将用以下备份覆盖当前数据：') + "`n" + $latest.Name + "`n`n" + (T '会先自动备份当前数据，继续？')
  $answer = [System.Windows.MessageBox]::Show($askBody, (T '恢复备份'), 'YesNo', 'Question')
  if ($answer -ne 'Yes') { return }
  [void](Import-StateFile $latest.FullName)
}

function Apply-AllSettingsUi {
  Set-Theme ([string]$script:Settings.theme) $false
  Set-TopmostMode ([bool]$script:Settings.topmost)
  Set-GlassMode ([bool]$script:Settings.glass) $false
  Update-ComposerTypeButton
  Sync-SettingsUi
  Set-TrayEnabled ([bool]$script:Settings.tray)
  if ($script:SourceInitialized) { [void](Set-HotkeyEnabled ([bool]$script:Settings.hotkey)) }
  $script:Settings.autostart = Test-Autostart
  Sync-SettingsUi
}
function Update-ComposerTypeButton {
  if ($null -eq $ui['RepeatButton']) { return }
  $kind = [string]$script:Settings.composerKind
  $label = switch ($kind) { 'day' { '每天' } 'week' { '每周' } 'month' { '每月' } 'note' { '笔记' } default { '单次' } }
  $ui['RepeatButton'].Content = $label + '  ▾'
  $ui['RepeatButton'].Foreground = if ($kind -eq 'once') { $script:Win.Resources['TextSecondaryBrush'] } else { $script:Win.Resources['AccentTextBrush'] }
  if ($ui['Placeholder']) {
    $ui['Placeholder'].Text = if ($kind -eq 'note') { '记一条笔记（没有勾选框），Enter 保存，Shift + Enter 换行…' } else { '添加一条便签，Enter 保存，Shift + Enter 换行…' }
  }
}

# ---------- 事件处理器（脚本作用域） ----------
# ---------- 勾选完成的即时反馈 ----------
# 勾掉时先播一小段动画（勾选框弹一下、卡片柔和沉到"已完成"的观感），190ms 后才真正落库并重建列表，
# 否则 Rebuild 会立刻销毁卡片，动画根本看不见。
function Play-DoneChime {
  if ([bool]$script:Settings.doneSound -eq $false) { return }
  try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
}
function Get-TaskCardAncestor([object]$element) {
  $cur = $element
  for ($i = 0; $i -lt 8; $i++) {
    if ($null -eq $cur) { return $null }
    if ($cur -is [System.Windows.Controls.Border] -and $null -ne $cur.Tag) { return $cur }
    try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { return $null }
  }
  return $null
}
$script:PendingDoneId = $null
$script:DoneFeedbackTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:DoneFeedbackTimer.Interval = [TimeSpan]::FromMilliseconds(190)
$script:DoneFeedbackTimer.Add_Tick({
    $script:DoneFeedbackTimer.Stop()
    $pending = [string]$script:PendingDoneId
    $script:PendingDoneId = $null
    if ($pending) { try { Set-TaskDone $pending $true } catch { Write-ErrorLog ("persist done state failed: " + $_.Exception.ToString()) } }
  })

$script:OnTaskChecked = {
  param($sender, $eventArgs)
  try {
    $taskId = [string]$sender.Tag
    if (-not [bool]$sender.IsChecked) { Set-TaskDone $taskId $false; return }
    # 上一条还在等动画时又被勾掉：先把上一条落库，避免快速连点丢一条
    if ($script:PendingDoneId) {
      $prev = [string]$script:PendingDoneId
      $script:PendingDoneId = $null
      try { Set-TaskDone $prev $true } catch { }
    }
    Play-DoneChime
    $card = Get-TaskCardAncestor $sender
    if ($card) {
      try {
        $ease = [System.Windows.Media.Animation.CubicEase]::new()
        $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.78, [TimeSpan]::FromMilliseconds(180))
        $fade.EasingFunction = $ease
        $card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
      } catch { }
    }
    try {
      $scale = [System.Windows.Media.ScaleTransform]::new(1, 1)
      $sender.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
      $sender.RenderTransform = $scale
      $pop = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 1.28, [TimeSpan]::FromMilliseconds(90))
      $pop.AutoReverse = $true
      $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
      $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
    } catch { }
    $script:PendingDoneId = $taskId
    $script:DoneFeedbackTimer.Stop()
    $script:DoneFeedbackTimer.Start()
  } catch { Write-ErrorLog ("toggle handler failed: " + $_.Exception.ToString()) }
}
$script:OnTaskTextChanged = {
  param($sender, $eventArgs)
  if ($script:SyncingText) { return }
  try { Set-TaskText ([string]$sender.Tag) ([string]$sender.Text) } catch { }
}
$script:OnTaskTextKeyDown = {
  param($sender, $eventArgs)
  if ($eventArgs.Key -ne [System.Windows.Input.Key]::Enter) { return }
  # Shift + Enter 换行，交给 TextBox 自己插入；其余 Enter 收笔回到输入框
  $shiftDown = (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0)
  if ($shiftDown) { return }
  if ($eventArgs.Handled) { return }
  $eventArgs.Handled = $true
  if ($script:Ui['NoteInput']) { [void]$script:Ui['NoteInput'].Focus() }
}
$script:OnDoneTextClick = {
  param($sender, $eventArgs)
  if ($eventArgs.ClickCount -eq 2) { try { Set-TaskDone ([string]$sender.Tag) $false } catch { } }
}
$script:OnTaskDeleteClick = {
  param($sender, $eventArgs)
  try { Remove-Task ([string]$sender.Tag) } catch { Write-ErrorLog ("delete handler failed: " + $_.Exception.ToString()) }
}
$script:OnTaskPinToggled = {
  param($sender, $eventArgs)
  try { Set-TaskPinned ([string]$sender.Tag) ([bool]$sender.IsChecked) } catch { }
}
$script:OnHistoryRestoreClick = {
  param($sender, $eventArgs)
  try { Restore-History ([string]$sender.Tag) } catch { }
}
$script:OnHistoryDeleteClick = {
  param($sender, $eventArgs)
  try { Remove-History ([string]$sender.Tag) } catch { }
}
$script:OnTaskTagClick = {
  param($sender, $eventArgs)
  try { $eventArgs.Handled = $true; Show-TaskTagMenu $sender } catch { Write-ErrorLog ("tag menu failed: " + $_.Exception.ToString()) }
}
$script:OnTrashRestoreClick = {
  param($sender, $eventArgs)
  try { Restore-Trash ([string]$sender.Tag) } catch { Write-ErrorLog ("restore from trash failed: " + $_.Exception.ToString()) }
}
$script:OnTrashPurgeClick = {
  param($sender, $eventArgs)
  try { Purge-Trash ([string]$sender.Tag) } catch { Write-ErrorLog ("purge from trash failed: " + $_.Exception.ToString()) }
}
$script:OnTrashClearAll = {
  param($sender, $eventArgs)
  try { Clear-Trash } catch { Write-ErrorLog ("clear trash failed: " + $_.Exception.ToString()) }
}
$script:OnThemeCardClick = {
  param($sender, $eventArgs)
  try { Set-Theme ([string]$sender.Tag) $true } catch { Write-ErrorLog ("theme switch failed: " + $_.Exception.ToString()) }
}
$script:OnTypeMenuClick = {
  param($sender, $eventArgs)
  try {
    $info = $sender.Tag
    if ($info.action -eq 'stop') { Stop-TaskSeries ([string]$info.taskId) }
    elseif ($info.action -eq 'note') { Set-TaskMode ([string]$info.taskId) 'note' }
    elseif ($info.action -eq 'todo') { Set-TaskMode ([string]$info.taskId) 'todo' }
    else { Set-TaskSeries ([string]$info.taskId) ([string]$info.unit) }
  } catch { Write-ErrorLog ("task mode change failed: " + $_.Exception.ToString()) }
}
$script:OnTypeBadgeClick = {
  param($sender, $eventArgs)
  try {
    $eventArgs.Handled = $true
    $task = Find-Task ([string]$sender.Tag)
    if ($null -eq $task) { return }
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.PlacementTarget = $sender
    if (Test-IsNote $task) {
      $toTodo = [System.Windows.Controls.MenuItem]::new()
      $toTodo.Header = (T '转为待办（显示复选框）')
      $toTodo.Tag = @{ action = 'todo'; taskId = [string]$task.id }
      $toTodo.Add_Click($script:OnTypeMenuClick)
      [void]$menu.Items.Add($toTodo)
    } else {
      $toNote = [System.Windows.Controls.MenuItem]::new()
      $toNote.Header = (T '转为笔记（无勾选框）')
      $toNote.Tag = @{ action = 'note'; taskId = [string]$task.id }
      $toNote.Add_Click($script:OnTypeMenuClick)
      [void]$menu.Items.Add($toNote)
      [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
    }
    foreach ($unit in @('day', 'week', 'month')) {
      $item = [System.Windows.Controls.MenuItem]::new()
      $label = T ('改为' + (Get-UnitLabel $unit) + '循环')
      if ($task.kind -eq 'repeat' -and [string]$task.unit -eq $unit) { $item.Header = [string][char]0x2713 + ' ' + $label }
      else { $item.Header = $label }
      $item.Tag = @{ action = 'set'; taskId = [string]$task.id; unit = $unit }
      $item.Add_Click($script:OnTypeMenuClick)
      [void]$menu.Items.Add($item)
    }
    if ($task.kind -eq 'repeat') {
      [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
      $stop = [System.Windows.Controls.MenuItem]::new(); $stop.Header = (T '停止循环')
      $stop.Tag = @{ action = 'stop'; taskId = [string]$task.id }
      $stop.Add_Click($script:OnTypeMenuClick)
      [void]$menu.Items.Add($stop)
    }
    Open-FloatingMenu $menu $sender
  } catch { Write-ErrorLog ("task mode menu failed: " + $_.Exception.ToString()) }
}
$script:OnTaskClockClick = {
  param($sender, $eventArgs)
  try {
    $taskId = [string]$sender.Tag
    $task = Find-Task $taskId
    if ($null -eq $task) { return }
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.PlacementTarget = $sender
    $now = Get-Date
    $monday = $now.Date.AddDays((8 - ([int]$now.DayOfWeek + 6) % 7) % 7)
    if ($monday -le $now.Date) { $monday = $monday.AddDays(7) }
    $quick = @(
      @{ label = '1 小时后'; when = $now.AddHours(1) },
      @{ label = '今天 20:00'; when = $now.Date.AddHours(20) },
      @{ label = '明天 09:00'; when = $now.Date.AddDays(1).AddHours(9) },
      @{ label = '下周一 09:00'; when = $monday.AddHours(9) }
    )
    foreach ($item in $quick) {
      $mi = [System.Windows.Controls.MenuItem]::new()
      $mi.Header = (T $item.label)
      $mi.Tag = @{ taskId = $taskId; when = ([datetime]$item.when).ToString('o') }
      $mi.Add_Click($script:OnRemindQuickPick)
      [void]$menu.Items.Add($mi)
    }
    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
    $custom = [System.Windows.Controls.MenuItem]::new()
    $custom.Header = (T '自定义时间…')
    $custom.Tag = $taskId
    $custom.Add_Click({ param($s, $e) Open-RemindEditor ([string]$s.Tag) })
    [void]$menu.Items.Add($custom)
    if ($null -ne (Get-TaskRemindAt $task)) {
      $clear = [System.Windows.Controls.MenuItem]::new()
      $clear.Header = (T '取消提醒')
      $clear.Tag = $taskId
      $clear.Add_Click({ param($s, $e) Set-TaskRemind ([string]$s.Tag) $null })
      [void]$menu.Items.Add($clear)
    }
    Open-FloatingMenu $menu $sender
  } catch { Write-ErrorLog ("reminder menu failed: " + $_.Exception.ToString()) }
}
$script:OnRemindQuickPick = {
  param($sender, $eventArgs)
  try {
    $info = $sender.Tag
    Set-TaskRemind ([string]$info.taskId) ([datetime]::Parse([string]$info.when, $script:Invariant))
  } catch { Write-ErrorLog ("set reminder failed: " + $_.Exception.ToString()) }
}
$script:OnRemindAction = {
  param($sender, $eventArgs)
  try {
    $info = $sender.Tag
    $taskId = [string]$info.taskId
    $action = [string]$info.action
    $task = Find-Task $taskId
    if ($action -eq 'done') {
      Set-TaskDone $taskId $true
    } elseif ($action -eq 'snooze' -and $task) {
      $task.snoozeAt = (Get-Date).AddMinutes(5).ToString('o')
      $task.reminded = $true
      Save-State
      Show-Toast '5 分钟后再提醒'
    } elseif ($action -eq 'resnooze' -and $task) {
      # 「已错过」条目重新提醒：默认 30 分钟后，循环任务同步改掉链上的时刻，后续周期跟着走
      $next = (Get-Date).AddMinutes(30)
      $task.remindAt = $next.ToString('o')
      $task.reminded = $false
      $task.snoozeAt = $null
      $task.expiredAt = $null
      if ([string]$task.kind -eq 'repeat' -and $task.seriesId) {
        $series = Find-Series ([string]$task.seriesId)
        if ($series) { $series.remindClock = $next.ToString('HH:mm') }
      }
      Save-State
      Show-Toast ('已重新提醒：' + (Format-RemindLabel $next))
      Rebuild-Tasks $false
      Update-MissedUi
    } elseif ($action -eq 'ignore' -and $task) {
      # 忽略 = 这条提醒作废（任务本身保留），不再出现在「已错过」里
      $task.remindAt = $null
      $task.reminded = $false
      $task.snoozeAt = $null
      $task.expiredAt = $null
      Save-State
      Show-Toast '已忽略这条提醒'
      Rebuild-Tasks $false
      Update-MissedUi
    }
    $script:RemindItems = @($script:RemindItems | Where-Object { [string]$_ -ne $taskId })
    Update-RemindOverlay
  } catch { Write-ErrorLog ("reminder action failed: " + $_.Exception.ToString()) }
}
$script:OnRemindSubmit = {
  try {
    $taskId = [string]$script:RemindEditTaskId
    if ([string]::IsNullOrWhiteSpace($taskId)) { Close-RemindEditor; return }
    $when = ConvertTo-RemindDate ([string]$script:Ui['RemindInput'].Text)
    if ($null -eq $when) {
      $script:Ui['RemindHint'].Text = '时间格式无法识别，试试 2026-10-31 09:00 或 10-31 09:00'
      return
    }
    Close-RemindEditor
    Set-TaskRemind $taskId $when
  } catch { Write-ErrorLog ("parse reminder time failed: " + $_.Exception.ToString()) }
}

# ---------- 拖动：自绘 ghost 跟手 ----------
# 原来用 WPF DragDrop.DoDragDrop，只有系统那个小光标，看不出拖的是哪一条，
# 也没法在松手前提示落点。这里改成手动拖动 + 半透明浮层跟随光标。
function Start-TaskDrag($pos) {
  $task = Find-Task ([string]$script:DragTaskId)
  if ($null -eq $task) { End-TaskDrag $false; return }
  $card = $script:DragSourceCard
  $layer = $script:Ui['DragLayer']
  if ($null -eq $layer -or $null -eq $card) { return }
  $ghostWidth = [double]$card.ActualWidth - 6
  if ($ghostWidth -lt 120) { $ghostWidth = 120 }

  $ghost = [System.Windows.Controls.Border]::new()
  $ghost.CornerRadius = [System.Windows.CornerRadius]::new(12)
  $ghost.Background = $script:Win.Resources['SettingsBgBrush']
  $ghost.BorderBrush = $script:Win.Resources['AccentDeepBrush']
  $ghost.BorderThickness = [System.Windows.Thickness]::new(1)
  $ghost.Padding = [System.Windows.Thickness]::new(10, 7, 10, 7)
  $ghost.Width = $ghostWidth
  $ghost.Opacity = 0
  $shadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
  $shadow.BlurRadius = 16; $shadow.ShadowDepth = 6; $shadow.Opacity = 0.5
  $shadow.Direction = 270; $shadow.Color = [System.Windows.Media.Color]::FromArgb(255, 0, 0, 0)
  $ghost.Effect = $shadow
  $ghostText = [System.Windows.Controls.TextBlock]::new()
  $ghostText.Text = [string]$task.text
  $ghostText.Tag = 'user'
  $ghostText.FontSize = 13
  $ghostText.Foreground = $script:Win.Resources['TextPrimaryBrush']
  $ghostText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $ghostText.MaxHeight = 40
  $ghost.Child = $ghostText
  $ghost.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
  $scaleT = [System.Windows.Media.ScaleTransform]::new(0.94, 0.94)
  $ghost.RenderTransform = $scaleT
  [void]$layer.Children.Add($ghost)

  # 光标在卡片内的相对位置，拖动时保持不变，手感才跟手
  try {
    $cardPos = $card.TranslatePoint([System.Windows.Point]::new(0, 0), $script:Win)
    $script:DragGrabDx = [double]$pos.X - [double]$cardPos.X
    $script:DragGrabDy = [double]$pos.Y - [double]$cardPos.Y
  } catch {
    $script:DragGrabDx = 20
    $script:DragGrabDy = 14
  }
  $script:DragGhost = $ghost
  $script:DragSourceOpacity = [double]$card.Opacity
  $card.Opacity = 0.3
  $script:DragActive = $true

  $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120))
  $ease = [System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  $fadeIn = [System.Windows.Media.Animation.DoubleAnimation]::new(0.0, 0.97, $duration)
  $fadeIn.EasingFunction = $ease
  $ghost.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
  $scaleUp = [System.Windows.Media.Animation.DoubleAnimation]::new(0.94, 1.0, $duration)
  $scaleUp.EasingFunction = $ease
  $scaleT.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleUp)
  $scaleT.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleUp)
}
function Move-TaskDragGhost($pos) {
  $ghost = $script:DragGhost
  if ($null -eq $ghost) { return }
  try {
    [System.Windows.Controls.Canvas]::SetLeft($ghost, [double]$pos.X - [double]$script:DragGrabDx)
    [System.Windows.Controls.Canvas]::SetTop($ghost, [double]$pos.Y - [double]$script:DragGrabDy)
  } catch { }
}
function Update-TaskDragTarget($pos) {
  $target = $null
  $hostPanel = $script:Ui['TasksHost']
  if ($null -ne $hostPanel) {
    foreach ($child in $hostPanel.Children) {
      if ($child -isnot [System.Windows.Controls.Border]) { continue }
      if ([object]::ReferenceEquals($child, $script:DragSourceCard)) { continue }
      if ([object]::ReferenceEquals($child, $script:DragTargetCard)) { continue }
      try {
        $origin = $child.TranslatePoint([System.Windows.Point]::new(0, 0), $script:Win)
        $height = [double]$child.ActualHeight
        if ($height -le 0) { continue }
        if ($pos.Y -ge ([double]$origin.Y - 2) -and $pos.Y -le ([double]$origin.Y + $height + 2)) { $target = $child; break }
      } catch { }
    }
  }
  if ([object]::ReferenceEquals($target, $script:DragTargetCard)) { return }
  if ($null -ne $script:DragTargetCard) {
    try { $script:DragTargetCard.ClearValue([System.Windows.Controls.Border]::BorderBrushProperty) } catch { }
  }
  $script:DragTargetCard = $target
  if ($null -ne $target) {
    try { $target.BorderBrush = $script:Win.Resources['AccentDeepBrush'] } catch { }
  }
}
function Test-CursorOutOfMainWindow {
  try {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $tl = $script:Win.PointToScreen([System.Windows.Point]::new(0, 0))
    $br = $script:Win.PointToScreen([System.Windows.Point]::new([double]$script:Win.ActualWidth, [double]$script:Win.ActualHeight))
    if ($cursor.X -lt ($tl.X - 6) -or $cursor.X -gt ($br.X + 6)) { return $true }
    if ($cursor.Y -lt ($tl.Y - 6) -or $cursor.Y -gt ($br.Y + 6)) { return $true }
    return $false
  } catch { return $false }
}
function End-TaskDrag([bool]$drop) {
  $id = [string]$script:DragTaskId
  $card = $script:DragSourceCard
  $ghost = $script:DragGhost
  $target = $script:DragTargetCard
  $active = [bool]$script:DragActive
  $restoreOpacity = $script:DragSourceOpacity
  $lastPos = $script:DragLastPos
  # 先清状态再做事，避免回调里重入
  $script:DragActive = $false
  $script:DragTaskId = $null
  $script:DragStartPoint = $null
  $script:DragLastPos = $null
  $script:DragGhost = $null
  $script:DragSourceCard = $null
  $script:DragTargetCard = $null
  try { [void][System.Windows.Input.Mouse]::Capture($null) } catch { }

  if ($null -ne $target) {
    try { $target.ClearValue([System.Windows.Controls.Border]::BorderBrushProperty) } catch { }
  }
  if ($active -and $null -ne $card) {
    $card.Opacity = if ($restoreOpacity -gt 0 -and $restoreOpacity -lt 1) { $restoreOpacity } else { 1.0 }
    $task = Find-Task $id
    if ($null -ne $task -and [bool]$task.done) { $card.Opacity = 0.78 }
  }
  if ($null -ne $ghost) {
    $ghost.IsHitTestVisible = $false
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(130))
    $ease = [System.Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fadeOut = [System.Windows.Media.Animation.DoubleAnimation]::new(0.97, 0.0, $duration)
    $fadeOut.EasingFunction = $ease
    $script:DragFadeGhost = $ghost
    $fadeOut.Add_Completed({
        $g = $script:DragFadeGhost
        if ($null -ne $g) {
          try { [void]$script:Ui['DragLayer'].Children.Remove($g) } catch { }
        }
        $script:DragFadeGhost = $null
      })
    $ghost.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
  }
  if (-not $drop -or -not $active) { return }
  if ([string]::IsNullOrWhiteSpace($id)) { return }
  $task = Find-Task $id
  if ($null -eq $task) { return }
  if (Test-CursorOutOfMainWindow) {
    if (Test-IsNote $task) {
      $null = New-NoteWindow $task
      Show-Toast '已把这条笔记拖成独立小窗（原条目仍在）'
    }
    return
  }
  if ($null -ne $target) {
    $insertAfter = $false
    if ($null -ne $lastPos) {
      try {
        $tPos = $target.TranslatePoint([System.Windows.Point]::new(0, 0), $script:Win)
        $mid = [double]$tPos.Y + [double]$target.ActualHeight / 2
        $insertAfter = ([double]$lastPos.Y -gt $mid)
      } catch { }
    }
    Move-TaskOrder $id ([string]$target.Tag) $insertAfter
  }
}

$script:OnDragHandleDown = {
  param($sender, $eventArgs)
  if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
  if ([bool]$script:Settings.locked) { return }
  $script:DragStartPoint = [System.Windows.Input.Mouse]::GetPosition($script:Win)
  $script:DragTaskId = [string]$sender.Tag
  $script:DragActive = $false
  $script:DragTargetCard = $null
  $script:DragSourceCard = $null
  try { $script:DragSourceCard = $sender.Parent.Parent } catch { }
  try { [void]$sender.CaptureMouse() } catch { }
  $eventArgs.Handled = $true
}
$script:OnDragHandleMove = {
  param($sender, $eventArgs)
  if ([string]::IsNullOrEmpty([string]$script:DragTaskId)) { return }
  if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
    End-TaskDrag $false
    return
  }
  if ($null -eq $script:DragStartPoint) { return }
  $pos = [System.Windows.Input.Mouse]::GetPosition($script:Win)
  $script:DragLastPos = $pos
  $dx = [double]$pos.X - [double]$script:DragStartPoint.X
  $dy = [double]$pos.Y - [double]$script:DragStartPoint.Y
  if (-not $script:DragActive) {
    if (([math]::Abs($dx) + [math]::Abs($dy)) -lt 6) { return }
    Start-TaskDrag $pos
  }
  Move-TaskDragGhost $pos
  Update-TaskDragTarget $pos
  $eventArgs.Handled = $true
}
$script:OnDragHandleUp = {
  param($sender, $eventArgs)
  if ([string]::IsNullOrEmpty([string]$script:DragTaskId)) { return }
  $eventArgs.Handled = $true
  End-TaskDrag $true
}

# ---------- 控件事件绑定 ----------
$ui['NoteInput'].Add_TextChanged({
  $hasText = -not [string]::IsNullOrEmpty($script:Ui['NoteInput'].Text)
  $script:Ui['Placeholder'].Visibility = if ($hasText) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
  # 边写边落盘：拔电源也只丢最后 200 毫秒
  Request-DraftSave
})
# 多行输入：Shift + Enter 换行，Enter 保存。AcceptsReturn 必须开，否则 TextBox 不接收换行；
# 用 PreviewKeyDown 在 TextBox 的类处理插入换行之前拦下普通 Enter。
$ui['NoteInput'].AcceptsReturn = $true
$ui['NoteInput'].TextWrapping = [System.Windows.TextWrapping]::Wrap
$ui['NoteInput'].Add_PreviewKeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
    # 直接查键盘状态，比 $eventArgs.KeyboardDevice.Modifiers 更可靠（后者在 Preview 阶段可能滞后）
    $shiftDown = (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0)
    if ($shiftDown) { return }
    $eventArgs.Handled = $true
    Add-TaskFromInput
  }
  elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { $script:Ui['NoteInput'].Text = ''; Reset-Draft }
})
$ui['AddButton'].Add_Click({ Add-TaskFromInput })
$ui['RepeatButton'].Add_Click({
  try {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.PlacementTarget = $script:Ui['RepeatButton']
    foreach ($entry in @(@{ kind = 'once'; label = '单次待办' }, @{ kind = 'day'; label = '每天循环' }, @{ kind = 'week'; label = '每周循环' }, @{ kind = 'month'; label = '每月循环' }, @{ kind = 'note'; label = '笔记（无勾选框）' })) {
      $item = [System.Windows.Controls.MenuItem]::new()
      if ([string]$script:Settings.composerKind -eq $entry.kind) { $item.Header = [string][char]0x2713 + ' ' + (T $entry.label) } else { $item.Header = (T $entry.label) }
      $item.Tag = $entry.kind
      $item.Add_Click({
        param($s, $e)
        $script:Settings.composerKind = [string]$s.Tag
        Update-ComposerTypeButton
        Save-State
        Request-DraftSave
      })
      [void]$menu.Items.Add($item)
      if ($entry.kind -eq 'month') {
        [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
      }
    }
    Open-FloatingMenu $menu $sender
  } catch { Write-ErrorLog ("type picker menu failed: " + $_.Exception.ToString()) }
})
$ui['TabTasks'].Add_Checked({
  if ($script:SyncingUi) { return }
  Switch-View 'tasks'
})
$ui['TabHistory'].Add_Checked({
  if ($script:SyncingUi) { return }
  Switch-View 'history'
})
$ui['TabTasks'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:SyncingUi = $true
  $script:Ui['TabTasks'].IsChecked = $true
  $script:SyncingUi = $false
})
$ui['TabHistory'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:SyncingUi = $true
  $script:Ui['TabHistory'].IsChecked = $true
  $script:SyncingUi = $false
})
$ui['TabTrash'].Add_Checked({
  if ($script:SyncingUi) { return }
  Switch-View 'trash'
})
$ui['TabTrash'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:SyncingUi = $true
  $script:Ui['TabTrash'].IsChecked = $true
  $script:SyncingUi = $false
})
$ui['SearchButton'].Add_Click({ if ($script:SearchOpen) { Close-Search } else { Open-Search } })
$ui['SearchInput'].Add_TextChanged({
  $script:SearchQuery = [string]$script:Ui['SearchInput'].Text
  $script:Ui['SearchPlaceholder'].Visibility = if ([string]::IsNullOrEmpty($script:SearchQuery)) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  if ($script:CurrentView -eq 'tasks') { Rebuild-Tasks $false }
  elseif ($script:CurrentView -eq 'history') { Rebuild-History $false }
})
$ui['SearchInput'].Add_KeyDown({ param($sender, $eventArgs) if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Close-Search } })
$ui['SearchClearButton'].Add_Click({ $script:Ui['SearchInput'].Text = ''; [void]$script:Ui['SearchInput'].Focus() })
$ui['TagFilterButton'].Add_Click({
  try {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.PlacementTarget = $script:Ui['TagFilterButton']
    $all = [System.Windows.Controls.MenuItem]::new()
    $all.Header = $(if ([string]::IsNullOrWhiteSpace([string]$script:TagFilter)) { [string][char]0x2713 + ' ' + (T '全部标签') } else { T '全部标签' })
    $all.Tag = ''
    $all.Add_Click({ param($s, $e) Set-TagFilter '' })
    [void]$menu.Items.Add($all)
    if ($script:Tags.Count -gt 0) { [void]$menu.Items.Add([System.Windows.Controls.Separator]::new()) }
    foreach ($tag in @($script:Tags | Sort-Object -Property @{ Expression = { [int]$_.order } })) {
      $mi = [System.Windows.Controls.MenuItem]::new()
      $isOn = ([string]$script:TagFilter -eq [string]$tag.id)
      $mi.Header = New-MenuTagHeader (Format-TagMenuLabel ([string]$tag.name) (Get-TagUsage ([string]$tag.id))) ([string]$tag.color) $isOn
      $mi.Tag = [string]$tag.id
      $mi.Add_Click({ param($s, $e) Set-TagFilter ([string]$s.Tag) })
      [void]$menu.Items.Add($mi)
    }
    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
    $manage = [System.Windows.Controls.MenuItem]::new()
    $manage.Header = (T '组织管理…')
    $manage.Add_Click({ Open-TagPanel })
    [void]$menu.Items.Add($manage)
    Open-FloatingMenu $menu $menu.PlacementTarget
  } catch { Write-ErrorLog ("tag filter menu failed: " + $_.Exception.ToString()) }
})
$ui['TagsButton'].Add_Click({ Open-TagPanel })
$ui['TagCloseButton'].Add_Click({ Close-TagPanel })
$ui['TagOverlay'].Add_MouseLeftButtonDown({
  param($sender, $eventArgs)
  if ($eventArgs.OriginalSource -eq $script:Ui['TagOverlay']) { Close-TagPanel }
})
$ui['TagInput'].Add_TextChanged({
  $hasText = -not [string]::IsNullOrEmpty($script:Ui['TagInput'].Text)
  $script:Ui['TagInputPlaceholder'].Visibility = if ($hasText) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
})
$ui['TagInput'].Add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
    $eventArgs.Handled = $true
    $tag = New-Tag ([string]$script:Ui['TagInput'].Text)
    if ($null -ne $tag) {
      $script:Ui['TagInput'].Text = ''
      $script:Ui['TagStatus'].Text = Format-TagCreatedText ([string]$tag.name)
      # 从条目的「新建标签」进来时，顺手把这条归到新标签下
      if (-not [string]::IsNullOrWhiteSpace([string]$script:TagPendingTaskId)) {
        Set-TaskTag ([string]$script:TagPendingTaskId) ([string]$tag.id) $true
        $script:TagPendingTaskId = $null
      }
      Refresh-TagList
      Rebuild-All
    }
  } elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Close-TagPanel }
})
$ui['TagAddButton'].Add_Click({
  $tag = New-Tag ([string]$script:Ui['TagInput'].Text)
  if ($null -ne $tag) {
    $script:Ui['TagInput'].Text = ''
    $script:Ui['TagStatus'].Text = Format-TagCreatedText ([string]$tag.name)
    if (-not [string]::IsNullOrWhiteSpace([string]$script:TagPendingTaskId)) {
      Set-TaskTag ([string]$script:TagPendingTaskId) ([string]$tag.id) $true
      $script:TagPendingTaskId = $null
    }
    Refresh-TagList
    Rebuild-All
  }
})
$ui['TagClearFilterButton'].Add_Click({ Set-TagFilter ''; Refresh-TagList; Show-Toast '已清除标签筛选' })
$ui['SettingsButton'].Add_Click({ Open-Settings })
$ui['LockToggle'].Add_Checked({ if ($script:SyncingUi) { return }; Set-Locked $true })
$ui['LockToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; Set-Locked $false })
$ui['FocusToggle'].Add_Checked({ if ($script:SyncingUi) { return }; Set-FocusMode $true })
$ui['FocusToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; Set-FocusMode $false })
$ui['FocusExitButton'].Add_Click({ Set-FocusMode $false })
$ui['PomodoroPanel'].Add_MouseLeftButtonUp({
  param($sender, $eventArgs)
  $script:Pomodoro.running = -not $script:Pomodoro.running
  if ($script:Pomodoro.running) {
    if ([int]$script:Pomodoro.remain -le 0) { $script:Pomodoro.remain = [int]$script:Pomodoro.total }
    $script:PomodoroTimer.Start()
  } else {
    $script:PomodoroTimer.Stop()
  }
  Update-PomodoroUi
})
$ui['PomodoroPanel'].Add_MouseRightButtonUp({
  param($sender, $eventArgs)
  try {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    foreach ($entry in @(@{ m = 25; label = '专注 25 分钟' }, @{ m = 5; label = '休息 5 分钟' })) {
      $item = [System.Windows.Controls.MenuItem]::new()
      $item.Header = (T $entry.label)
      $item.Tag = [int]$entry.m
      $item.Add_Click({ param($s, $e) Set-PomodoroMode ([int]$s.Tag) })
      [void]$menu.Items.Add($item)
    }
    [void]$menu.Items.Add(([System.Windows.Controls.Separator]::new()))
    $custom = [System.Windows.Controls.MenuItem]::new()
    $custom.Header = (T '自定义…')
    $custom.Add_Click({ param($s, $e) Open-PomodoroEditor })
    [void]$menu.Items.Add($custom)
    Open-FloatingMenu $menu $sender
  } catch { Write-ErrorLog ("pomodoro menu failed: " + $_.Exception.ToString()) }
})
$ui['Clock24Toggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  $script:Settings.clock24 = $true; Save-State; Update-Clock
})
$ui['Clock24Toggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:Settings.clock24 = $false; Save-State; Update-Clock
})
$ui['ClockSecondsToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  $script:Settings.clockSeconds = $true; Save-State; Update-Clock
})
$ui['ClockSecondsToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:Settings.clockSeconds = $false; Save-State; Update-Clock
})
$ui['ClockCalendarToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  $script:Settings.clockCalendar = $true; Save-State; Update-Clock
})
$ui['ClockCalendarToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $script:Settings.clockCalendar = $false; Save-State; Update-Clock
})
$ui['RemindSoundToggle'].Add_Checked({ if ($script:SyncingUi) { return }; $script:Settings.remindSound = $true; Save-State })
$ui['RemindSoundToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; $script:Settings.remindSound = $false; Save-State })
$ui['DoneSoundToggle'].Add_Checked({ if ($script:SyncingUi) { return }; $script:Settings.doneSound = $true; Save-State })
$ui['DoneSoundToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; $script:Settings.doneSound = $false; Save-State })
$ui['PomodoroToggle'].Add_Checked({ if ($script:SyncingUi) { return }; $script:Settings.pomodoro = $true; Save-State; if ([bool]$script:Settings.focusMode) { Set-FocusMode $true } })
$ui['PomodoroToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; $script:Settings.pomodoro = $false; Save-State; if ([bool]$script:Settings.focusMode) { Set-FocusMode $true } })
foreach ($pair in @(@{ name = 'RemindLead0'; value = 0 }, @{ name = 'RemindLead5'; value = 5 },
    @{ name = 'RemindLead15'; value = 15 }, @{ name = 'RemindLead30'; value = 30 })) {
  $btn = $ui[$pair.name]
  if ($null -eq $btn) { continue }
  $btn.Tag = [int]$pair.value
  $btn.Add_Click({
    param($sender, $eventArgs)
    try {
      $script:Settings.remindLead = [int]$sender.Tag
      Update-RemindLeadUi
      Save-State
      $desc = switch ([int]$sender.Tag) { 5 { '提前 5 分钟' } 15 { '提前 15 分钟' } 30 { '提前 30 分钟' } default { '准时提醒' } }
      Show-Toast ('已设为' + $desc)
    } catch { }
  })
}
foreach ($pair in @(@{ name = 'RemindExpire24'; value = 24 }, @{ name = 'RemindExpire72'; value = 72 },
    @{ name = 'RemindExpire168'; value = 168 }, @{ name = 'RemindExpire0'; value = 0 })) {
  $btn = $ui[$pair.name]
  if ($null -eq $btn) { continue }
  $btn.Tag = [int]$pair.value
  $btn.Add_Click({
    param($sender, $eventArgs)
    try { Set-RemindExpire ([int]$sender.Tag) } catch { }
  })
}
$ui['MissedViewButton'].Add_Click({ Show-MissedReminders })
# 提示条带动作时可点：这里是「有 N 条提醒已错过，点这里查看」的唯一入口之一（另一个在设置面板）
$ui['Toast'].Add_MouseLeftButtonUp({
  if ($null -eq $script:ToastAction) { return }
  $act = $script:ToastAction
  Hide-Toast
  try { & $act } catch { Write-ErrorLog ("toast action failed: " + $_.Exception.ToString()) }
})
$ui['RemindOkButton'].Add_Click({ & $script:OnRemindSubmit })
$ui['RemindCancelButton'].Add_Click({ Close-RemindEditor })
$ui['RemindInput'].Add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) { $eventArgs.Handled = $true; & $script:OnRemindSubmit }
  elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Close-RemindEditor }
})
$ui['RemindEditor'].Add_MouseLeftButtonDown({
  param($sender, $eventArgs)
  if ($eventArgs.OriginalSource -eq $script:Ui['RemindEditor']) { Close-RemindEditor }
})
$script:OnPomodoroSubmit = {
  try {
    $raw = ([string]$ui['PomodoroInput'].Text).Trim()
    $mins = 0
    if ([int]::TryParse($raw, [ref]$mins) -and $mins -ge 1 -and $mins -le 480) {
      Set-PomodoroMode $mins
      Close-PomodoroEditor
      Show-Toast ("已设为自定义 " + $mins + " 分钟")
    } else {
      Show-Toast '请输入 1 到 480 之间的分钟数'
    }
  } catch { }
}
$ui['PomodoroOkButton'].Add_Click({ & $script:OnPomodoroSubmit })
$ui['PomodoroCancelButton'].Add_Click({ Close-PomodoroEditor })
$ui['PomodoroInput'].Add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) { $eventArgs.Handled = $true; & $script:OnPomodoroSubmit }
  elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Close-PomodoroEditor }
})
$ui['PomodoroEditor'].Add_MouseLeftButtonDown({
  param($sender, $eventArgs)
  if ($eventArgs.OriginalSource -eq $script:Ui['PomodoroEditor']) { Close-PomodoroEditor }
})
$ui['RemindCloseButton'].Add_Click({
  $script:RemindItems = @()
  $script:ShowMissed = $false
  Update-RemindOverlay
})
$ui['SettingsCloseButton'].Add_Click({ Close-Settings })
$ui['SettingsOverlay'].Add_MouseLeftButtonDown({
  param($sender, $eventArgs)
  if ($eventArgs.OriginalSource -eq $script:Ui['SettingsOverlay']) { Close-Settings }
})
$ui['PinToggle'].Add_Checked({ Set-TopmostMode $true; Save-State })
$ui['PinToggle'].Add_Unchecked({ Set-TopmostMode $false; Save-State })
$ui['GlassToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  Set-GlassMode $true $true
  $script:SyncingUi = $true; $script:Ui['SettingsGlassToggle'].IsChecked = $true; $script:SyncingUi = $false
  Save-State
})
$ui['GlassToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  Set-GlassMode $false $true
  $script:SyncingUi = $true; $script:Ui['SettingsGlassToggle'].IsChecked = $false; $script:SyncingUi = $false
  Save-State
})
$ui['SettingsGlassToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  Set-GlassMode $true $true
  $script:SyncingUi = $true; $script:Ui['GlassToggle'].IsChecked = $true; $script:SyncingUi = $false
  $script:Ui['OpacitySlider'].IsEnabled = $true; Save-State
})
$ui['SettingsGlassToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  Set-GlassMode $false $true
  $script:SyncingUi = $true; $script:Ui['GlassToggle'].IsChecked = $false; $script:SyncingUi = $false
  $script:Ui['OpacitySlider'].IsEnabled = $false; Save-State
})
$ui['OpacitySlider'].Add_ValueChanged({ if ($script:SyncingUi) { return }; Apply-GlassOpacity ([double]$script:Ui['OpacitySlider'].Value) })
$ui['PresetClear'].Add_Click({ $script:Ui['OpacitySlider'].Value = 55 })
$ui['PresetStandard'].Add_Click({ $script:Ui['OpacitySlider'].Value = 86 })
$ui['PresetDeep'].Add_Click({ $script:Ui['OpacitySlider'].Value = 92 })
$ui['TrayToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  Set-TrayEnabled $true
  $script:Ui['CloseToTrayToggle'].IsEnabled = $true
  Show-Toast '托盘图标已开启'
})
$ui['TrayToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  Set-TrayEnabled $false
  $script:Ui['CloseToTrayToggle'].IsEnabled = $false
  Show-Toast '托盘图标已关闭'
})
$ui['CloseToTrayToggle'].Add_Checked({ if ($script:SyncingUi) { return }; $script:Settings.closeToTray = $true; Save-State })
$ui['CloseToTrayToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; $script:Settings.closeToTray = $false; Save-State })
$ui['HotkeyToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  $ok = Set-HotkeyEnabled $true
  if (-not $ok) {
    $script:SyncingUi = $true; $script:Ui['HotkeyToggle'].IsChecked = $false; $script:SyncingUi = $false
    Show-Toast '快捷键注册失败（可能被其他程序占用）'
  } else { Show-Toast '已开启全局快捷键 Ctrl + Alt + N' }
  Save-State
})
$ui['HotkeyToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; [void](Set-HotkeyEnabled $false); Save-State })
$ui['AutostartToggle'].Add_Checked({
  if ($script:SyncingUi) { return }
  $ok = Set-Autostart $true
  if (-not $ok) { $script:SyncingUi = $true; $script:Ui['AutostartToggle'].IsChecked = $false; $script:SyncingUi = $false; Show-Toast '设置开机自启失败，请检查权限' }
  else { Show-Toast '已设置开机自启' }
})
$ui['AutostartToggle'].Add_Unchecked({
  if ($script:SyncingUi) { return }
  $ok = Set-Autostart $false
  if (-not $ok) { $script:SyncingUi = $true; $script:Ui['AutostartToggle'].IsChecked = $true; $script:SyncingUi = $false; Show-Toast '取消开机自启失败，请检查权限' }
})
$ui['ExportMdButton'].Add_Click({ Export-HistoryMarkdown })
$ui['ExportCsvButton'].Add_Click({ Export-RecordsCsv })
$ui['ClearHistoryButton'].Add_Click({
  $answer = [System.Windows.MessageBox]::Show((T '确定清空全部历史记录吗？此操作不可撤销（建议先导出或备份）。'), (T '清空历史'), 'YesNo', 'Warning')
  if ($answer -eq 'Yes') {
    $script:History.Clear(); Save-State; Rebuild-All
    $script:Ui['SettingsStatus'].Text = (T '历史记录已清空'); Show-Toast '历史记录已清空'
  }
})
$ui['BackupButton'].Add_Click({ [void](New-Backup) })
$ui['RestoreLatestButton'].Add_Click({ Restore-LatestBackup })
$ui['RestoreFileButton'].Add_Click({
  try {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = (T '选择备份文件'); $dialog.Filter = (T 'JSON 备份') + ' (*.json)|*.json|' + (T '所有文件') + ' (*.*)|*.*'
    $dialog.InitialDirectory = (Get-ExportDir)
    if ($dialog.ShowDialog() -eq $true) {
      $answer = [System.Windows.MessageBox]::Show((T '将用该备份覆盖当前数据，继续？'), (T '恢复备份'), 'YesNo', 'Question')
      if ($answer -eq 'Yes') { [void](Import-StateFile $dialog.FileName) }
    }
  } catch { Show-Toast '打开备份文件失败' }
})
$ui['OpenDataFolderButton'].Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:DataDir + '"') } catch { Show-Toast '无法打开数据文件夹' } })
$ui['MinButton'].Add_Click({ if ($script:Settings.tray -and $script:Settings.closeToTray) { Hide-AppWindow } else { $script:Win.WindowState = [System.Windows.WindowState]::Minimized } })
$ui['CloseButton'].Add_Click({ if ($script:Settings.tray -and $script:Settings.closeToTray) { Hide-AppWindow } else { $script:Win.Close() } })
# ---------- 窗口拖动 ----------
# 统一在窗口层用「隧道」事件接管拖动。原来的气泡事件有两个坑：
#   1) 头部里的子控件一旦把 MouseLeftButtonDown 标成 Handled，事件就到不了 HeaderGrid；
#   2) 任何控件残留鼠标捕获（拖条目排序、拖缩放手柄中途松手）都会让后续按下收不到。
# 两种情况表现都是「窗口拖不动，点一下锁定再解锁才恢复」。隧道事件先于子控件触发，
# 且拖动前主动清空捕获，能一次解决这两类问题。
$script:DragInProgress = $false
$script:DragZoneNames = @('HeaderGrid', 'FocusDragBar')
$script:DragZoneContainers = @('RootGrid', 'GlassCard', 'SolidBg', 'GlassBg', 'MainGrid', 'NoiseLayer', 'SheenLayer')
# 向上查找「交互控件」时的停止边界：碰到这些容器就说明命中的是空白背景，可以拖动
$script:DragStopNames = @('HeaderGrid', 'FocusDragBar', 'MainGrid', 'RootGrid', 'GlassCard')
function Test-AncestorIs([object]$node, [string[]]$names, [int]$maxDepth = 14) {
  $depth = 0
  while ($null -ne $node -and $depth -lt $maxDepth) {
    foreach ($name in $names) {
      if ($script:Ui[$name] -and [object]::ReferenceEquals($node, $script:Ui[$name])) { return $true }
    }
    $parent = $null
    try {
      if ($node -is [System.Windows.Media.Visual]) { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
      elseif ($node -is [System.Windows.Media.Media3D.Visual3D]) { $parent = [System.Windows.Media.Media3D.VisualTreeHelper]::GetParent($node) }
    } catch { $parent = $null }
    if ($null -eq $parent -and $node -is [System.Windows.FrameworkElement]) { $parent = $node.Parent }
    $node = $parent
    $depth++
  }
  return $false
}
function Test-InteractiveElement([object]$node, [int]$maxDepth = 10) {
  $depth = 0
  while ($null -ne $node -and $depth -lt $maxDepth) {
    # 走到头部 / 卡片容器这一层就停：再往上就是窗口本身，窗口也是 Control，不能算「交互控件」
    if (Test-AncestorIs $node $script:DragStopNames 1) { return $false }
    if ($node -is [System.Windows.Controls.Primitives.ButtonBase] -or
      $node -is [System.Windows.Controls.Primitives.TextBoxBase] -or
      $node -is [System.Windows.Controls.Primitives.Thumb] -or
      $node -is [System.Windows.Controls.Primitives.ScrollBar] -or
      $node -is [System.Windows.Controls.Primitives.Selector] -or
      $node -is [System.Windows.Controls.Slider] -or
      $node -is [System.Windows.Controls.ComboBox]) { return $true }
    $parent = $null
    try {
      if ($node -is [System.Windows.Media.Visual]) { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
    } catch { $parent = $null }
    if ($null -eq $parent -and $node -is [System.Windows.FrameworkElement]) { $parent = $node.Parent }
    $node = $parent
    $depth++
  }
  return $false
}
function Test-InDragZone([object]$source, [double]$y) {
  if ($null -eq $source) { return $false }
  if (Test-AncestorIs $source $script:DragZoneNames) { return $true }
  # 卡片顶部那条空白（时钟上方）也算拖动区，抓起来更顺手
  if ($y -le 96 -and (Test-AncestorIs $source $script:DragZoneContainers)) { return $true }
  return $false
}
function Clear-MouseCapture {
  try { [void][System.Windows.Input.Mouse]::Capture($null) } catch { }
}
function Start-WindowDrag([string]$origin) {
  if ($script:DragInProgress) { return $false }
  if ([bool]$script:Settings.locked) { return $false }
  if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return $false }
  $script:DragInProgress = $true
  try {
    Clear-MouseCapture
    $script:Win.DragMove()
  } catch {
    Write-ToastLog ("window drag failed [$origin]：" + $_.Exception.Message)
  } finally {
    $script:DragInProgress = $false
    Clear-MouseCapture
    Update-Bounds
    Request-Save
    [void](Snap-WindowToEdge)
  }
  return $true
}
$script:Win.Add_PreviewMouseLeftButtonDown({
  param($sender, $eventArgs)
  try {
    if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    if ([bool]$script:Settings.locked) { return }
    # 覆盖设置 / 搜索 / 提醒等浮层显示时不抢拖动
    foreach ($name in @('SettingsOverlay', 'SearchOverlay', 'RemindEditor', 'TagOverlay')) {
      if ($ui[$name] -and $ui[$name].Visibility -eq [System.Windows.Visibility]::Visible) { return }
    }
    $source = $eventArgs.OriginalSource
    $pos = $eventArgs.GetPosition($script:Win)
    # 番茄钟是可点击的交互区（左键开始/暂停、右键换时长），不能走窗口拖动，否则非锁定状态会吃掉点击
    if (Test-AncestorIs $source @('PomodoroPanel')) { return }
    if (-not (Test-InDragZone $source $pos.Y)) { return }
    if (Test-InteractiveElement $source) { return }
    if (Start-WindowDrag 'header') { $eventArgs.Handled = $true }
  } catch {
    # 拖动逻辑绝不能把鼠标事件通道打断
    Write-ToastLog ("drag handler exception: " + $_.Exception.Message)
  }
})
# 右下角手柄：完整模式与专注模式通用。专注模式最小 200×160，完整模式不小于设置面板所需 440×540
function Get-ClampedWindowSize([double]$w, [double]$h) {
  $focus = [bool]$script:Settings.focusMode
  $minW = if ($focus) { [double]$script:FocusMinWidth } else { [double]$script:FullMinWidth }
  $minH = if ($focus) { [double]$script:FocusMinHeight } else { [double]$script:FullMinHeight }
  $area = Get-WindowWorkArea
  $maxW = [math]::Max($minW, $area.right - $area.left - 8)
  $maxH = [math]::Max($minH, $area.bottom - $area.top - 8)
  return @{
    w = [math]::Min([math]::Max($minW, $w), $maxW)
    h = [math]::Min([math]::Max($minH, $h), $maxH)
  }
}
$ui['ResizeGrip'].Add_MouseLeftButtonDown({
  param($sender, $eventArgs)
  if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
  if ([bool]$script:Settings.locked) { return }
  $script:FocusResizing = $true
  $script:FocusResizeStart = @{
    x = [double][System.Windows.Forms.Cursor]::Position.X
    y = [double][System.Windows.Forms.Cursor]::Position.Y
    w = [double]$script:Win.ActualWidth
    h = [double]$script:Win.ActualHeight
  }
  try { [void]$sender.CaptureMouse() } catch { }
  $eventArgs.Handled = $true
})
$ui['ResizeGrip'].Add_MouseMove({
  param($sender, $eventArgs)
  if (-not $script:FocusResizing -or $null -eq $script:FocusResizeStart) { return }
  $scale = Get-DpiScale
  if ($scale -le 0) { $scale = 1.0 }
  $dx = ([double][System.Windows.Forms.Cursor]::Position.X - $script:FocusResizeStart.x) / $scale
  $dy = ([double][System.Windows.Forms.Cursor]::Position.Y - $script:FocusResizeStart.y) / $scale
  $size = Get-ClampedWindowSize ([double]$script:FocusResizeStart.w + $dx) ([double]$script:FocusResizeStart.h + $dy)
  try { $script:Win.Width = $size.w; $script:Win.Height = $size.h } catch { }
  $eventArgs.Handled = $true
})
$ui['ResizeGrip'].Add_MouseLeftButtonUp({
  param($sender, $eventArgs)
  if (-not $script:FocusResizing) { return }
  $script:FocusResizing = $false
  $script:FocusResizeStart = $null
  try { [void]$sender.ReleaseMouseCapture() } catch { }
  Update-Bounds
  [void](Snap-WindowToEdge)
})
$ui['ResizeGrip'].Add_LostMouseCapture({
  param($sender, $eventArgs)
  if ($script:FocusResizing) {
    $script:FocusResizing = $false
    $script:FocusResizeStart = $null
    Update-Bounds
  }
})
# 专注小窗顶部：置顶 / 锁定
$ui['FocusPinToggle'].Add_Checked({ if ($script:SyncingUi) { return }; Set-TopmostMode $true; Save-State })
$ui['FocusPinToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; Set-TopmostMode $false; Save-State })
$ui['FocusLockToggle'].Add_Checked({ if ($script:SyncingUi) { return }; Set-Locked $true })
$ui['FocusLockToggle'].Add_Unchecked({ if ($script:SyncingUi) { return }; Set-Locked $false })
$script:Win.Add_PreviewKeyDown({
  param($sender, $eventArgs)
  $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
  if ($ctrl -and $eventArgs.Key -eq [System.Windows.Input.Key]::N) { [void]$script:Ui['NoteInput'].Focus(); $eventArgs.Handled = $true }
  elseif ($ctrl -and $eventArgs.Key -eq [System.Windows.Input.Key]::F) { Open-Search; $eventArgs.Handled = $true }
  elseif ($ctrl -and $eventArgs.Key -eq [System.Windows.Input.Key]::H) { Switch-View 'history'; $eventArgs.Handled = $true }
  elseif ($ctrl -and $eventArgs.Key -eq [System.Windows.Input.Key]::D) { Switch-View 'tasks'; $eventArgs.Handled = $true }
  elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
    if ($script:Ui['RemindEditor'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-RemindEditor; $eventArgs.Handled = $true }
    elseif ($script:Ui['TagOverlay'] -and $script:Ui['TagOverlay'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-TagPanel; $eventArgs.Handled = $true }
    elseif ($script:Ui['SettingsOverlay'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings; $eventArgs.Handled = $true }
    elseif ($script:SearchOpen) { Close-Search; $eventArgs.Handled = $true }
    elseif ([bool]$script:Settings.focusMode) { Set-FocusMode $false; $eventArgs.Handled = $true }
  }
})
function Update-Bounds {
  if ($script:Win.WindowState -ne [System.Windows.WindowState]::Normal) { return }
  $script:Bounds.left = $script:Win.Left
  $script:Bounds.top = $script:Win.Top
  $w = [double]$script:Win.ActualWidth
  $h = [double]$script:Win.ActualHeight
  if ([bool]$script:Settings.focusMode) {
    # 小窗尺寸单独记忆，下次进专注模式沿用
    if ($w -ge 160) { $script:Settings.focusWidth = [math]::Round($w) }
    if ($h -ge 140) { $script:Settings.focusHeight = [math]::Round($h) }
  } else {
    $script:Bounds.width = $w
    $script:Bounds.height = $h
  }
}
$script:Win.Add_LocationChanged({ Update-Bounds; Request-Save })
$script:Win.Add_SizeChanged({ Update-Bounds; Request-Save; Update-GlowClip; Update-RemindLayout })
$script:Win.Add_Closing({
  param($sender, $eventArgs)
  try {
    # 先刷草稿再刷数据，保证正在写的那句话一定落盘
    Save-Draft
    Save-State
    $script:SaveTimer.Stop(); $script:ClockTimer.Stop(); $script:RollTimer.Stop()
    if ($script:HotkeyRegistered -and $script:Hwnd -ne [IntPtr]::Zero) { [void][GN.Native]::UnregisterHotKey($script:Hwnd, 1) }
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
  } catch { }
  try { if ($script:Hook -and $script:Source) { $script:Source.RemoveHook($script:Hook) } } catch { }
})
# 注销 / 关机 / 重启：Windows 只会给很短的时间，Application.SessionEnding 里同步刷盘，
# 别指望 220ms 防抖定时器还有机会跑（Window 本身没有这个事件，挂在 Application 上）

# ---------- 无边框缩放 + 全局快捷键 ----------
$script:Win.Add_SourceInitialized({
  try {
    $script:Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:Win).Handle
    $script:Source = [System.Windows.Interop.HwndSource]::FromHwnd($script:Hwnd)
    $script:SourceInitialized = $true
    if ([bool]$script:Settings.hotkey) {
      $ok = Set-HotkeyEnabled $true
      if (-not $ok) {
        Write-ToastLog 'global hotkey register failed'
        $script:SyncingUi = $true
        $ui['HotkeyToggle'].IsChecked = $false
        $script:SyncingUi = $false
        Save-State
      }
    }
    $script:Hook = $script:Source.AddHook({
        param([System.IntPtr]$hWnd, [int]$msg, [System.IntPtr]$wParam, [System.IntPtr]$lParam, [ref]$handled)
        if ($msg -eq 0x0312) {
          if ([int]$wParam -eq 1) { Toggle-WindowVisibility }
          $handled.Value = $true
          return [System.IntPtr]::Zero
        }
        if ($msg -ne 0x0084) { return [System.IntPtr]::Zero }
        if ([bool]$script:Settings.locked) { return [System.IntPtr]::Zero }
        $lp = $lParam.ToInt64()
        $px = [int]($lp -band 0xFFFF); if ($px -ge 0x8000) { $px -= 0x10000 }
        $py = [int](($lp -shr 16) -band 0xFFFF); if ($py -ge 0x8000) { $py -= 0x10000 }
        try { $pt = $script:Win.PointFromScreen([System.Windows.Point]::new($px, $py)) } catch { return [System.IntPtr]::Zero }
        $margin = 26.0; $edge = 7.0
        # 右下角缩放手柄区域交还给 WPF，否则会被下面的边缘命中测试抢走，手柄拖不动
        $grip = $ui['ResizeGrip']
        if ($grip -and $grip.Visibility -eq [System.Windows.Visibility]::Visible) {
          $gw = [double]$grip.ActualWidth; $gh = [double]$grip.ActualHeight
          if ($gw -gt 0 -and $gh -gt 0 -and $pt.X -ge ($script:Win.ActualWidth - $margin - $gw) -and
            $pt.Y -ge ($script:Win.ActualHeight - $margin - $gh)) {
            return [System.IntPtr]::Zero
          }
        }
        $right = $script:Win.ActualWidth - $margin; $bottom = $script:Win.ActualHeight - $margin
        $left = $margin; $top = $margin
        $insideX = ($pt.X -ge ($left - $edge)) -and ($pt.X -le ($right + $edge))
        $insideY = ($pt.Y -ge ($top - $edge)) -and ($pt.Y -le ($bottom + $edge))
        if (-not $insideX -or -not $insideY) { $handled.Value = $true; return [System.IntPtr](-1) }
        $nearLeft = $pt.X -le ($left + $edge); $nearRight = $pt.X -ge ($right - $edge)
        $nearTop = $pt.Y -le ($top + $edge); $nearBottom = $pt.Y -ge ($bottom - $edge)
        $code = 0
        if (-not $nearTop -and -not $nearBottom) {
          if ($nearLeft) { $code = 0x0A } elseif ($nearRight) { $code = 0x0B }
        }
        if (-not $nearLeft -and -not $nearRight) {
          if ($nearTop) { $code = 0x0C } elseif ($nearBottom) { $code = 0x0F }
        } else {
          if ($nearTop -and $nearLeft) { $code = 0x0D } elseif ($nearTop -and $nearRight) { $code = 0x0E }
          elseif ($nearBottom -and $nearLeft) { $code = 0x10 } elseif ($nearBottom -and $nearRight) { $code = 0x11 }
        }
        if ($code -ne 0) { $handled.Value = $true; return [System.IntPtr]$code }
        return [System.IntPtr]::Zero
      })
  } catch { Write-ErrorLog "window init failed: $($_.Exception.ToString())" }
})

# ---------- 定时器 ----------
$script:ClockTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:ClockTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:ClockTimer.Add_Tick({ Update-Clock })
$script:RollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:RollTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:RemindTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:RemindTimer.Interval = [TimeSpan]::FromSeconds(10)
$script:RemindTimer.Add_Tick({ try { Invoke-ReminderCheck } catch { Write-ErrorLog ("reminder check failed: " + $_.Exception.ToString()) } })
$script:RollTimer.Add_Tick({
  $todayKey = Get-DateKey (Get-Date).Date
  if ([string]$script:Settings.lastRollDate -ne $todayKey) {
    $summary = Invoke-DayRollover $false
    Rebuild-All
    if ($summary.archived -gt 0 -or $summary.spawned -gt 0) { Update-Clock }
  }
})

# ---------- 初始化 ----------
Build-ThemeCards
Set-Theme ([string]$script:Settings.theme) $false
$script:Settings.autostart = Test-Autostart
if (-not $script:Settings.autostart -and -not $loaded -and -not $SmokeTest) {
  # 首次运行：默认写入开机自启
  [void](Set-Autostart $true)
  $script:Settings.autostart = Test-Autostart
}
$script:SyncingUi = $true
$ui['PinToggle'].IsChecked = [bool]$script:Settings.topmost
$ui['GlassToggle'].IsChecked = [bool]$script:Settings.glass
$script:SyncingUi = $false
Set-TopmostMode ([bool]$script:Settings.topmost)
Set-GlassMode ([bool]$script:Settings.glass) $false
$ui['OpacitySlider'].Value = [double]$script:Settings.glassOpacity * 100
$ui['OpacityValueText'].Text = ('{0}%' -f [int]([double]$script:Settings.glassOpacity * 100))
Update-ComposerTypeButton
Update-Clock
Invoke-DayRollover $true | Out-Null
Switch-View $(if ($script:Settings.view -in @('tasks', 'history', 'trash')) { [string]$script:Settings.view } else { 'tasks' })
Sync-SettingsUi
Refresh-TagList
Update-SearchBar
Update-RemindLayout
[void](Restore-Draft)
Initialize-Tray
# 启动时无条件按「未锁定」初始化：锁定状态不跟随上次关闭（其余状态照常恢复），
# 同时顺手清掉可能残留的鼠标捕获，避免出现「界面看着没锁，实际拖不动」的状态错位。
Clear-MouseCapture
Set-Locked $false $false
if ([bool]$script:Settings.focusMode) { Set-FocusMode $true }
Save-State
$script:Win.Add_Loaded({
  try { Build-LangButtons } catch { }
  Update-LangUi
  # 立刻查一次提醒：关机期间到点的不用再等定时器首跳的 10 秒（自检里由断言直接调用，跳过）
  if (-not $SmokeTest) {
    try { Invoke-ReminderCheck } catch { Write-ErrorLog ("startup reminder check failed: " + $_.Exception.ToString()) }
  }
  try { $script:RemindTimer.Start() } catch { }
  if ($script:RecoveredFromBackup) {
    Show-Toast '数据文件损坏，已用备份 notes.bak.json 恢复'
  }
  if ($script:RolloverSummary.archived -gt 0 -or $script:RolloverSummary.spawned -gt 0) {
    $parts = @()
    if ($script:RolloverSummary.archived -gt 0) { $parts += "已归档 $($script:RolloverSummary.archived) 项完成记录" }
    if ($script:RolloverSummary.spawned -gt 0) { $parts += "新增 $($script:RolloverSummary.spawned) 项循环任务" }
    Show-Toast ('新的一天：' + ($parts -join '，'))
  }
})

if ($SmokeTest) {
  $report = @()
  $fails = 0
  function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { Write-Output ("  OK   " + $name) }
    else { Write-Output ("  FAIL " + $name); $script:SmokeFails++ }
  }
  $script:SmokeFails = 0
  try {
    Write-Output '--- 冒烟测试 ---'
    # 版本号：更新补丁（更新_vX.vbs）靠这一行识别本机版本，格式坏掉补丁就失效
    Assert-True '版本号已定义' (-not [string]::IsNullOrWhiteSpace([string]$script:AppVersion))
    Assert-True '版本号格式为 x.y 或 x.y.z' ([bool]([string]$script:AppVersion -match '^\d+\.\d+(\.\d+)?$'))
    Assert-True '设置面板显示当前版本号' ([string]$ui['VersionText'].Text -eq ('核桃便签 v' + [string]$script:AppVersion))

    # 0. 列表元信息文案：笔记不显示时间；未完成任务只说「N 天前创建」，不再写「已顺延 N 天」
    $noteMeta = @{ mode = 'note'; kind = 'once'; created = (Get-Date).AddDays(-3).ToString('o'); done = $false }
    $openMeta = @{ mode = 'todo'; kind = 'once'; created = (Get-Date).AddDays(-3).ToString('o'); done = $false }
    $doneMeta = @{ mode = 'todo'; kind = 'once'; created = (Get-Date).AddDays(-3).ToString('o'); done = $true
      doneAt = (Get-Date).Date.AddHours(12).ToString('o') }
    Assert-True '笔记不显示任何顺延/逾期信息' ((Get-TaskInfo $noteMeta) -eq '')
    Assert-True '未完成任务显示「3 天前创建」' ((Get-TaskInfo $openMeta) -eq '3 天前创建')
    Assert-True '未完成任务不再出现「顺延 / 延迟」字样' ((Get-TaskInfo $openMeta) -notmatch '顺延|延迟')
    Assert-True '已完成任务仍显示「完成于 HH:mm」' ((Get-TaskInfo $doneMeta) -eq '完成于 12:00')

    # 0. 开关可见性：浅色主题的轨道必须叠黑（白底 + 白钮看不见），深色主题保持叠白
    foreach ($tid in @('noteyellow', 'notewhite', 'notepink')) {
      $tc = Get-Color (Get-ThemeBrushHex $script:Themes[$tid] 'switchTrackOff')
      Assert-True ("浅色主题 $tid 的开关轨道不是白色系（R/G/B 均 < 220）") (([int]$tc.R -lt 220) -and ([int]$tc.G -lt 220) -and ([int]$tc.B -lt 220))
      Assert-True ("浅色主题 $tid 的开关轨道不透光度 >= 0x30") ([int]$tc.A -ge 0x30)
    }
    foreach ($tid in @('lime', 'sakura', 'midnight')) {
      $tc = Get-Color (Get-ThemeBrushHex $script:Themes[$tid] 'switchTrackOff')
      Assert-True ("深色主题 $tid 的开关轨道仍为叠白") (([int]$tc.R -gt 200) -and ([int]$tc.A -lt 0x80))
    }

    # 0. 旧存档迁移：没有 layoutVersion 时窗口重置为新默认 800×600
    $legacyState = [pscustomobject]@{
      settings = [pscustomobject]@{ theme = 'lime'; glass = $true }
      window = [pscustomobject]@{ left = 10; top = 10; width = 400; height = 640 }
      tasks = @(); history = @(); series = @()
    }
    Normalize-LoadedState $legacyState
    Assert-True '旧存档升级后窗口为 800×600' ([double]$script:Bounds.width -eq 800 -and [double]$script:Bounds.height -eq 600)
    Assert-True '迁移后标记 layoutVersion=2' ([int]$script:Settings.layoutVersion -eq 2)

    # 1. 建任务 + 渲染
    [void]$script:Tasks.Add((New-TaskObject '冒烟测试任务'))
    Rebuild-All
    Assert-True '新增任务后列表有内容' ($script:Tasks.Count -ge 1)
    Assert-True '任务行已渲染' ($ui['TasksHost'].Children.Count -ge 1)

    # 2. 完成 → 历史 → 跨天归档（把完成时间改到昨天）
    $t = @($script:Tasks)[0]
    $id = [string]$t.id
    Set-TaskDone $id $true
    $after = @($script:Tasks | Where-Object { [string]$_.id -eq $id })
    Assert-True '完成后 tasks 标记 done' ($after.Count -eq 1 -and [bool]$after[0].done)
    if ($after.Count -eq 1) { $after[0].doneAt = (Get-Date).Date.AddDays(-1).AddHours(10).ToString('o') }
    Invoke-DayRollover $true | Out-Null
    Assert-True '已归档到历史' (@($script:History | Where-Object { $_.id -eq $id }).Count -eq 1)
    Assert-True '待办中已移除' (@($script:Tasks | Where-Object { $_.id -eq $id }).Count -eq 0)

    # 3. 提醒：设置一个已过期的提醒并检查触发
    [void]$script:Tasks.Add((New-TaskObject '带提醒的任务'))
    Rebuild-All
    $rt = @($script:Tasks)[0]
    $rt.remindAt = (Get-Date).AddMinutes(-1).ToString('o')
    $rt.reminded = $false
    $rt.snoozeAt = $null
    $trigger = Get-RemindTriggerAt $rt
    Assert-True '过期提醒已到触发点' ($null -ne $trigger -and $trigger -le (Get-Date))
    Invoke-ReminderCheck
    Assert-True '提醒进入浮层队列' ($script:RemindItems -contains [string]$rt.id)
    Assert-True '提醒浮层可见' ($ui['RemindOverlay'].Visibility -eq [System.Windows.Visibility]::Visible)

    # 3.2 关机错过：超出保留时长的不再弹窗，但绝不能静默丢弃——要留「已错过」记录和可点提示
    $prevExpire = [int]$script:Settings.remindExpire
    Assert-True '默认的错过保留时长是 24 小时' ($prevExpire -eq 24)
    Assert-True '设置面板有 4 档错过保留时长' (
      ($null -ne $ui['RemindExpire24']) -and ($null -ne $ui['RemindExpire72']) -and
      ($null -ne $ui['RemindExpire168']) -and ($null -ne $ui['RemindExpire0']))
    Assert-True '错过保留时长的按钮文案可读' ([string]$ui['RemindExpireText'].Text -like '*24 小时*')

    $oldTask = New-TaskObject '关机两天后才开机的提醒'
    [void]$script:Tasks.Add($oldTask)
    $oldTask.remindAt = (Get-Date).AddHours(-50).ToString('o')
    $oldTask.reminded = $false
    $oldTask.expiredAt = $null
    $script:RemindItems = @()
    $script:ShowMissed = $false
    $script:Settings.remindExpire = 24
    Invoke-ReminderCheck
    Assert-True '超期提醒不再弹窗打扰' ($script:RemindItems -notcontains [string]$oldTask.id)
    Assert-True '超期提醒被记为「已错过」而非静默丢弃' (-not [string]::IsNullOrWhiteSpace([string]$oldTask.expiredAt))
    Assert-True '已错过清单能查到该条' (@(Get-MissedReminders | Where-Object { [string]$_.id -eq [string]$oldTask.id }).Count -eq 1)
    Assert-True '过期后弹出可点击的汇总提示' (($null -ne $script:ToastAction) -and [bool]$ui['Toast'].IsHitTestVisible)
    # 点提示条等价于执行这个动作块：跑一遍确认真的会打开「已错过」列表
    $toastAct = $script:ToastAction
    Hide-Toast
    Assert-True '提示条动作可执行' ($null -ne $toastAct)
    & $toastAct
    Show-MissedReminders
    Assert-True '已错过列表可以展开查看' ($ui['RemindOverlay'].Visibility -eq [System.Windows.Visibility]::Visible)
    Assert-True '浮层标题标明是已错过' ([string]$ui['RemindTitle'].Text -like '*已错过*')
    $missedRow = $ui['RemindHost'].Children[0]
    Assert-True '已错过条目带操作按钮' ($null -ne $missedRow -and $missedRow.Children.Count -eq 2)
    Update-MissedUi
    Assert-True '设置面板出现已错过入口' ($ui['MissedBanner'].Visibility -eq [System.Windows.Visibility]::Visible)

    # 重新提醒：清掉已错过标记，提醒时间推到未来
    & $script:OnRemindAction ([pscustomobject]@{ Tag = @{ action = 'resnooze'; taskId = [string]$oldTask.id } }) $null
    Assert-True '重新提醒后清除已错过标记' ([string]::IsNullOrWhiteSpace([string]$oldTask.expiredAt))
    $resnoozed = Get-TaskRemindAt $oldTask
    Assert-True '重新提醒的时间在未来' ($null -ne $resnoozed -and $resnoozed -gt (Get-Date))
    Assert-True '重新提醒后不再出现在已错过清单' (@(Get-MissedReminders | Where-Object { [string]$_.id -eq [string]$oldTask.id }).Count -eq 0)

    # 忽略：提醒作废，任务保留
    $ignTask = New-TaskObject '忽略掉这条错过的提醒'
    [void]$script:Tasks.Add($ignTask)
    $ignTask.remindAt = (Get-Date).AddHours(-30).ToString('o')
    $ignTask.reminded = $false
    $ignTask.expiredAt = $null
    Invoke-ReminderCheck
    Assert-True '忽略前该条已在已错过清单' (-not [string]::IsNullOrWhiteSpace([string]$ignTask.expiredAt))
    & $script:OnRemindAction ([pscustomobject]@{ Tag = @{ action = 'ignore'; taskId = [string]$ignTask.id } }) $null
    Assert-True '忽略后提醒与已错过标记都清空' ([string]::IsNullOrEmpty([string]$ignTask.remindAt) -and [string]::IsNullOrEmpty([string]$ignTask.expiredAt))
    Assert-True '忽略只清提醒、任务本身还在' ($null -ne (Find-Task ([string]$ignTask.id)))

    # 阈值设为「永久」：再久的提醒也照样补弹
    $foreverTask = New-TaskObject '十天前就该提醒我'
    [void]$script:Tasks.Add($foreverTask)
    $foreverTask.remindAt = (Get-Date).AddDays(-10).ToString('o')
    $foreverTask.reminded = $false
    $foreverTask.expiredAt = $null
    $script:Settings.remindExpire = 0
    $script:RemindItems = @()
    Invoke-ReminderCheck
    Assert-True '设为永久后超期提醒仍然补弹' ($script:RemindItems -contains [string]$foreverTask.id)
    $script:Settings.remindExpire = $prevExpire
    $script:RemindItems = @()
    $script:ShowMissed = $false
    Hide-Toast
    foreach ($deadId in @([string]$oldTask.id, [string]$ignTask.id, [string]$foreverTask.id)) {
      $script:Tasks.Remove((Find-Task $deadId))
    }
    Update-MissedUi


    # 3.5 收起提醒浮层再测命中：浮层横跨顶部，会盖住右上角那排按钮，导致命中判定误判
    $script:RemindItems = @()
    Update-RemindOverlay

    # 3.6 循环任务的提醒跟着循环走
    $script:Tasks.Clear(); $script:Series.Clear()
    New-RepeatTask '循环提醒测试' 'day'
    $rep = @($script:Tasks | Where-Object { $_.kind -eq 'repeat' })[0]
    $repSeries = Find-Series ([string]$rep.seriesId)
    Set-TaskRemind ([string]$rep.id) ((Get-Date).Date.AddHours(21))
    Assert-True '设提醒后循环链记住时刻' ([string]$repSeries.remindClock -eq '21:00')
    Set-TaskRemind ([string]$rep.id) $null
    Assert-True '取消提醒后循环链清空时刻' ([string]::IsNullOrEmpty([string]$repSeries.remindClock))
    Set-TaskRemind ([string]$rep.id) ((Get-Date).Date.AddHours(21))
    # 移除当前这条（相当于已完成归档），把 nextAt 推到今天，触发 rollover 生成下一条
    [void]$script:Tasks.Remove($rep)
    $repSeries.nextAt = Get-DateKey (Get-Date).Date
    Invoke-DayRollover $true | Out-Null
    $gen = @($script:Tasks | Where-Object { $_.kind -eq 'repeat' -and [string]$_.seriesId -eq [string]$rep.seriesId })
    $genAt = $null
    if ($gen.Count -ge 1) { $genAt = Get-TaskRemindAt $gen[0] }
    Assert-True '跨天生成的新任务带当天同时刻提醒' ($null -ne $genAt -and $genAt -eq (Get-Date).Date.AddHours(21))
    # 清理本节造的循环数据，避免污染后续 CSV 导出等断言
    foreach ($g in $gen) { [void]$script:Tasks.Remove($g) }
    for ($i = $script:Series.Count - 1; $i -ge 0; $i--) { if ([string]$script:Series[$i].id -eq [string]$rep.seriesId) { $script:Series.RemoveAt($i) } }
    # 后续断言依赖 Tasks 非空，补一条占位任务
    [void]$script:Tasks.Add((New-TaskObject '循环提醒测试占位'))
    Rebuild-All

    # 4. 锁定 / 专注 / 缩放 / 吸附 / 周历 往返
    # 4. 拖动判定：头部可拖、正文不可拖、控件不被抢
    $script:Win.UpdateLayout()
    $clockHit = $script:Win.InputHitTest([System.Windows.Point]::new(80, 60))
    Assert-True '头部时钟可被鼠标命中' ($null -ne $clockHit)
    Assert-True '头部区域判定为拖动区' ((Test-InDragZone $clockHit 60) -eq $true)
    # 按钮是圆角（CornerRadius = 半宽），取中心点判定，别取左上角那 4px 的圆角外区域
    $lockCenter = [System.Windows.Point]::new([double]$ui['LockToggle'].ActualWidth / 2, [double]$ui['LockToggle'].ActualHeight / 2)
    $lockPt = $ui['LockToggle'].TranslatePoint($lockCenter, $script:Win)
    $lockHit = $script:Win.InputHitTest($lockPt)
    Assert-True '锁定按钮位置判定为可交互' ((Test-InteractiveElement $lockHit) -eq $true)
    Clear-MouseCapture
    Assert-True '清空鼠标捕获后无残留捕获' ($null -eq [System.Windows.Input.Mouse]::Captured)
    $bodyY = [double]$script:Win.ActualHeight - 90
    $bodyHit = $script:Win.InputHitTest([System.Windows.Point]::new(80, $bodyY))
    Assert-True '正文区域不判定为拖动区' ((Test-InDragZone $bodyHit $bodyY) -eq $false)
    Set-Locked $true
    Assert-True '锁定后输入框禁用' (-not $ui['ComposerGrid'].IsEnabled)
    Set-Locked $false
    Assert-True '解锁后输入框可用' ($ui['ComposerGrid'].IsEnabled)

    $clampedFull = Get-ClampedWindowSize 200 200
    Assert-True '完整模式缩放下限 440×540' ([math]::Round($clampedFull.w) -eq 440 -and [math]::Round($clampedFull.h) -eq 540)
    Set-FocusMode $true
    $clampedFocus = Get-ClampedWindowSize 120 100
    Assert-True '专注模式缩放下限 200×160' ([math]::Round($clampedFocus.w) -eq 200 -and [math]::Round($clampedFocus.h) -eq 160)
    Assert-True '专注模式隐藏工具栏' ($ui['ToolbarGrid'].Visibility -eq [System.Windows.Visibility]::Collapsed)
    Assert-True '专注模式窗口不宽于 340' ([double]$script:Win.Width -le 340)
    Assert-True '专注模式显示缩放手柄' ($ui['ResizeGrip'].Visibility -eq [System.Windows.Visibility]::Visible)
    Assert-True '专注模式最小宽度 200' ([double]$script:Win.MinWidth -le 200)
    Assert-True '专注模式显示置顶按钮' ($ui['FocusPinToggle'].Visibility -eq [System.Windows.Visibility]::Visible)
    Assert-True '专注模式显示锁定按钮' ($ui['FocusLockToggle'].Visibility -eq [System.Windows.Visibility]::Visible)
    Assert-True '专注模式显示退出按钮' ($ui['FocusExitButton'].Visibility -eq [System.Windows.Visibility]::Visible)
    $pinChecked = [bool]$script:Settings.topmost
    Assert-True '专注置顶按钮状态与设置同步' ([bool]$ui['FocusPinToggle'].IsChecked -eq $pinChecked)
    # 已完成项目在小窗里不出现
    $doneTask = @($script:Tasks)[0]
    $doneTask.done = $true; $doneTask.doneAt = (Get-Date).ToString('o')
    Rebuild-All
    $doneLabels = @($ui['TasksHost'].Children | Where-Object {
        $_ -is [System.Windows.Controls.TextBlock] -and ([string]$_.Text) -like '已完成*' })
    Assert-True '专注模式不显示已完成分组' ($doneLabels.Count -eq 0)
    # 条目右侧的提醒 / 置顶 / 删除按钮在小窗里收起
    $row = @($ui['TasksHost'].Children | Where-Object { $_ -is [System.Windows.Controls.Border] })[0]
    $rowActionsVisible = 0
    if ($null -ne $row) {
      foreach ($child in $row.Child.Children) {
        if ([System.Windows.Controls.Grid]::GetColumn($child) -in @(3, 4, 5, 6) -and
          $child.Visibility -eq [System.Windows.Visibility]::Visible) { $rowActionsVisible++ }
      }
    }
    Assert-True '专注模式收起条目操作按钮' ($rowActionsVisible -eq 0)
    $doneTask.done = $false; $doneTask.doneAt = $null
    $script:Win.Width = 300; $script:Win.Height = 300
    Update-Bounds
    Assert-True '专注模式记住自定义宽度' ([double]$script:Settings.focusWidth -ge 290)
    $wa = Get-WindowWorkArea
    $script:Win.Left = $wa.left + 8
    $script:Win.Top = $wa.top + 8
    $snapped = Snap-WindowToEdge
    Assert-True '贴边吸附已触发' ([bool]$snapped)
    Assert-True '吸附后左边缘对齐工作区' ([math]::Abs([double]$script:Win.Left - $wa.left) -lt 1)
    Set-FocusMode $false
    Assert-True '退出专注恢复工具栏' ($ui['ToolbarGrid'].Visibility -eq [System.Windows.Visibility]::Visible)
    Assert-True '退出专注隐藏专注按钮组' ($ui['FocusActions'].Visibility -eq [System.Windows.Visibility]::Collapsed)
    Assert-True '完整模式最小宽度 440' ([double]$script:Win.MinWidth -ge 440)
    Assert-True '完整模式最小高度 540' ([double]$script:Win.MinHeight -ge 540)
    Assert-True '完整模式恢复后不小于最小宽度' ([double]$script:Win.Width -ge 440)
    Assert-True '完整模式恢复后不小于最小高度' ([double]$script:Win.Height -ge 540)
    Assert-True '完整模式可缩放（未锁定可见手柄）' ($ui['ResizeGrip'].Visibility -eq [System.Windows.Visibility]::Visible)
    Set-Locked $true
    Assert-True '锁定后缩放手柄隐藏' ($ui['ResizeGrip'].Visibility -eq [System.Windows.Visibility]::Collapsed)
    Set-Locked $false

    # 4.5 顶栏归位：锁定 / 专注 / 设置 与 置顶 / 毛玻璃 同一行
    $headerParent = $ui['PinToggle'].Parent
    Assert-True '锁定按钮与置顶同行' ([object]::ReferenceEquals($ui['LockToggle'].Parent, $headerParent))
    Assert-True '专注按钮与置顶同行' ([object]::ReferenceEquals($ui['FocusToggle'].Parent, $headerParent))
    Assert-True '设置按钮与置顶同行' ([object]::ReferenceEquals($ui['SettingsButton'].Parent, $headerParent))
    Assert-True '搜索按钮仍留在工具栏' ([object]::ReferenceEquals($ui['SearchButton'].Parent, $ui['TagsButton'].Parent))
    Assert-True '工具栏不再有锁定按钮' (-not [object]::ReferenceEquals($ui['LockToggle'].Parent, $ui['SearchButton'].Parent))

    # 4.6 笔记条目模式 + 复选框列宽
    $note = New-TaskObject '这是一条笔记' 'note'
    [void]$script:Tasks.Add($note)
    Rebuild-All $false
    $script:Win.UpdateLayout()
    $noteRow = $null
    $todoRow = $null
    foreach ($child in $ui['TasksHost'].Children) {
      if ($child -isnot [System.Windows.Controls.Border]) { continue }
      $hasCheck = $false
      foreach ($inner in $child.Child.Children) { if ($inner -is [System.Windows.Controls.CheckBox]) { $hasCheck = $true } }
      if ([string]$child.Tag -eq [string]$note.id) { $noteRow = $child }
      elseif ($hasCheck -and $null -eq $todoRow) { $todoRow = $child }
    }
    Assert-True '笔记行已渲染' ($null -ne $noteRow)
    $noteHasCheck = $false
    if ($null -ne $noteRow) {
      foreach ($inner in $noteRow.Child.Children) { if ($inner -is [System.Windows.Controls.CheckBox]) { $noteHasCheck = $true } }
    }
    Assert-True '笔记行没有复选框' (-not $noteHasCheck)
    Assert-True '待办行仍有复选框' ($null -ne $todoRow)
    if ($null -ne $todoRow) {
      Assert-True '勾选框列宽不小于 28px（不再被裁切）' ([double]$todoRow.Child.ColumnDefinitions[1].Width.Value -ge 28)
      $checkCtl = $null
      foreach ($inner in $todoRow.Child.Children) { if ($inner -is [System.Windows.Controls.CheckBox]) { $checkCtl = $inner } }
      Assert-True '勾选框实际宽度完整（>=20px）' ($null -ne $checkCtl -and [double]$checkCtl.ActualWidth -ge 20)
      $handleBoxOk = $false
      foreach ($inner in $todoRow.Child.Children) {
        if ($inner -is [System.Windows.Controls.Border] -and [string]$inner.Tag -eq [string]$todoRow.Tag -and
          [double]$inner.Width -ge 16 -and $null -ne $inner.Background) { $handleBoxOk = $true }
      }
      Assert-True '拖动把手有透明命中盒（不只 3px 字形）' $handleBoxOk
    }
    $expectPending = @($script:Tasks | Where-Object { -not (Test-IsNote $_) -and -not $_.done }).Count
    $shownPending = 0
    if (([string]$ui['ProgressText'].Text) -match '待办 (\d+)') { $shownPending = [int]$Matches[1] }
    Assert-True '笔记不参与完成率统计' ($shownPending -eq $expectPending)

    # 4.7 标签：新建 / 归档 / 筛选 / 改名
    $tagA = New-Tag '工作'
    Assert-True '标签可新建' ($null -ne $tagA -and $script:Tags.Count -ge 1)
    Assert-True '同名标签不会重复' ($null -eq (New-Tag '工作'))
    Set-TaskTag ([string]$note.id) ([string]$tagA.id) $true
    Assert-True '条目已归档到标签' (@(Get-TaskTagIds $note) -contains [string]$tagA.id)
    Set-TagFilter ([string]$tagA.id)
    $filtered = @(Get-FilteredTasks)
    Assert-True '按标签筛选只留归档条目' ($filtered.Count -eq 1 -and [string]$filtered[0].id -eq [string]$note.id)
    Assert-True '筛选时搜索栏自动展开' ($ui['SearchBar'].Visibility -eq [System.Windows.Visibility]::Visible)
    Set-TagFilter ''
    Assert-True '清除筛选后条目恢复' (@(Get-FilteredTasks).Count -ge 2)
    Assert-True '筛选按钮回到全部标签' (([string]$ui['TagFilterButton'].Content) -like '全部标签*')
    Rename-Tag ([string]$tagA.id) '工作事项'
    $renamed = Find-Tag ([string]$tagA.id)
    Assert-True '标签可重命名' ($null -ne $renamed -and [string]$renamed.name -eq '工作事项')

    # 归档菜单：代码里现造的 ContextMenu 必须留强引用，否则弹层会被 GC 一闪就没
    $probe = [System.Windows.Controls.Button]::new()
    $probe.Tag = [string]$note.id
    [void]$ui['TasksHost'].Children.Add($probe)
    $script:ActiveMenu = $null
    Show-TaskTagMenu $probe
    $menuOk = ($null -ne $script:ActiveMenu) -and [bool]$script:ActiveMenu.IsOpen -and $script:ActiveMenu.Items.Count -ge 2
    Assert-True '条目标签菜单能弹出且留住了引用' $menuOk
    if ($null -ne $script:ActiveMenu) { $script:ActiveMenu.IsOpen = $false }
    $script:ActiveMenu = $null
    [void]$ui['TasksHost'].Children.Remove($probe)

    # 4.8 回收站：删除 / 还原 / 彻底删除
    $trashBefore = $script:Trash.Count
    Remove-Task ([string]$note.id)
    Assert-True '删除后进入回收站' ($script:Trash.Count -eq $trashBefore + 1)
    Assert-True '删除后列表里已没有' ($null -eq (Find-Task ([string]$note.id)))
    Rebuild-Trash $true
    Assert-True '回收站视图有内容' ($ui['TrashHost'].Children.Count -ge 1)
    Restore-Trash ([string]$note.id)
    Assert-True '可从回收站还原' ($null -ne (Find-Task ([string]$note.id)))

    # 在回收站页面做还原时，顶部进度角标必须跟着刷新（否则会停在删除前的旧数字）
    $pendingTodo = @($script:Tasks | Where-Object { -not (Test-IsNote $_) -and -not $_.done })[0]
    Switch-View 'tasks'
    Rebuild-All
    $progressBefore = [string]$ui['ProgressText'].Text
    Switch-View 'trash'
    Remove-Task ([string]$pendingTodo.id)
    $progressWhileGone = [string]$ui['ProgressText'].Text
    Restore-Trash ([string]$pendingTodo.id)
    $progressRestored = [string]$ui['ProgressText'].Text
    Assert-True '回收站页面删除会刷新顶部进度' ($progressWhileGone -ne $progressBefore)
    Assert-True '回收站还原后顶部进度已刷新' ($progressRestored -eq $progressBefore)
    Switch-View 'tasks'
    $note2 = New-TaskObject '待彻底删除' 'note'
    [void]$script:Tasks.Add($note2)
    Remove-Task ([string]$note2.id)
    Purge-Trash ([string]$note2.id)
    Assert-True '彻底删除后回收站不留痕' ($null -eq (Find-TrashItem ([string]$note2.id)))

    # 4.9 草稿：写一半就退出也不丢
    $ui['NoteInput'].Text = '正在写一半的句子'
    Save-Draft
    Assert-True '草稿文件已落盘' (Test-Path -LiteralPath $script:DraftFile)
    $ui['NoteInput'].Text = ''
    $draftOk = Restore-Draft
    Assert-True '草稿可回填到输入框' ($draftOk -and [string]$ui['NoteInput'].Text -eq '正在写一半的句子')
    $ui['NoteInput'].Text = ''
    Reset-Draft
    Assert-True '清空草稿后文件消失' (-not (Test-Path -LiteralPath $script:DraftFile))

    # 4.10 多行输入：Enter 保存、Shift + Enter 换行
    Assert-True '输入框允许回车换行' ([bool]$ui['NoteInput'].AcceptsReturn)
    Assert-True '输入框自动折行' ($ui['NoteInput'].TextWrapping -eq [System.Windows.TextWrapping]::Wrap)
    Assert-True '预描述写明 Shift + Enter 换行' (([string]$ui['Placeholder'].Text).IndexOf('Shift') -ge 0)
    $idsBefore = @($script:Tasks | ForEach-Object { [string]$_.id })
    $ui['NoteInput'].Text = "第一行`r`n第二行"
    Add-TaskFromInput
    $multiTask = @($script:Tasks | Where-Object { $idsBefore -notcontains [string]$_.id }) | Select-Object -First 1
    Assert-True '多行内容保存为一条' ($null -ne $multiTask)
    Assert-True '多行内容保留换行' ($null -ne $multiTask -and ([string]$multiTask.text).Contains("`n"))
    if ($null -ne $multiTask) { Remove-Task ([string]$multiTask.id); Purge-Trash ([string]$multiTask.id) }

    # 4.10b 编辑已有条目同样支持换行（样式默认单行，靠每行的本地值覆盖）
    $probe = New-TaskObject '编辑换行探测'
    [void]$script:Tasks.Add($probe)
    Rebuild-All
    $probeBox = $script:TaskTextElements[[string]$probe.id]
    Assert-True '编辑已有条目可换行（AcceptsReturn）' ($null -ne $probeBox -and [bool]$probeBox.AcceptsReturn)
    Assert-True '编辑框自动折行' ($null -ne $probeBox -and $probeBox.TextWrapping -eq [System.Windows.TextWrapping]::Wrap)
    if ($null -ne $probeBox) {
      $probeBox.Text = "一`r`n二"
      Assert-True '编辑后多行内容真实入库' (([string](Find-Task ([string]$probe.id)).text).Contains("`n"))
    }
    Remove-Task ([string]$probe.id); Purge-Trash ([string]$probe.id)
    # 按键层：条目编辑框必须对 Shift + Enter 放行，否则又被收笔逻辑吃掉
    $selfSrc = ''
    try { $selfSrc = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8) } catch { }
    $keyMatch = [regex]::Match($selfSrc, 'OnTaskTextKeyDown = \{(?s).*?\n\}')
    Assert-True '条目编辑 Shift+Enter 放行换行' ($keyMatch.Success -and $keyMatch.Value.Contains('Shift') -and $keyMatch.Value.Contains('return'))

    # 4.11 番茄钟
    Assert-True '番茄钟面板已渲染' ($null -ne $ui['PomodoroPanel'])
    Set-PomodoroMode 25
    Assert-True '番茄钟默认 25 分钟' ([int]$script:Pomodoro.total -eq 1500 -and [int]$script:Pomodoro.remain -eq 1500)
    Assert-True '番茄钟默认不自动开始' (-not [bool]$script:Pomodoro.running)
    Assert-True '倒计时格式为 mm:ss' ((Format-PomodoroTime 1500) -eq '25:00' -and (Format-PomodoroTime 65) -eq '01:05' -and (Format-PomodoroTime 0) -eq '00:00')
    Set-PomodoroMode 5
    Assert-True '可切到 5 分钟休息' ([int]$script:Pomodoro.total -eq 300 -and [string]$script:Pomodoro.label -eq '休息')
    Set-PomodoroMode 30
    Assert-True '支持自定义 30 分钟' ([int]$script:Pomodoro.total -eq 1800 -and [string]$script:Pomodoro.label -eq '专注')
    Set-PomodoroMode 25
    Assert-True '番茄钟开关默认开启' ([bool]$script:Settings.pomodoro -eq $true)
    Assert-True '番茄钟开关已渲染' ($null -ne $ui['PomodoroToggle'])
    Assert-True '番茄钟自定义编辑器已渲染' ($null -ne $ui['PomodoroEditor'] -and $null -ne $ui['PomodoroInput'])
    # 番茄钟点击不得被窗口拖动逻辑拦截（非锁定状态也能开始/暂停）
    $selfSrc = ''
    try { $selfSrc = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8) } catch { }
    Assert-True '番茄钟区域排除在窗口拖动之外' ($selfSrc.Contains('Test-AncestorIs $source @(''PomodoroPanel'')'))
    Assert-True '切换主题会刷新图标颜色' ($selfSrc.Contains('function Sync-ChromeIcons') -and $selfSrc.Contains('Sync-ChromeIcons'))
    # 单次下拉按钮的 Padding 要绑定到内容区，否则文字贴边超出椭圆
    $xamlSrc = ''
    try { $xamlSrc = [System.IO.File]::ReadAllText($script:UiFile, [System.Text.Encoding]::UTF8) } catch { }
    Assert-True '类型按钮 Padding 已绑定（不超出椭圆）' ($xamlSrc.Contains('TypeButtonStyle') -and $xamlSrc.Contains('Margin="{TemplateBinding Padding}"'))

    # 4.12 完成音效 + 右键复制
    Assert-True '完成音效默认开启' ([bool]$script:Settings.doneSound -eq $true)
    Assert-True '完成音效开关已渲染' ($null -ne $ui['DoneSoundToggle'])
    $copyMenu = New-CopyContextMenu '测试内容'
    Assert-True '右键菜单含复制内容项' ($copyMenu.Items.Count -eq 1 -and [string]$copyMenu.Items[0].Header -eq '复制内容')
    # 设置是逐字段写盘的，新增开关必须自己加进去，否则重启就忘了用户的选择
    $script:Settings.doneSound = $false
    Save-State
    $soundSaved = [IO.File]::ReadAllText($script:DataFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-True '完成音效开关能落盘' ([bool]$soundSaved.settings.doneSound -eq $false)
    $script:Settings.doneSound = $true
    Save-State
    Rebuild-Tasks $false
    # 番茄钟开关也要落盘
    $script:Settings.pomodoro = $false
    Save-State
    $pomodoroSaved = [IO.File]::ReadAllText($script:DataFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-True '番茄钟开关能落盘' ([bool]$pomodoroSaved.settings.pomodoro -eq $false)
    $script:Settings.pomodoro = $true
    Save-State
    $cardsWithMenu = @($ui['TasksHost'].Children | Where-Object { $_ -is [System.Windows.Controls.Border] -and $null -ne $_.ContextMenu })
    Assert-True '任务卡片都挂了右键菜单' ($cardsWithMenu.Count -ge 1)

    $script:Settings.clockCalendar = $true
    $script:WeekStripKey = ''
    Update-WeekStrip
    Assert-True '周历渲染 7 天' ($ui['WeekStripHost'].Children.Count -eq 7)
    Assert-True '周历可见' ($ui['WeekStrip'].Visibility -eq [System.Windows.Visibility]::Visible)
    $script:Settings.clockCalendar = $false
    Update-WeekStrip
    Assert-True '关闭后周历隐藏' ($ui['WeekStrip'].Visibility -eq [System.Windows.Visibility]::Collapsed)
    $script:Settings.clockCalendar = $true
    $script:WeekStripKey = ''
    Update-WeekStrip

    Switch-View 'history'
    $firstHistoryChild = if ($ui['HistoryHost'].Children.Count -gt 0) { $ui['HistoryHost'].Children[0] } else { $null }
    Assert-True '历史页首项不是统计卡' (-not ($firstHistoryChild -is [System.Windows.Controls.Border]))
    Switch-View 'tasks'

    # 5. 主题切换不炸（含新增的传统便签亮色配色）
    $themeIds = @($script:Themes.Keys)
    foreach ($k in $themeIds) { Set-Theme $k $false }
    Assert-True "全部主题切换完成（$($themeIds.Count) 套）" ($themeIds.Count -ge 9)
    Set-Theme 'noteyellow' $false
    $lightPrimary = $script:Win.Resources['TextPrimaryBrush']
    Assert-True '便签黄主题文字为深色' ($lightPrimary.Color.R -lt 110)
    Assert-True '便签黄主题底色为浅色' ($script:Win.Resources['BgSolidBrush'].GradientStops[0].Color.R -gt 200)
    Set-Theme 'notewhite' $false
    Assert-True '便签白主题文字为深色' ($script:Win.Resources['TextPrimaryBrush'].Color.R -lt 110)
    Set-Theme 'lime' $false
    Assert-True '回到深色主题文字恢复浅色' ($script:Win.Resources['TextPrimaryBrush'].Color.R -gt 200)

    # 5.0b 单次按钮 / 标签筛选按钮的文字颜色也要跟着主题即时刷新（此前漏掉，切换后仍显示旧色）
    $script:Settings.composerKind = 'once'
    Set-TagFilter ''
    Set-Theme 'noteyellow' $false
    $repeatFgLight = ([System.Windows.Media.SolidColorBrush]$ui['RepeatButton'].Foreground).Color
    Assert-True '切浅色后单次按钮即时刷新' ($repeatFgLight -eq $script:Win.Resources['TextSecondaryBrush'].Color)
    Set-Theme 'lime' $false
    $repeatFgDark = ([System.Windows.Media.SolidColorBrush]$ui['RepeatButton'].Foreground).Color
    Assert-True '切深色后单次按钮即时刷新' ($repeatFgDark -eq $script:Win.Resources['TextSecondaryBrush'].Color)
    $tagBtnFg = ([System.Windows.Media.SolidColorBrush]$ui['TagFilterButton'].Foreground).Color
    Assert-True '标签筛选按钮文字随主题刷新' ($tagBtnFg -eq $script:Win.Resources['TextSecondaryBrush'].Color)

    # 5.1 弹出菜单皮肤必须跟着主题走（亮色主题下不能还是深底深字）
    Set-Theme 'noteyellow' $false
    $menuBgLight = $script:Win.Resources['MenuBgBrush']
    Assert-True '便签黄主题下菜单是浅色底' ($menuBgLight.Color.R -gt 200 -and $menuBgLight.Color.G -gt 190)
    Assert-True '亮色主题菜单底色与文字反差足够' ([math]::Abs([int]$menuBgLight.Color.R - [int]$script:Win.Resources['TextPrimaryBrush'].Color.R) -gt 90)
    $menuHoverLight = $script:Win.Resources['MenuHoverBgBrush']
    Assert-True '亮色主题菜单悬停色与底色可区分' ([math]::Abs([int]$menuHoverLight.Color.R - [int]$menuBgLight.Color.R) -ge 5)
    Set-Theme 'lime' $false
    $menuBgDark = $script:Win.Resources['MenuBgBrush']
    Assert-True '深色主题下菜单仍是深色底' ($menuBgDark.Color.R -lt 80)
    Assert-True '深色主题菜单底色与文字反差足够' (([int]$script:Win.Resources['TextPrimaryBrush'].Color.R - [int]$menuBgDark.Color.R) -gt 150)
    $menuStyle = $script:Win.Resources['AppMenuStyle']
    $bgSetter = $null
    foreach ($setter in $menuStyle.Setters) {
      if ($setter -is [System.Windows.Setter] -and [string]$setter.Property.Name -eq 'Background') { $bgSetter = $setter }
    }
    $bgIsDynamic = $false
    if ($null -ne $bgSetter -and $bgSetter.Value -is [System.Windows.DynamicResourceExtension]) {
      $bgIsDynamic = ([string]$bgSetter.Value.ResourceKey -eq 'MenuBgBrush')
    }
    Assert-True '菜单背景绑定到主题画刷（否则切主题不变色）' $bgIsDynamic

    # 6. CSV 导出
    $csvBefore = @(Get-ChildItem $script:ExportDir -Filter '*.csv' -ErrorAction SilentlyContinue).Count
    Export-RecordsCsv
    $csvFiles = @(Get-ChildItem $script:ExportDir -Filter '*.csv' -ErrorAction SilentlyContinue)
    Assert-True 'CSV 文件已生成' ($csvFiles.Count -gt $csvBefore)
    if ($csvFiles.Count -gt 0) {
      $lines = [System.IO.File]::ReadAllLines($csvFiles[0].FullName)
      Assert-True 'CSV 有表头+数据行' ($lines.Count -ge 2)
      Assert-True 'CSV 表头正确' ($lines[0] -match '内容' -and $lines[0] -match '提醒时间' -and $lines[0] -match '循环')
      Write-Output ('  表头: ' + $lines[0])
      Write-Output ('  示例: ' + $lines[1])
    }

    # 6.1 Markdown 导出（此前完全没覆盖，属于只测了 CSV 的漏网区）
    $mdBefore = @(Get-ChildItem $script:ExportDir -Filter '*.md' -ErrorAction SilentlyContinue).Count
    Export-HistoryMarkdown
    $mdFiles = @(Get-ChildItem $script:ExportDir -Filter '*.md' -ErrorAction SilentlyContinue)
    Assert-True 'Markdown 文件已生成' ($mdFiles.Count -gt $mdBefore)
    if ($mdFiles.Count -gt 0) {
      $mdLines = [System.IO.File]::ReadAllLines($mdFiles[0].FullName, [System.Text.UTF8Encoding]::new($false))
      Assert-True ('Markdown 首行是标题 [' + $mdFiles[0].Name + ']') ($mdLines.Count -ge 3 -and $mdLines[0] -eq '# 核桃便签历史记录')
      $mdRecords = @(Get-CompletionRecords)
      $mdText = $mdLines -join "`n"
      if ($mdRecords.Count -gt 0) {
        Assert-True ('Markdown 按日期分组 [' + $mdRecords.Count + ' 条记录]') ($mdText -match '(?m)^## ')
        Assert-True 'Markdown 含 - [x] 条目' ($mdText -match '(?m)^- \[x\] ')
      } else {
        Assert-True 'Markdown 无历史时只输出头部且不报错' ($mdLines.Count -ge 3)
      }
      Write-Output ('  Markdown 行数: ' + $mdLines.Count + '，记录数: ' + $mdRecords.Count)
    }

    # 7. 真机快照（供人工目检布局）
    try {
      if (-not [string]::IsNullOrWhiteSpace($Theme) -and $script:Themes.Contains($Theme)) { Set-Theme $Theme $false }
      [void]$script:Tasks.Add((New-TaskObject '写季度复盘，附上三张图表'))
      [void]$script:Tasks.Add((New-TaskObject '给客户回电话确认交付时间'))
      New-RepeatTask '每天喝一杯水' 'day'
      $pinTask = @($script:Tasks)[0]
      $pinTask.pinned = $true
      $rmTask = @($script:Tasks)[1]
      $rmTask.remindAt = (Get-Date).Date.AddDays(1).AddHours(9).ToString('o')
      Rebuild-All
      $tmpDir = [System.IO.Path]::GetTempPath()
      $script:Win.Show()
      $script:Win.Width = $script:FullDefaultWidth; $script:Win.Height = $script:FullDefaultHeight
      $script:Win.UpdateLayout()
      # 手柄必须真的能被鼠标命中，否则拖不动（曾被边缘命中测试抢走）
      $hitW = [double]$script:Win.ActualWidth; $hitH = [double]$script:Win.ActualHeight
      $gripHit = $script:Win.InputHitTest([System.Windows.Point]::new($hitW - 26 - 12, $hitH - 26 - 7))
      Assert-True '右下角缩放手柄可被鼠标命中' ($null -ne $gripHit)
      Write-Output ('  手柄命中元素: ' + $(if ($gripHit) { $gripHit.GetType().Name } else { '无' }))
      # 笔记浮窗（把笔记拖出主窗口后的最终形态）
      $popNote = New-TaskObject '把这条笔记拖出窗口试试' 'note'
      [void]$script:Tasks.Add($popNote)
      Rebuild-All $false
      $histBeforePop = $script:History.Count
      $nw = New-NoteWindow $popNote
      Assert-True '笔记浮窗已创建' ($null -ne $nw)
      Assert-True '浮窗已登记' (@($script:NoteWindows).Count -eq 1)
      # 小窗是独立 Window，主题资源必须注入，否则配色解析不到主窗口、换主题也不刷新
      Assert-True '小窗已注入主题资源' ($nw.Resources.Contains('SettingsBgBrush'))
      try { $nw.UpdateLayout() } catch { }
      $nwToggleCount = 0
      $nwStack = [System.Collections.Generic.Stack[System.Windows.DependencyObject]]::new()
      $nwStack.Push($nw.Content)
      while ($nwStack.Count -gt 0) {
        $nwNode = $nwStack.Pop()
        if ($nwNode -is [System.Windows.Controls.Primitives.ToggleButton]) { $nwToggleCount++ }
        $nwKids = 0
        try { $nwKids = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($nwNode) } catch { }
        for ($nwI = 0; $nwI -lt $nwKids; $nwI++) { $nwStack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($nwNode, $nwI)) }
      }
      Assert-True '小窗含半透明/置顶/锁定三个开关' ($nwToggleCount -ge 3)
      # 真点一遍三个开关。这三个按钮曾因为处理代码块读不到函数局部变量而完全没反应（静默失败），
      # 这里用 RaiseEvent 真触发 Click，断言窗口属性确实变了，防止同类问题再回归。
      $clickEv = [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
      $assertNotesOk = $true
      try {
        $tbTrans = $nw.Tag.transBtn
        $tbTrans.IsChecked = $true; $tbTrans.RaiseEvent($clickEv)
        Assert-True '小窗半透明开关生效' ([double]$nw.Opacity -lt 0.9)
        $tbTrans.IsChecked = $false; $tbTrans.RaiseEvent($clickEv)
        Assert-True '小窗半透明开关可还原' ([double]$nw.Opacity -gt 0.9)
        $tbPin = $nw.Tag.pinBtn
        $tbPin.IsChecked = $false; $tbPin.RaiseEvent($clickEv)
        Assert-True '小窗置顶开关可取消' ($nw.Topmost -eq $false)
        $tbPin.IsChecked = $true; $tbPin.RaiseEvent($clickEv)
        Assert-True '小窗置顶开关可恢复' ($nw.Topmost -eq $true)
        $tbLock = $nw.Tag.lockBtn
        $tbLock.IsChecked = $true; $tbLock.RaiseEvent($clickEv)
        Assert-True '小窗锁定开关生效' ([bool]$nw.Tag.locked)
        Assert-True '锁定后标题提示已锁定' ([string]$nw.Tag.caption.Text -like '*已锁定*')
        # 缩放手柄：锁定时必须被拦下，解锁后必须真的改变尺寸，且不小于最小尺寸
        $wBefore = [double]$nw.Width
        $nw.Tag.resizing = $true; $nw.Tag.w = 250.0; $nw.Tag.h = 176.0; $nw.Tag.scale = 1.0
        Resize-NoteWindow $nw 80 60
        Assert-True '锁定时不可缩放' ([double]$nw.Width -eq $wBefore)
        $tbLock.IsChecked = $false; $tbLock.RaiseEvent($clickEv)
        Assert-True '小窗可解锁' (-not [bool]$nw.Tag.locked)
        $nw.Tag.resizing = $true; $nw.Tag.w = 250.0; $nw.Tag.h = 176.0; $nw.Tag.scale = 1.0
        Resize-NoteWindow $nw 80 60
        Assert-True '解锁后可放大' ([double]$nw.Width -gt $wBefore -and [double]$nw.Height -gt 176)
        $nw.Tag.w = 200.0; $nw.Tag.h = 120.0
        Resize-NoteWindow $nw -500 -500
        Assert-True '缩到最小尺寸被夹住' (([double]$nw.Width -eq [double]$nw.MinWidth) -and ([double]$nw.Height -eq [double]$nw.MinHeight))
        $nw.Tag.resizing = $false
      } catch {
        $assertNotesOk = $false
        Assert-True ('小窗交互断言执行异常: ' + $_.Exception.Message) $false
      }
      Write-Output ('  小窗交互断言: ' + $(if ($assertNotesOk) { '完成' } else { '有异常' }))

      # 主面板改文字 → 小窗必须实时跟上。小窗创建时只读一次 task.text，
      # 之前改完主面板，小窗一直停在旧文字上，看起来像「没保存」。
      $syncBefore = [string]$nw.Tag.body.Text
      Set-TaskText ([string]$popNote.id) '把这条笔记拖出窗口试试（已改）'
      Assert-True '主面板改文字后小窗正文同步' ([string]$nw.Tag.body.Text -eq '把这条笔记拖出窗口试试（已改）')
      Assert-True '小窗标题跟随正文' ([string]$nw.Title -like '*已改*')
      Set-TaskText ([string]$popNote.id) $syncBefore
      Assert-True '小窗正文可还原' ([string]$nw.Tag.body.Text -eq $syncBefore)

      try {
        # 上面的缩放断言把窗口缩到了最小尺寸，出快照前先还原，否则截出来是被裁掉的样子
        $nw.Width = 250; $nw.Height = 176
        $nw.UpdateLayout()
        $pw = [int]$nw.Width; $ph = [int]$nw.Height
        if ($pw -gt 0 -and $ph -gt 0) {
          $prtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($pw, $ph, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
          $prtb.Render($nw.Content)
          $penc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
          $penc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($prtb))
          $ppath = Join-Path $tmpDir 'gn_note_window.png'
          $pfs = [System.IO.File]::Create($ppath); $penc.Save($pfs); $pfs.Close()
          Write-Output ('  浮窗快照: ' + $ppath)
        }
      } catch { Write-Output ('  浮窗快照失败: ' + $_.Exception.Message) }
      try { $nw.Close() } catch { }
      Start-Sleep -Milliseconds 150
      Assert-True '关闭浮窗后条目仍在列表' ($null -ne (Find-Task ([string]$popNote.id)))
      Assert-True '关闭浮窗不进历史' ($script:History.Count -eq $histBeforePop)
      Assert-True '浮窗关闭后登记清零' (@($script:NoteWindows).Count -eq 0)
      Remove-Task ([string]$popNote.id)
      # 真实窗口尺寸下验证：进小窗再退出，完整尺寸必须还原
      $beforeFullW = [double]$script:Win.ActualWidth
      $beforeFullH = [double]$script:Win.ActualHeight
      Set-FocusMode $true
      $script:Win.UpdateLayout()
      Assert-True '小窗实际宽度小于完整模式' ([double]$script:Win.ActualWidth -lt $beforeFullW)
      Set-FocusMode $false
      $script:Win.UpdateLayout()
      Assert-True '退出小窗还原完整宽度' ([math]::Abs([double]$script:Win.ActualWidth - $beforeFullW) -lt 2)
      Assert-True '退出小窗还原完整高度' ([math]::Abs([double]$script:Win.ActualHeight - $beforeFullH) -lt 2)
      function Save-Shot([string]$name) {
        # 等入场动画播完再截图，否则拍到的是透明度接近 0 的行
        for ($i = 0; $i -lt 10; $i++) {
          [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
          Start-Sleep -Milliseconds 45
        }
        $w = [int]$script:Win.ActualWidth; $h = [int]$script:Win.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($script:Win.Content)
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $path = Join-Path $tmpDir $name
        $fs = [System.IO.File]::Create($path); $enc.Save($fs); $fs.Close()
        Write-Output ('  快照: ' + $path + '  (' + $w + 'x' + $h + ')')
      }
      $ui['RemindOverlay'].Visibility = [System.Windows.Visibility]::Collapsed
      $ui['Toast'].Visibility = [System.Windows.Visibility]::Collapsed
      Save-Shot 'gn_live.png'
      $script:Win.Width = 800; $script:Win.Height = 840
      Open-Settings
      Save-Shot 'gn_live_settings.png'
      # 提醒区在面板下半部分，滚到那里再拍一张，方便目检「错过保留时长」和「已错过」入口
      try {
        $ui['MissedBanner'].Visibility = [System.Windows.Visibility]::Visible
        $ui['MissedText'].Text = (TCount '有 {0} 条提醒已错过（到点时程序没在运行）' 2)
        $ui['RemindExpireText'].BringIntoView()
        $scroller = $script:Win.FindName('SettingsScroller')
        if ($scroller) { $scroller.ScrollToVerticalOffset([double]$scroller.ScrollableHeight) }
        $script:Win.UpdateLayout()
        Save-Shot 'gn_settings_remind.png'
        Update-MissedUi
      } catch { Write-Output ('  提醒区快照失败: ' + $_.Exception.Message) }
      # 再拍一张「开关全关」：浅色主题下最看不清的就是关闭态，留一张对照图方便目检
      $toggleNames = @('SettingsGlassToggle', 'Clock24Toggle', 'ClockSecondsToggle', 'ClockCalendarToggle',
        'RemindSoundToggle', 'DoneSoundToggle', 'PomodoroToggle', 'TrayToggle', 'CloseToTrayToggle',
        'HotkeyToggle', 'AutostartToggle')
      $savedToggles = @{}
      foreach ($tn in $toggleNames) {
        if ($ui.ContainsKey($tn)) { $savedToggles[$tn] = [bool]$ui[$tn].IsChecked; $ui[$tn].IsChecked = $false }
      }
      Save-Shot 'gn_live_settings_off.png'
      foreach ($tn in @($savedToggles.Keys)) { $ui[$tn].IsChecked = $savedToggles[$tn] }
      Close-Settings
      $script:Win.Width = 800; $script:Win.Height = 600
      # 已错过浮层：确认标题、原定时间、「重新提醒 / 忽略」按钮在窄窗口里不挤
      try {
        $missShot = New-TaskObject '关机两天后才想起来的事'
        [void]$script:Tasks.Add($missShot)
        $missShot.remindAt = (Get-Date).AddHours(-30).ToString('o')
        $missShot.expiredAt = (Get-Date).AddHours(-30).ToString('o')
        $missShot.reminded = $true
        Show-MissedReminders
        Save-Shot 'gn_missed_overlay.png'
        $script:RemindItems = @()
        $script:ShowMissed = $false
        Update-RemindOverlay
        [void]$script:Tasks.Remove($missShot)
      } catch { Write-Output ('  已错过浮层快照失败: ' + $_.Exception.Message) }
      Set-FocusMode $true
      $script:Win.Width = 320; $script:Win.Height = 420
      Save-Shot 'gn_live_focus.png'
      Set-FocusMode $false
      Set-Locked $true
      Save-Shot 'gn_live_lock.png'
      Set-Locked $false
      # 语言：切英文后拍一张对照图，顺便验证静态文案被翻译、用户便签不被翻译
      try {
        Set-AppLanguage 'en'
        Update-Clock
        Rebuild-All $false
        Update-LangUi
        $script:Win.UpdateLayout()
        Save-Shot 'gn_lang_en.png'
        Open-Settings
        try {
          $langScroller = $script:Win.FindName('SettingsScroller')
          if ($langScroller) { $langScroller.ScrollToVerticalOffset(0) }
        } catch { }
        $script:Win.UpdateLayout()
        Update-LangUi
        Save-Shot 'gn_lang_en_settings.png'
        Assert-True '英文界面：版本行被翻译' ([string]$ui['VersionText'].Text -match 'Hetao Notes v')
        $sampleBox = $null
        foreach ($k in $script:TaskTextElements.Keys) { $sampleBox = $script:TaskTextElements[$k]; break }
        Assert-True '英文界面：用户便签正文不被翻译' ($null -eq $sampleBox -or [string]$sampleBox.Text -match '[\u4e00-\u9fff]')
        Assert-True '英文界面：语言按钮标签被翻译' ([string]$ui['LangPanel'].Children[0].Content -eq 'System')
        Assert-True '英文界面：拼接文本能被替换' ((Convert-LangText '10:00 · 单次') -eq '10:00 · One-time')
        $script:Settings.language = 'en'
        Save-State
        $langSaved = ([System.IO.File]::ReadAllText($script:DataFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).settings.language
        Assert-True '语言设置能写进存档' ($langSaved -eq 'en')
        Assert-True '英文界面：数量为 1 时用单数' ((TCount '{0} 项' 1) -eq '1 item')
        Assert-True '英文界面：数量不为 1 时用复数' ((TCount '{0} 项' 3) -eq '3 items')
        Assert-True '英文界面：已错过时长为 1 天用单数' ((TCount '已错过 {0} 天' 1) -eq 'missed 1 day')
        Assert-True '英文界面：已错过时长为复数天' ((TCount '已错过 {0} 天' 30) -eq 'missed 30 days')
        Assert-True '英文界面：进度句单数' ((TCount '全部完成 · 共 {0} 项' 1) -eq 'All done · 1 item')
        Assert-True '英文界面：浮层标题双数量' ((Format-RemindTitle 2 1) -eq '2 due · 1 missed')
        Assert-True '英文界面：浮层标题单边' ((Format-RemindTitle 3 0) -eq '3 due now')
        Assert-True '英文界面：错过的提醒标题' ((Format-RemindTitle 0 2) -eq '2 missed')
        $oneDayAgo = New-TaskObject 'sample created a day ago'
        $oneDayAgo.created = (Get-Date).AddDays(-1).ToString('o')
        Assert-True '英文界面：创建时长为 1 天用单数' ((Get-TaskInfo $oneDayAgo) -eq '1 day ago')
        $threeDaysAgo = New-TaskObject 'sample created three days ago'
        $threeDaysAgo.created = (Get-Date).AddDays(-3).ToString('o')
        Assert-True '英文界面：创建时长为复数天' ((Get-TaskInfo $threeDaysAgo) -eq '3 days ago')
        Assert-True '英文界面：错过分组标题用单数' ((TCount '已错过 · {0} 条' 1) -eq 'Missed · 1 reminder')
        Assert-True '英文界面：错过分组标题用复数' ((TCount '已错过 · {0} 条' 3) -eq 'Missed · 3 reminders')
        # 右键菜单/托盘菜单是代码现造的 Popup，不在视觉树里，只能在这里直接验生成结果
        $copyMenu = New-CopyContextMenu 'sample'
        Assert-True '英文界面：右键「复制内容」被翻译' ([string]$copyMenu.Items[0].Header -eq 'Copy text')
        Assert-True '英文界面：标签菜单计数括号用半角' ((Format-TagMenuLabel 'Work' 3) -eq '#Work (3)')
        Assert-True '英文界面：标签菜单用英文' ((Format-TagCreatedText 'Work') -eq 'Tag created: Work')
        Assert-True '英文界面：循环项用英文' ((T ('改为' + (Get-UnitLabel 'week') + '循环')) -eq 'Repeat weekly')
        Assert-True '英文界面：清空标签项用英文' ((T '清空这条的标签') -eq 'Clear tags on this note')
        Assert-True '英文界面：托盘菜单用英文' ((T '显示 / 隐藏') -eq 'Show / hide')
        # 筛选菜单也是 Popup，不在视觉树里：真点开一次，把每个条目的文字读出来验一遍
        # 标签名是用户内容，替换成占位符后再查残留，避免把「工作」当成漏翻
        $probeTag = @($script:Tags)[0]
        if ($null -eq $probeTag) { $probeTag = New-Tag 'ProbeTag' }
        $script:ActiveMenu = $null
        $ui['TagFilterButton'].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $filterText = ''
        if ($null -ne $script:ActiveMenu) {
          foreach ($mi in $script:ActiveMenu.Items) {
            $h = $mi.Header
            if ($h -is [string]) { $filterText += $h + '|' }
            elseif ($null -ne $h) { foreach ($child in $h.Children) { if ($child -is [System.Windows.Controls.TextBlock]) { $filterText += [string]$child.Text + '|' } } }
          }
          $script:ActiveMenu.IsOpen = $false
        }
        $script:ActiveMenu = $null
        $filterProbe = $filterText.Replace([string]$probeTag.name, 'TAG')
        Assert-True '英文界面：筛选菜单能弹出' ($filterText -ne '')
        Assert-True '英文界面：筛选菜单无中文残留' (-not ($filterProbe -match '[\u4e00-\u9fff]'))
        Assert-True '英文界面：筛选菜单计数用半角括号' ($filterProbe -match '#TAG \(\d+\)')
        # 英文模式下扫一遍视觉树，看还有多少中文残留（用户自己写的内容带 Tag=user，跳过；隐藏的不算）
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($script:Win)
        $residue = @()
        while ($queue.Count -gt 0) {
          $node = $queue.Dequeue()
          $isUser = $false
          try { $isUser = ([string]$node.Tag -eq 'user') } catch { }
          if ($isUser) { continue }
          $isUserMark = $false
          try { $isUserMark = ([string][System.Windows.Automation.AutomationProperties]::GetHelpText($node) -eq 'user') } catch { }
          if ($isUserMark) { continue }
          $hidden = $false
          try { if ($node -is [System.Windows.UIElement]) { $hidden = ($node.Visibility -ne [System.Windows.Visibility]::Visible) } } catch { }
          if ($hidden) { continue }
          $t = ''
          try {
            if ($node -is [System.Windows.Controls.TextBlock]) { $t = [string]$node.Text }
            elseif (($node -is [System.Windows.Controls.ContentControl]) -and ($node.Content -is [string])) { $t = [string]$node.Content }
          } catch { }
          if ($t -match '[\u4e00-\u9fff]') { $residue += ('{0}#{1}: {2}' -f $node.GetType().Name, $node.Name, $t) }
          $n = 0
          try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node) } catch { $n = 0 }
          for ($i = 0; $i -lt $n; $i++) { $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)) }
        }
        foreach ($line in $residue) { Write-Output ('  残留中文 | ' + $line) }
        $script:LangResidue = @($residue | Where-Object { $_ -notmatch '中文$' })
        Assert-True '英文界面没有中文残留' ($script:LangResidue.Count -eq 0)
        Close-Settings
        Switch-View 'history'
        Rebuild-All $false
        Update-LangUi
        $script:Win.UpdateLayout()
        Save-Shot 'gn_lang_en_history.png'
        Switch-View 'tasks'
        Set-AppLanguage 'zh'
        Update-Clock
        Rebuild-All $false
        Update-LangUi
        Assert-True '切回中文后版本行还原' ([string]$ui['VersionText'].Text -like '核桃便签 v*')
        Assert-True '切回中文后计数用中文' ((TCount '{0} 项' 1) -eq '1 项')
        Assert-True '切回中文后浮层标题还原' ((Format-RemindTitle 2 1) -eq '到点提醒 · 2 条（已错过 1 条）')
        Assert-True '切回中文后标签菜单用全角括号' ((Format-TagMenuLabel '工作' 3) -eq '#工作（3）')
        Assert-True '切回中文后标签提示还原' ((Format-TagCreatedText '工作') -eq '已新建标签「工作」')
        # 日志统一英文：error.log / run.log 是给排查用的，钉死英文后任何系统区域设置下都能读
        try { Remove-Item -LiteralPath $script:ErrorLog -Force -ErrorAction SilentlyContinue } catch { }
        Write-ErrorLog 'sample failure'
        $logText = ''
        try { $logText = [System.IO.File]::ReadAllText($script:ErrorLog, [System.Text.Encoding]::UTF8) } catch { }
        Assert-True '错误日志按传入内容落盘' ($logText -like '*sample failure*')
        Assert-True '错误日志不含中文' (-not ($logText -match '[\u4e00-\u9fff]'))
        $selfPath = $PSCommandPath
        $cnLog = @()
        if ($selfPath -and (Test-Path -LiteralPath $selfPath)) {
          # 唯一豁免：SettingsStatus 是界面状态文字，用 T() 包裹后由界面翻译
          $cnLog = @(Get-Content -LiteralPath $selfPath -Encoding UTF8 | Where-Object {
            ($_ -match 'Write-(ErrorLog|ToastLog)') -and ($_ -match '[\u4e00-\u9fff]') -and ($_ -notmatch 'SettingsStatus')
          })
        }
        Assert-True '源码里的日志调用没有中文文案' ($cnLog.Count -eq 0)
      } catch { Write-Output ('  语言快照失败: ' + $_.Exception.Message) }
      $script:Win.Hide()
    } catch { Write-Output ('  快照失败: ' + $_.Exception.Message) }

    # 8. 存档往返 + 锁定状态不跟随上次关闭
    Set-Locked $true
    Save-State
    $rawSaved = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.UTF8Encoding]::new($false))
    $savedObj = $rawSaved | ConvertFrom-Json
    Assert-True '锁定状态下落盘仍是 locked=false' (-not [bool]$savedObj.settings.locked)
    $script:Tasks.Clear(); $script:History.Clear(); $script:Series.Clear()
    Load-State | Out-Null
    Assert-True '重新读档后历史仍在' ($script:History.Count -ge 1)
    Assert-True '重新读档后是未锁定状态' (-not [bool]$script:Settings.locked)
    # 即便存档被人为写成 locked=true，启动也必须从未锁定开始
    $forcedObj = $rawSaved | ConvertFrom-Json
    $forcedObj.settings.locked = $true
    Normalize-LoadedState $forcedObj
    Assert-True '存档写着锁定也按未锁定启动' (-not [bool]$script:Settings.locked)
    Set-Locked $false $false
    Assert-True '其他状态照旧跟随（主题仍在）' (-not [string]::IsNullOrWhiteSpace([string]$script:Settings.theme))

    # 9. 抗损坏：原子写入 + 主文件损坏时从 notes.bak.json 抢救
    Save-State; Save-State
    Assert-True '保存后不留临时文件 .tmp' (-not (Test-Path -LiteralPath ($script:DataFile + '.tmp')))
    Assert-True '保存后留有上一版备份 notes.bak.json' (Test-Path -LiteralPath $script:BakFile)
    $bakObj = [System.IO.File]::ReadAllText($script:BakFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $expectCount = @($bakObj.tasks).Count
    Assert-True ('备份文件可解析且含条目 [' + $expectCount + ']') ($null -ne $bakObj -and [int]$bakObj.version -ge 2 -and $expectCount -ge 1)
    # 模拟断电：主文件被写成半截 JSON
    [System.IO.File]::WriteAllText($script:DataFile, '{ "version": 4, "tasks": [ { "text": "写到一半就停', [System.Text.UTF8Encoding]::new($false))
    $script:Tasks.Clear(); $script:History.Clear(); $script:Series.Clear()
    $script:RecoveredFromBackup = $false
    $recovered = Load-State
    Assert-True '主文件损坏时不会当成空库启动' ([bool]$recovered)
    Assert-True '已从 notes.bak.json 恢复数据' ([bool]$script:RecoveredFromBackup)
    Assert-True ('恢复的条目数与备份一致 [' + $script:Tasks.Count + '/' + $expectCount + ']') ($script:Tasks.Count -eq $expectCount)
    Assert-True '损坏的文件已另存取证' (@(Get-ChildItem -LiteralPath $script:DataDir -Filter 'notes.corrupt.*.json' -ErrorAction SilentlyContinue).Count -ge 1)
    $script:RecoveredFromBackup = $false
  } catch {
    Write-Output ("EXCEPTION: " + $_.Exception.ToString())
    $script:SmokeFails++
  }
  if ($script:SmokeFails -eq 0) { Write-Output 'SMOKE_ALL_PASSED' } else { Write-Output ("SMOKE_FAILED=" + $script:SmokeFails) }
  if (Test-Path -LiteralPath $script:ErrorLog) {
    Write-Output '--- error.log ---'
    Get-Content -LiteralPath $script:ErrorLog -Encoding UTF8 | ForEach-Object { Write-Output $_ }
  }
  try { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  exit 0
}

$script:App = [System.Windows.Application]::new()
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$script:App.Add_SessionEnding({
  param($sender, $eventArgs)
  try { Save-Draft; Save-State } catch { }
})
$script:App.Add_DispatcherUnhandledException({
  param($sender, $eventArgs)
  Write-ErrorLog ("UI exception: " + $eventArgs.Exception.ToString())
  $eventArgs.Handled = $true
})
$script:ClockTimer.Start()
$script:RollTimer.Start()
try {
  [void]$script:App.Run($script:Win)
} catch {
  Write-ErrorLog ("runtime exception: " + $_.Exception.ToString())
  Write-ErrorLog ("stack trace: " + $_.ScriptStackTrace)
  [System.Windows.MessageBox]::Show("核桃便签启动失败 / HetaoNotes failed to start：`n$($_.Exception.Message)`n`n日志 / log：$script:ErrorLog", '核桃便签 HetaoNotes', 'OK', 'Error') | Out-Null
} finally {
  try { $script:Mutex.ReleaseMutex() } catch { }
  try { if ($script:Source -and $script:Hook) { $script:Source.RemoveHook($script:Hook) } } catch { }
}
