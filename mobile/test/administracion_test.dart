import 'dart:convert';

import 'package:bankdoit/administracion.dart';
import 'package:bankdoit/api_apuestas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'El administrador consulta cuentas y conserva la jornada entre dos partidos',
    (tester) async {
      final enviados = <Json>[];
      final claves = <String>{};
      final cliente = MockClient((req) async {
        if (req.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'usuario_id': 8,
              'alias': 'prueba',
              'access_token': 'prueba',
              'rol': 'administrador',
            }),
            200,
          );
        }
        expect(req.headers['Authorization'], 'Bearer prueba');
        if (req.url.path == '/admin/cuentas') {
          return http.Response('[{"alias":"raul","estado":"activa"}]', 200);
        }
        if (req.url.path == '/admin/equipos') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'equipos': [
                  for (final i in [1, 2, 3, 4])
                    {
                      'deporte_id': i < 3 ? 1 : 2,
                      'deporte': i < 3 ? 'Fútbol' : 'Fútbol americano',
                      'equipo_id': i,
                      'nombre': 'Equipo $i',
                    },
                ],
              }),
            ),
            200,
          );
        }
        expect(req.url.path, '/admin/partidos');
        claves.add(req.headers['Idempotency-Key']!);
        enviados.add(jsonDecode(req.body));
        return http.Response('{}', 201);
      });
      final api = await ApiApuestas(cliente: cliente)
          .ingresar('prueba', 'prueba');
      expect(api.sesion!.administrador, isTrue);
      await tester.pumpWidget(MaterialApp(home: Administracion(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('raul'), findsOneWidget);
      expect(find.text('activa'), findsOneWidget);
      await tester.tap(find.text('Jornadas'));
      await tester.pumpAndSettle();
      Future<void> elegir(int campo, String opcion) async {
        final selector = find.byType(DropdownButtonFormField<int>).at(campo);
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text(opcion).last);
        await tester.pumpAndSettle();
      }

      await elegir(0, 'Fútbol americano');
      for (final n in [1, 2]) {
        await elegir(1, n == 1 ? 'Equipo 3' : 'Equipo 4');
        await elegir(2, n == 1 ? 'Equipo 4' : 'Equipo 3');
        final guardar = find.text('Guardar y agregar otro');
        await tester.ensureVisible(guardar);
        await tester.tap(guardar);
        await tester.pumpAndSettle();
        expect(find.text('Partido guardado.'), findsOneWidget);
      }
      expect(enviados.map((j) => j['deporte_id']), everyElement(2));
      expect(enviados.first['fecha_hora'], enviados.last['fecha_hora']);
      expect(DateTime.parse(enviados.first['fecha_hora']).isUtc, isTrue);
      expect(enviados.map((j) => j['equipo_local_id']), [3, 4]);
      expect(enviados.map((j) => j['equipo_visitante_id']), [4, 3]);
      expect(claves.length, 2);
    },
  );
}
