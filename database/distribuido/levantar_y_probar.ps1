# =====================================================================
# BANKDOIT · levantar_y_probar.ps1  (#17)
# Simula los dos nodos en esta computadora, carga los usuarios 3 y 4 y
# comprueba dónde se escribe cada registro y dónde aparece su réplica.
# Uso (desde database\distribuido):   .\levantar_y_probar.ps1
# =====================================================================
$ErrorActionPreference = 'Continue'   # docker escribe progreso en stderr
Set-Location $PSScriptRoot

if (-not (Test-Path .env)) {
    Write-Host 'Falta .env: copia .env.example a .env y define las contraseñas.' -ForegroundColor Red
    exit 1
}
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object {
    $cfg[$Matches[1]] = $Matches[2].Trim()
}
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }

# Proyecto y prefijo configurables para ensayar sin tocar otra instalación:
#   $env:BANKDOIT_PROYECTO='bankdoit-ensayo'; $env:BANKDOIT_PREFIJO='ensayo-'
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$A_PRIM = "${P}nodo-a-primario-impar"
$A_REPL = "${P}nodo-a-replica-par"
$B_PRIM = "${P}nodo-b-primario-par"
$B_REPL = "${P}nodo-b-replica-impar"
$todos  = @($A_PRIM, $B_REPL, $B_PRIM, $A_REPL)
$perfiles = @('-p', $PROYECTO, '--profile', 'nodo-a', '--profile', 'nodo-b', '--profile', 'recuperacion')
$script:fallos = 0

function Titulo($texto) { Write-Host ''; Write-Host "== $texto ==" -ForegroundColor Cyan }

