import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void comprobarHistorial() {
  expect(find.text('Mis apuestas'), findsOneWidget);
  expect(find.text('Dallas vs. Filadelfia'), findsOneWidget);
  final seleccionada = find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.selected == true,
  );
  expect(
    find.descendant(of: seleccionada, matching: find.text('En curso (1)')),
    findsOneWidget,
  );
  for (final (etiqueta, monto) in const [
    ('Saldo disponible', r'$900'),
    ('En juego', r'$100'),
  ]) {
    final columna = find
        .ancestor(of: find.text(etiqueta), matching: find.byType(Column))
        .first;
    expect(
      find.descendant(of: columna, matching: find.text(monto)),
      findsOneWidget,
    );
  }
}

void main() {
  for (final plataforma in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('Recorridos en ${kIsWeb ? "web" : plataforma.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = plataforma;
      try {
        final movil = !kIsWeb && plataforma == TargetPlatform.android;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(movil ? 390 : 1000, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final cliente = MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'bankroll': {'disponible': '900.00', 'en_juego': '100.00'},
                'presupuesto': {
                  'usado_centavos': 10000,
                  'limite_centavos': 50000,
                },
                'partidos': [
                  {
                    'id': 42,
                    'local': 'Dallas',
                    'visitante': 'Filadelfia',
                    'deporte': 'Fútbol americano',
                  },
                ],
                'apuestas': [
                  {
                    'id': 1,
                    'partido_id': 42,
                    'seleccion': 'Dallas',
                    'monto': '100.00',
                    'cuota': '2.00',
                    'estado': 'pendiente',
                  },
                ],
              }),
            ),
            200,
          ),
        );
        await tester.pumpWidget(
          BankDoItApp(
            api: ApiApuestas(
              sesion: const Sesion(3, 'prueba', 'prueba'),
              cliente: cliente,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Mis apuestas'), findsOneWidget);
        expect(
          find.byType(BottomNavigationBar),
          movil ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationRail),
          !kIsWeb && !movil ? findsOneWidget : findsNothing,
        );
        expect(find.byType(DataTable), movil ? findsNothing : findsOneWidget);
        await tester.tap(find.text('Ganadas (0)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('+ Registrar apuesta'));
        await tester.pumpAndSettle();
        expect(find.text('Registrar apuesta'), findsOneWidget);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.text('Sin apuestas ganadas.'), findsOneWidget);
        await tester.tap(find.text('En curso (1)'));
        await tester.pumpAndSettle();
        comprobarHistorial();
        await tester.tap(
          find.text(movil ? 'Dallas vs. Filadelfia' : 'Ver detalle'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Detalle de apuesta'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        comprobarHistorial();
        await tester.tap(find.text('Bankroll').first);
        await tester.pumpAndSettle();
        expect(find.text('Mis apuestas'), findsNothing);
        await tester.tap(find.text('Apuestas').first);
        await tester.pumpAndSettle();
        expect(find.text('Mis apuestas'), findsOneWidget);
        if (!movil && !kIsWeb) {
          for (var i = 0; i < 12; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            final focus = FocusManager.instance.primaryFocus?.context;
            if (focus?.findAncestorWidgetOfExactType<FilledButton>() != null) {
              break;
            }
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('Registrar apuesta'), findsOneWidget);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
    if (kIsWeb) break;
  }
}
