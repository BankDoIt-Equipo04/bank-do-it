import 'package:bankdoit/administracion.dart';
import 'package:bankdoit/api_apuestas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Registra dos partidos en una jornada con la API PostgreSQL', (
    tester,
  ) async {
    const alias = String.fromEnvironment('ADMIN_PRUEBA');
    const password = String.fromEnvironment('CLAVE_PRUEBA');
    final api = await ApiApuestas().ingresar(alias, password);
    expect(api.sesion!.administrador, isTrue);
    await tester.pumpWidget(MaterialApp(home: Administracion(api: api)));
    Future<void> esperar(Finder objetivo) async {
      for (var i = 0; i < 100 && objetivo.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(objetivo, findsWidgets);
    }

    await esperar(find.text(alias));
    await tester.tap(find.text('Jornadas'));
    await tester.pumpAndSettle();
    Future<void> elegir(int campo, String nombre) async {
      final selector = find.byType(DropdownButtonFormField<int>).at(campo);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text(nombre).last);
      await tester.pumpAndSettle();
    }

    await elegir(0, 'Fútbol americano');
    for (final local in ['Chiefs', 'Eagles']) {
      await elegir(1, local);
      await elegir(2, local == 'Chiefs' ? 'Eagles' : 'Chiefs');
      final guardar = find.text('Guardar y agregar otro');
      await tester.ensureVisible(guardar);
      await tester.tap(guardar);
      await tester.pump();
      await esperar(find.text('Partido guardado.'));
    }
    await api.salir();
  });
}
