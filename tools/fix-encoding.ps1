# Repair files mangled by repeated "read UTF-8 bytes as CP1251, save as UTF-8".
# Reverse pass: string -> CP1251 bytes -> decode as UTF-8.
# A pass is allowed while it does not create '?' (irreversible loss: the char
# does not exist in CP1251). The U+FEFF BOM is lost exactly that way, so the
# BOM is stripped up front and never written back.
# ASCII-only source on purpose: PowerShell 5.1 reads BOM-less .ps1 as ANSI.

param([switch]$Apply)

$cp = [System.Text.Encoding]::GetEncoding(1251)
$u8 = [System.Text.Encoding]::UTF8
$root = 'C:\dev\kadaster-buffer'

$reQ    = [regex]'\?'
# Over-decoding shows up as U+FFFD: proper cyrillic becomes one CP1251 byte
# each, which is invalid UTF-8 on the way back.
$reBad  = [regex]'\uFFFD'
$reRu   = [regex]'[\u0430-\u044F\u0451]'            # lowercase cyrillic
$reJunk = [regex]'[\u0420\u0421][\u0080-\u04FF]'    # mojibake bigrams

$targets = @()
$targets += Get-ChildItem "$root\qml"       -Recurse -Include *.qml,*.js,*.qrc -File
$targets += Get-ChildItem "$root\src"       -Recurse -Include *.cpp,*.h -File
$targets += Get-ChildItem "$root\python"    -Recurse -Include *.py -File
$targets += Get-ChildItem "$root\installer" -Recurse -Include *.iss -File
$targets += Get-ChildItem "$root\resources" -Recurse -Include *.in -File
$targets += Get-Item "$root\CMakeLists.txt"
$targets += Get-Item "$root\README.md"

$rows = @()
foreach ($f in $targets) {
    $s0 = $u8.GetString([System.IO.File]::ReadAllBytes($f.FullName))
    $hadBom = ($s0.Length -gt 0) -and ($s0[0] -eq [char]0xFEFF)
    if ($hadBom) { $s0 = $s0.Substring(1) }

    # '?' occurs legitimately in source (ternaries), so only count the surplus
    # over the untouched file; U+FFFD only ever means a pass went too far.
    $qBase = $reQ.Matches($s0).Count

    $cands = @()
    $cur = $s0
    for ($i = 0; $i -le 6; $i++) {
        if ($i -gt 0) {
            # U+FEFF has no CP1251 counterpart; drop it instead of letting it
            # decay into '?' and skew the score.
            $cur = $u8.GetString($cp.GetBytes(($cur -replace "\uFEFF", '')))
        }
        $ru   = $reRu.Matches($cur).Count
        $junk = $reJunk.Matches($cur).Count
        $bad  = [Math]::Max(0, $reQ.Matches($cur).Count - $qBase) + $reBad.Matches($cur).Count
        $cands += [pscustomobject]@{
            n = $i; s = $cur; ru = $ru; junk = $junk; bad = $bad
            score = $ru - 3 * $junk - 20 * $bad
        }
    }

    # Mangled text is itself full of lowercase cyrillic, so depth cannot be
    # chosen by cyrillic count alone - mojibake bigrams and losses outvote it.
    # Pure-ASCII files score 0 at every depth (the roundtrip is idempotent on
    # ASCII), so prefer the shallowest pass to keep the choice deterministic.
    $best = $cands |
        Sort-Object -Property @{E={$_.score};Descending=$true}, @{E={$_.n}} |
        Select-Object -First 1

    $sample = ($best.s -split "`n" | Where-Object { $reRu.IsMatch($_) } | Select-Object -First 1)
    if ($sample) {
        $sample = $sample.Trim()
        if ($sample.Length -gt 56) { $sample = $sample.Substring(0, 56) }
    } else { $sample = '(no cyrillic)' }

    $rows += [pscustomobject]@{
        File    = $f.FullName.Replace("$root\", '')
        Passes  = $best.n
        Bom     = $(if ($hadBom) { 'yes' } else { '-' })
        Cyr     = $best.ru
        Junk    = $best.junk
        Sample  = $sample
    }

    if ($Apply -and (($best.n -gt 0) -or $hadBom)) {
        [System.IO.File]::WriteAllText($f.FullName, $best.s, (New-Object System.Text.UTF8Encoding($false)))
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 200
if ($Apply) { 'FILES REWRITTEN' } else { 'dry run - nothing written' }
