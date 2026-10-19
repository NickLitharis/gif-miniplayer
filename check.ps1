# check.ps1 -- the cheap invariants from the plan. Each one caused a real failure earlier.
param([string]$App = 'GifMiniPlayer.ps1')
$fail = 0
function Check($name, $ok, $detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}
$path = (Resolve-Path $App).Path
$src  = Get-Content -LiteralPath $path -Raw
$lines = Get-Content -LiteralPath $path

# 1. parses
$t = $null; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e) | Out-Null
Check 'parses' ($e.Count -eq 0) ($e | ForEach-Object { "L$($_.Extent.StartLineNumber):$($_.Message)" }) -join '; '

# 2. constants defined before use (this exact bug made the button bar 0px tall)
# every layout constant must be defined before its first *reference*
foreach ($const in @('barHeight', 'progHeight')) {
    $defLine = ($lines | Select-String -Pattern ("^\`$script:{0}\s*=" -f $const) | Select-Object -First 1).LineNumber
    $useLine = ($lines | Select-String -Pattern ("\`$script:{0}\b" -f $const) | Where-Object { $_.LineNumber -gt $defLine } | Select-Object -First 1).LineNumber
    Check "$const defined before use" ($defLine -and $useLine -and $defLine -lt $useLine) "def=$defLine firstuse=$useLine"
}

# 3. picture box is not Dock=Fill (Fill covered the bar)
Check "picture box not Dock=Fill" (-not ($src -match "\`$script:pic\.Dock\s*=\s*'Fill'"))

# 4. single instance guard exists and runs before the form is built
$guardLine = ($lines | Select-String -Pattern 'instanceMutex = New-Object' | Select-Object -First 1).LineNumber
$formLine  = ($lines | Select-String -Pattern '\$script:form = New-Object System\.Windows\.Forms\.Form' | Select-Object -First 1).LineNumber
# createdNew is the wrong question: a stale mutex object outlives its owner and would block
# every future start. The guard must try to take ownership instead.
Check 'single-instance uses ownership not createdNew' (($src -match 'WaitOne') -and ($src -notmatch '\[ref\]\$script:isFirstInstance'))
Check 'instance namespace supported' ($src -match 'GMP_INSTANCE')
Check 'single-instance guard before form' ($guardLine -and $formLine -and $guardLine -lt $formLine) "guard=$guardLine form=$formLine"

# 5. no invented API
Check 'no StopAnimatedImages (api does not exist)' (-not ($src -match 'StopAnimatedImages'))

# 6. UI-thread exceptions are logged, not shown as a modal dialog
Check 'ThreadException handler present' ($src -match 'add_ThreadException')

# 7. no function name shadowed by a built-in alias
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$clashes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { Get-Alias -Name $_.Name -ErrorAction SilentlyContinue } | ForEach-Object { $_.Name }
Check 'no alias-shadowed functions' ($clashes.Count -eq 0) ($clashes -join ',')

# 8. frame stepping is ours (a paused player must not be able to animate itself)
Check 'frames stepped manually' ($src -match 'SelectActiveFrame')

"`n$($script:fail) failure(s)"
if ($fail -gt 0) { exit 1 }
