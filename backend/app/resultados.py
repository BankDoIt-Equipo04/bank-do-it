"""Resultados personales calculados del libro de movimientos, en orden de registro."""
from decimal import ROUND_HALF_UP, Decimal


def pesos(centavos):
    return format(Decimal(centavos).scaleb(-2), ".2f")


def resultados_personales(movimientos):
    disponible = en_juego = ganancia = consecutivas = 0
    ultima = None
    maximas = {"ganada": 0, "perdida": 0}
    deportes = {}
    evolucion = []
    for m in movimientos:
        disponible += m["disponible"]
        en_juego += m["en_juego"]
        if m["tipo"] == "liquidacion" and m["estado"] in maximas:
            neta = m["disponible"] + m["en_juego"]
            ganancia += neta
            grupo = deportes.setdefault(m["deporte"], {"importe": 0, "neta": 0})
            grupo["importe"] -= m["en_juego"]
            grupo["neta"] += neta
            consecutivas = consecutivas + 1 if ultima == m["estado"] else 1
            ultima = m["estado"]
            maximas[ultima] = max(maximas[ultima], consecutivas)
        evolucion.append({"fecha": m["fecha"], "tipo": m["tipo"], "disponible": pesos(disponible),
                          "en_juego": pesos(en_juego), "total": pesos(disponible + en_juego),
                          "ganancia_neta": pesos(ganancia)})
    roi = []
    for deporte, grupo in sorted(deportes.items()):
        porcentaje = (Decimal(grupo["neta"]) * 100 / grupo["importe"]).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP)
        roi.append({"deporte": deporte, "monto_resuelto": pesos(grupo["importe"]),
                    "ganancia_neta": pesos(grupo["neta"]), "roi_porcentaje": str(porcentaje)})
    return {"bankroll": {"disponible": pesos(disponible), "en_juego": pesos(en_juego)},
            "ganancia_neta": pesos(ganancia), "evolucion": evolucion, "roi_por_deporte": roi,
            "rachas": {"actual": ultima, "longitud": consecutivas, "maxima_ganadora": maximas["ganada"],
                       "maxima_perdedora": maximas["perdida"]}}
