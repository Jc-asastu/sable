# Describes what is on the clipboard without showing it: length and kinds of characters only.
$k = (Get-Clipboard | Out-String).Trim()
$kinds = @()
if ($k -cmatch '[a-z]') { $kinds += 'minusculas' }
if ($k -cmatch '[A-Z]') { $kinds += 'mayusculas' }
if ($k -match '[0-9]') { $kinds += 'numeros' }
if ($k -match '[-_]') { $kinds += 'guiones' }
if ($k -match '[/:.]') { $kinds += 'barras/puntos (parece URL)' }
if ($k -match '\s') { $kinds += 'espacios' }
if ($k -match '[^A-Za-z0-9/:._\-\s]') { $kinds += 'otros simbolos' }
Write-Output ("largo: {0} | tiene: {1}" -f $k.Length, ($kinds -join ', '))
$k = $null
