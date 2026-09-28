# Odoo 19 con soporte ODBC.
#
# La imagen oficial odoo:19 es Ubuntu 24.04 y no trae ni el driver ODBC de
# Microsoft ni pyodbc, que es lo que usa metallurgy.sql.connection para leer
# el SQL Server de planta (192.168.15.2\cdosage01).
FROM odoo:19

USER root

# Repositorio de Microsoft + driver ODBC 18 + pyodbc.
# ACCEPT_EULA=Y acepta la licencia de msodbcsql18 sin preguntar.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg; \
    echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" \
        > /etc/apt/sources.list.d/mssql-release.list; \
    apt-get update; \
    ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        msodbcsql18 \
        unixodbc \
        python3-pyodbc; \
    rm -rf /var/lib/apt/lists/*

# El build falla aqui si el driver o la libreria no quedaron utilizables,
# en vez de fallar mas tarde dentro de Odoo con un UserError.
RUN odbcinst -q -d | grep -q 'ODBC Driver 18 for SQL Server' \
    && python3 -c 'import pyodbc; print("pyodbc", pyodbc.version)'

USER odoo
