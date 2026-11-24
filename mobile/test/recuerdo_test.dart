import 'dart:convert';

import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/recuerdo.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CamaraDePrueba extends ImagePicker {
  ImageSource? origen;
  XFile? siguiente;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    origen = source;
    return siguiente;
  }
}

void main() {
  for (final plataforma in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'Seleccionar, cancelar y volver a abrir el recuerdo en ${kIsWeb ? 'web' : plataforma.name}',
      (tester) async {
        debugDefaultTargetPlatformOverride = plataforma;
        try {
          SharedPreferences.setMockInitialValues({});
          final fotos = <String, Uint8List>{};
          var cambios = 0;
          final api = ApiApuestas(
            sesion: const Sesion(3, 'prueba', 'prueba'),
            cliente: MockClient((req) async {
              final ruta = req.url.path;
              if (req.method == 'PUT') {
                fotos[ruta] = req.bodyBytes;
                cambios++;
                return http.Response('', 204);
              }
              return fotos[ruta] == null
                  ? http.Response('', 204)
                  : http.Response.bytes(fotos[ruta]!, 200);
            }),
          );
          final picker = CamaraDePrueba();
          final movil = !kIsWeb && plataforma == TargetPlatform.android;
          final boton = find.text(movil ? 'Tomar foto' : 'Seleccionar imagen');
          Future<void> abrir(int id) async {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Recuerdo(
                    key: ValueKey(id),
                    api: api,
                    apuestaId: id,
                    selector: SelectorFoto(
                      usuario: api.usuario,
                      picker: picker,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          await abrir(7);
          await tester.tap(boton);
          await tester.pumpAndSettle();
          expect(
            picker.origen,
            movil ? ImageSource.camera : ImageSource.gallery,
          );
          expect(cambios, 0);
          final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEklEQVR4nGNkaGCAAyYGBmI4ABoEAIhjNExLAAAAAElFTkSuQmCC',
          );
          picker.siguiente = XFile.fromData(
            bytes,
            name: 'foto.png',
            mimeType: 'image/png',
          );
          await tester.tap(boton);
          await tester.pumpAndSettle();
          expect(fotos['/usuarios/3/apuestas/7/recuerdo'], bytes);
          expect(find.byType(Image), findsOneWidget);
          picker.siguiente = null;
          await tester.tap(boton);
          await tester.pumpAndSettle();
          expect(cambios, 1);
          expect(find.byType(Image), findsOneWidget);
          await abrir(8);
          expect(find.byType(Image), findsNothing);
          await abrir(7);
          expect(find.byType(Image), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
    if (kIsWeb) break;
  }
}
