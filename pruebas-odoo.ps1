<#
.SYNOPSIS
    Odoo de pruebas: copia produccion, le aplica el codigo a probar y lo levanta
    en http://<IP>:8170. Produccion (aura_odoo, base odoo, :8169) solo se lee.

.DESCRIPTION
    1. Codigo: extra-addons-pruebas\odoo_aura_plant, un git worktree del repo de
       produccion apuntando a -Ref (por defecto origin/20.0, lo ultimo subido).
    2. Datos (salvo -SoloCodigo): pg_dump de la base odoo a backup\, restaurado
       como odoo_pruebas, y copia del filestore (adjuntos, fotos).
    3. Neutraliza la copia: sin correo, sin tareas programadas, Telegram apagado.
    4. Modulos del repo: -u los que la base ya tiene instalados, -i los nuevos
       (menos -Excluir; mas -Instalar, p. ej. modulos estandar de Odoo).
       Si esto falla, en produccion fallaria igual: no se lleva.
    5. Levanta aura_odoo_pruebas e imprime el comando -i/-u para produccion,
       calculado contra la base odoo real.

.EXAMPLE
    .\pruebas-odoo.ps1                          # copia fresca + origin/20.0
.EXAMPLE
    .\pruebas-odoo.ps1 -Ref origin/mi-rama      # otra rama, tag o commit
.EXAMPLE
    .\pruebas-odoo.ps1 -SoloCodigo              # mismos datos, solo codigo + -u
.EXAMPLE
    .\pruebas-odoo.ps1 -Excluir plant_borrador  # modulo del repo que NO se instala
.EXAMPLE
    .\pruebas-odoo.ps1 -Instalar stock          # ademas, uno que no esta en el repo
.EXAMPLE
    .\pruebas-odoo.ps1 -Bajar                   # borra todo el entorno de pruebas
