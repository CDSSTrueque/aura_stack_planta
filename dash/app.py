"""Dash — lee las DOS bases: nodered (proceso) y odoo (lab/turnos)."""
import os

import dash
import pandas as pd
import plotly.express as px
from dash import dcc, html
from sqlalchemy import create_engine, text

# Dos engines: no hay JOIN en SQL entre bases distintas.
# Los cruces se hacen en pandas (pd.merge_asof).
eng_nodered = create_engine(os.environ["DSN_NODERED"], pool_pre_ping=True)
eng_odoo = create_engine(os.environ["DSN_ODOO"], pool_pre_ping=True)

app = dash.Dash(__name__)
server = app.server  # gunicorn entra por aquí


def proceso_24h():
    """Promedio por hora de las últimas 24 h. Reemplaza al CSV leído cada 10 s."""
    q = text("""
        SELECT time_bucket('1 hour', ts) AS hora,
               avg(rec_cu)    AS rec_cu,
               avg(cu_cabeza) AS cu_cabeza,
               avg(cu_colas)  AS cu_colas
        FROM registro_proceso
        WHERE ts > now() - interval '24 hours'
        GROUP BY 1
        ORDER BY 1
    """)
    with eng_nodered.connect() as c:
        return pd.read_sql(q, c)


try:
    df = proceso_24h()
    figura = px.line(df, x="hora", y=["rec_cu", "cu_cabeza", "cu_colas"],
                     title="Últimas 24 h — promedio por hora")
    contenido = dcc.Graph(figure=figura)
except Exception as exc:  # la tabla aún no existe (antes de la Fase B)
    contenido = html.Pre(f"Sin datos todavía:\n{exc}")

app.layout = html.Div([html.H1("AuraPlanta"), contenido])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8050, debug=True)
