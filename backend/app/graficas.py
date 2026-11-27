"""Gráficas personales que se envían a Flutter sólo cuando la vista las solicita."""
import base64
from io import BytesIO
from threading import Lock

from matplotlib.figure import Figure
from matplotlib.ticker import MaxNLocator

_dibujo = Lock()


def imagen(dibujar):
    with _dibujo:
        figura = Figure(figsize=(5.4, 2.5), dpi=120, layout="constrained")
        eje = figura.subplots()
        eje.spines[["top", "right"]].set_visible(False)
        dibujar(eje)
        with BytesIO() as archivo:
            figura.savefig(archivo, format="png")
            return base64.b64encode(archivo.getvalue()).decode("ascii")


def graficas(evolucion, roi, secuencias):
    def saldos(eje):
        cierres = {}
        for punto in evolucion:
            dia = str(punto["fecha"])[:10] if punto["fecha"] else "Inicial"
            cierres[dia] = punto
        dias = list(cierres)
        for campo, etiqueta, color in [("total", "Bankroll", "#007985"),
                                        ("ganancia_neta", "Ganancia neta", "#444444")]:
            eje.plot(range(len(dias)), [float(p[campo]) for p in cierres.values()],
                     label=etiqueta, color=color, marker="." if len(dias) < 30 else None)
        indices = sorted({round(i * (len(dias) - 1) / 2) for i in range(3)})
        eje.set_xticks(indices, [dias[i] for i in indices])
        eje.set_ylabel("Pesos")
        eje.legend()

    def retornos(eje):
        eje.barh([r["deporte"] for r in roi], [float(r["roi_porcentaje"]) for r in roi],
                 color="#007985")
        eje.axvline(0, color="#444444", linewidth=1)
        eje.set_xlabel("ROI (%)")

    def rachas(eje):
        for estado, etiqueta, color in [("ganada", "Ganadas", "#007985"), ("perdida", "Perdidas", "#94452d")]:
            barras = [(i, n) for i, (tipo, n) in enumerate(secuencias, 1) if tipo == estado]
            eje.bar([i for i, _ in barras], [n for _, n in barras], color=color, label=etiqueta)
        eje.yaxis.set_major_locator(MaxNLocator(integer=True))
        eje.xaxis.set_major_locator(MaxNLocator(integer=True))
        eje.set_xlabel("Secuencia")
        eje.set_ylabel("Apuestas")
        eje.legend()

    return {"evolucion": imagen(saldos) if evolucion else None,
            "roi": imagen(retornos) if roi else None,
            "rachas": imagen(rachas) if secuencias else None}