#>
param(
    [string]$Ref = 'origin/20.0',
    [string[]]$Instalar = @(),
    [string[]]$Excluir = @(),
    [switch]$SoloCodigo,
    [switch]$Bajar
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Db             = 'aura_db'
$BaseProd       = 'odoo'
$BasePruebas    = 'odoo_pruebas'
$Servicio       = 'odoo_pruebas'
$Imagen         = 'aura_odoo:20'
$ComposePruebas = Join-Path $PSScriptRoot 'docker-compose.pruebas.yml'
$RepoProd       = Join-Path $PSScriptRoot 'extra-addons\odoo_aura_plant'
$RepoPruebas    = Join-Path $PSScriptRoot 'extra-addons-pruebas\odoo_aura_plant'
$VolumenProd    = 'aura_stack_planta_odoo-data'
$VolumenPruebas = 'aura_pruebas_odoo-data'
# Dentro de aura_db; en el host es backup\odoo_para_pruebas.dump. Se pisa en
# cada corrida, y de paso queda como respaldo reciente de produccion.
$Dump           = '/backup/odoo_para_pruebas.dump'

function Paso([string]$Texto) { Write-Host "`n==> $Texto" -ForegroundColor Cyan }

# Corre un comando externo y corta el script si falla.
function Ejecutar {
    $exe = $args[0]
    $resto = @($args | Select-Object -Skip 1)
    & $exe @resto
    if ($LASTEXITCODE -ne 0) { throw "Fallo ($LASTEXITCODE): $exe $($resto -join ' ')" }
}

function Compose { Ejecutar docker compose -f $ComposePruebas @args }

# SQL por stdin: evita los problemas de comillas de PowerShell con los
# argumentos de programas externos. Devuelve las filas (-At).
function Sql([string]$Base, [string]$Consulta) {
    $salida = $Consulta | docker exec -i $Db psql -U postgres -d $Base -X -q -At -v ON_ERROR_STOP=1
    if ($LASTEXITCODE -ne 0) { throw "psql fallo en la base $Base" }
    if ($salida) { $salida }
}

# Se corre antes Y despues del -u: los XML de los modulos (crons, el bot de
# Telegram con su token) no son noupdate, y el -u los vuelve a dejar como en
# produccion.
function Neutralizar {
    Paso 'Neutralizando la copia'
    # Lo estandar de Odoo: apaga tareas programadas y servidores de correo.
    Compose run --rm --no-deps $Servicio odoo neutralize -d $BasePruebas
    # Lo propio: el bot de Telegram escribe a chats reales. Se apaga y se le
    # cambia el token, para que ni "Ejecutar manualmente" llegue a mandar nada.
    Sql $BasePruebas @'
DO $$
BEGIN
    IF to_regclass('plant_telegram_bot') IS NOT NULL THEN
        UPDATE plant_telegram_bot SET active = false, token = 'pruebas:desactivado';
    END IF;
END $$;
'@ | Out-Null
}

$reloj = [Diagnostics.Stopwatch]::StartNew()

if ((docker inspect -f '{{.State.Running}}' $Db) -ne 'true') {
    throw "El contenedor $Db no esta en ejecucion: levanta produccion primero (docker compose up -d)."
}
if ($SoloCodigo -and -not (Sql postgres "SELECT 1 FROM pg_database WHERE datname = '$BasePruebas';")) {
    throw "No existe la base ${BasePruebas}: corre una vez sin -SoloCodigo."
}

# ---------------------------------------------------------------------------
if ($Bajar) {
    if (Test-Path $RepoPruebas) {
        if (git -C $RepoPruebas status --porcelain) {
            throw "$RepoPruebas tiene cambios sin commitear. Commitealos o descartalos y vuelve a correr -Bajar."
        }
    }
    Paso 'Borrando contenedor y volumen de pruebas'
    Compose down --volumes
    Paso "Borrando la base $BasePruebas"
    Sql postgres "DROP DATABASE IF EXISTS $BasePruebas WITH (FORCE);" | Out-Null
    if (Test-Path $RepoPruebas) {
        Paso 'Quitando el worktree de pruebas'
        Ejecutar git -C $RepoProd worktree remove $RepoPruebas
    }
    Write-Host "`nEntorno de pruebas borrado. Produccion no se toco." -ForegroundColor Green
    return
}

# --- 1. Codigo --------------------------------------------------------------
Paso "Codigo a probar: $Ref"
# Solo actualiza las referencias remotas del repo de produccion; su carpeta de
# trabajo (la que ve aura_odoo) no cambia.
git -C $RepoProd fetch --prune origin
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'No se pudo hacer fetch (sin internet?). Se usa lo que ya tiene el repo local.'
}
if (-not (Test-Path $RepoPruebas)) {
    Ejecutar git -C $RepoProd worktree add --detach $RepoPruebas $Ref
}
elseif (git -C $RepoPruebas status --porcelain) {
    Write-Warning "La copia de pruebas tiene cambios sin commitear: se prueba tal cual, sin pasar a $Ref."
}
else {
    Ejecutar git -C $RepoPruebas checkout --quiet --detach $Ref
}
$commit = Ejecutar git -C $RepoPruebas log -1 --format='%h %s'
Write-Host "    $commit"

# --- 2. Datos ---------------------------------------------------------------
if (-not $SoloCodigo) {
    Paso 'Deteniendo Odoo de pruebas'
    Compose stop $Servicio

    Paso "Volcando la base de produccion ($BaseProd) en backup\"
    # pg_dump lee una foto consistente sin bloquear: produccion sigue andando.
    Ejecutar docker exec $Db pg_dump -U postgres -Fc -f $Dump $BaseProd

    Paso "Restaurando como $BasePruebas"
    Sql postgres "DROP DATABASE IF EXISTS $BasePruebas WITH (FORCE);" | Out-Null
    Sql postgres "CREATE DATABASE $BasePruebas OWNER odoo TEMPLATE template0;" | Out-Null
    Ejecutar docker exec $Db pg_restore -U postgres -d $BasePruebas --exit-on-error $Dump

    Paso 'Copiando el filestore'
    # create: deja listo el volumen de pruebas sin arrancar Odoo.
    Compose create $Servicio
    Ejecutar docker run --rm --user root --entrypoint sh `
        -v "${VolumenProd}:/origen:ro" -v "${VolumenPruebas}:/destino" $Imagen `
        -c "rm -rf /destino/filestore/$BasePruebas && mkdir -p /destino/filestore && if [ -d /origen/filestore/$BaseProd ]; then cp -a /origen/filestore/$BaseProd /destino/filestore/$BasePruebas; fi && chown -R odoo:odoo /destino"

    Neutralizar
}

