import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Bankroll usa la API real para movimientos y límite semanal', (
    tester,
  ) async {
    expect(ApiApuestas.servidor, 'http://127.0.0.1:18810');
    final acceso = ApiApuestas();
    addTearDown(acceso.cliente.close);
    final alias = ApiApuestas.nuevaClave(), password = ApiApuestas.nuevaClave();
    await acceso.crearCuenta(alias, password, '100.00');
    final cuenta = await acceso.ingresar(alias, password);
    addTearDown(cuenta.salir);
    await tester.pumpWidget(BankDoItApp(api: cuenta));
    await tester.pumpAndSettle();

    Future<void> esperar(String texto) async {
      final fin = DateTime.now().add(const Duration(seconds: 15));
      while (find.text(texto).evaluate().isEmpty &&
          DateTime.now().isBefore(fin)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(texto), findsWidgets);
    }

    Future<void> tocar(String texto) async {
      await esperar(texto);
      final boton = find.text(texto).first;
      await tester.ensureVisible(boton);
      await tester.tap(boton);
      await tester.pumpAndSettle();
    }

    Future<void> guardar(String tipo, String valor) async {
      await tocar(tipo);
      final entrada = find.byType(TextField);
      await tester.tap(entrada);
      await tester.enterText(entrada, valor);
      await tocar('Guardar');
    }

    await tocar('Bankroll');
    await esperar('Saldo inicial');
    await guardar('Aportación', '50');
    await esperar(r'$150');
    await esperar('Aportación simulada');
    await guardar('Retiro', '160');
    await esperar('Saldo insuficiente.');
    await tocar('Cancelar');
    await guardar('Retiro', '30');
    await esperar(r'$120');
    await esperar('Retiro simulado');
    await guardar('Límite semanal', '250');
    await esperar(r'$0 de $250');
    await guardar('Límite semanal', '');
    await esperar('Sin límite semanal');
    final historial = await cuenta.cargar();
    expect(historial.disponible, '120.00');
    expect(historial.limite, isNull);
    expect((await cuenta.movimientos()).map((m) => m['tipo']), [
      'retiro',
      'aportacion',
      'saldo_inicial',
    ]);
  });
}
