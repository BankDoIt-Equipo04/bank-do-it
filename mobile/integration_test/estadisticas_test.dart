import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Estadísticas personales y globales con la API', (tester) async {
    expect(ApiApuestas.servidor, 'http://127.0.0.1:18810');
    final alias = ApiApuestas.nuevaClave(), clave = ApiApuestas.nuevaClave();
    final acceso = ApiApuestas();
    await acceso.crearCuenta(alias, clave, '1000');
    final api = await acceso.ingresar(alias, clave);
    await tester.pumpWidget(BankDoItApp(api: api));
    Future<void> ver(Finder f) async {
      for (int i = 0; i < 150 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(f, findsWidgets);
    }

    await ver(find.text('Mis apuestas'));
    await tester.tap(find.text('Estadísticas').first);
    await ver(find.text('Sin datos'));
    final registro = await api.registrar({
      'partido_id': 101,
      'seleccion': 'América',
      'monto': '100',
      'cuota': '2',
    }, ApiApuestas.nuevaClave());
    await api.resolver(registro['apuesta']['id'], 'ganada');
    await tester.tap(find.byTooltip('Actualizar estadísticas'));
    await ver(find.text(r'Ganancia neta: $100'));
    final lista = find.byType(Scrollable).last;
    for (final etiqueta in ['ROI por deporte', 'Rachas de apuestas']) {
      await tester.scrollUntilVisible(
        find.text(etiqueta),
        150,
        scrollable: lista,
      );
      await tester.ensureVisible(find.text(etiqueta));
      await ver(
        find.byWidgetPredicate(
          (w) => w is Image && w.semanticLabel == etiqueta,
        ),
      );
    }
    await ver(find.text('Mayor racha ganadora: 1 · Mayor racha perdedora: 0'));
    await tester.tap(find.text('Globales'));
    final globales = await api.resultadosGlobales();
    expect(
      globales['total_apuestas'],
      greaterThan(0),
      reason: 'Publica un corte de prueba en MongoDB.',
    );
    await ver(find.text('Apuestas registradas: ${globales['total_apuestas']}'));
    await ver(find.text('Por deporte'));
    await ver(find.text('Por partido'));
    await ver(find.textContaining('Hora de corte (local)'));
    await api.salir();
  });
}