# --- 3. Modulos -------------------------------------------------------------
# Sin lista fija que mantener: cada modulo del repo (installable, no excluido)
# va con -u si la base ya lo tiene instalado, o con -i si es nuevo para ella.
$modulos = @(Get-ChildItem $RepoPruebas -Directory | Where-Object {
        $manifiesto = Join-Path $_.FullName '__manifest__.py'
        (Test-Path $manifiesto) -and
        -not (Select-String -Path $manifiesto -Pattern '[''"]installable[''"]\s*:\s*False' -Quiet)
    } | ForEach-Object Name | Where-Object { $Excluir -notcontains $_ } | Sort-Object)

function Plan([string]$Base) {
    $lista = ($modulos | ForEach-Object { "'$_'" }) -join ','
    $instalados = @(Sql $Base "SELECT name FROM ir_module_module WHERE state IN ('installed', 'to upgrade') AND name IN ($lista);")
    $nuevos = @($modulos | Where-Object { $instalados -notcontains $_ }) + @($Instalar)
    [pscustomobject]@{
        Actualizar = @($modulos | Where-Object { $instalados -contains $_ })
        Instalar   = @($nuevos | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Opciones($P) {
    $o = @()
    if ($P.Instalar.Count)   { $o += '-i', ($P.Instalar -join ',') }
    if ($P.Actualizar.Count) { $o += '-u', ($P.Actualizar -join ',') }
    $o
}

$plan = Plan $BasePruebas
$opciones = @(Opciones $plan)
Paso 'Modulos'
Write-Host "    -i (nuevos):    $(if ($plan.Instalar.Count) { $plan.Instalar -join ', ' } else { '-' })"
Write-Host "    -u (instalados): $(if ($plan.Actualizar.Count) { $plan.Actualizar -join ', ' } else { '-' })"
if ($Excluir) { Write-Host "    excluidos:      $($Excluir -join ', ')" }
Compose stop $Servicio
try {
    Compose run --rm --no-deps $Servicio odoo -d $BasePruebas @opciones --stop-after-init
}
catch {
    Write-Host "`nLa actualizacion FALLO: en produccion fallaria igual. Revisa el log de arriba." -ForegroundColor Red
    throw
}
Neutralizar

# --- 4. Arranque ------------------------------------------------------------
Paso 'Levantando Odoo de pruebas'
Compose up -d $Servicio

$minutos = [math]::Round($reloj.Elapsed.TotalMinutes, 1)
Write-Host @"

Listo en $minutos min. Odoo de PRUEBAS:
    http://localhost:8170      (o http://<IP de esta PC>:8170)
    base $BasePruebas, codigo $commit
    Mismos usuarios y contrasenas que produccion. Tareas programadas apagadas.

Ojo: el navegador comparte la sesion entre :8169 y :8170 si usas el mismo
nombre de host. Entra a pruebas por localhost y a produccion por la IP, o
usa una ventana privada, para no estar deslogueandote.

"@ -ForegroundColor Green

# Lo que le falta a produccion, contra su base real (en -SoloCodigo la copia
# ya tiene instalados los nuevos, asi que su plan no sirve para esto).
$planProd = Plan $BaseProd
$sha = ($commit -split ' ')[0]
Write-Host @"
Si todo esta bien, en produccion (desde aura_stack_planta):
    docker exec $Db pg_dump -U postgres -Fc -f /backup/odoo_antes_$sha.dump $BaseProd
    git -C extra-addons\odoo_aura_plant fetch origin
    git -C extra-addons\odoo_aura_plant merge --ff-only $sha     # exactamente lo probado
    docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d $BaseProd $((Opciones $planProd) -join ' ') --stop-after-init
    docker compose restart odoo
"@ -ForegroundColor Yellow
