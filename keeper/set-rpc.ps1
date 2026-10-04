# Loads an Alchemy API key from the clipboard into Railway as the keeper's first RPC, without
# printing it or writing it anywhere, then clears the clipboard. Copy only the key (the part after /v2/).
$k = (Get-Clipboard | Out-String).Trim()
if ($k -match '/v2/([A-Za-z0-9_-]+)') { $k = $Matches[1] }
if ($k -notmatch '^[A-Za-z0-9_-]{20,64}$') { Write-Output 'El portapapeles no tiene una API key de Alchemy. No se envio nada.'; exit 1 }
Set-Location $PSScriptRoot
$base = "https://base-mainnet.g.alchemy.com/v2/$k,https://base-rpc.publicnode.com,https://base.drpc.org,https://mainnet.base.org"
railway variables --set "BASE_RPC_URL=$base" *> $null
$ok = $LASTEXITCODE -eq 0
Set-Clipboard -Value ' '
$k = $null; $base = $null
if ($ok) { Write-Output 'listo: RPC de Alchemy cargado en Railway, portapapeles limpio' } else { Write-Output 'railway fallo; la key no se imprimio' }
