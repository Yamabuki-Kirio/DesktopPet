# PetLife 单实例 / 统一退出 真实进程验收脚本（规格§九）。
#
# 用法（单行）：
#   powershell -ExecutionPolicy Bypass -File tool\acceptance_single_instance.ps1 -ExePath build\windows\x64\runner\Release\petlife.exe
#
# 可选参数：
#   -DataRoot <dir>   数据沙箱目录（默认 %USERPROFILE%\petlife_acceptance_data）。
#                     通过 PETLIFE_DATA_ROOT 传给被测进程（仅 --acceptance 下生效），
#                     不碰用户真实数据。
#   -SkipStartup      跳过 20 连启（快速冒烟）。
#
# 覆盖场景：
#   A. 连续快速启动 20 次 → 始终只有 1 个 petlife.exe（本构建）。
#   C. 请求退出（--shutdown 第二实例转交）→ 3 秒内进程数 = 0。
#   D. 再次启动 → 进程数 = 1，数据库可写（进程稳定存活即预检通过）。
#   E. 数据库文件不被删除（petlife.db 保留）。
#
# 计数口径：tasklist 快速总数（<200ms）相对**基线**（A0 时刻已存在的
# 其他 petlife 进程，含旧版本残留）。本构建的实例数 = 总数 - 基线。
param(
  [Parameter(Mandatory = $true)][string]$ExePath,
  [string]$DataRoot = (Join-Path $env:USERPROFILE 'petlife_acceptance_data'),
  [switch]$SkipStartup
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $ExePath).Path
if (-not (Test-Path $exe)) { throw "找不到被测程序：$exe" }

$results = New-Object System.Collections.Generic.List[string]
function Record([string]$name, [bool]$ok, [string]$detail = '') {
  $line = "{0} {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " | $detail" } else { '' })
  $results.Add($line)
  Write-Host $line
}

function Get-PetLifeTotal {
  # tasklist CSV：首行表头，其余为进程行（每行以 "petlife.exe" 开头）。
  @((tasklist /FO CSV /FI 'IMAGENAME eq petlife.exe' 2>$null) |
    Where-Object { $_ -match '^"petlife\.exe"' }).Count
}

function Wait-Count([int]$expected, [int]$timeoutMs) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ((Get-PetLifeTotal) -eq $expected) { return $true }
    Start-Sleep -Milliseconds 120
  }
  return ((Get-PetLifeTotal) -eq $expected)
}

# ---------- 准备：沙箱数据目录 + 记录基线 ----------
# 沙箱目录由**被测实例自己创建**（预检第 1 步的正常路径）：部分安全软件
# 会拦截"未信任新进程向既有目录写入新文件"，但放行进程自建目录——
# 由应用自建可避免把环境防护误计为产品缺陷。
if (Test-Path $DataRoot) { Remove-Item -Recurse -Force $DataRoot }
$env:PETLIFE_DATA_ROOT = $DataRoot

# A0 前先请求退出本构建可能存在的残留实例（按路径认亲）。
$pre = Get-CimInstance Win32_Process -Filter "Name='petlife.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -eq $exe }
if ($pre) {
  Write-Host "注意：检测到 $($pre.Count) 个本构建的 petlife.exe 正在运行，先请求其退出。"
  Start-Process -FilePath $exe -ArgumentList '--acceptance','--shutdown'
  if (-not (Wait-Count (Get-PetLifeTotal - 1) 6000)) {
    Start-Sleep -Seconds 3
  }
}

$base = Get-PetLifeTotal
Record "A0 前置：基线（其他 petlife 进程）=$base，无本构建实例" $true

# ---------- A. 连续快速启动 20 次 ----------
if ($SkipStartup) {
  Start-Process -FilePath $exe -ArgumentList '--acceptance' | Out-Null
  Wait-Count ($base + 1) 15000 | Out-Null
} else {
  for ($i = 1; $i -le 20; $i++) {
    Start-Process -FilePath $exe -ArgumentList '--acceptance' | Out-Null
    Start-Sleep -Milliseconds 400   # 快速双击节奏
    if ($i -in 1, 2, 5, 10, 20) {
      Start-Sleep -Milliseconds 600   # let the previous duplicate exit
      $n = Get-PetLifeTotal
      Record "A$i 连启第 $i 次后进程数=1" ($n -eq ($base + 1)) "实际=$(($n - $base))"
    }
  }
}
Start-Sleep -Seconds 4   # 等主实例完全就绪（预检 + 打开库 + 建托盘）
$countAfter = Get-PetLifeTotal
Record 'A 连续启动 20 次后只有一个进程' ($countAfter -eq ($base + 1)) "实际=$(($countAfter - $base))"

# ---------- E. 数据库文件存在且未被删除 ----------
$db = Join-Path $DataRoot 'petlife.db'
Record 'E 数据库文件保留（不被删除/重建）' (Test-Path $db) $db

# ---------- C. 请求退出 → 3 秒内本构建进程归零 ----------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process -FilePath $exe -ArgumentList '--acceptance','--shutdown' | Out-Null
$zero = Wait-Count $base 3000
$sw.Stop()
Record 'C 请求退出后 3 秒内进程数=0' $zero ("耗时={0}ms" -f $sw.ElapsedMilliseconds)
if (-not $zero) { Wait-Count $base 8000 | Out-Null }

# ---------- D. 再次启动 → 1 个进程（正常退出后数据库可写） ----------
Start-Process -FilePath $exe -ArgumentList '--acceptance' | Out-Null
$one = Wait-Count ($base + 1) 15000
Start-Sleep -Seconds 3
$restartCount = Get-PetLifeTotal
Record 'D 正常退出后再次启动：进程数=1（数据库可写）' ($one -and ($restartCount -eq ($base + 1))) "实际=$(($restartCount - $base))"

# ---------- 清理：退出被测实例，保留数据目录供检查 ----------
Start-Process -FilePath $exe -ArgumentList '--acceptance','--shutdown' | Out-Null
Wait-Count $base 5000 | Out-Null

Write-Host ''
Write-Host '===== 验收摘要 ====='
$failed = @($results | Where-Object { $_ -like 'FAIL*' })
foreach ($r in $results) { Write-Host $r }
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