# Ejecuta SQL en un contenedor y devuelve el resultado sin formato.
function Q($contenedor, $sql) {
    $salida = docker exec $contenedor psql -U $usuarioBD -d $baseBD -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    return (($salida | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Verificar($condicion, $nombre, $detalle = '') {
    if ($condicion) {
        Write-Host "OK    $nombre" -ForegroundColor Green
    } else {
        Write-Host "FALLO $nombre $detalle" -ForegroundColor Red
        $script:fallos++
    }
}

# Exige que el SQL falle y que el error contenga el texto esperado.
function DebeFallar($contenedor, $sql, $esperado, $nombre) {
    $r = Q $contenedor $sql
    Verificar (($script:codigo -ne 0) -and ($r -match [regex]::Escape($esperado))) "$nombre -> $esperado" "(obtenido: $r)"
}

function Esperar($descripcion, [scriptblock]$condicion, $segundos = 120) {
    $limite = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $limite) {
        if (& $condicion) { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Host "Tiempo agotado esperando: $descripcion" -ForegroundColor Red
    docker compose @perfiles logs --tail 30
    exit 1
}

function InitTerminado($contenedor) {
    $logs = docker logs $contenedor 2>&1 | Out-String
    if ($logs -notmatch 'init process complete') { return $false }
    docker exec $contenedor pg_isready -q -U $usuarioBD -d $baseBD 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------
if (-not (Test-Path .\certs\nodo-a.crt) -or -not (Test-Path .\certs\nodo-b.crt)) {
    Titulo 'Generando certificados TLS de prueba'
    & .\generar_certificados.ps1 | Out-Null
}
Titulo 'Borrando la simulación anterior'
docker compose @perfiles down -v --remove-orphans 2>&1 | Out-Null

Titulo 'Levantando los primarios (Nodo A: impar, Nodo B: par)'
docker compose @perfiles up -d nodo-a-primario-impar nodo-b-primario-par 2>&1 | Out-Null
Esperar 'inicialización de los primarios' { (InitTerminado $A_PRIM) -and (InitTerminado $B_PRIM) } | Out-Null
Write-Host 'Primarios listos.'

Titulo 'Levantando las réplicas (copia con pg_basebackup)'
docker compose @perfiles up -d nodo-a-replica-par nodo-b-replica-impar 2>&1 | Out-Null
Esperar 'réplicas síncronas conectadas' {
    ((Q $A_PRIM "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'replica_impar'") -eq 'sync') -and
    ((Q $B_PRIM "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'replica_par'") -eq 'sync')
} | Out-Null
Write-Host 'Réplicas conectadas en modo síncrono.'

Titulo 'Catálogo común: se carga en el primario impar y se suscribe el par'
docker exec $A_PRIM psql -U $usuarioBD -d $baseBD -q -v ON_ERROR_STOP=1 -f /datos/catalogo.sql 2>&1 | Out-Null
docker exec $B_PRIM bash /scripts/suscribir_catalogo.sh 2>&1 | ForEach-Object { "$_" }
Esperar 'copia del catálogo al fragmento par' { (Q $B_PRIM 'SELECT count(*) FROM partido') -eq '3' } | Out-Null

Titulo 'Usuarios de prueba: la API enruta por usuario_id % 2'
Write-Host 'usuario 3 (ana_gol): 3 % 2 = 1 -> primario impar (Nodo A)'
docker exec $A_PRIM psql -U $usuarioBD -d $baseBD -q -v ON_ERROR_STOP=1 -f /datos/usuarios_impar.sql 2>&1 | Out-Null
Verificar ($LASTEXITCODE -eq 0) 'datos del fragmento impar cargados'
Write-Host 'usuario 4 (beto_td): 4 % 2 = 0 -> primario par (Nodo B)'
docker exec $B_PRIM psql -U $usuarioBD -d $baseBD -q -v ON_ERROR_STOP=1 -f /datos/usuarios_par.sql 2>&1 | Out-Null
Verificar ($LASTEXITCODE -eq 0) 'datos del fragmento par cargados'

# ---------------------------------------------------------------------
Titulo '1. Estado de la replicación'
Verificar ((Q $A_PRIM "SELECT state || '/' || sync_state FROM pg_stat_replication WHERE application_name = 'replica_impar'") -eq 'streaming/sync') `
    'Nodo A primario impar -> réplica en Nodo B: streaming, síncrona'
Verificar ((Q $B_PRIM "SELECT state || '/' || sync_state FROM pg_stat_replication WHERE application_name = 'replica_par'") -eq 'streaming/sync') `
    'Nodo B primario par -> réplica en Nodo A: streaming, síncrona'
foreach ($c in @($A_REPL, $B_REPL)) {
    Verificar ((Q $c 'SELECT pg_is_in_recovery()') -eq 't') "$c está en modo réplica (solo lectura)"
}
foreach ($c in @($A_PRIM, $B_PRIM)) {
    Verificar ((Q $c 'SELECT pg_is_in_recovery()') -eq 'f') "$c es primario (acepta escrituras)"
}

Titulo '2. Dónde quedó cada usuario (usuario/bankroll/apuestas/movimientos)'
$conteo = "SELECT (SELECT count(*) FROM usuario WHERE usuario_id = {0}) || '/' || " +
          "(SELECT count(*) FROM bankroll WHERE usuario_id = {0}) || '/' || " +
          "(SELECT count(*) FROM apuesta WHERE usuario_id = {0}) || '/' || " +
          "(SELECT count(*) FROM movimiento WHERE usuario_id = {0})"
$saldo = "SELECT COALESCE((SELECT saldo_disponible || ' / ' || monto_en_juego FROM bankroll WHERE usuario_id = {0}), '-')"
$esperado = @{
    "$A_PRIM|3" = '1/1/2/4'; "$B_REPL|3" = '1/1/2/4'; "$B_PRIM|3" = '0/0/0/0'; "$A_REPL|3" = '0/0/0/0'
    "$A_PRIM|4" = '0/0/0/0'; "$B_REPL|4" = '0/0/0/0'; "$B_PRIM|4" = '1/1/1/2'; "$A_REPL|4" = '1/1/1/2'
}
$tabla = foreach ($c in $todos) {
    $u3 = Q $c ($conteo -f 3); $u4 = Q $c ($conteo -f 4)
    Verificar ($u3 -eq $esperado["$c|3"]) "$c, usuario 3: $u3"
    Verificar ($u4 -eq $esperado["$c|4"]) "$c, usuario 4: $u4"
    [pscustomobject]@{
        Instancia    = $c
        'Usuario 3'  = $u3
        'Saldo 3'    = Q $c ($saldo -f 3)
        'Usuario 4'  = $u4
        'Saldo 4'    = Q $c ($saldo -f 4)
        Partidos     = Q $c 'SELECT count(*) FROM partido'
    }
}
$tabla | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Verificar ((Q $A_PRIM ($saldo -f 3)) -eq '940.00 / 100.00') 'usuario 3: $940 disponibles y $100 en juego (igual en su réplica)'
Verificar ((Q $B_REPL ($saldo -f 3)) -eq '940.00 / 100.00') 'réplica del usuario 3 en Nodo B con el mismo saldo'
Verificar ((Q $B_PRIM ($saldo -f 4)) -eq '600.00 / 200.00') 'usuario 4: $600 disponibles y $200 en juego'
Verificar ((Q $A_REPL ($saldo -f 4)) -eq '600.00 / 200.00') 'réplica del usuario 4 en Nodo A con el mismo saldo'
foreach ($c in $todos) {
    Verificar ((Q $c 'SELECT count(*) FROM partido') -eq '3') "$c tiene el catálogo completo (3 partidos)"
}

Titulo '3. Escrituras nuevas: se replican al confirmar (replicación síncrona)'
$r = Q $A_PRIM "SELECT apuesta_id FROM registrar_apuesta(3, 'vivo-ana', 42, 'Chivas', 20.00, 2.50)"
Verificar ($script:codigo -eq 0) "nueva apuesta del usuario 3 en el primario impar (apuesta_id $r, impar)"
Verificar ((Q $B_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'vivo-ana'") -eq '1') `
    'la apuesta ya está en la réplica del Nodo B en cuanto se confirmó'
$nuevo = Q $B_PRIM "SELECT crear_usuario('carla_mx', repeat('x', 30), 300.00)"
Verificar ($nuevo -eq '6') "usuario nuevo en el primario par recibe un id par ($nuevo)"
Verificar ((Q $A_REPL 'SELECT count(*) FROM usuario WHERE usuario_id = 6') -eq '1') 'el usuario 6 ya está en la réplica del Nodo A'
Q $A_PRIM "INSERT INTO partido (deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES (2, 4, 3, '2026-12-06 12:00-06')" | Out-Null
Esperar 'partido nuevo en el fragmento par' { (Q $B_PRIM 'SELECT count(*) FROM partido') -eq '4' } 30 | Out-Null
Esperar 'partido nuevo en las réplicas' {
    ((Q $A_REPL 'SELECT count(*) FROM partido') -eq '4') -and ((Q $B_REPL 'SELECT count(*) FROM partido') -eq '4')
} 30 | Out-Null
Verificar $true 'un partido nuevo en el primario impar llega al primario par y a las dos réplicas'

Titulo '4. Reglas de la distribución'
DebeFallar $A_PRIM "SELECT crear_usuario('par_en_impar', repeat('x', 30), 10, NULL, 'usuario', 8)" `
    'ck_usuario_fragmento' 'el fragmento impar rechaza un usuario par'
DebeFallar $B_PRIM "SELECT crear_usuario('impar_en_par', repeat('x', 30), 10, NULL, 'usuario', 7)" `
    'ck_usuario_fragmento' 'el fragmento par rechaza un usuario impar'
DebeFallar $B_REPL "SELECT registrar_apuesta(3, 'en-replica', 101, 'América', 10, 2)" `
    'read-only transaction' 'la réplica del Nodo B no acepta escrituras'
DebeFallar $A_REPL "SELECT registrar_apuesta(4, 'en-replica', 101, 'Chivas', 10, 2)" `
    'read-only transaction' 'la réplica del Nodo A no acepta escrituras'
DebeFallar $B_PRIM "INSERT INTO deporte (nombre) VALUES ('Béisbol')" `
    'catalogo_solo_lectura' 'el catálogo no se edita en el fragmento par'

Titulo '5. Conciliación en cada instancia'
foreach ($c in $todos) {
    Verificar ((Q $c 'SELECT bool_and(cuadra) FROM conciliar_bankroll()') -eq 't') "${c}: bankroll = movimientos = apuestas pendientes"
}

Write-Host ''
if ($script:fallos -eq 0) {
    Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green
    Write-Host 'Los cuatro contenedores siguen arriba para revisarlos (puertos 5441, 5442, 5451, 5452).'
    Write-Host "Para apagarlos: docker compose -p $PROYECTO --profile nodo-a --profile nodo-b --profile recuperacion down"
    exit 0
}
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
