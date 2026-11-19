# BANKDOIT · Demuestra el Issue #16 desde una base vacía.
# 1) borra el contenedor y su volumen, 2) lo crea de nuevo (corre los
# scripts de ./sql), 3) ejecuta las pruebas de integridad.
# Uso (desde la carpeta database):  .\probar_desde_cero.ps1
# Docker escribe su progreso en stderr; en Windows PowerShell 5.1 eso no
# debe tratarse como error. Se revisa $LASTEXITCODE después de cada paso.
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

if (-not (Test-Path .env)) {
    Write-Host 'Falta .env: copia .env.example a .env y define POSTGRES_PASSWORD.' -ForegroundColor Red
    exit 1
}

Write-Host '== Borrando base anterior ==' -ForegroundColor Cyan
docker compose down -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '== Creando base nueva y ejecutando sql/01..03 ==' -ForegroundColor Cyan
docker compose up -d --wait
if ($LASTEXITCODE -ne 0) {
    docker compose logs postgres
    exit $LASTEXITCODE
}

# El healthcheck puede responder mientras aún corren los scripts de
# inicio; se espera el aviso de PostgreSQL de que terminó la carga.
$listo = $false
for ($i = 0; $i -lt 60; $i++) {
    $logs = docker compose logs postgres 2>&1 | Out-String
    if ($logs -match 'init process complete') {
        docker compose exec -T postgres sh -c 'pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
        if ($LASTEXITCODE -eq 0) { $listo = $true; break }
    }
    if ($logs -match 'ERROR:') { break }
    Start-Sleep -Seconds 2
}
if (-not $listo) {
    docker compose logs postgres
    Write-Host 'La base no termino de inicializarse; revisa los logs de arriba.' -ForegroundColor Red
    exit 1
}

Write-Host '== Ejecutando pruebas de integridad ==' -ForegroundColor Cyan
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -f /pruebas/pruebas_integridad.sql'
exit $LASTEXITCODE
