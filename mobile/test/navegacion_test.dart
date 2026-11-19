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
      debugDefaultTargetPlatformOverride = plataforma;
      try {
        final movil = !kIsWeb && plataforma == TargetPlatform.android;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(movil ? 390 : 1000, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const BankDoItApp());
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
