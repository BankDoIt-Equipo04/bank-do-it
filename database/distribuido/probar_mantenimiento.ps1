# =====================================================================
# BANKDOIT · probar_mantenimiento.ps1  (#56)
# Prueba el procedimiento mantenimiento_diario() sobre una instalación ya
# levantada y con el acceso de la API configurado:
#   levantar_y_probar.ps1  ->  configurar_acceso_api.ps1  ->  este script
# Guarda la evidencia en evidencia\evidencia_mantenimiento.md.
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$A_PRIM = "${P}nodo-a-primario-impar"; $A_REPL = "${P}nodo-a-replica-par"
$B_PRIM = "${P}nodo-b-primario-par";   $B_REPL = "${P}nodo-b-replica-impar"
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }
$script:fallos = 0
$filas = New-Object System.Collections.Generic.List[object]

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Q($c, $sql, $usuario = $usuarioBD) {
    $s = docker exec $c psql -U $usuario -d $baseBD -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    (($s | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Verificar($ok, $prueba, $esperado, $obtenido) {
    $filas.Add([pscustomobject]@{ Prueba = $prueba; Esperado = $esperado; Obtenido = $obtenido; Ok = [bool]$ok })
    if ($ok) { Write-Host "OK    $prueba -> $obtenido" -ForegroundColor Green }
    else { Write-Host "FALLO $prueba (esperado: $esperado; obtenido: $obtenido)" -ForegroundColor Red; $script:fallos++ }
}

foreach ($c in @($A_PRIM, $B_PRIM, $A_REPL, $B_REPL)) {
    if ("$(docker inspect -f '{{.State.Running}}' $c 2>$null)".Trim() -ne 'true') {
        Write-Host "El contenedor $c no está corriendo. Ejecuta antes levantar_y_probar.ps1 y configurar_acceso_api.ps1." -ForegroundColor Red; exit 1
    }
}
if ((Q $A_PRIM "SELECT to_regclass('public.sesion') IS NOT NULL") -ne 't') {
    Write-Host 'Falta el directorio de cuentas. Ejecuta antes configurar_acceso_api.ps1.' -ForegroundColor Red; exit 1
}

# ------------------------------------------------------ 1. instalación
Titulo 'Instalar el procedimiento dos veces (idempotente)'
$bitacoraAntes = @{}
foreach ($vuelta in 1, 2) {
    foreach ($c in $A_PRIM, $B_PRIM) {
        $s = docker exec $c psql -U $usuarioBD -d $baseBD -X -q -v ON_ERROR_STOP=1 -f /scripts/22_mantenimiento.sql 2>&1 | ForEach-Object { "$_" }
        if ($vuelta -eq 1) { $bitacoraAntes[$c] = Q $c 'SELECT count(*) FROM bitacora_mantenimiento' }
        else { Verificar ($LASTEXITCODE -eq 0) "Instalar de nuevo en $c" 'sin errores' $(if ($LASTEXITCODE -eq 0) { 'sin errores' } else { $s -join ' ' }) }
    }
}
foreach ($c in $A_PRIM, $B_PRIM) {
    $n = Q $c 'SELECT count(*) FROM bitacora_mantenimiento'
    Verificar ($n -eq $bitacoraAntes[$c]) "La reinstalación conserva la bitácora de $c" "$($bitacoraAntes[$c]) registros" "$n registros"
}
Verificar ((Q $A_PRIM "SELECT prokind FROM pg_proc WHERE proname = 'mantenimiento_diario'") -eq 'p') 'Es un procedimiento (pg_proc.prokind)' 'p' (Q $A_PRIM "SELECT prokind FROM pg_proc WHERE proname = 'mantenimiento_diario'")

# --------------------------------------------- 2. preparar el escenario
Titulo 'Preparar sesiones vencidas y un bankroll descuadrado'
$uid = Q $A_PRIM "SELECT usuario_id FROM cuenta WHERE estado = 'activa' ORDER BY usuario_id LIMIT 1"
if (-not $uid) {
    $uid = Q $A_PRIM "SELECT registrar_cuenta('mantenimiento_demo', decode(md5(random()::text), 'hex'), sha256(convert_to(random()::text, 'UTF8')))"
    Q $A_PRIM "SELECT activar_cuenta($uid)" | Out-Null
}
Q $A_PRIM "INSERT INTO sesion (huella, usuario_id, vence, creada_en)
           SELECT sha256(convert_to('vencida-' || g || '-' || clock_timestamp(), 'UTF8')), $uid,
                  now() - interval '1 hour', now() - interval '2 days'
             FROM generate_series(1, 2500) g;
           INSERT INTO sesion (huella, usuario_id, vence)
           SELECT sha256(convert_to('vigente-' || g || '-' || clock_timestamp(), 'UTF8')), $uid, now() + interval '1 day'
             FROM generate_series(1, 3) g" | Out-Null
$vencidasAntes = Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence <= now()'
$vigentesAntes = Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence > now()'
Write-Host "  Primario impar: $vencidasAntes sesiones vencidas y $vigentesAntes vigentes (cuenta $uid)."

# Descuadre simulado: el administrador salta el trigger que protege el
# saldo, como si el dato se hubiera dañado por fuera de las funciones.
$uPar = Q $B_PRIM 'SELECT min(usuario_id) FROM bankroll'
Q $B_PRIM "BEGIN; ALTER TABLE bankroll DISABLE TRIGGER trg_bankroll_proteger;
           UPDATE bankroll SET saldo_disponible = saldo_disponible + 1 WHERE usuario_id = $uPar;
           ALTER TABLE bankroll ENABLE TRIGGER trg_bankroll_proteger; COMMIT" | Out-Null
Write-Host "  Primario par: se alteró a mano el saldo del usuario $uPar (+1.00) para simular un descuadre."

# ----------------------------------------------------- 3. ejecutar
Titulo 'CALL mantenimiento_diario() en cada primario'
$salidaA = docker exec $A_PRIM psql -U $usuarioBD -d $baseBD -X -c 'CALL mantenimiento_diario(1000)' 2>&1 | ForEach-Object { "$_" }
$okA = $LASTEXITCODE -eq 0
$salidaB = docker exec $B_PRIM psql -U $usuarioBD -d $baseBD -X -c 'CALL mantenimiento_diario()' 2>&1 | ForEach-Object { "$_" }
$okB = $LASTEXITCODE -eq 0
$salidaA + $salidaB | Where-Object { $_ -match 'NOTICE|WARNING' } | ForEach-Object { Write-Host "  $_" }
Verificar ($okA -and $okB) 'CALL en ambos primarios' 'sin errores' $(if ($okA -and $okB) { 'sin errores' } else { ($salidaA + $salidaB) -join ' ' })

$ultA = Q $A_PRIM "SELECT sesiones_eliminadas || '|' || lotes || '|' || bankrolls_revisados || '|' || bankrolls_descuadrados FROM bitacora_mantenimiento ORDER BY ejecucion_id DESC LIMIT 1"
$ultB = Q $B_PRIM "SELECT sesiones_eliminadas || '|' || lotes || '|' || bankrolls_revisados || '|' || bankrolls_descuadrados || '|' || (descuadres -> 0 ->> 'usuario_id') FROM bitacora_mantenimiento ORDER BY ejecucion_id DESC LIMIT 1"
$a = $ultA -split '\|'; $b = $ultB -split '\|'
Verificar ((Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence <= now()') -eq '0') 'Sesiones vencidas tras el CALL (impar)' '0' (Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence <= now()')
Verificar ((Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence > now()') -eq $vigentesAntes) 'Sesiones vigentes conservadas (impar)' $vigentesAntes (Q $A_PRIM 'SELECT count(*) FROM sesion WHERE vence > now()')
Verificar ([int]$a[0] -eq [int]$vencidasAntes -and [int]$a[1] -eq [math]::Ceiling([int]$vencidasAntes / 1000)) 'Bitácora impar: sesiones y lotes de 1000' "$vencidasAntes sesiones en $([math]::Ceiling([int]$vencidasAntes / 1000)) lotes" "$($a[0]) sesiones en $($a[1]) lotes"
Verificar ($a[3] -eq '0') 'Bitácora impar: bankrolls descuadrados' "0 de $($a[2])" "$($a[3]) de $($a[2])"
Verificar ($b[0] -eq '0' -and $b[1] -eq '0') 'Bitácora par: sin tabla de sesiones' '0 sesiones, 0 lotes' "$($b[0]) sesiones, $($b[1]) lotes"
Verificar ($b[3] -eq '1' -and $b[4] -eq $uPar) 'Bitácora par: detecta el descuadre simulado' "1 descuadre (usuario $uPar)" "$($b[3]) descuadre(s) (usuario $($b[4]))"

# ----------------------------------------------- 4. permisos y réplicas
Titulo 'Permisos y réplicas'
$r = Q $A_PRIM 'CALL mantenimiento_diario()' 'bankdoit_api'
Verificar ($script:codigo -ne 0 -and $r -match 'permission denied') 'bankdoit_api intenta CALL mantenimiento_diario()' 'permiso denegado' ($r -split "`n" | Select-Object -First 1)
$r = Q $A_PRIM 'SELECT count(*) FROM bitacora_mantenimiento' 'bankdoit_api'
Verificar ($script:codigo -ne 0 -and $r -match 'permission denied') 'bankdoit_api intenta leer la bitácora' 'permiso denegado' ($r -split "`n" | Select-Object -First 1)
$r = Q $B_REPL 'CALL mantenimiento_diario()'
Verificar ($script:codigo -ne 0 -and $r -match 'solo_en_primario') 'CALL en una réplica' 'solo_en_primario' ($r -split "`n" | Select-Object -First 1)
Verificar ((Q $B_REPL 'SELECT count(*) FROM bitacora_mantenimiento') -eq (Q $A_PRIM 'SELECT count(*) FROM bitacora_mantenimiento')) 'La bitácora impar está en su réplica (Nodo B)' 'mismos registros' "$(Q $B_REPL 'SELECT count(*) FROM bitacora_mantenimiento') registros"
Verificar ((Q $B_REPL 'SELECT count(*) FROM sesion WHERE vence <= now()') -eq '0') 'La limpieza de sesiones llegó a la réplica' '0 vencidas' "$(Q $B_REPL 'SELECT count(*) FROM sesion WHERE vence <= now()') vencidas"

# ----------------------------------------- 5. corregir y volver a revisar
Titulo 'Corregir el descuadre y volver a ejecutar'
Q $B_PRIM "BEGIN; ALTER TABLE bankroll DISABLE TRIGGER trg_bankroll_proteger;
           UPDATE bankroll SET saldo_disponible = saldo_disponible - 1 WHERE usuario_id = $uPar;
           ALTER TABLE bankroll ENABLE TRIGGER trg_bankroll_proteger; COMMIT" | Out-Null
docker exec $B_PRIM psql -U $usuarioBD -d $baseBD -X -q -c 'CALL mantenimiento_diario()' 2>&1 | Out-Null
$fin = Q $B_PRIM 'SELECT bankrolls_descuadrados FROM bitacora_mantenimiento ORDER BY ejecucion_id DESC LIMIT 1'
Verificar ($fin -eq '0') 'Tras corregir el saldo, el siguiente CALL' '0 descuadres' "$fin descuadres"

$bitacora = foreach ($c in $A_PRIM, $B_PRIM) {
    Q $c "SELECT ejecucion_id || '|' || to_char(ejecutado_en AT TIME ZONE 'America/Mexico_City', 'YYYY-MM-DD HH24:MI:SS') || '|' || fragmento || '|' || sesiones_eliminadas || '|' || lotes || '|' || bankrolls_revisados || '|' || bankrolls_descuadrados || '|' || duracion_ms FROM bitacora_mantenimiento ORDER BY ejecucion_id DESC LIMIT 3"
}

# --------------------------------------------------------- evidencia
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Evidencia: procedimiento de mantenimiento (#56)'); $md.Add('')
$md.Add("Generado por ``database/distribuido/probar_mantenimiento.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm') sobre la simulación de dos nodos (proyecto ``$PROYECTO``).")
$md.Add(''); $md.Add('```sql'); $md.Add('CALL mantenimiento_diario(1000);   -- primario impar'); $md.Add('CALL mantenimiento_diario();       -- primario par'); $md.Add('```'); $md.Add('')
$md.Add('Mensajes del procedimiento:'); $md.Add(''); $md.Add('```')
$salidaA + $salidaB | Where-Object { $_ -match 'NOTICE|WARNING' } | ForEach-Object { $md.Add(($_ -replace '^psql:\S+\s*', '')) }
$md.Add('```'); $md.Add('')
$md.Add('## Comprobaciones'); $md.Add('')
$md.Add('| Prueba | Esperado | Obtenido | |'); $md.Add('| --- | --- | --- | --- |')
foreach ($f in $filas) { $md.Add("| $($f.Prueba) | $($f.Esperado) | $(($f.Obtenido -replace '\|', '/')) | $(if ($f.Ok) { '✔' } else { '✘' }) |") }
$md.Add(''); $md.Add('## Últimos registros de `bitacora_mantenimiento`'); $md.Add('')
$md.Add('| Ejecución | Fecha (CDMX) | Fragmento | Sesiones eliminadas | Lotes | Bankrolls revisados | Descuadrados | Duración (ms) |'); $md.Add('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |')
foreach ($bloque in $bitacora) { foreach ($l in ($bloque -split "`n")) { if ($l) { $md.Add('| ' + ($l -replace '\|', ' | ') + ' |') } } }
New-Item -ItemType Directory -Force evidencia | Out-Null
$md | Out-File -Encoding utf8 evidencia\evidencia_mantenimiento.md

Write-Host ''
Write-Host 'Evidencia guardada en evidencia\evidencia_mantenimiento.md'
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
