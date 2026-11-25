# =====================================================================
# BANKDOIT · configurar_acceso_api.ps1  (#32)
# Sobre una instalación ya levantada (levantar_y_probar.ps1):
#   1. Aplica dos veces 20_acceso_api.sh en las cuatro instancias (rol de
#      la API, directorio de cuentas, pg_hba con TLS) y comprueba que no
#      se borran ni duplican datos.
#   2. Ejecuta el cliente de Python como lo hará la API (TLS verify-full).
#   3. Comprueba con el administrador dónde quedó cada registro (primario
#      y réplica) y guarda la evidencia en evidencia\evidencia_conexion_api.md.
# Uso (desde database\distribuido):  .\configurar_acceso_api.ps1
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$A_PRIM = "${P}nodo-a-primario-impar"; $A_REPL = "${P}nodo-a-replica-par"
$B_PRIM = "${P}nodo-b-primario-par";   $B_REPL = "${P}nodo-b-replica-impar"
$todos = @($A_PRIM, $B_PRIM, $B_REPL, $A_REPL)
$script:fallos = 0

# --------------------------------------------------------- configuración
if (-not (Test-Path .env)) { Write-Host 'Falta .env (copia .env.example).' -ForegroundColor Red; exit 1 }
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
if (-not $cfg.BANKDOIT_API_PASSWORD) {
    $nueva = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 28 | ForEach-Object { [char]$_ })
    Add-Content .env "`nBANKDOIT_API_PASSWORD=$nueva"
    $cfg.BANKDOIT_API_PASSWORD = $nueva
    Write-Host 'Se agregó BANKDOIT_API_PASSWORD (aleatoria) a .env; .env no se sube al repositorio.' -ForegroundColor Yellow
}
function Valor($nombre, $omision) { $v = [Environment]::GetEnvironmentVariable($nombre); if ($v) { $v } elseif ($cfg[$nombre]) { $cfg[$nombre] } else { $omision } }
$usuarioBD = Valor 'POSTGRES_USER' 'bankdoit'
$baseBD    = Valor 'POSTGRES_DB' 'bankdoit'
$puertoA   = Valor 'PUERTO_A_PRIMARIO' '5441'
$puertoB   = Valor 'PUERTO_B_PRIMARIO' '5451'
$hostAPI   = Valor 'BANKDOIT_PG_HOST' 'localhost'      # nombre que valida el certificado
$ipAPI     = Valor 'BANKDOIT_PG_HOSTADDR' '127.0.0.1'  # dirección a la que se conecta
$ca        = (Resolve-Path .\certs\ca.crt).Path -replace '\\', '/'

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Q($c, $sql) {
    $s = docker exec $c psql -U $usuarioBD -d $baseBD -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    (($s | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Verificar($ok, $nombre, $detalle = '') {
    if ($ok) { Write-Host "OK    $nombre" -ForegroundColor Green } else { Write-Host "FALLO $nombre $detalle" -ForegroundColor Red; $script:fallos++ }
}
function Conteos() {
    $r = @{}
    foreach ($c in $todos) {
        $r[$c] = Q $c ("SELECT (SELECT count(*) FROM usuario) || '/' || (SELECT count(*) FROM bankroll) || '/' || " +
                       "(SELECT count(*) FROM apuesta) || '/' || (SELECT count(*) FROM movimiento) || '/' || (SELECT count(*) FROM partido)")
    }
    return $r
}

foreach ($c in $todos) {
    $estado = docker inspect -f '{{.State.Running}}' $c 2>$null
    if ("$estado".Trim() -ne 'true') { Write-Host "El contenedor $c no está corriendo. Ejecuta antes levantar_y_probar.ps1." -ForegroundColor Red; exit 1 }
}

# ------------------------------------------------- 1. aplicar dos veces
Titulo 'Datos antes de configurar (usuarios/bankrolls/apuestas/movimientos/partidos)'
$antes = Conteos
$todos | ForEach-Object { Write-Host ("  {0,-30} {1}" -f $_, $antes[$_]) }

$salidaConfig = @()
foreach ($vuelta in 1, 2) {
    Titulo "Aplicando 20_acceso_api.sh (vuelta $vuelta de 2)"
    foreach ($c in $todos) {
        $s = docker exec $c bash /scripts/20_acceso_api.sh 2>&1 | ForEach-Object { "$_" }
        $ok = ($LASTEXITCODE -eq 0)
        Verificar $ok "$c" ($s -join ' ')
        if ($vuelta -eq 2) { $salidaConfig += "${c}: " + (($s | Where-Object { $_ -match 'listo|configurado|Réplica' }) -join ' · ') }
    }
}
$despues = Conteos
foreach ($c in $todos) { Verificar ($antes[$c] -eq $despues[$c]) "$c conserva sus datos ($($despues[$c]))" }
Verificar ((Q $A_PRIM "SELECT count(*) FROM pg_roles WHERE rolname = 'bankdoit_api'") -eq '1') 'un solo rol bankdoit_api'
Verificar ((Q $B_REPL "SELECT count(*) FROM pg_roles WHERE rolname = 'bankdoit_api'") -eq '1') 'el rol llegó a la réplica del fragmento impar'
Verificar ((Q $A_REPL "SELECT count(*) FROM pg_roles WHERE rolname = 'bankdoit_api'") -eq '1') 'el rol llegó a la réplica del fragmento par'
Verificar ((Q $A_PRIM "SELECT to_regclass('cuenta') IS NOT NULL AND to_regclass('sesion') IS NOT NULL") -eq 't') 'directorio de cuentas y sesiones en el primario impar'
Verificar ((Q $B_PRIM "SELECT to_regclass('cuenta') IS NULL") -eq 't') 'el primario par no tiene directorio (vive solo en el impar)'
foreach ($c in $todos) { Verificar ((Q $c 'SHOW ssl') -eq 'on') "$c tiene TLS activo" }
$hba = Q $A_PRIM "SELECT rpad(type, 8) || rpad(array_to_string(database, ','), 13) || rpad(array_to_string(user_name, ','), 15) || rpad(coalesce(address, ''), 16) || auth_method FROM pg_hba_file_rules ORDER BY line_number"

# ------------------------------------------- 2. cliente como el de Luis
Titulo 'Cliente Python (psycopg) con el rol bankdoit_api y TLS verify-full'
$venv = '.\cliente\.venv\Scripts\python.exe'
if (-not (Test-Path $venv)) {
    py -3.13 -m venv .\cliente\.venv
    & $venv -m pip install -q -r .\cliente\requirements.txt 2>&1 | Out-Null
}
$env:BANKDOIT_PG_IMPAR_DSN = "host=$hostAPI hostaddr=$ipAPI port=$puertoA dbname=$baseBD user=bankdoit_api sslmode=verify-full sslrootcert='$ca'"
$env:BANKDOIT_PG_PAR_DSN   = "host=$hostAPI hostaddr=$ipAPI port=$puertoB dbname=$baseBD user=bankdoit_api sslmode=verify-full sslrootcert='$ca'"
$env:BANKDOIT_PG_PASSWORD  = $cfg.BANKDOIT_API_PASSWORD
$env:BANKDOIT_CA_NO_CONFIABLE = (Resolve-Path .\certs\ca_no_confiable.crt).Path -replace '\\', '/'
$salidaPy = & $venv .\cliente\verificar_conexion_api.py 2>&1 | ForEach-Object { "$_" }
$codigoPy = $LASTEXITCODE
$salidaPy | Where-Object { $_ -notmatch '^RESULTADO_JSON:' } | ForEach-Object {
    $color = if ($_ -match '^OK') { 'Green' } elseif ($_ -match '^FALLO') { 'Red' } else { 'Gray' }
    Write-Host "  $_" -ForegroundColor $color
}
Remove-Item Env:BANKDOIT_PG_PASSWORD
$json = ($salidaPy | Where-Object { $_ -match '^RESULTADO_JSON:' } | Select-Object -Last 1) -replace '^RESULTADO_JSON:', ''
if (-not $json) { Write-Host 'El cliente no devolvió resultados.' -ForegroundColor Red; exit 1 }
$res = $json | ConvertFrom-Json
Verificar ($codigoPy -eq 0) "cliente Python: $(@($res.resultados).Count) comprobaciones, $($res.fallos) fallos"

# ------------------------- 3. dónde quedó cada registro (como administrador)
Titulo 'Ubicación de los datos de cada cuenta (usuario/bankroll/apuestas/movimientos · saldo)'
$ubicacion = @()
foreach ($cta in $res.cuentas) {
    $uid = [int64]$cta.usuario_id
    $prim = if ($cta.fragmento -eq 'impar') { $A_PRIM } else { $B_PRIM }
    $repl = if ($cta.fragmento -eq 'impar') { $B_REPL } else { $A_REPL }
    foreach ($c in @($A_PRIM, $B_REPL, $B_PRIM, $A_REPL)) {
        $v = Q $c ("SELECT (SELECT count(*) FROM usuario WHERE usuario_id = $uid) || '/' || (SELECT count(*) FROM bankroll WHERE usuario_id = $uid) || '/' || " +
                   "(SELECT count(*) FROM apuesta WHERE usuario_id = $uid) || '/' || (SELECT count(*) FROM movimiento WHERE usuario_id = $uid) || ' · ' || " +
                   "COALESCE((SELECT saldo_disponible || ' / ' || monto_en_juego FROM bankroll WHERE usuario_id = $uid), '—')")
        $esperado = if ($c -eq $prim -or $c -eq $repl) { "1/1/1/$(if ($cta.fragmento -eq 'impar') { 3 } else { 2 }) · $($cta.saldo_final)" } else { '0/0/0/0 · —' }
        Verificar ($v -eq $esperado) ("{0} (id {1}) en {2}: {3}" -f $cta.alias, $uid, $c, $v) "(esperado $esperado)"
        $ubicacion += [pscustomobject]@{ Cuenta = "$($cta.alias) (id $uid)"; Instancia = $c; Datos = $v; Esperado = $esperado }
    }
    $dirA = Q $A_PRIM "SELECT estado FROM cuenta WHERE usuario_id = $uid"
    $dirB = Q $B_REPL "SELECT estado FROM cuenta WHERE usuario_id = $uid"
    Verificar (($dirA -eq 'activa') -and ($dirB -eq 'activa')) "$($cta.alias): cuenta activa en el directorio (primario impar y su réplica)"
}

# -------------------------------------------------------------- evidencia
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Evidencia: acceso de la API a los fragmentos (#32)'); $md.Add('')
$md.Add("Generado por ``database/distribuido/configurar_acceso_api.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Simulación de los dos nodos con Docker en una sola computadora (proyecto ``$PROYECTO``). Sin contraseñas ni llaves.")
$md.Add('')
$md.Add('## 1. Configuración aplicada dos veces (idempotente)'); $md.Add('')
$md.Add('| Instancia | Datos antes | Datos después | Resultado de la segunda vuelta |'); $md.Add('| --- | --- | --- | --- |')
foreach ($c in $todos) { $linea = ($salidaConfig | Where-Object { $_ -like "${c}:*" }) -replace "^${c}: ", ''; $md.Add("| ``$c`` | $($antes[$c]) | $($despues[$c]) | $linea |") }
$md.Add(''); $md.Add('Conteo: usuarios/bankrolls/apuestas/movimientos/partidos.'); $md.Add('')
$md.Add('`pg_hba.conf` del primario impar (`pg_hba_file_rules`):'); $md.Add(''); $md.Add('```'); $hba -split "`n" | ForEach-Object { $md.Add($_) }; $md.Add('```')
$md.Add(''); $md.Add('## 2. Sesión TLS desde el cliente de la API'); $md.Add('')
$md.Add('Consulta ejecutada por el cliente con cada conexión:'); $md.Add('')
$md.Add('```sql'); $md.Add('SELECT current_user, current_database(), nombre FROM fragmento_local;'); $md.Add('SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid();'); $md.Add('```'); $md.Add('')
$md.Add('| Conexión | Servidor | Usuario | Fragmento | sslmode | ssl | Versión | Cifrado |'); $md.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
foreach ($f in 'impar', 'par') { $t = $res.tls.$f; $md.Add("| $f | $($t.host):$($t.puerto) | $($t.usuario) | $($t.fragmento) | $($t.sslmode) | $($t.ssl) | $($t.version) | $($t.cifrado) ($($t.bits) bits) |") }
$md.Add(''); $md.Add('## 3. Cuentas de prueba'); $md.Add('')
$md.Add('| Cuenta | usuario_id | Fragmento | Primario | Réplica | Saldo inicial | Saldo final |'); $md.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($cta in $res.cuentas) {
    $prim = if ($cta.fragmento -eq 'impar') { "$A_PRIM (Nodo A)" } else { "$B_PRIM (Nodo B)" }
    $repl = if ($cta.fragmento -eq 'impar') { "$B_REPL (Nodo B)" } else { "$A_REPL (Nodo A)" }
    $md.Add("| $($cta.alias) | $($cta.usuario_id) | $($cta.fragmento) | ``$prim`` | ``$repl`` | 1000.00 / 0.00 | $($cta.saldo_final) |")
}
$md.Add(''); $md.Add('## 4. Resultados del cliente (rol bankdoit_api)'); $md.Add('')
$md.Add('| Usuario de prueba | Fragmento esperado | Operación | Resultado esperado | Resultado obtenido | |'); $md.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($r in $res.resultados) { $md.Add("| $($r.usuario) | $($r.fragmento) | $($r.operacion) | $($r.esperado) | $(($r.obtenido -replace '\|', '/')) | $(if ($r.ok) { '✔' } else { '✘' }) |") }
$md.Add(''); $md.Add('## 5. Dónde quedó cada registro (comprobado como administrador)'); $md.Add('')
$md.Add('| Cuenta | Instancia | Usuario/bankroll/apuestas/movimientos · saldo | Esperado |'); $md.Add('| --- | --- | --- | --- |')
foreach ($u in $ubicacion) { $md.Add("| $($u.Cuenta) | ``$($u.Instancia)`` | $($u.Datos) | $($u.Esperado) |") }
New-Item -ItemType Directory -Force evidencia | Out-Null
$md | Out-File -Encoding utf8 evidencia\evidencia_conexion_api.md

Write-Host ''
Write-Host 'Evidencia guardada en evidencia\evidencia_conexion_api.md'
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
