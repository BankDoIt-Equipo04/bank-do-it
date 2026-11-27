# =====================================================================
# BANKDOIT · probar_respaldo_mongo.ps1  (#58)
# Ensayo aislado del respaldo de MongoDB de análisis:
#   1. Levanta un MongoDB de ensayo (proyecto bankdoit-analytics-ensayo,
#      puerto 27018) y publica dos cortes con procesar.py.
#   2. Respalda con respaldar_mongo.ps1.
#   3. Restaura en un MongoDB limpio y sin red y compara documentos, horas
#      de corte y contenido con el original.
#   4. Simula la pérdida de la colección y la recupera en el original
#      conservando la hora de corte.
#   5. Prueba la retención con respaldos simulados de 40 días.
# No toca otro MongoDB que tengas en 27017. Evidencia:
#   ..\database\distribuido\evidencia\evidencia_respaldo_mongo.md
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$PROYECTO = 'bankdoit-analytics-ensayo'
$PUERTO = if ($env:MONGO_PUERTO) { $env:MONGO_PUERTO } else { '27018' }
$BASE = 'bankdoit_analytics'
$IMAGEN = 'mongo:7.0'
$script:fallos = 0
$filas = New-Object System.Collections.Generic.List[object]

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Verificar($ok, $prueba, $esperado, $obtenido) {
    $filas.Add([pscustomobject]@{ Prueba = $prueba; Esperado = "$esperado"; Obtenido = "$obtenido"; Ok = [bool]$ok })
    if ($ok) { Write-Host "OK    $prueba -> $obtenido" -ForegroundColor Green }
    else { Write-Host "FALLO $prueba (esperado: $esperado; obtenido: $obtenido)" -ForegroundColor Red; $script:fallos++ }
}
function M($c, $js) { (docker exec $c mongosh --quiet $BASE --eval $js 2>&1 | Select-Object -Last 1 | Out-String).Trim() }
function EsperarMongo($c) {
    for ($i = 0; $i -lt 60; $i++) {
        $r = docker exec $c mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' 2>$null
        if ("$r".Trim() -eq '1') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
# Huella del contenido: id, hora de corte y cifras clave de cada resumen.
$HUELLA = @'
print(JSON.stringify(db.resumenes.find().sort({_id: 1}).toArray().map(d => ({
  id: String(d._id), corte_utc: d.corte_utc.toISOString(), archivo: d.archivo,
  leidas: d.auditoria.leidas, validas: d.auditoria.validas,
  deportes: d.por_deporte.length, apuestas: d.por_deporte.reduce((s, x) => s + x.apuestas, 0),
  monto_centavos: d.por_deporte.reduce((s, x) => s + x.monto_centavos, 0), partidos: d.por_partido.length }))));
'@

# ------------------------------------------- 1. MongoDB de ensayo y cortes
Titulo "MongoDB de ensayo en 127.0.0.1:$PUERTO y dos cortes de procesar.py"
$env:MONGO_PUERTO = $PUERTO
docker compose -p $PROYECTO -f compose.yaml down -v 2>&1 | Out-Null
docker compose -p $PROYECTO -f compose.yaml up -d 2>&1 | Out-Null
$origen = (docker compose -p $PROYECTO -f compose.yaml ps -q mongo | Select-Object -First 1)
Verificar (EsperarMongo $origen) 'MongoDB de ensayo listo' "puerto $PUERTO" "puerto $PUERTO"

$py = '.\.venv\Scripts\python.exe'
if (-not (Test-Path $py)) {
    py -3.13 -m venv .venv
    & $py -m pip install -q -r requirements.txt 2>&1 | Out-Null
}
$env:MONGODB_URI = "mongodb://127.0.0.1:$PUERTO"
& $py procesar.py 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" }
$parcial = Join-Path $env:TEMP 'BANKDOIT_apuestas_50000.csv'
Get-Content datos\BANKDOIT_apuestas_100000.csv -TotalCount 50001 -Encoding UTF8 | Set-Content $parcial -Encoding UTF8
& $py procesar.py --csv $parcial 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" }
Remove-Item $parcial -ErrorAction SilentlyContinue
$antes = M $origen $HUELLA
# En Windows PowerShell 5.1 ConvertFrom-Json entrega la lista como un solo objeto: se enumera aparte.
$docs = @((ConvertFrom-Json $antes) | ForEach-Object { $_ })
Verificar ($docs.Count -eq 2) 'Cortes publicados en el MongoDB de ensayo' '2 resúmenes' "$($docs.Count) resúmenes ($(($docs | ForEach-Object { "$($_.archivo): $($_.validas) válidas" }) -join '; '))"

# ------------------------------------------------------- 2. respaldar
Titulo 'Respaldo con respaldar_mongo.ps1'
$env:MONGO_PROYECTO = $PROYECTO
$salida = & .\respaldar_mongo.ps1 *>&1 | ForEach-Object { "$_" }
$salida | Where-Object { $_ -notmatch '^FECHA_RESPALDO=' } | ForEach-Object { Write-Host "  $_" }
$fecha = (($salida | Where-Object { $_ -match '^FECHA_RESPALDO=' } | Select-Object -Last 1) -replace '^FECHA_RESPALDO=', '').Trim()
Verificar ([bool]$fecha) 'mongodump de bankdoit_analytics' 'respaldo generado' $(if ($fecha) { "mongo_$fecha.archive.gz" } else { 'falló' })
if (-not $fecha) { exit 1 }
$manifiesto = Get-Content "respaldos\mongo_$fecha.json" -Raw | ConvertFrom-Json
$archivo = "respaldos\mongo_$fecha.archive.gz"

# --------------------------------------------- 3. restaurar en limpio
Titulo 'Restauración en un MongoDB limpio y sin red'
$limpio = 'ensayo-mongo-restauracion'
docker rm -f $limpio 2>$null | Out-Null
docker run -d --name $limpio --network none $IMAGEN 2>&1 | Out-Null
Verificar (EsperarMongo $limpio) 'Arranque del MongoDB limpio' 'listo' 'listo'
$sha = (Get-FileHash $archivo -Algorithm SHA256).Hash.ToLower()
Verificar ($sha -eq $manifiesto.sha256) 'Integridad del archivo' 'sha256 igual al manifiesto' "$($sha.Substring(0, 12))…"
docker cp $archivo "${limpio}:/tmp/respaldo.archive.gz" 2>&1 | Out-Null
$r = docker exec $limpio mongorestore --quiet --gzip --archive=/tmp/respaldo.archive.gz 2>&1 | Out-String
Verificar ($LASTEXITCODE -eq 0) 'mongorestore' 'sin errores' $(if ($LASTEXITCODE -eq 0) { 'sin errores' } else { $r.Trim() })
$restaurado = M $limpio $HUELLA
Verificar ($restaurado -eq $antes) 'Contenido restaurado igual al original' 'mismos documentos, cortes y cifras' $(if ($restaurado -eq $antes) { "$($docs.Count) resúmenes idénticos" } else { $restaurado })
$cortes = ($manifiesto.colecciones.resumenes.cortes | ForEach-Object { $_.corte_utc }) -join ', '
$cortesR = (@((ConvertFrom-Json $restaurado) | ForEach-Object { $_ }) | ForEach-Object { $_.corte_utc }) -join ', '
Verificar ($cortes -eq $cortesR) 'Horas de corte conservadas' $cortes $cortesR
docker rm -f $limpio 2>$null | Out-Null

# ------------------------------------ 4. pérdida y recuperación en el original
Titulo 'Pérdida de la colección y recuperación en el MongoDB original'
M $origen 'db.resumenes.drop(); print(db.resumenes.countDocuments())' | Out-Null
$vacio = M $origen 'print(db.resumenes.countDocuments())'
Write-Host "  Se borró la colección resumenes ($vacio documentos)." -ForegroundColor Yellow
docker cp $archivo "${origen}:/tmp/respaldo.archive.gz" 2>&1 | Out-Null
docker exec $origen mongorestore --quiet --gzip --drop --archive=/tmp/respaldo.archive.gz 2>&1 | Out-Null
docker exec $origen rm -f /tmp/respaldo.archive.gz | Out-Null
$recuperado = M $origen $HUELLA
Verificar ($vacio -eq '0' -and $recuperado -eq $antes) 'Colección recuperada tras borrarla' 'mismos resúmenes y horas de corte' $(if ($recuperado -eq $antes) { "$($docs.Count) resúmenes recuperados" } else { $recuperado })
# procesar.py conserva el primer corte de cada archivo: tras restaurar, reprocesar no lo cambia.
& $py procesar.py 2>&1 | Out-Null
$despues = M $origen $HUELLA
Verificar ($despues -eq $antes) 'Reprocesar el CSV después de restaurar' 'conserva la hora de corte original' $(if ($despues -eq $antes) { 'sin cambios' } else { $despues })

# ---------------------------------------------------------- 5. retención
Titulo 'Retención con 40 días de respaldos simulados'
$reales = Get-ChildItem respaldos -Filter 'mongo_*' | Select-Object -ExpandProperty Name
$hoy = Get-Date
foreach ($d in 1..40) {
    $f = $hoy.AddDays(-$d).ToString('yyyyMMdd')
    foreach ($h in '020000', '140000') {
        Set-Content "respaldos\mongo_$f-$h.archive.gz" 'simulado'
        Set-Content "respaldos\mongo_$f-$h.json" '{}'
    }
}
& .\respaldar_mongo.ps1 *>&1 | Out-Null
$quedan = Get-ChildItem respaldos -Filter 'mongo_*.archive.gz' | Sort-Object Name -Descending
$dias = $quedan | ForEach-Object { $_.Name.Substring(6, 8) } | Sort-Object -Unique -Descending
$ultimos7 = 0..6 | ForEach-Object { $hoy.AddDays(-$_).ToString('yyyyMMdd') }
$huerfanos = Get-ChildItem respaldos -Filter 'mongo_*.json' | Where-Object { -not (Test-Path ($_.FullName -replace '\.json$', '.archive.gz')) }
Verificar (@($ultimos7 | Where-Object { $dias -contains $_ }).Count -eq 7) 'Conserva los 7 días más recientes' '7 días' "$(@($ultimos7 | Where-Object { $dias -contains $_ }).Count) días"
Verificar ($quedan.Count -ge 7 -and $quedan.Count -le 11 -and @($quedan | Group-Object { $_.Name.Substring(6, 8) } | Where-Object Count -gt 1).Count -eq 0) 'Uno por día y semanales de 4 semanas' '7 a 11, uno por día' "$($quedan.Count): $($dias -join ', ')"
Verificar ($huerfanos.Count -eq 0) 'Manifiestos borrados junto con su respaldo' '0 sueltos' "$($huerfanos.Count) sueltos"
# Quita los simulados (los reales de hoy se conservan).
Get-ChildItem respaldos -Filter 'mongo_*' | Where-Object { (Get-Content $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -in 'simulado', '{}' } | Remove-Item

docker compose -p $PROYECTO -f compose.yaml down -v 2>&1 | Out-Null

# ---------------------------------------------------------- evidencia
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Evidencia: respaldo y restauración de MongoDB (#58)'); $md.Add('')
$md.Add("Generado por ``analytics/probar_respaldo_mongo.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm') con un MongoDB de ensayo aislado (proyecto ``$PROYECTO``, puerto $PUERTO).")
$md.Add(''); $md.Add("Respaldo ``mongo_$fecha.archive.gz`` ($($manifiesto.bytes) bytes, sha256 ``$($manifiesto.sha256.Substring(0, 12))…``) de la base ``$BASE``:"); $md.Add('')
$md.Add('| Resumen (sha256 del CSV) | Archivo | Hora de corte (UTC) | Filas leídas | Válidas | Apuestas | Monto (centavos) | Partidos |'); $md.Add('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |')
foreach ($d in $docs) { $md.Add("| ``$($d.id.Substring(0, 12))…`` | $($d.archivo) | $($d.corte_utc) | $($d.leidas) | $($d.validas) | $($d.apuestas) | $($d.monto_centavos) | $($d.partidos) |") }
$md.Add(''); $md.Add('## Comprobaciones'); $md.Add('')
$md.Add('| Prueba | Esperado | Obtenido | |'); $md.Add('| --- | --- | --- | --- |')
foreach ($f in $filas) { $md.Add("| $($f.Prueba) | $($f.Esperado -replace '\|', '/') | $($f.Obtenido -replace '\|', '/') | $(if ($f.Ok) { '✔' } else { '✘' }) |") }
$destino = '..\database\distribuido\evidencia\evidencia_respaldo_mongo.md'
$md | Out-File -Encoding utf8 $destino

Write-Host ''
Write-Host "Evidencia guardada en $destino"
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
