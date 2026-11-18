from dataclasses import dataclass
from decimal import Decimal


class SaldoInsuficienteError(ValueError):
    pass


@dataclass
class Bankroll:
    disponible: Decimal
    en_juego: Decimal = Decimal("0.00")

    def reservar(self, monto: Decimal) -> None:
        if not monto.is_finite() or monto <= 0:
            raise ValueError("El monto debe ser positivo.")
        if monto != monto.quantize(Decimal("0.01")):
            raise ValueError("El monto debe expresarse en pesos y centavos.")
        if monto > self.disponible:
            raise SaldoInsuficienteError("Saldo insuficiente.")

        self.disponible -= monto
        self.en_juego += monto
