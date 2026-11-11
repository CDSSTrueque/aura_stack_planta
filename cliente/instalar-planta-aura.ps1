# Prepara esta PC para abrir https://planta.aura (Odoo detras de Caddy).
#
# Hace tres cosas, y se puede correr las veces que haga falta:
#   1. Averigua por cual IP llega esta PC al servidor. El servidor tiene dos
#      redes (192.168.16.19 y 192.168.1.54) y cada PC ve solo una.
#   2. Escribe "planta.aura" en el archivo hosts apuntando a esa IP. No hay
#      registro en el DNS de la empresa, asi que sin esto el navegador da
#      DNS_PROBE_FINISHED_NXDOMAIN.
#   3. Instala la CA de Caddy (aura-root-ca.crt, al lado de este script) como
#      raiz de confianza, para que el navegador no diga "No es seguro".
#
#   Uso: doble clic en instalar-planta-aura.bat (pide permisos de admin).

$ErrorActionPreference = 'Stop'

$Nombre     = 'planta.aura'
$Servidores = '192.168.16.19', '192.168.1.54'
$Cert       = Join-Path $PSScriptRoot 'aura-root-ca.crt'
$Hosts      = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

function Test-Puerto($ip, $puerto) {
    $tcp = New-Object Net.Sockets.TcpClient
    try { return $tcp.ConnectAsync($ip, $puerto).Wait(2000) }
    catch { return $false }
    finally { $tcp.Dispose() }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Hay que ejecutarlo como administrador: usar instalar-planta-aura.bat.' }
if (-not (Test-Path $Cert)) { throw "Falta ${Cert}: copiar la carpeta completa, no solo el script." }

# --- 1. IP del servidor alcanzable desde esta PC -------------------------
Write-Host 'Buscando el servidor...'
$ip = $Servidores | Where-Object { Test-Puerto $_ 443 } | Select-Object -First 1
if (-not $ip) {
    throw ("Esta PC no llega al servidor por el puerto 443 en ninguna de sus IPs " +
           "($($Servidores -join ', ')). Revisar cable/red o pedir a TI que abra el acceso.")
}
Write-Host "  Servidor alcanzable en $ip"

# --- 2. hosts --------------------------------------------------------------
# Se quita cualquier linea vieja de planta.aura y se agrega la buena, asi
# correrlo de nuevo (o tras cambiar de red) no deja entradas duplicadas.
$lineas = @(Get-Content $Hosts) | Where-Object { $_ -notmatch "^\s*[0-9.]+\s+$([regex]::Escape($Nombre))\s*$" }
$lineas += "$ip`t$Nombre"
try {
    Set-Content -Path $Hosts -Value $lineas -Encoding ASCII
}
catch [UnauthorizedAccessException] {
    throw ('Windows no dejo modificar el archivo hosts aunque se corre como administrador. ' +
           'Casi seguro es el antivirus de la empresa: pedir a TI que lo permita, o que ' +
           "creen en el DNS interno el registro $Nombre -> $ip.")
}
ipconfig /flushdns | Out-Null
Write-Host "  hosts: $Nombre -> $ip"

# --- 3. Certificado raiz ---------------------------------------------------
$huella = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $Cert).Thumbprint
if (Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $huella) {
    Write-Host '  Certificado: ya estaba instalado'
}
else {
    Import-Certificate -FilePath $Cert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Write-Host '  Certificado: instalado'
}

# --- Prueba ----------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $r = Invoke-WebRequest "https://$Nombre/web/login" -UseBasicParsing -TimeoutSec 15
    Write-Host ''
    Write-Host "Listo: https://$Nombre responde ($($r.StatusCode))." -ForegroundColor Green
    Write-Host 'Cerrar el navegador por completo y abrir https://planta.aura (escribirlo con https://).'
}
catch {
    Write-Host ''
    Write-Host "Configurado, pero la prueba fallo: $($_.Exception.Message)" -ForegroundColor Yellow
}
