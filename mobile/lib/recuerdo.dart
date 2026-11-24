import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_apuestas.dart';

class SelectorFoto {
  SelectorFoto({required this.usuario, ImagePicker? picker})
    : _picker = picker ?? ImagePicker();
  final int usuario;
  final ImagePicker _picker;
  bool get camara => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  String get _pendiente => 'captura:${ApiApuestas.servidor}:$usuario';
  Future<XFile?> elegir(int id) async {
    if (!camara) return _picker.pickImage(source: ImageSource.gallery);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pendiente, id);
    try {
      return await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
        maxHeight: 3000,
        imageQuality: 90,
      );
    } finally {
      await prefs.remove(_pendiente);
    }
  }

  Future<void> recuperar(ApiApuestas api) async {
    if (!camara) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_pendiente);
    if (id == null) return;
    final respuesta = await _picker.retrieveLostData();
    if (respuesta.exception != null) throw respuesta.exception!;
    final archivo = respuesta.files?.firstOrNull;
    if (archivo != null) await api.foto(id, contenido: await leer(archivo));
    await prefs.remove(_pendiente);
  }

  Future<Uint8List> leer(XFile archivo) async {
    if (await archivo.length() > 10 * 1024 * 1024) {
      throw FalloApi('El tamaño máximo es de 10 MB.');
    }
    return archivo.readAsBytes();
  }
}

class Recuerdo extends StatefulWidget {
  const Recuerdo({
    super.key,
    required this.api,
    required this.apuestaId,
    this.selector,
  });
  final ApiApuestas api;
  final int apuestaId;
  final SelectorFoto? selector;
  @override
  State<Recuerdo> createState() => _RecuerdoState();
}

class _RecuerdoState extends State<Recuerdo> {
  late final selector =
      widget.selector ?? SelectorFoto(usuario: widget.api.usuario);
  Uint8List? imagen;
  String? error;
  bool ocupado = true;
  @override
  void initState() {
    super.initState();
    cargar();
  }

  Future<void> cargar() => ejecutar(() async {
    await selector.recuperar(widget.api);
    imagen = await widget.api.foto(widget.apuestaId);
  });
  Future<void> elegir() => ejecutar(() async {
    final archivo = await selector.elegir(widget.apuestaId);
    if (archivo == null) return;
    final bytes = await selector.leer(archivo);
    await widget.api.foto(widget.apuestaId, contenido: bytes);
    imagen = bytes;
  });
  Future<void> ejecutar(Future<void> Function() accion) async {
    setState(() {
      ocupado = true;
      error = null;
    });
    try {
      await accion();
    } on FalloApi catch (e) {
      error = e.mensaje;
    } on PlatformException catch (e) {
      error = e.code.contains('denied')
          ? 'Permite el acceso a la cámara para tomar la foto.'
          : 'No se pudo abrir la cámara o el selector de imágenes.';
    } catch (_) {
      error = 'No se pudo cargar la imagen. Inténtalo de nuevo.';
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(height: 32),
      Text(
        'Recuerdo fotográfico',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (imagen != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Image.memory(
            imagen!,
            height: 180,
            fit: BoxFit.contain,
            semanticLabel: 'Foto de esta apuesta',
            errorBuilder: (_, e, stack) =>
                const Text('No se pudo mostrar la imagen.'),
          ),
        ),
      if (error != null)
        Row(
          children: [
            Expanded(child: Text(error!)),
            TextButton(
              onPressed: ocupado ? null : cargar,
              child: const Text('Volver a cargar'),
            ),
          ],
        ),
      OutlinedButton.icon(
        onPressed: ocupado ? null : elegir,
        icon: Icon(
          selector.camara ? Icons.photo_camera_outlined : Icons.image_outlined,
        ),
        label: Text(selector.camara ? 'Tomar foto' : 'Seleccionar imagen'),
      ),
    ],
  );
}
