import 'package:flutter/material.dart';

import 'api_apuestas.dart';
import 'main.dart' show Marca;

class Acceso extends StatefulWidget {
  const Acceso({super.key, required this.api, required this.alIngresar});
  final ApiApuestas api;
  final ValueChanged<ApiApuestas> alIngresar;
  @override
  State<Acceso> createState() => _AccesoState();
}

class _AccesoState extends State<Acceso> {
  final form = GlobalKey<FormState>();
  final alias = TextEditingController(),
      clave = TextEditingController(),
      saldo = TextEditingController();
  bool registro = false, ocupado = false;
  String? mensaje;

  @override
  void dispose() {
    alias.dispose();
    clave.dispose();
    saldo.dispose();
    super.dispose();
  }

  void cambiar(bool crear, [String? aviso]) {
    form.currentState?.reset();
    clave.clear();
    saldo.clear();
    setState(() {
      registro = crear;
      mensaje = aviso;
    });
  }

  Future<void> enviar() async {
    if (ocupado || !form.currentState!.validate()) return;
    setState(() {
      ocupado = true;
      mensaje = null;
    });
    final nombre = alias.text.trim();
    try {
      if (registro) {
        await widget.api.crearCuenta(
          nombre,
          clave.text,
          decimal(centavos(saldo.text)!),
        );
        if (mounted) {
          cambiar(false, 'Cuenta creada. Inicia sesión con tu contraseña.');
          alias.text = nombre;
        }
      } else {
        final cuenta = await widget.api.ingresar(nombre, clave.text);
        if (mounted) widget.alIngresar(cuenta);
      }
    } on FalloApi catch (e) {
      if (mounted) setState(() => mensaje = e.mensaje);
    } finally {
      if (mounted) setState(() => ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Marca()),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    registro ? 'Crear cuenta' : 'Iniciar sesión',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: alias,
                    enabled: !ocupado,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Alias'),
                    validator: (v) =>
                        RegExp(r'^[a-zA-Z0-9_.-]{3,40}$')
                            .hasMatch(v?.trim() ?? '')
                        ? null
                        : 'Usa de 3 a 40 letras, números, puntos, guiones o guiones bajos.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: clave,
                    enabled: !ocupado,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Contraseña'),
                    onFieldSubmitted: registro ? null : (_) => enviar(),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Escribe tu contraseña.';
                      }
                      if (registro &&
                          (v.runes.length < 8 || v.runes.length > 128)) {
                        return 'Usa entre 8 y 128 caracteres.';
                      }
                      return null;
                    },
                  ),
                  if (registro) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: saldo,
                      enabled: !ocupado,
                      decoration: const InputDecoration(
                        labelText: 'Saldo inicial simulado',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onFieldSubmitted: (_) => enviar(),
                      validator: (v) => centavos(v ?? '') == null
                          ? 'Escribe un saldo de cero o mayor, con hasta dos decimales.'
                          : null,
                    ),
                  ],
                  if (ocupado) const LinearProgressIndicator(),
                  if (mensaje != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(liveRegion: true, child: Text(mensaje!)),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: ocupado ? null : enviar,
                    child: Text(registro ? 'Registrar cuenta' : 'Entrar'),
                  ),
                  TextButton(
                    onPressed: ocupado ? null : () => cambiar(!registro),
                    child: Text(
                      registro ? 'Volver al inicio de sesión' : 'Crear cuenta',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
