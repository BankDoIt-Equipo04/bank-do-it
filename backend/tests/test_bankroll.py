from decimal import Decimal

import pytest

from app.bankroll import Bankroll, SaldoInsuficienteError


def test_reservar_apuesta():
    saldo = Bankroll(Decimal("1000.00"))
    saldo.reservar(Decimal("100.00"))
    assert saldo.disponible == Decimal("900.00")
    assert saldo.en_juego == Decimal("100.00")


@pytest.mark.parametrize("monto", ["0", "-10", "0.005"])
def test_rechaza_monto_invalido(monto):
    saldo = Bankroll(Decimal("1000.00"))
    with pytest.raises(ValueError):
        saldo.reservar(Decimal(monto))
    assert saldo == Bankroll(Decimal("1000.00"))


def test_rechaza_apuesta_si_falta_saldo():
    saldo = Bankroll(Decimal("50.00"))
    with pytest.raises(SaldoInsuficienteError):
        saldo.reservar(Decimal("100.00"))
    assert saldo == Bankroll(Decimal("50.00"))
