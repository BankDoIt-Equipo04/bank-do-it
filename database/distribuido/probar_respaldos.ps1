# =====================================================================
# BANKDOIT · probar_respaldos.ps1  (#57)
# Sobre una instalación levantada y configurada (levantar_y_probar.ps1 +
# configurar_acceso_api.ps1):
#   1. Respalda ambos fragmentos con respaldar.ps1.
#   2. Restaura cada respaldo lógico en un PostgreSQL limpio y aislado y
#      compara conteos, saldos, restricciones y triggers con el manifiesto.
#   3. Recuperación a un punto en el tiempo (PITR): registra una apuesta
#      válida, marca un punto de restauración, comete un error (suspender
#      todas las cuentas) y recupera el respaldo físico + WAL justo antes
#      del error.
#   4. Prueba la retención con respaldos simulados de 40 días.
# Evidencia: evidencia\evidencia_respaldos.md
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }
$respaldos = (Resolve-Path .\respaldos).Path
$IMAGEN = 'postgres:16.4'
$script:fallos = 0
$filas = New-Object System.Collections.Generic.List[object]

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Q($c, $sql) {
    $s = docker exec $c psql -U $usuarioBD -d $baseBD -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    (($s | ForEach-Object { "$_" }) -join "`n").Trim()
}
function QL($c, $sql) {   # contenedor de restauración (usuario postgres, base bankdoit)
    $s = docker exec $c psql -U postgres -d bankdoit -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    (($s | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Verificar($ok, $seccion, $prueba, $esperado, $obtenido) {
    $filas.Add([pscustomobject]@{ Seccion = $seccion; Prueba = $prueba; Esperado = "$esperado"; Obtenido = "$obtenido"; Ok = [bool]$ok })
    if ($ok) { Write-Host "OK    $prueba -> $obtenido" -ForegroundColor Green }
    else { Write-Host "FALLO $prueba (esperado: $esperado; obtenido: $obtenido)" -ForegroundColor Red; $script:fallos++ }
}
function EsperarListo($c, $usuario = 'postgres', $segundos = 120) {
    $limite = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $limite) {
        docker exec $c pg_isready -q -U $usuario 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            docker exec $c psql -U $usuario -d postgres -tAqc 'SELECT 1' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    docker logs --tail 30 $c
    return $false
}

# Primarios actuales.
$primarios = @{}
foreach ($n in 'nodo-a-primario-impar', 'nodo-b-primario-par', 'nodo-a-replica-par', 'nodo-b-replica-impar', 'nodo-b-replica-par') {
    $c = "$P$n"
    if ("$(docker inspect -f '{{.State.Running}}' $c 2>$null)".Trim() -ne 'true') { continue }
    if ((Q $c 'SELECT pg_is_in_recovery()') -eq 'f') { $primarios[(Q $c 'SELECT nombre FROM fragmento_local')] = $c }
}
if (-not $primarios.impar -or -not $primarios.par) { Write-Host 'Se necesitan los dos primarios corriendo.' -ForegroundColor Red; exit 1 }
foreach ($c in $primarios.Values) {
    Verificar ((Q $c 'SHOW archive_mode') -eq 'on') 'Configuración' "Archivado de WAL en $c" 'archive_mode = on' "archive_mode = $(Q $c 'SHOW archive_mode')"
}

# ---------------------------------------------------- 1. respaldar
Titulo 'Respaldo de ambos fragmentos'
$salida = & .\respaldar.ps1 *>&1 | ForEach-Object { "$_" }
$salida | Where-Object { $_ -notmatch '^FECHA_RESPALDO=' } | ForEach-Object { Write-Host "  $_" }
$fecha = (($salida | Where-Object { $_ -match '^FECHA_RESPALDO=' } | Select-Object -Last 1) -replace '^FECHA_RESPALDO=', '').Trim()
Verificar ([bool]$fecha) 'Respaldo' 'respaldar.ps1 en ambos fragmentos' 'respaldo generado' $(if ($fecha) { "respaldo $fecha" } else { 'falló' })
if (-not $fecha) { exit 1 }
$manifiestos = @{}
foreach ($frag in 'impar', 'par') { $manifiestos[$frag] = Get-Content "respaldos\manifiestos\${frag}_$fecha.json" -Raw | ConvertFrom-Json }

# ------------------------------------- 2. restaurar respaldos lógicos
Titulo 'Restauración lógica en un PostgreSQL limpio y aislado (sin red)'
foreach ($frag in 'impar', 'par') {
    $m = $manifiestos[$frag]
    $c = "${P}restauracion-$frag"
    docker rm -f $c 2>$null | Out-Null
    docker run -d --name $c --network none -e POSTGRES_PASSWORD=solo_para_restaurar -e POSTGRES_DB=bankdoit `
        -v "${respaldos}:/respaldos:ro" $IMAGEN 2>&1 | Out-Null
    if (-not (EsperarListo $c)) { Verificar $false "Restauración $frag" 'Arranque del contenedor limpio' 'listo' 'no arrancó'; continue }
    $sha = (docker exec $c sha256sum "/respaldos/$($m.logico)" 2>&1 | Out-String).Substring(0, 64)
    Verificar ($sha -eq $m.logico_sha256) "Restauración $frag" "Integridad del archivo ($frag)" 'sha256 igual al manifiesto' "$($sha.Substring(0, 12))…"
    $r = docker exec $c pg_restore -U postgres -d bankdoit --no-owner --no-privileges --exit-on-error "/respaldos/$($m.logico)" 2>&1 | ForEach-Object { "$_" }
    Verificar ($LASTEXITCODE -eq 0) "Restauración $frag" "pg_restore del respaldo $frag" 'sin errores' $(if ($LASTEXITCODE -eq 0) { 'sin errores' } else { ($r | Select-Object -First 2) -join ' ' })
    $obt = (QL $c ("SELECT json_build_object('usuario', (SELECT count(*) FROM usuario), 'bankroll', (SELECT count(*) FROM bankroll), " +
        "'apuesta', (SELECT count(*) FROM apuesta), 'movimiento', (SELECT count(*) FROM movimiento), 'partido', (SELECT count(*) FROM partido), " +
        "'saldo_total', (SELECT COALESCE(sum(saldo_disponible), 0) FROM bankroll), 'en_juego_total', (SELECT COALESCE(sum(monto_en_juego), 0) FROM bankroll), " +
        "'restricciones', (SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public'), " +
        "'triggers', (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal))")) | ConvertFrom-Json
    $esp = $m.conteos
    $texto = { param($x) "usuarios $($x.usuario), bankrolls $($x.bankroll), apuestas $($x.apuesta), movimientos $($x.movimiento), partidos $($x.partido)" }
    Verificar ((& $texto $obt) -eq (& $texto $esp)) "Restauración $frag" "Conteos restaurados ($frag)" (& $texto $esp) (& $texto $obt)
    Verificar ([decimal]$obt.saldo_total -eq [decimal]$esp.saldo_total -and [decimal]$obt.en_juego_total -eq [decimal]$esp.en_juego_total) `
        "Restauración $frag" "Saldos restaurados ($frag)" "disponible $($esp.saldo_total) / en juego $($esp.en_juego_total)" "disponible $($obt.saldo_total) / en juego $($obt.en_juego_total)"
    Verificar ($obt.restricciones -eq $esp.restricciones -and $obt.triggers -eq $esp.triggers) "Restauración $frag" "Llaves, restricciones y triggers ($frag)" `
        "$($esp.restricciones) restricciones, $($esp.triggers) triggers" "$($obt.restricciones) restricciones, $($obt.triggers) triggers"
    $cuadra = QL $c 'SELECT bool_and(cuadra) FROM conciliar_bankroll()'
    Verificar ($cuadra -eq 't') "Restauración $frag" "Conciliación tras restaurar ($frag)" 'todos los bankrolls cuadran' $(if ($cuadra -eq 't') { 'todos cuadran' } else { $cuadra })
    docker rm -f $c 2>$null | Out-Null
}

# -------------------------------------- 3. recuperación a un punto (PITR)
Titulo 'Recuperación a un punto en el tiempo en el fragmento impar'
$A = $primarios.impar
$sello = Get-Date -Format 'HHmmss'
$usuarioImpar = Q $A 'SELECT min(usuario_id) FROM bankroll WHERE saldo_disponible >= 10'
$apuesta = Q $A "SELECT apuesta_id FROM registrar_apuesta($usuarioImpar, 'pitr-buena-$sello', 101, 'América', 10.00, 2.00)"
Write-Host "  Operación válida: apuesta $apuesta del usuario $usuarioImpar (clave pitr-buena-$sello)."
$activasAntes = Q $A "SELECT count(*) FROM cuenta WHERE estado = 'activa'"
$punto = "antes_del_error_$sello"
Q $A "SELECT pg_create_restore_point('$punto')" | Out-Null
Write-Host "  Punto de restauración: $punto ($activasAntes cuentas activas)."
$ids = Q $A "SELECT string_agg(usuario_id::text, ',') FROM cuenta WHERE estado = 'activa'"
Q $A "UPDATE cuenta SET estado = 'suspendida' WHERE estado = 'activa'" | Out-Null
$activasError = Q $A "SELECT count(*) FROM cuenta WHERE estado = 'activa'"
Write-Host "  Error simulado: el administrador suspendió todas las cuentas ($activasError activas)." -ForegroundColor Yellow
$segmento = Q $A 'SELECT pg_walfile_name(pg_switch_wal())'
$limite = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $limite -and -not (Test-Path "respaldos\wal\impar\$segmento")) { Start-Sleep -Seconds 2 }
Verificar (Test-Path "respaldos\wal\impar\$segmento") 'PITR' 'WAL con el error archivado' $segmento $(if (Test-Path "respaldos\wal\impar\$segmento") { "$segmento archivado" } else { 'no se archivó' })

$c = "${P}restauracion-pitr"
docker rm -f $c 2>$null | Out-Null
$base = "/respaldos/base/impar/$fecha"
$arranque = @"
set -e
mkdir -p "`$PGDATA" && cd "`$PGDATA"
tar xzf $base/base.tar.gz
tar xzf $base/pg_wal.tar.gz -C pg_wal
cat >> postgresql.auto.conf <<CONF
restore_command = 'cp /respaldos/wal/impar/%f %p'
recovery_target_name = '$punto'
recovery_target_action = 'promote'
CONF
touch recovery.signal
chmod 700 "`$PGDATA"
exec postgres -c synchronous_standby_names= -c archive_mode=off -c ssl=off -c listen_addresses=
"@
docker run -d --name $c --network none -u postgres -v "${respaldos}:/respaldos:ro" --entrypoint bash $IMAGEN -c $arranque 2>&1 | Out-Null
$listo = $false
$limite = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $limite) {
    $r = docker exec $c psql -U $usuarioBD -d $baseBD -tAqc 'SELECT pg_is_in_recovery()' 2>$null
    if ("$r".Trim() -eq 'f') { $listo = $true; break }
    Start-Sleep -Seconds 2
}
$logs = docker logs $c 2>&1 | Out-String
Verificar $listo 'PITR' 'Recuperación del respaldo físico + WAL' 'promovida en el punto marcado' $(if ($listo) { 'recuperación completa' } else { 'no terminó' })
Verificar ($logs -match "recovery stopping at restore point `"$punto`"") 'PITR' 'Se detuvo en el punto de restauración' $punto $(if ($logs -match 'recovery stopping at restore point "([^"]+)"') { $Matches[1] } else { 'sin mensaje' })
if ($listo) {
    $q = { param($s) (docker exec $c psql -U $usuarioBD -d $baseBD -tAqc $s 2>&1 | Out-String).Trim() }
    $buena = & $q "SELECT count(*) FROM apuesta WHERE clave_operacion = 'pitr-buena-$sello'"
    $activas = & $q "SELECT count(*) FROM cuenta WHERE estado = 'activa'"
    Verificar ($buena -eq '1') 'PITR' 'La apuesta válida (antes del punto) existe' '1 apuesta' "$buena apuesta"
    Verificar ($activas -eq $activasAntes) 'PITR' 'Las cuentas quedan como antes del error' "$activasAntes activas" "$activas activas"
    Verificar ((& $q 'SELECT bool_and(cuadra) FROM conciliar_bankroll()') -eq 't') 'PITR' 'Conciliación en la base recuperada' 'todos cuadran' (& $q 'SELECT bool_and(cuadra) FROM conciliar_bankroll()')
}
docker rm -f $c 2>$null | Out-Null

# Deshace el error en la instalación de ensayo (se reactivan solo las que estaban activas).
if ($ids) { Q $A "UPDATE cuenta SET estado = 'activa' WHERE usuario_id IN ($ids)" | Out-Null }
Verificar ((Q $A "SELECT count(*) FROM cuenta WHERE estado = 'activa'") -eq $activasAntes) 'PITR' 'Instalación de ensayo devuelta a su estado' "$activasAntes activas" "$(Q $A "SELECT count(*) FROM cuenta WHERE estado = 'activa'") activas"

# -------------------------------------------------------- 4. retención
Titulo 'Retención con 40 días de respaldos simulados'
$prueba = 'respaldos\prueba_retencion'
Remove-Item -Recurse -Force $prueba -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $prueba | Out-Null
$hoy = Get-Date
foreach ($d in 0..39) {
    $f = $hoy.AddDays(-$d).ToString('yyyyMMdd')
    foreach ($h in '020000', '140000') {
        New-Item -ItemType File "$prueba\bankdoit_impar_$f-$h.dump" | Out-Null
        New-Item -ItemType File "$prueba\roles_impar_$f-$h.sql" | Out-Null
    }
}
$r = docker exec -u postgres $primarios.impar bash /scripts/respaldar.sh --retencion /respaldos/prueba_retencion impar 2>&1 | Out-String
$quedan = Get-ChildItem $prueba -Filter 'bankdoit_*.dump' | Sort-Object Name -Descending
$dias = $quedan | ForEach-Object { $_.Name.Substring(15, 8) } | Sort-Object -Unique -Descending
$ultimos7 = 0..6 | ForEach-Object { $hoy.AddDays(-$_).ToString('yyyyMMdd') }
$huerfanos = Get-ChildItem $prueba -Filter 'roles_*.sql' | Where-Object { -not (Test-Path ("$prueba\bankdoit_" + $_.BaseName.Substring(6) + '.dump')) }
Verificar (@($ultimos7 | Where-Object { $dias -contains $_ }).Count -eq 7) 'Retención' 'Conserva los 7 días más recientes' '7 días' "$(@($ultimos7 | Where-Object { $dias -contains $_ }).Count) días"
Verificar ($quedan.Count -ge 7 -and $quedan.Count -le 11 -and @($quedan | Group-Object { $_.Name.Substring(15, 8) } | Where-Object Count -gt 1).Count -eq 0) 'Retención' 'Uno por día y semanales de 4 semanas' '7 a 11 respaldos, uno por día' "$($quedan.Count) respaldos: $($dias -join ', ')"
Verificar ($huerfanos.Count -eq 0) 'Retención' 'Los roles se borran junto con su respaldo' '0 archivos sueltos' "$($huerfanos.Count) sueltos"
Remove-Item -Recurse -Force $prueba -ErrorAction SilentlyContinue

# --------------------------------------------------------- evidencia
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Evidencia: respaldo y restauración de PostgreSQL (#57)'); $md.Add('')
$md.Add("Generado por ``database/distribuido/probar_respaldos.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm') sobre la simulación de dos nodos (proyecto ``$PROYECTO``).")
$md.Add(''); $md.Add("## Respaldo $fecha"); $md.Add('')
$md.Add('| Fragmento | Primario | Respaldo lógico | Respaldo físico | WAL archivado | Usuarios / apuestas / movimientos | Retención |'); $md.Add('| --- | --- | --- | --- | ---: | --- | --- |')
foreach ($frag in 'impar', 'par') {
    $m = $manifiestos[$frag]
    $md.Add(("| {0} | ``{1}`` | ``{2}`` ({3:N0} B, sha256 ``{4}…``) | ``{5}`` ({6:N0} B) | {7} | {8} / {9} / {10} | {11} |" -f $frag, $m.instancia, $m.logico, $m.logico_bytes, $m.logico_sha256.Substring(0, 12), $m.fisico, $m.fisico_bytes, $m.wal_archivados, $m.conteos.usuario, $m.conteos.apuesta, $m.conteos.movimiento, $m.retencion))
}
$md.Add(''); $md.Add('## Recuperación a un punto en el tiempo'); $md.Add('')
$md.Add("1. Apuesta válida ``pitr-buena-$sello`` (usuario $usuarioImpar)."); $md.Add("2. ``SELECT pg_create_restore_point('$punto')`` con $activasAntes cuentas activas.")
$md.Add("3. Error simulado: ``UPDATE cuenta SET estado = 'suspendida'`` (quedaron $activasError activas)."); $md.Add("4. Recuperación en un contenedor aislado con ``base/impar/$fecha`` + ``wal/impar`` y ``recovery_target_name = '$punto'``.")
$md.Add(''); $md.Add('## Comprobaciones'); $md.Add('')
$md.Add('| Sección | Prueba | Esperado | Obtenido | |'); $md.Add('| --- | --- | --- | --- | --- |')
foreach ($f in $filas) { $md.Add("| $($f.Seccion) | $($f.Prueba) | $($f.Esperado -replace '\|', '/') | $($f.Obtenido -replace '\|', '/') | $(if ($f.Ok) { '✔' } else { '✘' }) |") }
New-Item -ItemType Directory -Force evidencia | Out-Null
$md | Out-File -Encoding utf8 evidencia\evidencia_respaldos.md

Write-Host ''
Write-Host 'Evidencia guardada en evidencia\evidencia_respaldos.md'
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
