import 'package:bankdoit/main.dart';
import 'package:bankdoit/borradores.dart';
import 'package:bankdoit/api_apuestas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Registrar, confirmar el presupuesto y resolver contra la API', (
    tester,
  ) async {
    expect(
      ApiApuestas.servidor,
      'http://127.0.0.1:18810',
      reason: 'Usa la API temporal de pruebas.',
    );
    Future<void> tocar(String texto) async {
      final elemento = find.text(texto).last;
      await tester.ensureVisible(elemento);
      await tester.tap(elemento);
      await tester.pumpAndSettle();
    }

    Future<void> completar(String campo, String valor) async {
      final elemento = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == campo,
      );
      await tester.ensureVisible(elemento);
      await tester.tap(elemento);
      await tester.enterText(elemento, valor);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const BankDoItApp());
    await tester.pumpAndSettle();
    final alias = ApiApuestas.nuevaClave();
    final clave = ApiApuestas.nuevaClave();
    await tocar('Crear cuenta');
    await completar('Alias', alias);
    await completar('Contraseña', clave);
    await completar('Saldo inicial simulado', '1000');
    await tocar('Registrar cuenta');
    await completar('Contraseña', clave);
    await tocar('Entrar');
    expect(find.text(r'$1000'), findsOneWidget);
    for (final (monto, resultado, saldo) in [
      ('100', 'ganada', '1100'),
      ('450', 'anulada', '1100'),
      ('100', 'perdida', '1000'),
    ]) {
      await tocar('+ Registrar apuesta');
      await completar('Buscar equipo', 'chiefs');
      await tester.tap(find.byType(DropdownButtonFormField<Partido>));
      await tester.pumpAndSettle();
      await tocar('Chiefs vs. Eagles');
      await completar('Selección', 'Chiefs');
      await completar('Monto', monto);
      await completar('Cuota', '2.00');
      await tocar('Guardar apuesta');
      if (resultado != 'ganada') {
        if (resultado == 'anulada') {
          expect(find.textContaining(r'por $50.'), findsOneWidget);
          await tocar('Cancelar');
          expect(find.text('Registrar apuesta'), findsOneWidget);
          await tocar('Guardar apuesta');
        }
        await tocar('Confirmar');
      }
      expect(find.text('En curso (1)'), findsOneWidget);
      if (resultado == 'ganada') expect(find.text(r'$900'), findsOneWidget);
      await tocar('Ver detalle');
      await tocar('Marcar como $resultado');
      expect(find.text('En curso (0)'), findsOneWidget);
      expect(find.text('\$$saldo'), findsOneWidget);
      expect(find.text(r'$0'), findsOneWidget);
    }
    await tocar('Ganadas (1)');
    expect(find.text('Chiefs vs. Eagles'), findsOneWidget);
    final acceso = ApiApuestas();
    addTearDown(acceso.cliente.close);
    final cuentaA = await acceso.ingresar(alias, clave);
    final borradoresA = Borradores(cuentaA);
    await borradoresA.abrir();
    // Un borrador en espera de confirmación nunca debe aparecer en la otra cuenta.
    await borradoresA.guardar({
      'clave': ApiApuestas.nuevaClave(),
      'creado': DateTime.now().toIso8601String(),
      'datos': {'seleccion': 'Pendiente de A', 'monto': '10.00'},
      'error': 'Requiere confirmación',
    });
    await cuentaA.salir();
    Future<void> salir(String nombre) async {
      await tester.tap(find.byTooltip('Cerrar sesión ($nombre)'));
      await tester.pumpAndSettle();
      expect(find.text('Iniciar sesión'), findsOneWidget);
    }

    await salir(alias);
    final aliasB = ApiApuestas.nuevaClave();
    await tocar('Crear cuenta');
    await completar('Alias', aliasB);
    await completar('Contraseña', clave);
    await completar('Saldo inicial simulado', '75');
    await tocar('Registrar cuenta');
    await completar('Contraseña', 'incorrecta');
    await tocar('Entrar');
    expect(find.text('Alias o contraseña incorrectos.'), findsOneWidget);
    await completar('Contraseña', clave);
    expect(
      find.text(aliasB),
      findsOneWidget,
      reason: 'El login conserva el alias registrado',
    );
    final contrasena = tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.obscureText),
    );
    expect(
      contrasena.controller!.text == clave,
      isTrue,
      reason: 'El campo conserva la contraseña corregida',
    );
    await tocar('Entrar');
    expect(find.text(r'$75'), findsOneWidget);
    expect(find.text('Ganadas (0)'), findsOneWidget);
    expect(find.textContaining('Pendiente de A'), findsNothing);
    await salir(aliasB);
    await completar('Alias', alias);
    await completar('Contraseña', clave);
    await tocar('Entrar');
    expect(find.text(r'$1000'), findsOneWidget);
    expect(find.text('Ganadas (1)'), findsOneWidget);
    expect(find.textContaining('Pendiente de A'), findsOneWidget);
  });
}
